#!/bin/sh

apt-get -y install jq
npm install -g @localstack/lstk
lstk setup aws

# lstk reads LOCALSTACK_HOST (set for Lambda callback URLs, see docker-compose.yml) as its own
# endpoint host with no default port, producing the unreachable "http://localstack/". Force the
# correct in-container endpoint explicitly instead.
LSTK_AWS="lstk aws --endpoint-url http://localhost:4566"

# ---------------------------------------------------
# Region: us-east-1
# ---------------------------------------------------

# Create DynamoDB table
echo "Create DynamoDB table..."
$LSTK_AWS dynamodb create-table \
  --table-name Products \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region us-east-1

# Enable DynamoDB Streams
$LSTK_AWS dynamodb update-table \
  --table-name Products \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
  --region us-east-1

# Create Lambda for DynamoDB Stream
$LSTK_AWS lambda create-function \
  --function-name dynamodb-streams-to-lambda \
  --runtime java17 \
  --handler dynamodb_streams.DynamoDBStreamHandler::handleRequest \
  --memory-size 256 \
  --zip-file fileb:///etc/localstack/init/ready.d/target/product-lambda.jar \
  --role arn:aws:iam::000000000000:role/productRole \
  --region us-east-1

# Get stream ARN and create mapping
export STREAM_ARN=$($LSTK_AWS dynamodb describe-table --table-name Products --region us-east-1 | jq -r '.Table.LatestStreamArn')
$LSTK_AWS lambda create-event-source-mapping \
  --function-name dynamodb-streams-to-lambda \
  --event-source-arn $STREAM_ARN \
  --starting-position LATEST

# Create Lambdas
echo "Add Product Lambda..."
$LSTK_AWS lambda create-function \
  --function-name add-product \
  --runtime java17 \
  --handler lambda.AddProduct::handleRequest \
  --memory-size 512 \
  --zip-file fileb:///etc/localstack/init/ready.d/target/product-lambda.jar \
  --region us-east-1 \
  --role arn:aws:iam::000000000000:role/productRole \
  --environment Variables={AWS_REGION=us-east-1}

echo "Get Product Lambda..."
$LSTK_AWS lambda create-function \
  --function-name get-product \
  --runtime java17 \
  --handler lambda.GetProduct::handleRequest \
  --memory-size 512 \
  --zip-file fileb:///etc/localstack/init/ready.d/target/product-lambda.jar \
  --region us-east-1 \
  --role arn:aws:iam::000000000000:role/productRole \
  --environment Variables={AWS_REGION=us-east-1}

echo "Healthcheck Lambda..."
$LSTK_AWS lambda create-function \
  --function-name healthcheck \
  --runtime python3.11 \
  --handler healthcheck.lambda_handler \
  --memory-size 512 \
  --zip-file fileb:///etc/localstack/init/ready.d/healthcheck.zip \
  --region us-east-1 \
  --role arn:aws:iam::000000000000:role/productRole

# Create API Gateway
export REST_API_ID=12345

echo "Create Rest API..."
$LSTK_AWS apigateway create-rest-api --name quote-api-gateway --tags '{"_custom_id_":"12345"}' --region us-east-1

echo "Export Parent ID..."
export PARENT_ID=$($LSTK_AWS apigateway get-resources --rest-api-id $REST_API_ID --region=us-east-1 | jq -r '.items[0].id')

echo "Export Resource ID..."
export RESOURCE_ID=$($LSTK_AWS apigateway create-resource --rest-api-id $REST_API_ID --parent-id $PARENT_ID --path-part "productApi" --region=us-east-1 | jq -r '.id')

echo "Export HealthCheck Resource ID..."
export HEALTHCHECK_RESOURCE_ID=$($LSTK_AWS apigateway create-resource --rest-api-id $REST_API_ID --parent-id $PARENT_ID --path-part "healthcheck" --region=us-east-1 | jq -r '.id')

