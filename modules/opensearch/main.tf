# =============================================================================
# OpenSearch Module — full-text product search tier
# Single t3.small.search node (free tier 12mo), inside the VPC, reachable only
# from the ECS SG on 443. User searches hit OpenSearch, never Postgres.
# search-sync-worker keeps it in sync via the price-sync SQS queue.
# Access is restricted by the VPC security group, so the domain access policy
# can be open ("*") — only ECS can route to it.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_opensearch_domain" "this" {
  domain_name    = "${var.project_name}-search"
  engine_version = var.engine_version

  cluster_config {
    instance_type          = var.instance_type
    instance_count         = 1
    zone_awareness_enabled = false # single node = no multi-AZ (free tier)
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.ebs_volume_size
  }

  vpc_options {
    subnet_ids         = [var.subnet_id]
    security_group_ids = [var.security_group_id]
  }

  node_to_node_encryption {
    enabled = true
  }

  encrypt_at_rest {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  # SG already restricts access to the ECS tier; allow ES actions within VPC.
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = "es:*"
        Resource  = "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${var.project_name}-search/*"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-search"
  }
}
