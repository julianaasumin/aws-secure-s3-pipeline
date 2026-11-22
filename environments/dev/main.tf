terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.project_name}-${var.environment}-data-${data.aws_caller_identity.current.account_id}"
  queue_name  = "${var.project_name}-${var.environment}-events"
}

# ------------------------------------------------------------------------------
# 1. KMS Customer Managed Key (Registry Module)
# ------------------------------------------------------------------------------
module "kms" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 3.1"

  description             = "KMS key for S3 ingestion bucket and SQS event queue"
  key_usage               = "ENCRYPT_DECRYPT"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  # Allow S3 service to use this KMS key when publishing events to encrypted SQS
  key_statements = [
    {
      sid    = "AllowS3ToUseKMSForSQS"
      effect = "Allow"
      principals = [
        {
          type        = "Service"
          identifiers = ["s3.amazonaws.com"]
        }
      ]
      actions = [
        "kms:GenerateDataKey*",
        "kms:Decrypt"
      ]
      resources = ["*"]
    }
  ]

  aliases = ["${var.project_name}-${var.environment}-key"]
}

# ------------------------------------------------------------------------------
# 2. Amazon SQS Ingestion Queue + Dead-Letter Queue (Registry Module)
# ------------------------------------------------------------------------------
module "event_queue" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "~> 4.2"

  name = local.queue_name

  # Encrypt queue with our KMS CMK
  kms_master_key_id                 = module.kms.key_id
  kms_data_key_reuse_period_seconds = 300

  # Configure Dead-Letter Queue for resilient event processing
  create_dlq            = true
  dlq_name              = "${local.queue_name}-dlq"
  dlq_kms_master_key_id = module.kms.key_id
  redrive_policy = {
    maxReceiveCount = 3
  }

  # Least-privilege policy allowing ONLY our S3 bucket to send messages
  create_queue_policy = true
  queue_policy_statements = {
    s3_publish = {
      sid     = "AllowS3BucketNotifications"
      effect  = "Allow"
      actions = ["sqs:SendMessage"]
      principals = [
        {
          type        = "Service"
          identifiers = ["s3.amazonaws.com"]
        }
      ]
      resources = ["arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${local.queue_name}"]
      conditions = [
        {
          test     = "ArnLike"
          variable = "aws:SourceArn"
          values   = ["arn:aws:s3:::${local.bucket_name}"]
        }
      ]
    }
  }
}

# ------------------------------------------------------------------------------
# 3. Hardened S3 Ingestion Bucket (Registry Module)
# ------------------------------------------------------------------------------
module "s3_ingestion_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.5"

  bucket        = local.bucket_name
  force_destroy = var.environment == "dev" ? true : false

  # Enable versioning for accidental deletion/overwrite protection
  versioning = {
    enabled = true
  }

  # Enforce KMS Customer Managed Key encryption with Bucket Keys (reduces KMS API costs)
  server_side_encryption_configuration = {
    rule = {
      bucket_key_enabled = true
      apply_server_side_encryption_by_default = {
        kms_master_key_id = module.kms.key_arn
        sse_algorithm     = "aws:kms"
      }
    }
  }

  # Zero-Trust Public Access Block
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # Enforce TLS/HTTPS in transit and require KMS encryption headers
  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = true

  # FinOps Lifecycle Rules: Tier older objects & clean up incomplete multipart uploads
  lifecycle_rule = [
    {
      id      = "tier-and-expire-objects"
      enabled = true

      transition = [
        {
          days          = 30
          storage_class = "STANDARD_IA"
        },
        {
          days          = 90
          storage_class = "GLACIER_IR"
        }
      ]

      noncurrent_version_expiration = {
        days = 30
      }

      abort_incomplete_multipart_upload_days = 7
    }
  ]

  depends_on = [module.event_queue]
}

# ------------------------------------------------------------------------------
# 4. S3 Bucket Event Notification -> SQS
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = module.s3_ingestion_bucket.s3_bucket_id

  queue {
    queue_arn     = module.event_queue.queue_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "incoming/"
  }

  depends_on = [module.event_queue]
}