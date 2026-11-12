output "state_bucket_name" {
  description = "Name of the S3 bucket created for Terraform remote state"
  value       = module.tf_state_bucket.s3_bucket_id
}

output "github_actions_role_arn" {
  description = "ARN of the IAM role for GitHub Actions OIDC"
  value       = aws_iam_role.github_actions_role.arn
}
