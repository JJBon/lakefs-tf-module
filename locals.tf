locals {
  # You can fine-tune discovery (e.g., only map_public_ip_on_launch) if you need strict public/private separation.
  public_subnet_ids_effective = length(var.public_subnet_ids) > 0 ? var.public_subnet_ids : data.aws_subnets.all_in_vpc.ids
  db_subnet_ids_effective     = length(var.db_subnet_ids) > 0 ? var.db_subnet_ids : slice(data.aws_subnets.all_in_vpc.ids, 0, 2)
}


locals {
  lakefs_prefix = var.s3_prefix == "" ? null : var.s3_prefix
}

locals {
  lakefs_env = [
    {
      name  = "LAKEFS_LOGGING_LEVEL"
      value = var.lakefs_logging_level
    },
    {
      name  = "LAKEFS_DATABASE_TYPE"
      value = "postgres"
    },
    # URL-encode the password to avoid parsing errors with special characters
    {
      name  = "LAKEFS_BLOCKSTORE_TYPE"
      value = "s3"
    },
    {
      name  = "LAKEFS_BLOCKSTORE_S3_REGION"
      value = var.region
    },
    {
      name  = "LAKEFS_BLOCKSTORE_S3_FORCE_PATH_STYLE"
      value = tostring(var.force_path_style)
    },
    {
      name  = "LAKEFS_AUTH_ENCRYPT_SECRET_KEY"
      value = random_password.db.result
    },
    {
      name  = "LAKEFS_GATEWAYS_S3_FALLBACK_URL"
      value = var.s3_gateway_fallback_url
    },
    {
      name  = "DB_HOST"
      value = aws_rds_cluster.this.endpoint
    },
    {
      name  = "DB_PORT"
      value = "5432"
    },
    {
      name  = "DB_NAME"
      value = var.db_name
    }

  ]
}