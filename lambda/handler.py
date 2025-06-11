import boto3
import os
import json
import base64
import uuid
import logging
import email
from email.mime.multipart import MIMEMultipart
from io import BytesIO

# Set up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3_client = boto3.client('s3')
rekognition_client = boto3.client('rekognition')

def parse_multipart_form_data(body, content_type):
    #Parsing multipart/form-data without external dependencies
    try:
        # Extract boundary from content-type header
        boundary = None
        for part in content_type.split(';'):
            part = part.strip()
            if part.startswith('boundary='):
                boundary = part.split('=', 1)[1].strip('"')
                break
        
        if not boundary:
            raise ValueError("No boundary found in Content-Type header")
        
        # Parse the multipart data
        parts = body.split(f'--{boundary}'.encode())
        
        for part in parts:
            if b'Content-Disposition' in part and b'filename' in part:
                # Find the start of the file content (after double CRLF)
                header_end = part.find(b'\r\n\r\n')
                if header_end != -1:
                    file_content = part[header_end + 4:]
                    # Remove trailing boundary markers
                    if file_content.endswith(b'\r\n'):
                        file_content = file_content[:-2]
                    return file_content
        
        return None
    except Exception as e:
        logger.error(f"Error parsing multipart data: {str(e)}")
        return None

def lambda_handler(event, context):
    try:
        logger.info(f"Received event: {json.dumps(event, default=str)}")
        
        # Get bucket name from environment
        bucket_name = os.environ.get('BUCKET_NAME')
        if not bucket_name:
            raise ValueError("BUCKET_NAME environment variable not set")
        
        # Parse the multipart/form-data body
        content_type = event['headers'].get('content-type') or event['headers'].get('Content-Type')
        if not content_type:
            raise ValueError("Missing Content-Type header")
        
        body = event.get('body', '')
        if event.get("isBase64Encoded", False):
            body = base64.b64decode(body)
        else:
            body = body.encode("utf-8")
        
        # Parse multipart form data
        image_data = parse_multipart_form_data(body, content_type)
        
        if not image_data:
            raise ValueError("No file found in multipart/form-data payload")
        
        # Generate unique image ID
        image_id = str(uuid.uuid4()) + ".jpg"
        
        # Upload image to S3 (temp folder)
        temp_key = f"uploads/{image_id}"
        
        logger.info(f"Uploading to S3: bucket={bucket_name}, key={temp_key}")
        
        s3_client.put_object(
            Bucket=bucket_name,
            Key=temp_key,
            Body=image_data,
            ContentType='image/jpeg'
        )
        
        logger.info("Image uploaded successfully, starting moderation detection")
        
        # Detect moderation labels
        response = rekognition_client.detect_moderation_labels(
            Image={'S3Object': {'Bucket': bucket_name, 'Name': temp_key}},
            MinConfidence=70
        )
        
        nsfw_detected = False
        labels = [label['Name'] for label in response['ModerationLabels']]
        if labels:
            nsfw_detected = True
        
        logger.info(f"Moderation detection complete. NSFW: {nsfw_detected}, Labels: {labels}")
        
        # Determine final folder
        final_key = f"{'nsfw' if nsfw_detected else 'safe'}/{image_id}"
        
        # Copy to final location
        s3_client.copy_object(
            Bucket=bucket_name,
            CopySource={'Bucket': bucket_name, 'Key': temp_key},
            Key=final_key
        )
        
        # Delete temp object
        s3_client.delete_object(Bucket=bucket_name, Key=temp_key)
        
        logger.info(f"Image processed successfully and moved to {final_key}")
        
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Headers': 'Content-Type',
                'Access-Control-Allow-Methods': 'POST,OPTIONS'
            },
            'body': json.dumps({
                'file_name': image_id,
                'nsfw_detected': nsfw_detected,
                'labels': labels,
                'message': f"Image moved to {'nsfw' if nsfw_detected else 'safe'} folder",
                'final_location': final_key
            })
        }
        
    except Exception as e:
        logger.error(f"Error processing image: {str(e)}")
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'error': str(e),
                'message': 'Failed to process image'
            })
        }