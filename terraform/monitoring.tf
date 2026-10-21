# ──────────────────────────────────────────
# CloudWatch Log Groups
# ──────────────────────────────────────────
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/aws/${var.project}/app"
  retention_in_days = 90
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "anomaly_logs" {
  name              = "/aws/${var.project}/anomaly-detector"
  retention_in_days = 30
  tags              = local.tags
}

# ──────────────────────────────────────────
# CloudWatch Metric Filters
# ──────────────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "error_rate" {
  name           = "${var.project}-error-rate"
  pattern        = "[timestamp, level=\"ERROR\", ...]"
  log_group_name = aws_cloudwatch_log_group.app_logs.name

  metric_transformation {
    name      = "ErrorCount"
    namespace = "${var.project}/AppMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "latency" {
  name           = "${var.project}-high-latency"
  pattern        = "[timestamp, level, service, lat_ms > 1000, ...]"
  log_group_name = aws_cloudwatch_log_group.app_logs.name

  metric_transformation {
    name      = "HighLatencyCount"
    namespace = "${var.project}/AppMetrics"
    value     = "1"
  }
}

# ──────────────────────────────────────────
# CloudWatch Alarms
# ──────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "high_error_rate" {
  alarm_name          = "${var.project}-high-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ErrorCount"
  namespace           = "${var.project}/AppMetrics"
  period              = 60
  statistic           = "Sum"
  threshold           = 50
  alarm_description   = "Error count exceeded 50 per minute"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.project}-rds-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU above 80%"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }
  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-alb-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "ALB 5xx errors exceeded threshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }
  tags = local.tags
}

# ──────────────────────────────────────────
# SNS Topic for Alerts
# ──────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name              = "${var.project}-alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "lambda_detector" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.anomaly_detector.arn
}

# ──────────────────────────────────────────
# Lambda Anomaly Detector
# ──────────────────────────────────────────
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "anomaly_detector" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.project}-anomaly-detector"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  timeout          = 60
  memory_size      = 512
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DB_SECRET_ARN  = aws_secretsmanager_secret.db.arn
      SNS_TOPIC_ARN  = aws_sns_topic.alerts.arn
      LOG_GROUP_NAME = aws_cloudwatch_log_group.app_logs.name
      ENVIRONMENT    = var.environment
    }
  }

  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.ec2.id]
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.tags
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.anomaly_detector.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_cloudwatch_event_rule" "lambda_schedule" {
  name                = "${var.project}-anomaly-schedule"
  description         = "Run anomaly detection every 5 minutes"
  schedule_expression = "rate(5 minutes)"
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.lambda_schedule.name
  target_id = "AnomalyDetectorLambda"
  arn       = aws_lambda_function.anomaly_detector.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.anomaly_detector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_schedule.arn
}

# ──────────────────────────────────────────
# IAM Role for Lambda
# ──────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "${var.project}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_custom" {
  name = "${var.project}-lambda-custom"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
                    "logs:DescribeLogStreams", "logs:FilterLogEvents"]
        Resource = "${aws_cloudwatch_log_group.app_logs.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.db.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.lambda_dlq.arn
      }
    ]
  })
}

# ──────────────────────────────────────────
# SQS Dead Letter Queue for Lambda
# ──────────────────────────────────────────
resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "${var.project}-lambda-dlq"
  message_retention_seconds = 1209600  # 14 days
  kms_master_key_id         = "alias/aws/sqs"
  tags                      = local.tags
}

# ──────────────────────────────────────────
# Secrets Manager
# ──────────────────────────────────────────
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project}/db-credentials"
  recovery_window_in_days = 7
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    host     = aws_db_instance.main.address
    port     = 5432
    dbname   = "loganalytics"
    username = var.db_username
    password = var.db_password
  })
}

