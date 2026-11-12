locals {
  name                  = var.name
  asg_name              = "${local.name}-asg"
  lifecycle_hook_name   = "${local.name}-hook"
  termination_hook_name = "${local.name}-termination-hook"
  default_egress_rules = {
    egress_http = {
      cidr_ipv4   = "0.0.0.0/0"
      description = "Allow outbound HTTP traffic."
      ip_protocol = "tcp"
      from_port   = 80
      to_port     = 80
    },
    egress_https = {
      cidr_ipv4   = "0.0.0.0/0"
      description = "Allow outbound HTTPS traffic."
      ip_protocol = "tcp"
      from_port   = 443
      to_port     = 443
    },
  }
  default_ingress_rules = { for key, value in data.aws_subnet.private :
    "ingress-${value.id}" => {
      cidr_ipv4   = value.cidr_block
      description = "Allow inbound traffic from private subnet ${value.id}."
      ip_protocol = "-1"
      from_port   = -1
      to_port     = -1
    }
  }
  userdata = templatefile("${path.module}/templates/cloud-init.tpl", {
    architecture        = local.architecture
    aws_region          = data.aws_region.current.region
    lifecycle_hook_name = local.lifecycle_hook_name
    s3_bucket           = module.config_bucket.s3_bucket_id
    vpc_cidr_block      = data.aws_vpc.this.cidr_block
  })
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/nat-instance/access.log"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "cache" {
  name              = "/nat-instance/cache.log"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "iptables" {
  name              = "/nat-instance/iptables.log"
  retention_in_days = 14
}

# Health check and squid config sync results from the instance.
resource "aws_cloudwatch_log_group" "instance" {
  name              = "/nat-instance/instance.log"
  retention_in_days = 14
}

resource "aws_security_group" "instance" {
  name        = "${local.name}-instance-sg"
  description = "Security group for NAT instance/squid proxy instances."
  vpc_id      = data.aws_vpc.this.id

  tags = {
    Name = "${local.name}-instance-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "this" {
  for_each = merge(local.default_egress_rules, var.additional_egress_rules)

  cidr_ipv4                    = try(each.value.cidr_ipv4, null)
  cidr_ipv6                    = try(each.value.cidr_ipv6, null)
  description                  = try(each.value.description, null)
  from_port                    = try(each.value.from_port, null)
  ip_protocol                  = each.value.ip_protocol
  prefix_list_id               = try(each.value.prefix_list_id, null)
  referenced_security_group_id = try(each.value.referenced_security_group_id, null)
  security_group_id            = aws_security_group.instance.id
  tags = merge(
    var.tags,
    { "Name" = coalesce(try(each.value.name, null), "${aws_security_group.instance.name}-${each.key}") },
  )
  to_port = try(coalesce(each.value.to_port, each.value.from_port), null)
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = merge(local.default_ingress_rules, var.additional_ingress_rules)

  cidr_ipv4                    = try(each.value.cidr_ipv4, null)
  cidr_ipv6                    = try(each.value.cidr_ipv6, null)
  description                  = try(each.value.description, null)
  from_port                    = try(each.value.from_port, null)
  ip_protocol                  = each.value.ip_protocol
  prefix_list_id               = try(each.value.prefix_list_id, null)
  referenced_security_group_id = try(each.value.referenced_security_group_id, null)
  security_group_id            = aws_security_group.instance.id
  tags = merge(
    var.tags,
    { "Name" = coalesce(try(each.value.name, null), "${aws_security_group.instance.name}-${each.key}") },
  )
  to_port = try(coalesce(each.value.to_port, each.value.from_port), null)
}

resource "aws_iam_role" "instance" {
  name = "${local.name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

# Custom IAM policy for the NAT instance/squid instance
resource "aws_iam_policy" "instance" {
  name        = "${local.name}-instance-policy"
  description = "Policy for the NAT instance/squid proxy instances."
  policy      = data.aws_iam_policy_document.instance.json
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid = "ssm"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ec2messages"
    actions = [
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]
    resources = ["*"]
  }

  statement {
    sid = "EC2"
    actions = [
      "ec2:DescribeInstances",
      "ec2:ModifyInstanceAttribute",
    ]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.this.account_id}:instance/*"
    ]
  }

  statement {
    sid = "AsgLifecycle"
    actions = [
      "autoscaling:CompleteLifecycleAction",
      "autoscaling:SetInstanceHealth",
    ]
    resources = [
      join(":", [
        "arn:aws:autoscaling",
        data.aws_region.current.region,
        data.aws_caller_identity.this.account_id,
        "autoScalingGroup:*:autoScalingGroupName/${local.name}-asg",
      ]),
    ]
  }

  statement {
    sid = "S3"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:ListObject",
    ]
    resources = [
      module.config_bucket.s3_bucket_arn,
      "${module.config_bucket.s3_bucket_arn}*"
    ]
  }
}

# Attach the custom policy to the role
resource "aws_iam_role_policy_attachment" "custom" {
  role       = aws_iam_role.instance.name
  policy_arn = aws_iam_policy.instance.arn
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance-profile"
  role = aws_iam_role.instance.name
}

resource "aws_launch_template" "nat" {
  name          = "${local.name}-launchtemplate"
  image_id      = data.aws_ami.amazon_linux_2.id
  instance_type = var.instance_type

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 8
      volume_type = "gp3"
      encrypted   = "true"
    }
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.instance.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = var.detailed_monitoring
  }

  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups = [
      aws_security_group.instance.id,
    ]
  }

  # Compressed to stay under the 16 KB user data limit; cloud-init detects gzip.
  user_data = base64gzip(local.userdata)

  tag_specifications {
    resource_type = "instance"
    tags = merge({
      UserDataHash = md5(local.userdata)
    }, var.tags)
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge({
      Name = "${local.name}-volume"
    }, var.tags)
  }
}

resource "aws_eip" "nat" {
  count = var.enable_eip ? 1 : 0

  tags = {
    Name = "${local.name}-eip"
  }
}

resource "aws_autoscaling_group" "nat" {
  name                      = local.asg_name
  max_size                  = 1
  min_size                  = 1
  health_check_grace_period = 300
  health_check_type         = "EC2"
  default_instance_warmup   = 30
  capacity_rebalance        = coalesce(var.capacity_rebalance, var.enable_spot_instance)
  vpc_zone_identifier       = var.public_subnet_ids

  initial_lifecycle_hook {
    name                    = local.lifecycle_hook_name
    lifecycle_transition    = "autoscaling:EC2_INSTANCE_LAUNCHING"
    heartbeat_timeout       = 300
    default_result          = "ABANDON"
    notification_target_arn = aws_sns_topic.asg_lifecycle.arn
    role_arn                = aws_iam_role.asg_lifecycle.arn
  }

  instance_maintenance_policy {
    max_healthy_percentage = 200
    min_healthy_percentage = 100
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
    }
  }

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = coalesce(var.on_demand_base_capacity, var.enable_spot_instance ? 0 : 1)
      on_demand_percentage_above_base_capacity = coalesce(var.on_demand_percentage_above_base_capacity, var.enable_spot_instance ? 0 : 100)
      spot_allocation_strategy                 = var.enable_spot_instance ? var.spot_allocation_strategy : null
      # AWS applies lowest-price with 2 pools when no pools value is sent. The provider never sends 0,
      # so a 0 in config leaves a permanent 2 -> 0 diff; send null instead to keep the AWS value.
      spot_instance_pools = var.enable_spot_instance && var.spot_allocation_strategy == "lowest-price" && var.spot_instance_pools != 0 ? var.spot_instance_pools : null
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.nat.id
        version            = aws_launch_template.nat.latest_version
      }

      dynamic "override" {
        for_each = length(var.instance_type_overrides) > 0 ? var.instance_type_overrides : [var.instance_type]
        content {
          instance_type = override.value
        }
      }
    }
  }

  tag {
    key                 = "Name"
    propagate_at_launch = true
    value               = "${local.name}-instance"
  }

  tag {
    key                 = "RouteTableIds"
    propagate_at_launch = false
    value               = join(",", distinct(data.aws_route_table.private[*].id))
  }

  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      propagate_at_launch = false
      value               = tag.value
    }
  }

  depends_on = [
    module.squid_config,
    module.whitelist,
    aws_cloudwatch_log_group.access,
    aws_cloudwatch_log_group.cache,
    aws_cloudwatch_log_group.iptables,
    aws_cloudwatch_log_group.instance,
    aws_eip.nat,
    aws_lambda_function.nat,
    aws_iam_role_policy_attachment.cloudwatch,
    aws_iam_role_policy_attachment.custom,
    aws_iam_role_policy.asg_lifecycle,
  ]
}

# Holds a terminating instance until the Lambda has moved the routes and EIP to a healthy
# replacement. Managed outside initial_lifecycle_hook so it is also added to existing ASGs.
resource "aws_autoscaling_lifecycle_hook" "terminating" {
  name                    = local.termination_hook_name
  autoscaling_group_name  = aws_autoscaling_group.nat.name
  lifecycle_transition    = "autoscaling:EC2_INSTANCE_TERMINATING"
  heartbeat_timeout       = 600
  default_result          = "CONTINUE"
  notification_target_arn = aws_sns_topic.asg_lifecycle.arn
  role_arn                = aws_iam_role.asg_lifecycle.arn

  depends_on = [
    aws_sns_topic_subscription.lambda_sub,
    aws_iam_role_policy.asg_lifecycle,
  ]
}

# IAM role for ASG lifecycle hook
resource "aws_iam_role" "asg_lifecycle" {
  name = "${local.name}-asg-lifecycle-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "autoscaling.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "asg_lifecycle" {
  name = "${local.name}-asg-lifecycle-policy"
  role = aws_iam_role.asg_lifecycle.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.asg_lifecycle.arn
      }
    ]
  })
}

# SNS topic for lifecycle hook
resource "aws_sns_topic" "asg_lifecycle" {
  name              = "${local.name}-asg-lifecycle-topic"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "lambda_sub" {
  topic_arn = aws_sns_topic.asg_lifecycle.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.nat.arn
}
