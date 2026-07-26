
lstk aws lambda update-function-code --function-name process-product-events \
         --zip-file fileb://target/product-lambda.jar \
         --region us-east-1
