// ───────────────────────── variables.tf ─────────────────────────
variable "region" {
  type = string
}

variable "name" {
  type    = string
  default = "lakefs-ecs"
}

variable "vpc_id" {
  type    = string
  default = ""
}

variable "public_subnet_ids" {
  description = "Public (or routable) subnets for ALB/ECS. If empty, all subnets in the VPC are used."
  type        = list(string)
  default     = []
}

variable "db_subnet_ids" {
  description = "Subnets for Aurora DB subnet group. If empty, we pick the first 2 from the VPC."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "s3_bucket_name" {
  type = string
}

variable "s3_prefix" {
  type    = string
  default = ""
}

variable "force_path_style" {
  type    = bool
  default = false
}

variable "aurora_engine_version" {
  type    = string
  default = "15.7"
}

variable "db_name" {
  type    = string
  default = "lakefs"
}

variable "db_username" {
  type    = string
  default = "lakefs"
}

variable "db_min_acu" {
  type    = number
  default = 1
}

variable "db_max_acu" {
  type    = number
  default = 3
}

variable "lakefs_image" {
  type    = string
  default = "treeverse/lakefs:latest"
}

variable "lakefs_logging_level" {
  type    = string
  default = "INFO"
}

variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "initial_desired_count" {
  type    = number
  default = 1
}

variable "ecs_min_count" {
  type    = number
  default = 1
}

variable "ecs_max_count" {
  type    = number
  default = 2
}

# Scale-to-0 tuning: "no requests for (idle_eval_periods * idle_period_seconds)"
variable "idle_eval_periods" {
  description = "Evaluation periods for idle alarm. No requests for (idle_eval_periods * idle_period_seconds)"
  type        = number
  default     = 4
}

variable "idle_period_seconds" {
  description = "Alarm period in seconds. 15 min × 4 = 60 min idle -> scale to 0"
  type        = number
  default     = 900
}

variable "s3_gateway_fallback_url" {
  type    = string
  default = ""
}

variable "master_username" {
  type    = string
  default = "lakefsadmin"
}