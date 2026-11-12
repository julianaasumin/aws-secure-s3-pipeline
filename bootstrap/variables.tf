variable "aws_region" {
  description = "AWS region for bootstrap resources"
  type        = string
  default     = "us-east-1"
}

variable "github_org_or_user" {
  description = "Your GitHub username or organization name"
  type        = string
  default     = "julianaasumin"
}

variable "github_repo" {
  description = "The name of the GitHub repository"
  type        = string
  default     = "aws-secure-s3-pipeline"
}
