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
      aws_autoscaling_group.nat.instance_maintenance_policy[0].min_healthy_percentage == 100 &&
      aws_autoscaling_group.nat.instance_maintenance_policy[0].max_healthy_percentage == 200 &&
      aws_autoscaling_group.nat.instance_refresh[0].preferences[0].min_healthy_percentage == 100
    )
    error_message = "The ASG must launch the replacement before it terminates the old instance."
  }

  assert {
    condition = (
      one(aws_autoscaling_group.nat.initial_lifecycle_hook).lifecycle_transition == "autoscaling:EC2_INSTANCE_LAUNCHING" &&
      one(aws_autoscaling_group.nat.initial_lifecycle_hook).default_result == "ABANDON"
    )
    error_message = "A replacement that never reports ready must be abandoned, not put in service."
  }
}

run "termination_hook_holds_old_instance_until_cutover" {
  command = apply

  assert {
    condition = (
      aws_autoscaling_lifecycle_hook.terminating.lifecycle_transition == "autoscaling:EC2_INSTANCE_TERMINATING" &&
      aws_autoscaling_lifecycle_hook.terminating.default_result == "CONTINUE" &&
      aws_autoscaling_lifecycle_hook.terminating.notification_target_arn == aws_sns_topic.asg_lifecycle.arn
    )
    error_message = "The termination hook must notify the Lambda and continue on timeout."
  }

  assert {
    condition = (
      aws_lambda_function.nat.environment[0].variables["ASG_NAME"] == aws_autoscaling_group.nat.name &&
      aws_lambda_function.nat.environment[0].variables["TERMINATION_HOOK_NAME"] == aws_autoscaling_lifecycle_hook.terminating.name
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
}

run "without_eip" {
  command = apply

  assert {
    condition     = aws_lambda_function.nat.environment[0].variables["EIP_ALLOCATION_ID"] == "" && output.public_ip == null
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
      aws_lambda_function.nat.environment[0].variables["EIP_ALLOCATION_ID"] == aws_eip.nat[0].id &&
      output.public_ip == aws_eip.nat[0].public_ip
    )
    error_message = "The Lambda must be given the EIP to move to each replacement."
  }

  assert {
    condition = contains(
      flatten([for statement in data.aws_iam_policy_document.lambda.statement : statement.resources if statement.sid == "AssociateEIP"]),
      aws_eip.nat[0].arn,
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
