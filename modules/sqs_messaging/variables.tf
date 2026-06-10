variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "max_receive_count" {
  description = "Deliveries before a message moves to the DLQ"
  type        = number
  default     = 5
}

variable "visibility_timeout" {
  description = "Seconds a message stays invisible after a worker picks it up"
  type        = number
  default     = 300
}
