terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "your-terraform-state-bucket"
    key    = "cloud-log-analytics/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# ──────────────────────────────────────────
# VPC
# ──────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]
  database_subnets = ["10.0.21.0/24", "10.0.22.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  tags = local.tags
}

# ──────────────────────────────────────────
# Security Groups
# ──────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "ALB: allow HTTP/HTTPS inbound from internet"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP from internet"
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from internet"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-alb-sg" })
}

resource "aws_security_group" "ec2" {
  name        = "${var.project}-ec2-sg"
  description = "EC2: allow traffic only from ALB on app port"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "App traffic from ALB only"
  }
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    cidr_blocks     = [var.bastion_cidr]
    description     = "SSH from bastion only"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-ec2-sg" })
}

resource "aws_security_group" "rds" {
  name        = "${var.project}-rds-sg"
  description = "RDS: allow PostgreSQL only from EC2 SG"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
    description     = "PostgreSQL from EC2 only"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-rds-sg" })
}

# ──────────────────────────────────────────
# RDS PostgreSQL (Multi-AZ)
# ──────────────────────────────────────────
resource "aws_db_instance" "main" {
  identifier              = "${var.project}-postgres"
  engine                  = "postgres"
  engine_version          = "15.4"
  instance_class          = "db.t3.medium"
  allocated_storage       = 50
  max_allocated_storage   = 200
  storage_encrypted       = true
  storage_type            = "gp3"

  db_name  = "loganalytics"
  username = var.db_username
  password = var.db_password

  multi_az               = true
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  backup_retention_period   = 7
  backup_window             = "03:00-04:00"
  maintenance_window        = "mon:04:00-mon:05:00"
  auto_minor_version_upgrade = true
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project}-final-snapshot"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = merge(local.tags, { Name = "${var.project}-postgres" })
}

# ──────────────────────────────────────────
# Application Load Balancer
# ──────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = true
  enable_http2               = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb-access-logs"
    enabled = true
  }

  tags = local.tags
}

resource "aws_lb_target_group" "api" {
  name        = "${var.project}-api-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  stickiness {
    type    = "lb_cookie"
    enabled = false
  }

  tags = local.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ──────────────────────────────────────────
# Launch Template + Auto Scaling Group
# ──────────────────────────────────────────
resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.ec2.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2 enforced
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    ecr_registry   = var.ecr_registry
    db_host        = aws_db_instance.main.address
    db_name        = "loganalytics"
    db_username    = var.db_username
    aws_region     = var.aws_region
    project        = var.project
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.tags, { Name = "${var.project}-ec2" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  name                = "${var.project}-asg"
  vpc_zone_identifier = module.vpc.private_subnets
  target_group_arns   = [aws_lb_target_group.api.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 120

  min_size         = 2
  max_size         = 6
  desired_capacity = 2

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-ec2"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "${var.project}-scale-out"
  autoscaling_group_name = aws_autoscaling_group.app.name
  adjustment_type        = "ChangeInCapacity"
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

# ──────────────────────────────────────────
# IAM Role for EC2
# ──────────────────────────────────────────
resource "aws_iam_role" "ec2" {
  name = "${var.project}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy" "ec2_custom" {
  name = "${var.project}-ec2-custom"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:${var.project}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ──────────────────────────────────────────
# S3 Bucket for ALB logs
# ──────────────────────────────────────────
resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${var.project}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ──────────────────────────────────────────
# AWS Inspector v2 (vulnerability scanning)
# ──────────────────────────────────────────
resource "aws_inspector2_enabler" "ec2_and_ecr" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2", "ECR"]
}

# ──────────────────────────────────────────
# Data sources
# ──────────────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
