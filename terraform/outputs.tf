output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  description = "PostgreSQL RDS database connection endpoint address"
  value       = aws_db_instance.main.address
  sensitive   = true
}

output "vpc_id" {
  description = "VPC identifier hosting the cloud log analytics infrastructure"
  value       = module.vpc.vpc_id
}

output "sns_topic_arn" {
  description = "SNS Topic ARN for anomaly alerts and CloudWatch alarms"
  value       = aws_sns_topic.alerts.arn
}

output "cloudwatch_app_log_group" {
  description = "CloudWatch log group name for log collector container ingestion"
  value       = aws_cloudwatch_log_group.app_logs.name
}

output "secrets_manager_arn" {
  description = "AWS Secrets Manager ARN storing RDS database credentials"
  value       = aws_secretsmanager_secret.db.arn
}
