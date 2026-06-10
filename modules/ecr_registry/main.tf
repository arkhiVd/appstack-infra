# =============================================================================
# ECR Registry Module
# One private repo per microservice + worker. Free tier: 500 MB/month storage.
# Lifecycle policy expires old images so storage stays under the free limit.
# =============================================================================

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = "${var.project_name}/${each.value}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # dev: allow destroy even with images present

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  tags = {
    Name    = "${var.project_name}-${each.value}"
    Service = each.value
  }
}

# Keep only the N most recent images per repo to stay inside 500 MB free tier.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the ${var.max_image_count} most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
