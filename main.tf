locals {
  name                = var.name
  lifecycle_hook_name = "${local.name}-hook"
  userdata = templatefile("${path.module}/templates/cloud-init.tpl", {
    architecture        = local.architecture
    aws_region          = data.aws_region.current.name
    eip_allocation_id   = var.enable_eip ? aws_eip.squid[0].id : ""
    lifecycle_hook_name = local.lifecycle_hook_name
    s3_bucket           = module.config_bucket.s3_bucket_id
  })
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/squid-proxy/access.log"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "cache" {
  name              = "/squid-proxy/cache.log"
  retention_in_days = 14
}

resource "aws_security_group" "instance" {
  name        = "${local.name}-instance-sg"
  description = "Security group for Squid proxy instances."
  vpc_id      = data.aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-instance-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
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

# Custom IAM policy for the Squid instances
resource "aws_iam_policy" "instance" {
  name        = "${local.name}-instance-policy"
  description = "Policy for the Squid proxy instances."
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
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.this.account_id}:instance/*"
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
        "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.this.account_id}:elastic-ip/*",
        "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.this.account_id}:network-interface/*",
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
        data.aws_region.current.name,
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

resource "aws_launch_template" "squid" {
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
    tags = {
      UserDataHash = md5(local.userdata)
    }
  }

  lifecycle {
    ignore_changes = [
      image_id,
    ]
  }
}

resource "aws_eip" "squid" {
  count = var.enable_eip ? 1 : 0

  tags = {
    Name = "${local.name}-eip"
  }
}

resource "aws_autoscaling_group" "squid" {
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
    id      = aws_launch_template.squid.id
    version = aws_launch_template.squid.latest_version
  }

  tag {
    key                 = "Name"
    propagate_at_launch = true
    value               = "${local.name}-instance"
  }

  tag {
    key                 = "RouteTableIds"
    propagate_at_launch = false
    value               = join(",", data.aws_route_table.private[*].id)
  }

  depends_on = [
    module.squid_config,
    module.whitelist,
    aws_cloudwatch_log_group.access,
    aws_cloudwatch_log_group.cache,
    aws_eip.squid,
    aws_lambda_function.squid,
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
  endpoint  = aws_lambda_function.squid.arn
}
