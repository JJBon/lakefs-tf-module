# ────────────────────────────────────────────────────────────────────────────────
# lakeFS on ECS Fargate + Aurora PostgreSQL Serverless v2 (auto‑pause to 0)
# - Auto‑pause DB after 1 hour of inactivity (SecondsUntilAutoPause = 3600)
# - Run at up to 1 ACU (MaxCapacity = 1) and MinCapacity = 0 (scale to zero)
# - ECS service target tracking + step scaling to scale desired_count down to 0
# - ALB in front of ECS service
# - S3 as blockstore; task role is granted access to a specific bucket prefix
#
# NOTE: This is a minimal, opinionated starter to get you going. You can split
#       into modules for prod use.
# ────────────────────────────────────────────────────────────────────────────────

############################################
# files: main.tf, variables.tf, outputs.tf #
############################################

// ───────────────────────── main.tf ─────────────────────────
terraform {
  required_version = ">= 1.6.0, < 1.8.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}


provider "aws" {
  region = var.region
}

# ---------------------------
# Networking (simple VPC)
# ---------------------------



locals {
  vpc_id = var.vpc_id != "" ? data.aws_vpc.by_id[0].id : data.aws_vpc.default[0].id
}



resource "random_password" "db" {
  length  = 20
  special = true
}


# ---------------------------
# S3 bucket for lakeFS blockstore
# ---------------------------
resource "aws_s3_bucket" "lakefs" {
  bucket = var.s3_bucket_name
  tags   = { Name = "${var.name}-lakefs" }
}


# ---------------------------
# Aurora PostgreSQL Serverless v2 (auto‑pause to 0)
# ---------------------------
resource "aws_db_subnet_group" "aurora" {
  name       = "${var.name}-aurora-subnets"
  subnet_ids = local.db_subnet_ids_effective
}

resource "aws_security_group" "aurora" {
  name        = "${var.name}-aurora-sg"
  description = "Aurora PostgreSQL SG"
  vpc_id      = local.vpc_id
}

# Allow ECS tasks to talk to Aurora
resource "aws_security_group_rule" "aurora_ingress" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aurora.id
  source_security_group_id = aws_security_group.ecs_tasks.id
}

resource "aws_security_group_rule" "ecs_from_alb_8000" {
  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_tasks.id
  source_security_group_id = aws_security_group.alb.id
  description              = "ALB to lakeFS"
}


resource "aws_rds_cluster" "this" {
  cluster_identifier          = "${var.name}-aurora"
  engine                      = "aurora-postgresql"
  engine_version              = var.aurora_engine_version
  database_name               = var.db_name
  master_username             = var.master_username
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.aurora.name
  storage_encrypted           = true
  skip_final_snapshot         = true
  vpc_security_group_ids      = [aws_security_group.aurora.id]
  deletion_protection         = false

  serverlessv2_scaling_configuration {
    min_capacity             = var.db_min_acu
    max_capacity             = var.db_max_acu
    seconds_until_auto_pause = 3600 # 1 hour
  }

  tags = { Name = "${var.name}-aurora" }
}

resource "aws_rds_cluster_instance" "this" {
  identifier          = "${var.name}-aurora-instance"
  cluster_identifier  = aws_rds_cluster.this.id
  instance_class      = "db.serverless"
  engine              = aws_rds_cluster.this.engine
  engine_version      = aws_rds_cluster.this.engine_version
  publicly_accessible = false
}

# ---------------------------
# ECS Fargate + ALB
# ---------------------------
resource "aws_ecs_cluster" "this" {
  name = "${var.name}-cluster"
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.name}-task-exec"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}

data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "task_exec_attach" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task_role" {
  name               = "${var.name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}

# Allow access to the S3 bucket/prefix as blockstore
resource "aws_iam_policy" "s3_blockstore" {
  name   = "${var.name}-s3-blockstore"
  policy = data.aws_iam_policy_document.s3_blockstore.json
}

data "aws_iam_policy_document" "s3_blockstore" {
  statement {
    actions = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
    resources = local.lakefs_prefix == null ? [
      aws_s3_bucket.lakefs.arn,
      "${aws_s3_bucket.lakefs.arn}/*"
      ] : [
      aws_s3_bucket.lakefs.arn,
      "${aws_s3_bucket.lakefs.arn}/${var.s3_prefix}*"
    ]
  }
}

resource "aws_iam_role_policy_attachment" "s3_attach" {
  role       = aws_iam_role.task_role.name
  policy_arn = aws_iam_policy.s3_blockstore.arn
}

# Security group for ECS tasks
resource "aws_security_group" "ecs_tasks" {
  name   = "${var.name}-ecs-tasks"
  vpc_id = local.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ALB
resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.public_subnet_ids_effective
}

