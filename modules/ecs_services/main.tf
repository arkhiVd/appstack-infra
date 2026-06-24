# =============================================================================
# ECS Services Module — task definitions + services for the 8 microservices and
# 2 workers, on the EC2-backed cluster from ecs_compute.
#
# Web services: bridge networking with a dynamic host port; each gets its own
# ALB target group + a path-based listener rule (mirrors the local nginx routes).
# Workers: no load balancer.
#
# NOTE: 10 tasks at var.task_memory (256 MiB) need ~2.5 GB of host RAM. A single
# t3.micro (1 GB) fits only ~3; set ecs_compute instance_type to t3.medium to run
# the whole stack. db_password/jwt_key are passed as plain env for the demo — move
# to Secrets Manager for anything real.
# =============================================================================

locals {
  # web service -> ALB path rule (priority must be unique on the listener)
  web = {
    auth         = { priority = 10, path = "/auth/*" }
    catalog      = { priority = 20, path = "/catalog/*" }
    search       = { priority = 30, path = "/search*" }
    inventory    = { priority = 40, path = "/inventory/*" }
    orders       = { priority = 50, path = "/orders/*" }
    notification = { priority = 60, path = "/notifications*" }
    suppliers    = { priority = 70, path = "/suppliers*" }
    integration  = { priority = 80, path = "/integration/*" }
  }

  workers = {
    "search-sync-worker" = {}
    "pdf-ingest-worker"  = {}
  }

  all = merge(
    { for k, v in local.web : k => { web = true } },
    { for k, v in local.workers : k => { web = false } },
  )

  container_port = 8080

  # Injected into every container. AWS__ServiceUrl is intentionally absent so the
  # SDK talks to real SQS/S3; AWS_REGION lets the default credential/region chain
  # resolve (task-role creds come from the ECS agent).
  env = [
    { name = "ConnectionStrings__Postgres", value = "Host=${var.db_host};Port=5432;Database=${var.db_name};Username=${var.db_username};Password=${var.db_password}" },
    { name = "Jwt__Key", value = var.jwt_key },
    { name = "Jwt__Issuer", value = var.jwt_issuer },
    { name = "OpenSearch__Url", value = "https://${var.opensearch_endpoint}" },
    { name = "OpenSearch__Index", value = "parts" },
    { name = "AWS__Region", value = var.region },
    { name = "AWS_REGION", value = var.region },
    { name = "Queues__PriceSync", value = var.price_sync_queue_name },
    { name = "Queues__PdfIngest", value = var.pdf_ingest_queue_name },
    { name = "Storage__PdfBucket", value = var.pdf_bucket_name },
  ]
}

# -----------------------------------------------------------------------------
# Task role — shared by all services. The sqs_messaging worker policy already
# grants consume on both queues, publish to price-sync, and read the PDF bucket,
# which covers publishers, consumers, and workers alike.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "task" {
  name = "${var.project_name}-ecs-app-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_worker" {
  role       = aws_iam_role.task.name
  policy_arn = var.worker_policy_arn
}

# catalog writes bulk-import uploads into the PDF/CSV ingest bucket.
resource "aws_iam_role_policy" "task_s3_put" {
  name = "pdf-bucket-put"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "arn:aws:s3:::${var.pdf_bucket_name}/*"
    }]
  })
}

# -----------------------------------------------------------------------------
# CloudWatch log group per service
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "this" {
  for_each          = local.all
  name              = "/ecs/${var.project_name}/${each.key}"
  retention_in_days = var.log_retention_days
}

# -----------------------------------------------------------------------------
# Task definitions
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "this" {
  for_each                 = local.all
  family                   = "${var.project_name}-${each.key}"
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = aws_iam_role.task.arn
  cpu                      = "128"
  memory                   = tostring(var.task_memory)

  container_definitions = jsonencode([
    merge(
      {
        name              = each.key
        image             = "${var.ecr_repository_urls[each.key]}:${var.image_tag}"
        essential         = true
        memoryReservation = 128
        environment       = local.env
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = aws_cloudwatch_log_group.this[each.key].name
            "awslogs-region"        = var.region
            "awslogs-stream-prefix" = "ecs"
          }
        }
      },
      each.value.web ? {
        portMappings = [{ containerPort = local.container_port, hostPort = 0, protocol = "tcp" }]
      } : {}
    )
  ])
}

# -----------------------------------------------------------------------------
# Per-web-service target group + path rule on the shared ALB listener
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "this" {
  for_each    = local.web
  name        = "${var.project_name}-${each.key}-tg"
  port        = local.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.project_name}-${each.key}-tg" }
}

resource "aws_lb_listener_rule" "this" {
  for_each     = local.web
  listener_arn = var.alb_listener_arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  condition {
    path_pattern {
      values = [each.value.path]
    }
  }
}

# -----------------------------------------------------------------------------
# Services
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "this" {
  for_each        = local.all
  name            = "${var.project_name}-${each.key}"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this[each.key].arn
  desired_count   = var.desired_count
  launch_type     = "EC2"

  # Allow single-host rolling deploys (stop old task to free the dynamic port).
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  health_check_grace_period_seconds = each.value.web ? 60 : null

  # Spread tasks across the EC2 hosts so 10 tasks don't pile onto one t3.micro.
  ordered_placement_strategy {
    type  = "spread"
    field = "instanceId"
  }

  dynamic "load_balancer" {
    for_each = each.value.web ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.this[each.key].arn
      container_name   = each.key
      container_port   = local.container_port
    }
  }

  depends_on = [aws_lb_listener_rule.this]
}

# -----------------------------------------------------------------------------
# One-shot DB migration task (no service). Applies the schema/seed SQL to RDS
# from inside the VPC; the CI workflow runs it once after apply, before rollout.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "migrate" {
  name              = "/ecs/${var.project_name}/db-migrate"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_task_definition" "migrate" {
  family                   = "${var.project_name}-db-migrate"
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  execution_role_arn       = var.task_execution_role_arn
  cpu                      = "128"
  memory                   = "256"

  container_definitions = jsonencode([{
    name              = "db-migrate"
    image             = "${var.ecr_repository_urls["db-migrate"]}:${var.image_tag}"
    essential         = true
    memoryReservation = 128
    environment = [
      { name = "PGHOST", value = var.db_host },
      { name = "PGPORT", value = "5432" },
      { name = "PGUSER", value = var.db_username },
      { name = "PGPASSWORD", value = var.db_password },
      { name = "PGDATABASE", value = var.db_name },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.migrate.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}
