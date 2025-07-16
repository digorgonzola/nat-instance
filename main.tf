locals {
  name                = var.name
  lifecycle_hook_name = "${local.name}-hook"
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
  default_ingress_rules = {
    ingress_all = {
      cidr_ipv4   = "0.0.0.0/0"
      description = "Allow all inbound traffic."
      ip_protocol = "-1"
      from_port   = -1
      to_port     = -1
    }
  }
  userdata = templatefile("${path.module}/templates/cloud-init.tpl", {
    architecture        = local.architecture
    aws_region          = data.aws_region.current.region
    eip_allocation_id   = var.enable_eip ? aws_eip.nat[0].id : ""
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
  for_each          = merge(local.default_egress_rules, var.additional_egress_rules)
  cidr_ipv4         = each.value.cidr_ipv4
  description       = each.value.description
  from_port         = each.value.from_port
  ip_protocol       = each.value.ip_protocol
  security_group_id = aws_security_group.instance.id
  to_port           = each.value.to_port
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each          = merge(local.default_ingress_rules, var.additional_ingress_rules)
  cidr_ipv4         = each.value.cidr_ipv4
  description       = each.value.description
  from_port         = each.value.from_port
  ip_protocol       = each.value.ip_protocol
  security_group_id = aws_security_group.instance.id
  to_port           = each.value.to_port
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
    sid = "EC2"
    actions = [
      "ec2:DescribeInstances",
      "ec2:ModifyInstanceAttribute",
    ]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.this.account_id}:instance/*"
    ]
  }

  dynamic "statement" {
    for_each = var.enable_eip ? ["true"] : []
    content {
      sid = "DescribeEIP"
      actions = [
        "ec2:AssociateAddress",
        "ec2:DescribeAddresses",
      ]
      resources = [
        "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.this.account_id}:elastic-ip/*",
        "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.this.account_id}:network-interface/*",
      ]
    }
  }

  statement {
    sid = "AsgLifecycle"
    actions = [
      "autoscaling:CompleteLifecycleAction",
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

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
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

  user_data = base64encode(local.userdata)

  tag_specifications {
    resource_type = "instance"
    tags = merge({
      UserDataHash = md5(local.userdata)
    }, var.tags)
  }

  lifecycle {
    ignore_changes = [
      image_id,
    ]
  }
}

resource "aws_eip" "nat" {
  count = var.enable_eip ? 1 : 0

  tags = {
    Name = "${local.name}-eip"
  }
}

resource "aws_autoscaling_group" "nat" {
  name                      = "${local.name}-asg"
  max_size                  = 1
  min_size                  = 1
  health_check_grace_period = 300
  health_check_type         = "EC2"
  default_instance_warmup   = 30
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

  launch_template {
    id      = aws_launch_template.nat.id
    version = aws_launch_template.nat.latest_version
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
    aws_eip.nat,
    aws_lambda_function.nat,
    aws_iam_role_policy_attachment.cloudwatch,
    aws_iam_role_policy_attachment.custom,
    aws_iam_role_policy_attachment.ssm,
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
