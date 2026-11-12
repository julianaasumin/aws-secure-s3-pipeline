output "s3_bucket_id" {
  description = "Name of the provisioned S3 ingestion bucket"
  value       = module.s3_ingestion_bucket.s3_bucket_id
}

output "s3_bucket_arn" {
  description = "ARN of the provisioned S3 ingestion bucket"
  value       = module.s3_ingestion_bucket.s3_bucket_arn
}

output "kms_key_arn" {
  description = "ARN of the KMS Customer Managed Key"
  value       = module.kms.key_arn
}

output "sqs_queue_url" {
  description = "URL of the primary SQS ingestion queue"
  value       = module.event_queue.queue_url
}

output "sqs_dlq_url" {
  description = "URL of the SQS Dead-Letter Queue"
  value       = module.event_queue.dead_letter_queue_url
}