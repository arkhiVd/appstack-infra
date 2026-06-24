variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "repositories" {
  description = "ECR repo names to create (one per microservice/worker)"
  type        = list(string)
  default = [
    "auth",
    "catalog",
    "search",
    "inventory",
    "orders",
    "notification",
    "suppliers",
    "integration",
    "pdf-ingest-worker",
    "search-sync-worker",
  ]
}

variable "max_image_count" {
  description = "Keep only the N most recent images per repo (lifecycle policy, controls storage cost)"
  type        = number
  default     = 5
}

variable "scan_on_push" {
  description = "Enable ECR image vulnerability scan on push (free basic scanning)"
  type        = bool
  default     = true
}
