data "aws_vpc" "by_id" {
  count = var.vpc_id != "" ? 1 : 0
  id    = var.vpc_id
}

data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

data "aws_subnets" "all_in_vpc" {
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

data "aws_secretsmanager_secret" "rds_master" {
  arn = aws_rds_cluster.this.master_user_secret[0].secret_arn
}

data "aws_iam_policy_document" "task_exec_secrets" {
  statement {
    sid     = "AllowGetSecretValue"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    # Include all versions/stages of the secret by using the wildcard
    resources = [
      data.aws_secretsmanager_secret.rds_master.arn,
      "${data.aws_secretsmanager_secret.rds_master.arn}:*"
    ]
  }

  # Many setups also need KMS decrypt on the key used by the secret.
  # This is safe to include; it scopes decrypt to calls coming via Secrets Manager.
  statement {
    sid       = "AllowKmsDecryptForSecret"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_secretsmanager_secret.rds_master.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:secretsmanager:arn"
      values   = [data.aws_secretsmanager_secret.rds_master.arn]
    }
  }
}