# =============================================================================
# S3 + CloudFront Frontend Module (Angular admin panel)
# Private S3 bucket (no public access) served via CloudFront with Origin
# Access Control (OAC). CloudFront default cert = HTTPS for free.
# SPA routing: 403/404 -> /index.html so Angular client routing works.
# =============================================================================

data "aws_caller_identity" "current" {}

# Random suffix keeps the bucket name globally unique
resource "random_id" "bucket" {
  byte_length = 4
}

# -----------------------------------------------------------------------------
# Private S3 bucket — origin for the static site
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "site" {
  bucket = "${var.project_name}-${var.bucket_suffix}-${random_id.bucket.hex}"

  tags = {
    Name = "${var.project_name}-admin-panel"
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id
  versioning_configuration {
    status = "Enabled"
  }
}

# -----------------------------------------------------------------------------
# CloudFront Origin Access Control — modern replacement for OAI
# -----------------------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.project_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# -----------------------------------------------------------------------------
# CloudFront distribution
# -----------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = var.default_root_object
  price_class         = var.price_class
  comment             = "${var.project_name} admin panel"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-${aws_s3_bucket.site.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  # ALB origin for the API. Serving the SPA and the API from the SAME CloudFront
  # domain means the browser makes same-origin calls -> no CORS. The ALB has no
  # TLS listener, so CloudFront talks to it over HTTP (viewer side is still HTTPS).
  origin {
    domain_name = var.alb_dns_name
    origin_id   = "alb-api"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Default behavior -> S3 (the SPA, static).
  default_cache_behavior {
    target_origin_id       = "s3-${aws_s3_bucket.site.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]

    # AWS managed "CachingOptimized" policy
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # API paths -> ALB origin. CachingDisabled + AllViewer so auth headers, query
  # strings and request bodies pass through untouched.
  dynamic "ordered_cache_behavior" {
    for_each = var.api_path_patterns
    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = "alb-api"
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eb8c4dc7" # AllViewer
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "${var.project_name}-admin-cf"
  }
}

# -----------------------------------------------------------------------------
# Bucket policy — allow ONLY this CloudFront distribution to read objects
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "site" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json
}