resource "aws_security_group" "alb" {
  name   = "${var.name}-alb-sg"
  vpc_id = local.vpc_id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb_target_group" "this" {
  name        = "${var.name}-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"
  health_check {
    path                = "/_health"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    interval            = 30
    timeout             = 5
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}



resource "aws_iam_policy" "task_exec_secrets" {
  name   = "${var.name}-task-exec-secrets"
  policy = data.aws_iam_policy_document.task_exec_secrets.json
}

# Attach to the **execution** role (not task role)
resource "aws_iam_role_policy_attachment" "task_exec_attach_secrets" {
  role       = aws_iam_role.task_execution.name
  policy_arn = aws_iam_policy.task_exec_secrets.arn
}

resource "aws_ecs_task_definition" "lakefs" {
  family                   = "${var.name}-lakefs"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role.arn


  container_definitions = jsonencode([
    {
      name         = "lakefs"
      image        = var.lakefs_image
      essential    = true
      portMappings = [{ containerPort = 8000, hostPort = 8000, protocol = "tcp" }]
      environment  = local.lakefs_env
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = "${aws_rds_cluster.this.master_user_secret[0].secret_arn}:password::"
        },
        {
          name      = "DB_USER"
          valueFrom = "${aws_rds_cluster.this.master_user_secret[0].secret_arn}:username::"
        }
      ]

      entryPoint = ["/bin/sh", "-lc"]

      command = [
  "pw_esc=`printf %s \"$${DB_PASSWORD}\" | sed \"s/'/''/g\"`; export LAKEFS_DATABASE_POSTGRES_CONNECTION_STRING=\"host=$${DB_HOST} port=$${DB_PORT} user=$${DB_USER} password='$${pw_esc}' dbname=$${DB_NAME} sslmode=require\"; exec /app/lakefs run"
]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.lakefs.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "lakefs"
        }
      }
    }
  ])
}

resource "aws_cloudwatch_log_group" "lakefs" {
  name              = "/ecs/${var.name}-lakefs"
  retention_in_days = 14
}

resource "aws_ecs_service" "lakefs" {
  name                              = "${var.name}-svc"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.lakefs.arn
  desired_count                     = var.initial_desired_count
  launch_type                       = "FARGATE"
  enable_execute_command            = true
  health_check_grace_period_seconds = 500

  network_configuration {
    subnets          = local.public_subnet_ids_effective
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "lakefs"
    container_port   = 8000
  }

  lifecycle {
    ignore_changes = [desired_count] # let autoscaling control it
  }
}

# ---------------------------
# Application Auto Scaling (scale to zero when idle)
# ---------------------------
# 1) Target tracking based on ALB RequestCountPerTarget keeps service responsive
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.ecs_max_count
  min_capacity       = var.ecs_min_count
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.lakefs.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Target tracking on ALB requests per target (low target value triggers scale-in)
resource "aws_appautoscaling_policy" "tt_requests" {
  name               = "${var.name}-tt-req"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value     = 1
    disable_scale_in = false
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      # Correct format per AWS: "app/<lb-name>/<lb-id>/targetgroup/<tg-name>/<tg-id>"
      resource_label = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.this.arn_suffix}"
    }
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }

  depends_on = [aws_lb_listener.http]
}


# 2) Step scaling: if absolutely no requests arrive for N minutes, set count to 0
resource "aws_cloudwatch_metric_alarm" "idle" {
  alarm_name          = "${var.name}-no-requests"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.idle_eval_periods
  metric_name         = "RequestCountPerTarget"
  namespace           = "AWS/ApplicationELB"
  period              = var.idle_period_seconds
  statistic           = "Sum"
  threshold           = 1
  dimensions = {
    TargetGroup  = aws_lb_target_group.this.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }
}

resource "aws_appautoscaling_policy" "scale_to_zero" {
  name               = "${var.name}-scale-to-0"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 300
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1 # from 1 -> 0
    }
  }

  depends_on = [aws_cloudwatch_metric_alarm.idle]
}

resource "aws_cloudwatch_metric_alarm" "idle_action" {
  alarm_name          = "${var.name}-no-requests-action"
  comparison_operator = aws_cloudwatch_metric_alarm.idle.comparison_operator
  evaluation_periods  = aws_cloudwatch_metric_alarm.idle.evaluation_periods
  metric_name         = aws_cloudwatch_metric_alarm.idle.metric_name
  namespace           = aws_cloudwatch_metric_alarm.idle.namespace
  period              = aws_cloudwatch_metric_alarm.idle.period
  statistic           = aws_cloudwatch_metric_alarm.idle.statistic
  threshold           = aws_cloudwatch_metric_alarm.idle.threshold
  dimensions          = aws_cloudwatch_metric_alarm.idle.dimensions
  alarm_actions       = [aws_appautoscaling_policy.scale_to_zero.arn]
}

