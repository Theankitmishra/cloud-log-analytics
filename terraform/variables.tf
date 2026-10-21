variable "project" {
  description = "Project name prefix used for all provisioned AWS resources"
  type        = string
  default     = "cloud-log-analytics"
}

variable "environment" {
  description = "Deployment environment (e.g., production, staging, development)"
  type        = string
  default     = "production"
}

variable "aws_region" {
  description = "Target AWS region for infrastructure deployment"
  type        = string
  default     = "us-east-1"
}

variable "db_username" {
  description = "PostgreSQL master database username"
  type        = string
  default     = "logadmin"
}

variable "db_password" {
  description = "PostgreSQL master database password (stored in AWS Secrets Manager)"
  type        = string
  sensitive   = true
}

variable "bastion_cidr" {
  description = "CIDR block permitted for administrative SSH access (bastion host)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "alert_email" {
  description = "Email address for SNS alert subscriptions and critical alarm notifications"
  type        = string
  default     = "alerts@example.com"
}
