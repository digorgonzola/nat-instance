# Checks the replacement wiring with mocked providers, so it needs no AWS credentials.
# Runs use apply because most assertions compare ARNs and IDs that are unknown at plan.

mock_provider "aws" {
  # Provider-side ARN validation still runs against mocked values.
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:ap-southeast-2:123456789012:mock" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-southeast-2:123456789012:mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:ap-southeast-2:123456789012:function:mock" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:ap-southeast-2:123456789012:rule/mock" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock" }
  }
  mock_resource "aws_eip" {
    defaults = { arn = "arn:aws:ec2:ap-southeast-2:123456789012:elastic-ip/eipalloc-mock" }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16" }
  }
  mock_data "aws_subnet" {
    defaults = { cidr_block = "10.0.1.0/24" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-12345678" }
  }
  mock_data "aws_region" {
    defaults = { name = "ap-southeast-2", region = "ap-southeast-2" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

variables {
  name               = "t"
  vpc_id             = "vpc-1"
  public_subnet_ids  = ["subnet-pub-a", "subnet-pub-b"]
  private_subnet_ids = ["subnet-priv-a", "subnet-priv-b"]
}

run "asg_launches_replacement_before_terminating" {
  command = apply

  assert {
    condition = (
      aws_autoscaling_group.nat["single"].instance_maintenance_policy[0].min_healthy_percentage == 100 &&
      aws_autoscaling_group.nat["single"].instance_maintenance_policy[0].max_healthy_percentage == 200 &&
      aws_autoscaling_group.nat["single"].instance_refresh[0].preferences[0].min_healthy_percentage == 100
    )
    error_message = "The ASG must launch the replacement before it terminates the old instance."
  }

  assert {
    condition = (
      one(aws_autoscaling_group.nat["single"].initial_lifecycle_hook).lifecycle_transition == "autoscaling:EC2_INSTANCE_LAUNCHING" &&
      one(aws_autoscaling_group.nat["single"].initial_lifecycle_hook).default_result == "ABANDON"
    )
    error_message = "A replacement that never reports ready must be abandoned, not put in service."
  }
}

run "termination_hook_holds_old_instance_until_cutover" {
  command = apply

  assert {
    condition = (
      aws_autoscaling_lifecycle_hook.terminating["single"].lifecycle_transition == "autoscaling:EC2_INSTANCE_TERMINATING" &&
      aws_autoscaling_lifecycle_hook.terminating["single"].default_result == "CONTINUE" &&
      aws_autoscaling_lifecycle_hook.terminating["single"].notification_target_arn == aws_sns_topic.asg_lifecycle.arn
    )
    error_message = "The termination hook must notify the Lambda and continue on timeout."
  }

  assert {
    condition = (
      keys(jsondecode(aws_lambda_function.nat.environment[0].variables["NAT_GROUPS"])) == [aws_autoscaling_group.nat["single"].name] &&
      aws_lambda_function.nat.environment[0].variables["TERMINATION_HOOK_NAME"] == aws_autoscaling_lifecycle_hook.terminating["single"].name
    )
    error_message = "The Lambda must know which ASG and hook to complete."
  }
}

run "schedule_reconciles_every_minute" {
  command = apply

  assert {
    condition = (
      aws_cloudwatch_event_rule.reconcile.schedule_expression == "rate(1 minute)" &&
      aws_cloudwatch_event_target.reconcile.arn == aws_lambda_function.nat.arn &&
      aws_lambda_permission.reconcile_schedule.source_arn == aws_cloudwatch_event_rule.reconcile.arn
    )
    error_message = "The schedule must be allowed to invoke the Lambda every minute."
  }

  assert {
    condition     = aws_lambda_function.nat.reserved_concurrent_executions == 1
    error_message = "Concurrent runs could move routes back onto an instance another run has released."
  }
}

run "without_eip" {
  command = apply

  assert {
    condition = (
      jsondecode(aws_lambda_function.nat.environment[0].variables["NAT_GROUPS"]) == { (aws_autoscaling_group.nat["single"].name) = "" } &&
      output.public_ip == null &&
      output.public_ips == {}
    )
    error_message = "With the EIP disabled the Lambda must not move an EIP."
  }

  assert {
    condition     = !contains([for statement in data.aws_iam_policy_document.lambda.statement : statement.sid], "AssociateEIP")
    error_message = "The Lambda must not be allowed to associate an EIP it does not own."
  }
}

run "with_eip" {
  command = apply

  variables {
    enable_eip = true
  }

  assert {
    condition = (
      jsondecode(aws_lambda_function.nat.environment[0].variables["NAT_GROUPS"]) == { (aws_autoscaling_group.nat["single"].name) = aws_eip.nat["single"].id } &&
      output.public_ip == aws_eip.nat["single"].public_ip
    )
    error_message = "The Lambda must be given the EIP to move to each replacement."
  }

  assert {
    condition = contains(
      flatten([for statement in data.aws_iam_policy_document.lambda.statement : statement.resources if statement.sid == "AssociateEIP"]),
      aws_eip.nat["single"].arn,
    )
    error_message = "The Lambda must be allowed to associate the EIP."
  }
}

run "only_the_instance_decides_it_is_unhealthy" {
  command = apply

  assert {
    condition = contains(
      flatten([for statement in data.aws_iam_policy_document.instance.statement : statement.actions if statement.sid == "AsgLifecycle"]),
      "autoscaling:SetInstanceHealth",
    )
    error_message = "The instance must be allowed to mark itself Unhealthy."
  }

  assert {
    condition = length(setintersection(
      flatten([for statement in data.aws_iam_policy_document.lambda.statement : statement.actions]),
      ["autoscaling:SetInstanceHealth", "autoscaling:StartInstanceRefresh", "autoscaling:TerminateInstanceInAutoScalingGroup"],
    )) == 0
    error_message = "The Lambda only moves traffic; it must not replace instances."
  }
}

run "invalid_spot_allocation_strategy_fails" {
  command = plan

  variables {
    spot_allocation_strategy = "cheapest"
  }

  expect_failures = [var.spot_allocation_strategy]
}

run "invalid_availability_mode_fails" {
  command = plan

  variables {
    availability_mode = "multi"
  }

  expect_failures = [var.availability_mode]
}

run "per_az_runs_one_instance_and_eip_per_az" {
  command = apply

  variables {
    availability_mode = "per_az"
    enable_eip        = true
  }

  override_data {
    target = data.aws_subnet.public["subnet-pub-a"]
    values = { availability_zone = "az-a" }
  }
  override_data {
    target = data.aws_subnet.public["subnet-pub-b"]
    values = { availability_zone = "az-b" }
  }
  override_data {
    target = data.aws_subnet.private["subnet-priv-a"]
    values = { availability_zone = "az-a", cidr_block = "10.0.1.0/24" }
  }
  override_data {
    target = data.aws_subnet.private["subnet-priv-b"]
    values = { availability_zone = "az-b", cidr_block = "10.0.2.0/24" }
  }
  override_data {
    target = data.aws_route_table.private[0]
    values = { id = "rtb-a" }
  }
  override_data {
    target = data.aws_route_table.private[1]
    values = { id = "rtb-b" }
  }

  assert {
    condition = (
      aws_autoscaling_group.nat["az-a"].name == "t-az-a-asg" &&
      aws_autoscaling_group.nat["az-a"].vpc_zone_identifier == toset(["subnet-pub-a"]) &&
      aws_autoscaling_group.nat["az-b"].vpc_zone_identifier == toset(["subnet-pub-b"]) &&
      length(aws_autoscaling_group.nat) == 2
    )
    error_message = "Each AZ must get its own ASG in its own public subnet."
  }

  assert {
    condition = (
      one([for tag in aws_autoscaling_group.nat["az-a"].tag : tag.value if tag.key == "RouteTableIds"]) == "rtb-a" &&
      one([for tag in aws_autoscaling_group.nat["az-b"].tag : tag.value if tag.key == "RouteTableIds"]) == "rtb-b"
    )
    error_message = "Each ASG must serve only the route tables of its own AZ."
  }

  assert {
    condition = (
      length(aws_autoscaling_lifecycle_hook.terminating) == 2 &&
      aws_autoscaling_lifecycle_hook.terminating["az-b"].autoscaling_group_name == aws_autoscaling_group.nat["az-b"].name
    )
    error_message = "Each ASG must hold its terminating instance until the Lambda moves traffic off it."
  }

  assert {
    condition = jsondecode(aws_lambda_function.nat.environment[0].variables["NAT_GROUPS"]) == {
      "t-az-a-asg" = aws_eip.nat["az-a"].id
      "t-az-b-asg" = aws_eip.nat["az-b"].id
    }
    error_message = "The Lambda must be given every ASG and the EIP each one owns."
  }

  assert {
    condition = (
      output.public_ip == null &&
      output.public_ips == { "az-a" = aws_eip.nat["az-a"].public_ip, "az-b" = aws_eip.nat["az-b"].public_ip }
    )
    error_message = "Every EIP must be output for third-party allowlists."
  }

  assert {
    condition = length(flatten(
      [for statement in data.aws_iam_policy_document.instance.statement : statement.resources if statement.sid == "AsgLifecycle"]
    )) == 2
    error_message = "Each instance must be allowed to complete its own ASG's lifecycle actions."
  }
}

run "per_az_rejects_route_table_shared_across_azs" {
  command = plan

  variables {
    availability_mode = "per_az"
  }

  override_data {
    target = data.aws_subnet.public["subnet-pub-a"]
    values = { availability_zone = "az-a" }
  }
  override_data {
    target = data.aws_subnet.public["subnet-pub-b"]
    values = { availability_zone = "az-b" }
  }
  override_data {
    target = data.aws_subnet.private["subnet-priv-a"]
    values = { availability_zone = "az-a", cidr_block = "10.0.1.0/24" }
  }
  override_data {
    target = data.aws_subnet.private["subnet-priv-b"]
    values = { availability_zone = "az-b", cidr_block = "10.0.2.0/24" }
  }
  override_data {
    target = data.aws_route_table.private[0]
    values = { id = "rtb-shared" }
  }
  override_data {
    target = data.aws_route_table.private[1]
    values = { id = "rtb-shared" }
  }

  expect_failures = [aws_autoscaling_group.nat]
}

run "per_az_rejects_az_without_public_subnet" {
  command = plan

  variables {
    availability_mode = "per_az"
  }

  override_data {
    target = data.aws_subnet.public["subnet-pub-a"]
    values = { availability_zone = "az-a" }
  }
  override_data {
    target = data.aws_subnet.public["subnet-pub-b"]
    values = { availability_zone = "az-a" }
  }
  override_data {
    target = data.aws_subnet.private["subnet-priv-a"]
    values = { availability_zone = "az-a", cidr_block = "10.0.1.0/24" }
  }
  override_data {
    target = data.aws_subnet.private["subnet-priv-b"]
    values = { availability_zone = "az-b", cidr_block = "10.0.2.0/24" }
  }

  expect_failures = [aws_autoscaling_group.nat]
}

run "spot_instance_pools_sent_for_lowest_price" {
  command = plan

  variables {
    enable_spot_instance     = true
    spot_allocation_strategy = "lowest-price"
    spot_instance_pools      = 3
  }

  assert {
    condition     = aws_autoscaling_group.nat["single"].mixed_instances_policy[0].instances_distribution[0].spot_instance_pools == 3
    error_message = "spot_instance_pools must be sent when the strategy is lowest-price."
  }
}

# The provider skips 0 and the ASG then reports the AWS default of 2, so a pools value must not reach
# AWS unless spot uses lowest-price. Mock applies fill the unset computed attribute with 0.
run "spot_instance_pools_not_sent_when_spot_disabled" {
  command = apply

  variables {
    spot_allocation_strategy = "lowest-price"
    spot_instance_pools      = 3
  }

  assert {
    condition     = aws_autoscaling_group.nat["single"].mixed_instances_policy[0].instances_distribution[0].spot_instance_pools != 3
    error_message = "spot_instance_pools must be null when spot is disabled."
  }
}

run "spot_instance_pools_not_sent_without_lowest_price" {
  command = apply

  variables {
    enable_spot_instance     = true
    spot_allocation_strategy = "price-capacity-optimized"
    spot_instance_pools      = 3
  }

  assert {
    condition     = aws_autoscaling_group.nat["single"].mixed_instances_policy[0].instances_distribution[0].spot_instance_pools != 3
    error_message = "spot_instance_pools must be null unless the strategy is lowest-price."
  }
}
