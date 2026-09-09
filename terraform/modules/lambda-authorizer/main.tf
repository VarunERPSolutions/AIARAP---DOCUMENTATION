# npm install must run before the source dir gets zipped. Triggered on
# changes to package.json/package-lock.json so it re-runs when the
# dependency actually changes, not on every apply.
resource "null_resource" "npm_install" {
  triggers = {
    package_json = filesha256("${path.module}/src/package.json")
  }

  provisioner "local-exec" {
    command     = "npm install --omit=dev"
    working_dir = "${path.module}/src"
  }
}

data "archive_file" "authorizer" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/authorizer.zip"

  depends_on = [null_resource.npm_install]
}

resource "aws_iam_role" "authorizer" {
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
  role       = aws_iam_role.authorizer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "authorizer" {
  function_name = var.function_name
  role          = aws_iam_role.authorizer.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = var.timeout
  memory_size   = var.memory_size

  reserved_concurrent_executions = var.reserved_concurrent_executions

  filename         = data.archive_file.authorizer.output_path
  source_code_hash = data.archive_file.authorizer.output_base64sha256

  environment {
    variables = {
      POOL_MAP        = jsonencode(var.pool_map)
      API_BACKEND_MAP = jsonencode(var.api_backend_map)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.authorizer,
    aws_iam_role_policy_attachment.basic_execution,
  ]
}
