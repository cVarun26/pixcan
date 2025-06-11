output "api_endpoint" {
  value = "https://${aws_api_gateway_rest_api.rest_api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.prod_stage.stage_name}/upload"
}
