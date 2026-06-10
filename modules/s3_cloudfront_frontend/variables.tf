variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "bucket_suffix" {
  description = "Suffix to keep the S3 bucket name globally unique"
  type        = string
  default     = "admin"
}

variable "default_root_object" {
  description = "Default object served at /"
  type        = string
  default     = "index.html"
}

variable "price_class" {
  description = "CloudFront price class (PriceClass_100 = cheapest, US/EU/IN edges)"
  type        = string
  default     = "PriceClass_100"
}
