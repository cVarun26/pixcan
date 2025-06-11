provider "aws" {
  region = var.aws_region
}

#Creating Lambda execution IAM role
resource "aws_iam_role" "lambda_role" {
  name = "PixcanLambdaExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# IAM policy for S3 access
resource "aws_iam_role_policy" "lambda_s3_policy" {
  name = "PixcanLambdaS3Policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:CopyObject"
        ]
        Resource = "${aws_s3_bucket.uploads_bucket.arn}/*"
      }
    ]
  })
}

# IAM policy for Rekognition access
resource "aws_iam_role_policy" "lambda_rekognition_policy" {
  name = "PixcanLambdaRekognitionPolicy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "rekognition:DetectModerationLabels"
        ]
        Resource = "*"
      }
    ]
  })
}

# Creating S3 bucket
resource "aws_s3_bucket" "uploads_bucket" {
  bucket        = var.bucket_name
  force_destroy = true
}

# Block public access to S3 bucket
resource "aws_s3_bucket_public_access_block" "uploads_bucket_pab" {
  bucket = aws_s3_bucket.uploads_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Packaging the lambda function
data "archive_file" "zip_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/../lambda.zip"
}

# Lambda function
resource "aws_lambda_function" "pixcan" {
  function_name = var.lambda_function_name
  filename      = data.archive_file.zip_lambda.output_path
  handler       = "handler.lambda_handler"
  runtime       = "python3.9"
  role          = aws_iam_role.lambda_role.arn
  timeout       = 30

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.uploads_bucket.bucket
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_iam_role_policy.lambda_s3_policy,
    aws_iam_role_policy.lambda_rekognition_policy
  ]
}

# API Gateway REST API
resource "aws_api_gateway_rest_api" "rest_api" {
  name = "PixcanRestAPI"
  
  binary_media_types = [
    "multipart/form-data",
    "image/jpeg",
    "image/png",
    "image/*"
  ]
}

# /upload API
resource "aws_api_gateway_resource" "upload" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = "upload"
}

# POST method
resource "aws_api_gateway_method" "upload_post" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_resource.upload.id
  http_method   = "POST"
  authorization = "NONE"
}

# Integrating Lambda
resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.rest_api.id
  resource_id             = aws_api_gateway_resource.upload.id
  http_method             = aws_api_gateway_method.upload_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.pixcan.invoke_arn
}

#Deployment
resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  
  depends_on = [
    aws_api_gateway_integration.lambda_integration
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# Stage
resource "aws_api_gateway_stage" "prod_stage" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  stage_name    = "prod"
  description   = "Production"
}

# Lambda permission
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowExecutionFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pixcan.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.rest_api.execution_arn}/*/*"
}

# Output the API Gateway URL
output "api_gateway_url" {
  value = "https://${aws_api_gateway_rest_api.rest_api.id}.execute-api.${var.aws_region}.amazonaws.com/prod/upload"
  description = "The URL of the API Gateway"
}