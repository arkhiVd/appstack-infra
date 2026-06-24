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

variable "alb_dns_name" {
  description = "ALB DNS name to use as the API origin (so SPA + API share one origin, no CORS)"
  type        = string
}

variable "api_path_patterns" {
  description = "Request paths routed to the ALB origin instead of the S3 SPA"
  type        = list(string)
  default = [
    "/auth/*",
    "/catalog/*",
    "/search*",
    "/inventory/*",
    "/orders/*",
    "/notifications*",
    "/suppliers*",
    "/integration/*",
  ]
}
