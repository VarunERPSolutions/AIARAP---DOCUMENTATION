# npm install must run before the source dir gets zipped. Triggered on
# changes to package.json/package-lock.json so it re-runs when a dependency
# actually changes, not on every apply.
resource "null_resource" "npm_install" {
  triggers = {
    package_json = filesha256("${path.module}/src/package.json")
  }

  provisioner "local-exec" {
    command     = "npm install --omit=dev"
    working_dir = "${path.module}/src"
  }
}

data "archive_file" "writer" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/writer.zip"

  depends_on = [null_resource.npm_install]
}

resource "aws_iam_role" "writer" {
  name = "${var.function_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.writer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Required for any VPC-attached Lambda — grants ENI create/describe/delete.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.writer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Scoped to exactly the one secret this function needs — not a blanket
# secretsmanager:* grant.
resource "aws_iam_role_policy" "secrets_access" {
  name = "${var.function_name}-secrets-access"
  role = aws_iam_role.writer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.db_secret_arn
    }]
  })
}

resource "aws_cloudwatch_log_group" "writer" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "writer" {
  function_name = var.function_name
  role          = aws_iam_role.writer.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = var.timeout
  memory_size   = var.memory_size

  filename         = data.archive_file.writer.output_path
  source_code_hash = data.archive_file.writer.output_base64sha256

  vpc_config {
    subnet_ids         = var.vpc_subnet_ids
    security_group_ids = var.vpc_security_group_ids
  }

  environment {
    variables = {
      DB_HOST       = var.db_host
      DB_PORT       = tostring(var.db_port)
      DB_NAME       = var.db_name
      DB_SCHEMA     = var.db_schema
      DB_SECRET_ARN = var.db_secret_arn
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.writer,
    aws_iam_role_policy_attachment.basic_execution,
    aws_iam_role_policy_attachment.vpc_access,
    aws_iam_role_policy.secrets_access,
  ]
}

# Runs the idempotent CREATE SCHEMA/TABLE IF NOT EXISTS migration once at
# shared-stack apply time, and again whenever the deployed code (and
# therefore the embedded migration SQL) changes. Safe to re-run any number
# of times. Deliberately NOT lifecycle_scope = "CRUD" — there is no
# "undo the schema" action to run on destroy.
resource "aws_lambda_invocation" "migrate" {
  function_name = aws_lambda_function.writer.function_name
  input         = jsonencode({ action = "migrate" })

  triggers = {
    code_hash = data.archive_file.writer.output_base64sha256
  }
}
