#!/bin/bash

set -e
set -o pipefail

AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-"http://localhost:4566"}

# Colors for logging
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" >&2
}

error_log() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

trap 'error_log "An error occurred. Exiting..."; exit 1' ERR

# Setup SNS Topic
log "Creating SNS topic 'ProductEventsTopic'..."
SNS_TOPIC_ARN=$(lstk aws sns create-topic --name ProductEventsTopic --output json | jq -r '.TopicArn')
log "SNS topic created. ARN: $SNS_TOPIC_ARN"

# Setup SQS Queue
log "Creating SQS queue 'ProductEventsQueue'..."
QUEUE_URL=$(lstk aws sqs create-queue --queue-name ProductEventsQueue --output json | jq -r '.QueueUrl')
QUEUE_ARN=$(lstk aws sqs get-queue-attributes \
    --queue-url $QUEUE_URL \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' --output text)
log "SQS queue created. ARN: $QUEUE_ARN"

# Subscribe SQS Queue to SNS Topic
log "Subscribing SQS queue to SNS topic..."
lstk aws sns subscribe \
    --topic-arn $SNS_TOPIC_ARN \
    --protocol sqs \
    --notification-endpoint $QUEUE_ARN >/dev/null
log "SQS queue subscribed to SNS topic."

# Create Lambda Function
log "Creating Lambda function 'process-product-events'..."
lstk aws lambda create-function \
  --function-name process-product-events \
  --runtime java17 \
  --handler lambda.DynamoDBWriterLambda::handleRequest \
  --memory-size 1024 \
  --timeout 20 \
  --zip-file fileb://lambda-functions/target/product-lambda.jar \
  --role arn:aws:iam::000000000000:role/productRole >/dev/null
log "Lambda function created."

# Create Event Source Mapping from SQS to Lambda
log "Creating event source mapping from SQS to Lambda..."
lstk aws lambda create-event-source-mapping \
    --function-name process-product-events \
    --batch-size 10 \
    --event-source-arn $QUEUE_ARN >/dev/null
log "Event source mapping created."

# Set Queue Attributes
log "Setting SQS queue attributes..."
lstk aws sqs set-queue-attributes \
    --queue-url $QUEUE_URL \
    --attributes VisibilityTimeout=10 >/dev/null
log "SQS queue attributes set."

# Final Output
echo
echo -e "${BLUE}Setup completed successfully.${NC}"
echo -e "${BLUE}SNS Topic ARN:${NC} $SNS_TOPIC_ARN"
echo -e "${BLUE}SQS Queue ARN:${NC} $QUEUE_ARN"