echo "HEALTH CHECK ID 1:"
echo $HEALTHCHECK_RESOURCE
echo "RESOURCE ID:"
echo $RESOURCE

# Setup API Methods
echo "Put GET Method..."
$LSTK_AWS apigateway put-method \
  --rest-api-id $REST_API_ID \
  --resource-id $RESOURCE_ID \
  --http-method GET \
  --request-parameters "method.request.path.productApi=true" \
  --authorization-type "NONE" \
  --region=us-east-1

echo "Put POST Method..."
$LSTK_AWS apigateway put-method \
  --rest-api-id $REST_API_ID \
  --resource-id $RESOURCE_ID \
  --http-method POST \
  --request-parameters "method.request.path.productApi=true" \
  --authorization-type "NONE" \
  --region=us-east-1

echo "Update GET Method..."
$LSTK_AWS apigateway update-method \
  --rest-api-id $REST_API_ID \
  --resource-id $RESOURCE_ID \
  --http-method GET \
  --patch-operations "op=replace,path=/requestParameters/method.request.querystring.param,value=true" \
  --region=us-east-1

# Integrations
echo "Put POST Method Integration..."
$LSTK_AWS apigateway put-integration \
  --rest-api-id $REST_API_ID \
  --resource-id $RESOURCE_ID \
  --http-method POST \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:000000000000:function:add-product/invocations \
  --passthrough-behavior WHEN_NO_MATCH \
  --region=us-east-1

echo "Put GET Method Integration..."
$LSTK_AWS apigateway put-integration \
  --rest-api-id $REST_API_ID \
  --resource-id $RESOURCE_ID \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method GET \
  --uri arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:000000000000:function:get-product/invocations \
  --passthrough-behavior WHEN_NO_MATCH \
  --region=us-east-1

echo "Put GET Method for HealthCheck..."
$LSTK_AWS apigateway put-method \
  --rest-api-id $REST_API_ID \
  --resource-id $HEALTHCHECK_RESOURCE_ID \
  --http-method GET \
  --request-parameters "method.request.path.healthcheck=true" \
  --authorization-type "NONE" \
  --region=us-east-1

echo "Put GET Method Integration for HealthCheck..."
$LSTK_AWS apigateway put-integration \
  --rest-api-id $REST_API_ID \
  --resource-id $HEALTHCHECK_RESOURCE_ID \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:000000000000:function:healthcheck/invocations \
  --passthrough-behavior WHEN_NO_MATCH \
  --region=us-east-1

echo "Create DEV Deployment..."
$LSTK_AWS apigateway create-deployment \
  --rest-api-id $REST_API_ID \
  --stage-name dev \
  --region=us-east-1

# ---------------------------------------------------
# Region: us-west-1
# ---------------------------------------------------

# Create DynamoDB table
echo "Create DynamoDB table..."
$LSTK_AWS dynamodb create-table \
  --table-name Products \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region us-west-1

# Create Lambdas
echo "Add Product Lambda..."
$LSTK_AWS lambda create-function \
  --function-name add-product \
  --runtime java17 \
  --handler lambda.AddProduct::handleRequest \
  --memory-size 512 \
  --zip-file fileb:///etc/localstack/init/ready.d/target/product-lambda.jar \
  --region us-west-1 \
  --role arn:aws:iam::000000000000:role/productRole \
  --environment Variables={AWS_REGION=us-west-1}

echo "Get Product Lambda..."
$LSTK_AWS lambda create-function \
  --function-name get-product \
  --runtime java17 \
  --handler lambda.GetProduct::handleRequest \
  --memory-size 512 \
  --zip-file fileb:///etc/localstack/init/ready.d/target/product-lambda.jar \
  --region us-west-1 \
  --role arn:aws:iam::000000000000:role/productRole \
  --environment Variables={AWS_REGION=us-west-1}

echo "Healthcheck Lambda..."
$LSTK_AWS lambda create-function \
  --function-name healthcheck \
  --runtime python3.11 \
  --handler healthcheck.lambda_handler \
  --memory-size 512 \
  --zip-file fileb:///etc/localstack/init/ready.d/healthcheck.zip \
  --region us-west-1 \
  --role arn:aws:iam::000000000000:role/productRole

