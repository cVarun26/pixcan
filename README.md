# Pixcan: NSFW Image Moderation API

This project implements a simple, serverless API that accepts image uploads and uses AWS Rekognition to detect NSFW content. The images are stored in an S3 bucket and categorized into `safe/` or `nsfw/` folders based on moderation labels.

The infrastructure is fully defined using Terraform, and the API is deployed via AWS Lambda + API Gateway.

## Features

- Accepts image uploads via `multipart/form-data` (standard file upload)
- Stores uploaded images in an S3 bucket
- Uses AWS Rekognition Moderation API to detect explicit content
- Automatically moves images into:
  - `safe/` folder → for clean images
  - `nsfw/` folder → for detected NSFW content
- Fully serverless — no servers to manage