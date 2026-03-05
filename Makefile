export AWS_ACCESS_KEY_ID ?= test
export AWS_SECRET_ACCESS_KEY ?= test
export AWS_DEFAULT_REGION=us-east-1
SHELL := /bin/bash

usage:			## Show this help in table format
	@echo "| Target                 | Description                                                       |"
	@echo "|------------------------|-------------------------------------------------------------------|"
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/:.*##\s*/##/g' | awk -F'##' '{ printf "| %-22s | %-65s |\n", $$1, $$2 }'


check:			## Check if all required prerequisites are installed
	@command -v docker > /dev/null 2>&1 || { echo "Docker is not installed. Please install Docker and try again."; exit 1; }
	@command -v localstack > /dev/null 2>&1 || { echo "LocalStack is not installed. Please install LocalStack and try again."; exit 1; }
	@command -v terraform > /dev/null 2>&1 || { echo "Terraform is not installed. Please install Terraform and try again."; exit 1; }
	@command -v mvn > /dev/null 2>&1 || { echo "Maven is not installed. Please install Maven and try again."; exit 1; }
	@command -v java > /dev/null 2>&1 || { echo "Java is not installed. Please install Java and try again."; exit 1; }
	@command -v aws > /dev/null 2>&1 || { echo "AWS CLI is not installed. Please install AWS CLI and try again."; exit 1; }
	@command -v awslocal > /dev/null 2>&1 || { echo "awslocal is not installed. Please install awslocal and try again."; exit 1; }
	@command -v python3 > /dev/null 2>&1 || { echo "Python 3 is not installed. Please install Python 3 and try again."; exit 1; }
	@echo "All required prerequisites are available."

install:			## Install all required dependencies
	@echo "Installing all required dependencies..."
	cd lambda-functions && mvn clean package shade:shade;
	cd tests && pip install -r requirements-dev.txt;
	@echo "All required dependencies installed successfully."

test:			## Run all tests
	@echo "Running all tests..."
	pytest tests/
	@echo "All tests completed successfully."

deploy:			## Deploy all solutions
	@echo "Deploying all solutions..."
	./solutions/dynamodb-outage.sh
	./solutions/route53-failover.sh
	@echo "All solutions deployed successfully."

start:			## Start localstack
	@test -n "${LOCALSTACK_AUTH_TOKEN}" || (echo "LOCALSTACK_AUTH_TOKEN is not set. Find your token at https://app.localstack.cloud/workspace/auth-token"; exit 1)
	LOCALSTACK_AUTH_TOKEN=$(LOCALSTACK_AUTH_TOKEN) docker compose up --build --detach --wait

stop:			## Stop localstack
	docker compose down

logs:			## Show logs from LocalStack
	docker compose logs > logs.txt

ready:			## Wait until LocalStack is ready
	@echo "Waiting for LocalStack to be ready..."
	@while [[ "$$(curl -s localhost:4566/_localstack/init/ready | jq -r .completed)" != "true" ]]; do \
		echo "LocalStack not ready yet, waiting..."; \
		sleep 2; \
	done
	@echo "LocalStack is ready!"

.PHONY: usage check install start ready deploy test logs stop