# Create API Gateway
export REST_API_ID=67890

echo "Create Rest API..."
$LSTK_AWS apigateway create-rest-api --name quote-api-gateway --tags '{"_custom_id_":"67890"}' --region us-west-1

echo "Export Parent ID..."
export PARENT_ID=$($LSTK_AWS apigateway get-resources --rest-api-id $REST_API_ID --region=us-west-1 | jq -r '.items[0].id')

echo "Export Resource ID..."
export RESOURCE_ID=$($LSTK_AWS apigateway create-resource --rest-api-id $REST_API_ID --parent-id $PARENT_ID --path-part "productApi" --region=us-west-1 | jq -r '.id')

echo "Export HealthCheck Resource ID..."
export HEALTHCHECK_RESOURCE_ID=$($LSTK_AWS apigateway create-resource --rest-api-id $REST_API_ID --parent-id $PARENT_ID --path-part "healthcheck" --region=us-west-1 | jq -r '.id')

echo "HEALTH CHECK ID 1:"
echo $HEALTHCHECK_RESOURCE
echo "RESOURCE ID:"
echo $RESOURCE

# Setup API Methods
echo "Put GET Method..."
$LSTK_AWS apigateway put-method \
  --rest-api-id $REST_API_ID \
  --resource-id $RESOURCE_ID \
  --http-method GET \
  --request-parameters "method.request.path.productApi=true" \
  --authorization-type "NONE" \
  --region=us-west-1

echo "Put POST Method..."
$LSTK_AWS apigateway put-method \
  --rest-api-id $REST_API_ID \
  --resource-id $RESOURCE_ID \
  --http-method POST \
  --request-parameters "method.request.path.productApi=true" \
  --authorization-type "NONE" \
  --region=us-west-1

echo "Update GET Method..."
$LSTK_AWS apigateway update-method \
  --rest-api-id $REST_API_ID \
  --resource-id $RESOURCE_ID \
  --http-method GET \
  --patch-operations "op=replace,path=/requestParameters/method.request.querystring.param,value=true" \
  --region=us-west-1

# Integrations
echo "Put POST Method Integration..."
$LSTK_AWS apigateway put-integration \
  --rest-api-id $REST_API_ID \
  --resource-id $RESOURCE_ID \
  --http-method POST \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri arn:aws:apigateway:us-west-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-1:000000000000:function:add-product/invocations \
  --passthrough-behavior WHEN_NO_MATCH \
  --region=us-west-1

echo "Put GET Method Integration..."
$LSTK_AWS apigateway put-integration \
  --rest-api-id $REST_API_ID \
  --resource-id $RESOURCE_ID \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method GET \
  --uri arn:aws:apigateway:us-west-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-1:000000000000:function:get-product/invocations \
  --passthrough-behavior WHEN_NO_MATCH \
  --region=us-west-1

echo "Put GET Method for HealthCheck..."
$LSTK_AWS apigateway put-method \
  --rest-api-id $REST_API_ID \
  --resource-id $HEALTHCHECK_RESOURCE_ID \
  --http-method GET \
  --request-parameters "method.request.path.healthcheck=true" \
  --authorization-type "NONE" \
  --region=us-west-1

echo "Put GET Method Integration for HealthCheck..."
$LSTK_AWS apigateway put-integration \
  --rest-api-id $REST_API_ID \
  --resource-id $HEALTHCHECK_RESOURCE_ID \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri arn:aws:apigateway:us-west-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-1:000000000000:function:healthcheck/invocations \
  --passthrough-behavior WHEN_NO_MATCH \
  --region=us-west-1

echo "Create DEV Deployment..."
$LSTK_AWS apigateway create-deployment \
  --rest-api-id $REST_API_ID \
  --stage-name dev \
  --region=us-west-1
