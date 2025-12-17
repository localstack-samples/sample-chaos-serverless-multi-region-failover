# Chaos Testing a Serverless App with LocalStack

| Key          | Value                                                                                      |
| ------------ | ------------------------------------------------------------------------------------------ |
| Environment  | LocalStack                                                                                 |
| Services     | API Gateway, Lambda, DynamoDB, SNS, SQS, Route53                                           |
| Integrations | AWS CLI, Maven, pytest                                                                     |
| Categories   | Chaos Engineering, Serverless, Multi-Region                                                |
| Level        | Advanced                                                                                   |
| Use Case     | Chaos Engineering, Serverless, Multi-Region                                                |
| GitHub       | [Repository link](https://github.com/localstack-samples/sample-chaos-serverless-multi-region-failover)                 |

## Introduction

This sample demonstrates how to test resiliency in serverless applications using chaos engineering principles, provided by LocalStack's [Chaos API](https://docs.localstack.cloud/aws/capabilities/chaos-engineering/chaos-api/). The application features a multi-region product management system that gracefully handles service outages through automated failover mechanisms and message queuing. To test this application sample, we will demonstrate how you use the Chaos API to inject controlled failures into your infrastructure and validate that your application responds appropriately. We will show how Route53 health checks automatically redirect traffic between regions during outages and how SNS/SQS messaging ensures no data is lost when services are unavailable.

> [!NOTE]
> This sample demonstrates LocalStack's new Chaos API, which replaces the previous FIS (Fault Injection Simulator) functionality in this sample application. Chaos API provides more comprehensive local fault injection testing for cloud-native applications and is available in [LocalStack Enterprise](https://localstack.cloud/enterprise/).

## Architecture

The following diagram shows the architecture that this sample application builds and deploys:

![Architecture Diagram](images/architecture.png)

> [!NOTE]
> The above architecture diagram is a simplified view of the application. The actual architecture is more complex and includes additional services and components, distributed across multiple regions.

**Primary Region (us-east-1):**

- [API Gateway](https://docs.localstack.cloud/aws/services/apigateway/) with product management and health check endpoints
- [Lambda Functions](https://docs.localstack.cloud/aws/services/lambda/) for product CRUD operations and health monitoring
- [DynamoDB](https://docs.localstack.cloud/aws/services/dynamodb/) table for product storage with streams enabled
- [SNS Topic](https://docs.localstack.cloud/aws/services/sns/) for publishing failed requests during outages
- [SQS Queue](https://docs.localstack.cloud/aws/services/sqs/) for buffering requests when DynamoDB is unavailable

**Secondary Region (us-west-1):**

- Identical service stack for failover scenarios
- DynamoDB table synchronized via streams and Lambda replication
- Independent health check endpoint for Route53 monitoring

**Cross-Region Components:**

- [Route53](https://docs.localstack.cloud/aws/services/route53/) hosted zone with health checks and failover routing policies
- DNS-based traffic routing with automatic failover capabilities

## Prerequisites

- [`LOCALSTACK_AUTH_TOKEN`](https://docs.localstack.cloud/getting-started/auth-token/)
- [Docker](https://docs.docker.com/get-docker/) and [Docker Compose](https://docs.docker.com/compose/install/)
- [AWS CLI](https://docs.localstack.cloud/user-guide/integrations/aws-cli/) with the [`awslocal` wrapper](https://docs.localstack.cloud/user-guide/integrations/aws-cli/#localstack-aws-cli-awslocal)
- [Maven 3.8.5+](https://maven.apache.org/install.html) & [Java 17](https://www.java.com/en/download/help/download_options.html)
- [Python 3.11+](https://www.python.org/downloads/)
- [`make`](https://www.gnu.org/software/make/) (**optional**, but recommended for running the sample application)
- [`dig`](https://linux.die.net/man/1/dig) command-line DNS lookup utility

## Installation

To run the sample application, you need to install the required dependencies.

First, clone the repository:

```shell
git clone https://github.com/localstack-samples/sample-chaos-serverless-multi-region-failover.git
```

Then, navigate to the project directory:

```shell
cd sample-chaos-serverless-multi-region-failover
```

Install the project dependencies by running the following command:

```shell
make install
```

This will:

- Build the Java Lambda functions and package them into JAR files
- Install Python test dependencies for the integration test suite

## Deployment

Start LocalStack using Docker Compose with the `LOCALSTACK_AUTH_TOKEN` pre-configured:

```shell
LOCALSTACK_AUTH_TOKEN=<your-auth-token> docker compose up
```

The infrastructure will be automatically deployed using LocalStack's [Initialization Hooks](https://docs.localstack.cloud/aws/capabilities/config/initialization-hooks/). The deployment creates:

- DynamoDB tables in both `us-east-1` and `us-west-1` regions
- Lambda functions for product management and health checks  
- API Gateway endpoints with custom domain configurations
- SNS topics and SQS queues for message buffering
- DynamoDB streams with replication Lambda triggers

To deploy additional chaos engineering scenarios, run:

```shell
make deploy
```

This executes the solution scripts:

```shell
./solutions/dynamodb-outage.sh    # Sets up DynamoDB outage handling
./solutions/route53-failover.sh   # Configures Route53 DNS failover
```

## Testing

The sample application provides comprehensive test coverage for both chaos engineering scenarios.

### Running All Tests

Execute the complete test suite:

```shell
make test
```

This runs:
- DynamoDB outage resilience tests
- Route53 DNS failover validation
- End-to-end integration scenarios

### Manual Testing

Test normal product operations:

```shell
curl --location 'http://12345.execute-api.localhost.localstack.cloud:4566/dev/productApi' \
  --header 'Content-Type: application/json' \
  --data '{
    "id": "prod-2024",
    "name": "Test Product",
    "price": "29.99",
    "description": "A product for testing chaos scenarios"
  }'
```

Expected response: `Product added/updated successfully.`

### DNS Resolution Testing

Verify Route53 failover configuration:

```shell
dig @localhost test.hello-localstack.com CNAME
```

This should resolve to the primary API Gateway endpoint initially, then switch to the secondary during outages.

## Use Cases

### Chaos Engineering

This sample demonstrates comprehensive chaos engineering practices by using LocalStack's Chaos API to inject controlled failures into your infrastructure. The chaos testing validates that your application can gracefully handle service outages without data loss.

The application includes sophisticated error handling for database outages. When DynamoDB becomes unavailable, the Lambda functions:

1. Catch `DynamoDbException` errors from AWS SDK calls
2. Return user-friendly error messages instead of failing completely  
3. Publish failed requests to SNS for later processing
4. Use SQS dead letter queues and retry mechanisms
5. Automatically process queued items when services recover

To simulate a DynamoDB outage:

```shell
curl -X POST 'http://localhost:4566/_localstack/chaos/faults' \
  -H 'Content-Type: application/json' \
  -d '[{"service": "dynamodb", "region": "us-east-1"}]'
```

During the outage, product creation requests are gracefully handled:

```shell
curl --location 'http://12345.execute-api.localhost.localstack.cloud:4566/dev/productApi' \
  --data '{"id": "prod-outage", "name": "Outage Test", "price": "19.99", "description": "Testing resilience"}'
```

Expected response: `A DynamoDB error occurred. Message sent to queue.`

The message is automatically processed when you clear the outage:

```shell
curl -X DELETE 'http://localhost:4566/_localstack/chaos/faults' \
  -H 'Content-Type: application/json' \
  -d '[]'
```

Query the DynamoDB table to see the product:

```shell
awslocal dynamodb scan --table-name Products
```

The key chaos engineering patterns used in this sample are:

- Using LocalStack Chaos API for controlled service failures
- Monitoring application behavior during failure scenarios
- Ensuring systems return to normal operation after faults clear
- Limiting failures to specific services and regions
- Validating resilience through repeatable test scenarios

### Route53 DNS Failover

The sample showcases advanced DNS failover capabilities using Route53 health checks and routing policies. This ensures high availability by automatically redirecting traffic from failed regions to healthy alternatives.

The Route53 setup includes:

1. Monitoring primary region endpoints every 10 seconds
2. Primary and secondary CNAME records with different priorities
3. Services deployed across `us-east-1` (primary) and `us-west-1` (secondary)
4. DNS resolution changes based on health check status
5. Traffic automatically returns to primary when healthy

Verify initial DNS resolution points to primary:

```shell
dig @localhost test.hello-localstack.com CNAME
# Expected: 12345.execute-api.localhost.localstack.cloud
```

Inject chaos into the primary region:

```shell
curl -X POST 'http://localhost:4566/_localstack/chaos/faults' \
  -H 'Content-Type: application/json' \
  -d '[
    {"service": "apigateway", "region": "us-east-1"},
    {"service": "lambda", "region": "us-east-1"}
  ]'
```

Wait for health check failures and verify the failover:

```shell
dig @localhost test.hello-localstack.com CNAME  
# Expected: 67890.execute-api.localhost.localstack.cloud
```

Clear the chaos to test failback:

```shell
curl -X DELETE 'http://localhost:4566/_localstack/chaos/faults' \
  -H 'Content-Type: application/json' \
  -d '[]'
```

## Troubleshooting

| Issue | Resolution |
|-------|------------|
| DNS resolution returns NXDOMAIN | Ensure LocalStack is running with DNS enabled (port 53). Verify hosted zone exists with `awslocal route53 list-hosted-zones` |
| Health checks always report unhealthy | Check that API Gateway endpoints respond with HTTP 200. Verify Lambda functions are deployed and working: `awslocal lambda list-functions` |
| Failover not triggering after chaos injection | Wait at least 25 seconds for health check failure threshold. Check chaos faults are active: `curl --location --request GET 'http://localhost.localstack.cloud:4566/_localstack/chaos/faults'` |
| Products not appearing in DynamoDB after recovery | Verify SQS queue processing with `awslocal sqs receive-message`. Check Lambda function logs for processing errors |

## Learn More

- [LocalStack Chaos Engineering](https://docs.localstack.cloud/chaos-engineering/) (**recommended**)
- [Route53 Health Checks and Failover](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-failover.html)  
- [Chaos Engineering Principles](https://principlesofchaos.org/)
- [Testing resilience in cloud applications with LocalStack](https://blog.localstack.cloud/tags/Chaos%20Engineering/)
- [AWS Lambda Best Practices](https://docs.aws.amazon.com/lambda/latest/dg/best-practices.html)
- [DynamoDB Streams and Triggers](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Streams.html)
- [SNS/SQS Messaging Patterns](https://docs.aws.amazon.com/sns/latest/dg/sns-sqs-as-subscriber.html)
