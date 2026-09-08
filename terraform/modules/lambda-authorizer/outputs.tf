output "function_name" {
  value = aws_lambda_function.authorizer.function_name
}

output "function_arn" {
  value = aws_lambda_function.authorizer.arn
}

output "invoke_arn" {
  description = "Use this when wiring aws_api_gateway_authorizer.authorizer_uri in each per-backend REST API."
  value       = aws_lambda_function.authorizer.invoke_arn
}

output "role_arn" {
  value = aws_iam_role.authorizer.arn
}
