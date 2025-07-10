locals {
  squid_config = file("${path.module}/config_files/squid.conf")
  whitelist    = join("\n", var.allowed_domains)
}

module "config_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 5.0"
  bucket  = "${local.name}-config"
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }
  tags = {
    AutoScalingGroupName = "${local.name}-asg"
  }
  versioning = {
    enabled = true
  }
}

module "squid_config" {
  source  = "terraform-aws-modules/s3-bucket/aws//modules/object"
  version = "~> 5.0"

  bucket      = module.config_bucket.s3_bucket_id
  key         = "squid.conf"
  content     = local.squid_config
  source_hash = md5(local.squid_config)
}

module "whitelist" {
  source  = "terraform-aws-modules/s3-bucket/aws//modules/object"
  version = "~> 5.0"

  bucket      = module.config_bucket.s3_bucket_id
  key         = "whitelist.txt"
  content     = local.whitelist
  source_hash = md5(local.whitelist)
}

# Permission for S3 to invoke Lambda - also only AFTER first run
resource "aws_lambda_permission" "s3_trigger" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.squid.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = module.config_bucket.s3_bucket_arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = module.config_bucket.s3_bucket_id

  lambda_function {
    lambda_function_arn = aws_lambda_function.squid.arn
    events = [
      "s3:ObjectCreated:*",
    ]
  }
  depends_on = [
    aws_lambda_permission.s3_trigger,
  ]
}
