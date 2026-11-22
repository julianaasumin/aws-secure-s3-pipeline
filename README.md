# AWS Secure S3 Event-Driven Ingestion Pipeline

[![Terraform PR Checks & Plan](https://github.com/julianaasumin/aws-secure-s3-pipeline/actions/workflows/terraform-pr.yml/badge.svg)](https://github.com/julianaasumin/aws-secure-s3-pipeline/actions/workflows/terraform-pr.yml)[![Terraform Deploy to AWS](https://github.com/julianaasumin/aws-secure-s3-pipeline/actions/workflows/terraform-apply.yml/badge.svg)](https://github.com/julianaasumin/aws-secure-s3-pipeline/actions/workflows/terraform-apply.yml)
An automated, zero-trust event-driven data ingestion pipeline on AWS provisioned with **Terraform** and deployed via **GitHub Actions** using keyless **OIDC authentication**.

---

## Architecture Overview

When files are uploaded to the `incoming/` prefix in Amazon S3, S3 automatically publishes a KMS-encrypted event notification to an Amazon SQS queue for downstream microservice or consumer processing—without sending email alerts (SNS/SES).

```text
[Client / Producer]
       │  (HTTPS / TLS 1.2+ Only)
       ▼
┌─────────────────────────────────────────┐
│  Amazon S3 Ingestion Bucket             │
│  • KMS CMK Encryption (Bucket Keys)     │
│  • Public Access Blocked                │
│  • Versioning & Lifecycle Tiering       │
└──────────────────┬──────────────────────┘
                   │  Event: s3:ObjectCreated:* (prefix: incoming/)
                   ▼
┌─────────────────────────────────────────┐       ┌─────────────────────────────┐
│  Amazon SQS Event Queue                 │──────▶│  Amazon SQS Dead-Letter     │
│  • KMS CMK Encrypted                    │       │  Queue (DLQ)                │
│  • Least-Privilege Bucket Policy        │       │  • Max Receive Count: 3     │
└─────────────────────────────────────────┘       └─────────────────────────────┘
```

### Key Components
* **Bootstrap Infrastructure (`bootstrap/`):** Provisions a versioned, encrypted S3 remote state bucket (`AES256`) and configures an AWS IAM OIDC Identity Provider + IAM Role (`GitHubActions-S3Pipeline-Role`) scoped strictly to this repository using **GitHub ID-pinned subject claims (`@user-id` and `@repo-id`)** to prevent repository-rename takeover attacks.
* **Customer Managed KMS Key (`aws_kms_key`):** Encrypts both S3 objects and SQS messages at rest with automatic annual key rotation enabled.
* **Hardened S3 Ingestion Bucket:** Enforces HTTPS-only transport, blocks all public access, enables object versioning, uses S3 Bucket Keys to minimize KMS API costs, and tiers objects to `STANDARD_IA` (30 days) and `GLACIER_IR` (90 days).
* **Amazon SQS + Dead-Letter Queue (DLQ):** Captures `s3:ObjectCreated:*` events under `incoming/` and routes failed messages to a dedicated DLQ after 3 receive attempts.
* **CI/CD & DevSecOps Workflows (`.github/workflows/`):**
    * **Pull Request Pipeline:** Runs `terraform fmt -check`, `terraform validate`, `TFLint`, and `Checkov` static security analysis, then posts a `terraform plan` preview directly onto the PR.
    * **Deployment Pipeline:** Automatically runs `terraform apply` on merges to `main` using native S3 state locking (`use_lockfile = true`).

---

## Repository Structure

```text
.
├── .github/
│   └── workflows/
│       ├── terraform-pr.yml       # Format, Lint, Checkov scan, and PR Plan comment
│       └── terraform-deploy.yml   # Automated apply on push to main
├── bootstrap/
│   ├── main.tf                    # Remote state S3 bucket, GitHub OIDC provider & IAM role
│   ├── variables.tf               # Bootstrap input variables
│   └── outputs.tf                 # State bucket name and IAM Role ARN outputs
├── environments/
│   └── dev/
│       ├── backend.tf             # S3 remote backend with native .tflock locking
│       ├── main.tf                # KMS, SQS + DLQ, S3 bucket, and event notifications
│       └── variables.tf           # Environment variables with input validation
├── .tflint.hcl                    # TFLint AWS ruleset configuration
└── README.md
```

---

## Prerequisites

* **Terraform** `>= 1.10.0` (required for native S3 state locking via `use_lockfile = true`)
* **AWS CLI** configured with permissions to bootstrap IAM and S3 resources
* **GitHub Repository** with Actions enabled

---

## Setup & Deployment Guide

### 1. Bootstrap Remote State & GitHub OIDC
Initialize and apply the bootstrap stack to create the Terraform state bucket and IAM OIDC role:

```bash
cd bootstrap
terraform init
terraform apply
```

Note both output values:
* `github_actions_role_arn` (`arn:aws:iam::<ACCOUNT_ID>:role/GitHubActions-S3Pipeline-Role`)
* `state_bucket_name` (your generated S3 remote state bucket name)

### 2. Configure Remote Backend & GitHub Variables
1. Update the `bucket` value inside `environments/dev/backend.tf` with your `state_bucket_name` output.
2. In your GitHub repository, navigate to **Settings → Secrets and variables → Actions → Variables** and add:
    * **Name:** `AWS_ROLE_ARN`
    * **Value:** `arn:aws:iam::<ACCOUNT_ID>:role/GitHubActions-S3Pipeline-Role`

### 3. Deploy via Pull Request Workflow
1. Create a feature branch, commit your `backend.tf` and infrastructure changes under `environments/dev/`, and open a Pull Request targeting `main`.
2. Verify all automated checks (`Format, Lint & Security Scan` and `Terraform Plan`) pass.
3. Merge the Pull Request into `main` to trigger `terraform apply`.

---

## Testing the Ingestion Pipeline

Upload a test object to the `incoming/` prefix and poll the SQS queue to verify event delivery:

```bash
# 1. Upload a test file to S3
echo "sample ingestion payload" > test-event.txt
aws s3 cp test-event.txt s3://secure-ingestion-dev-data-<ACCOUNT_ID>/incoming/test-event.txt

# 2. Retrieve the S3 event notification from SQS
QUEUE_URL=\$(aws sqs get-queue-url --queue-name secure-ingestion-dev-events --query QueueUrl --output text)
aws sqs receive-message --queue-url "\$QUEUE_URL" --max-number-of-messages 1

# 3. Remove local test file
rm test-event.txt
```

---

## Cleanup / Teardown

To avoid ongoing AWS charges (such as the monthly KMS Customer Managed Key fee) when finished testing:

```bash
# 1. Destroy the dev ingestion environment
cd environments/dev
terraform destroy

# 2. Destroy bootstrap resources (empty the state bucket first if needed)
cd ../../bootstrap
terraform destroy
```
