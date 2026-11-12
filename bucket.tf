locals {
  squid_config = file("${path.module}/config_files/squid.conf")
  whitelist    = join("\n", var.allowed_web_domains)
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

  lifecycle_rule = [
    {
      id      = "abort-incomplete-multipart-uploads"
      enabled = true

      abort_incomplete_multipart_upload_days = 7
    },
  ]
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
