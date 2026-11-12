# IAM role for the Lambda function
resource "aws_iam_role" "lambda" {
  name = "${local.name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "lambda" {
  name        = "${local.name}-lambda-policy"
  policy      = data.aws_iam_policy_document.lambda.json
  description = "Policy for the NAT instance/squid proxy alarm lambda function."
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid = "DescribeRouteTables"
    actions = [
      "ec2:Describe*",
    ]
    resources = [
      "*",
    ]
  }
  statement {
    sid = "AllowUpdatePrivateRouteTables"
    actions = [
      "ec2:CreateRoute",
      "ec2:CreateTags",
      "ec2:ReplaceRoute",
    ]
    resources = [for rt in data.aws_route_table.private : rt.arn]
  }

  statement {
    sid = "DescribeAsg"
    actions = [
      "autoscaling:Describe*",
    ]
    resources = [
      "*"
    ]
  }

  statement {
    sid = "AllowUpdateAsg"
    actions = [
      "autoscaling:CompleteLifecycleAction",
    ]
    resources = local.asg_arns
  }

  dynamic "statement" {
    for_each = var.enable_eip ? ["true"] : []
    content {
      sid = "AssociateEIP"
      actions = [
        "ec2:AssociateAddress",
      ]
      resources = concat(values(aws_eip.nat)[*].arn, [
        "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.this.account_id}:instance/*",
        "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.this.account_id}:network-interface/*",
      ])
    }
  }

  statement {
    sid = "SendMessageDlq"
    actions = [
      "sqs:SendMessage",
    ]
    resources = [
      aws_sqs_queue.dlq.arn,
    ]
  }
}

# Attach the custom policy to the role
resource "aws_iam_role_policy_attachment" "lambda_custom" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda.arn
}

# Create additional policy attachments
resource "aws_iam_role_policy_attachment" "lambda_managed" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda permissions
resource "aws_lambda_permission" "lifecycle_sns" {
  statement_id  = "AllowExecutionFromLifecycleSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.nat.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.asg_lifecycle.arn
}

resource "aws_lambda_permission" "reconcile_schedule" {
  statement_id  = "AllowExecutionFromReconcileSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.nat.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reconcile.arn
}

# Safety net for missed or failed lifecycle notifications: repairs blackholed routes and
# releases instances held by the termination hook.
resource "aws_cloudwatch_event_rule" "reconcile" {
  name                = "${local.name}-reconcile"
  description         = "Periodically reconcile NAT instance routes and EIP."
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "reconcile" {
  rule = aws_cloudwatch_event_rule.reconcile.name
  arn  = aws_lambda_function.nat.arn
}

# Log group for Lambda
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}-lambda"
  retention_in_days = 14
}

# Archive file for Lambda code
data "archive_file" "lambda_source_code" {
  type        = "zip"
  output_path = "${path.module}/source_code.zip"

  source {
    content  = file("${path.module}/src/main.py")
    filename = "lambda_function.py"
  }
}

# Lambda function
resource "aws_lambda_function" "nat" {
  function_name = "${local.name}-lambda"
  architectures = var.architectures
  role          = aws_iam_role.lambda.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.15"
  timeout       = 30

  # One run at a time, so a run acting on an older snapshot cannot move routes back onto an
  # instance that a newer run has already released. Throttled async invocations are retried.
  reserved_concurrent_executions = 1

  filename         = data.archive_file.lambda_source_code.output_path
  source_code_hash = data.archive_file.lambda_source_code.output_base64sha256

  environment {
    variables = {
      TERMINATION_HOOK_NAME = local.termination_hook_name
      NAT_GROUPS = jsonencode({
        for key, group in local.nat_groups : group.asg_name => try(aws_eip.nat[key].id, "")
      })
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.lambda_custom,
    aws_iam_role_policy_attachment.lambda_managed,
  ]
}

# Dead letter queue for failed events
resource "aws_sqs_queue" "dlq" {
  name                    = "${local.name}-lambda-dlq"
  sqs_managed_sse_enabled = true
}
