terraform {
  backend "s3" {
    bucket       = "tf-state-s3-pipeline-027252077947"
    key          = "dev/s3-pipeline/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}