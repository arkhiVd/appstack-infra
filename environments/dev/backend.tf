# Remote state backend — bucket + lock table created by bootstrap/.
terraform {
  backend "s3" {
    bucket         = "appstack-tfstate-b4dbd932"
    key            = "environments/dev/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "appstack-tf-lock"
    encrypt        = true
  }
}
