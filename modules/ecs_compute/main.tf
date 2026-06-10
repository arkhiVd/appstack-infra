# =============================================================================
# ECS Compute Module — ECS-on-EC2 (free tier, not Fargate)
# Single t3.micro host in a public subnet joins the cluster via user_data.
# ALB fronts the cluster; services attach to the listener later.
# =============================================================================

# ECS-optimized Amazon Linux 2023 AMI (latest, via SSM public parameter)
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

# -----------------------------------------------------------------------------
# ECS cluster
# -----------------------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # CloudWatch Container Insights costs extra; off for free tier
  }

  tags = {
    Name = "${var.project_name}-cluster"
  }
}

# -----------------------------------------------------------------------------
# Launch template for ECS EC2 host
# user_data registers the instance into our cluster.
# -----------------------------------------------------------------------------
resource "aws_launch_template" "ecs" {
  name_prefix   = "${var.project_name}-ecs-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ecs_instance.arn
  }

  vpc_security_group_ids = [var.ecs_sg_id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.this.name}" >> /etc/ecs/ecs.config
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-ecs-host"
    }
  }

  tags = {
    Name = "${var.project_name}-ecs-lt"
  }
}

# -----------------------------------------------------------------------------
# Auto Scaling Group — public subnets, gets public IP (no NAT needed)
# -----------------------------------------------------------------------------
resource "aws_autoscaling_group" "ecs" {
  name                = "${var.project_name}-ecs-asg"
  vpc_zone_identifier = var.public_subnet_ids
  desired_capacity    = var.asg_desired
  min_size            = var.asg_desired
  max_size            = var.asg_max

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-ecs-host"
    propagate_at_launch = true
  }

  # Required so the ASG-backed capacity provider can manage instances
  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }
}

# -----------------------------------------------------------------------------
# Application Load Balancer (free tier: 750 hrs + 15 LCU for 12 months)
# -----------------------------------------------------------------------------
resource "aws_lb" "this" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# Default target group — microservice services attach here / add path rules later
resource "aws_lb_target_group" "default" {
  name        = "${var.project_name}-default-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.project_name}-default-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # No service yet — return a placeholder until microservices register.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "appstack ALB up - no service attached yet"
      status_code  = "200"
    }
  }
}
