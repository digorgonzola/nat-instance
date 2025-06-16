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
  description = "Policy for the Squid proxy alarm lambda function."
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid = "GetBucketTags"
    actions = [
      "s3:GetBucketTagging",
    ]
    resources = [
      module.config_bucket.s3_bucket_arn
    ]
  }
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
      "autoscaling:SetInstanceHealth",
      "autoscaling:StartInstanceRefresh",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
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
    sid = "AllowDescribeCloudwatchAlarm"
    actions = [
      "cloudwatch:Describe*",
    ]
    resources = [
      "arn:aws:cloudwatch:${data.aws_region.current.name}:${data.aws_caller_identity.this.account_id}:alarm:${local.name}-alarm",
    ]
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
resource "aws_lambda_permission" "alarm_sns" {
  statement_id  = "AllowExecutionFromAlarmSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.squid.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alarm.arn
}

resource "aws_lambda_permission" "lifecycle_sns" {
  statement_id  = "AllowExecutionFromLifecycleSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.squid.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.asg_lifecycle.arn
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
resource "aws_lambda_function" "squid" {
  function_name = "${local.name}-lambda"
  architectures = var.architectures
  role          = aws_iam_role.lambda.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.13"
  timeout       = 30

  filename         = data.archive_file.lambda_source_code.output_path
  source_code_hash = data.archive_file.lambda_source_code.output_base64sha256

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
