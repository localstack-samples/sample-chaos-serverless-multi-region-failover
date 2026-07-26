#!/bin/bash

set -e
set -o pipefail

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

# Step 1: Define Hosted Zone
log "Defining hosted zone..."
HOSTED_ZONE_NAME="hello-localstack.com"
RAW_HOSTED_ZONE_ID=$(lstk aws route53 create-hosted-zone \
    --name "$HOSTED_ZONE_NAME" \
    --caller-reference "zone-$(date +%s)" | jq -r .HostedZone.Id)
CLEANED_HOSTED_ZONE_ID="${RAW_HOSTED_ZONE_ID#/hostedzone/}"

log "Hosted Zone Name: $HOSTED_ZONE_NAME"
log "Raw Hosted Zone ID: $RAW_HOSTED_ZONE_ID"
export HOSTED_ZONE_NAME RAW_HOSTED_ZONE_ID

# Step 2: Define API Gateway and Health Check Parameters
log "Defining API Gateway and health check parameters..."
PRIMARY_API_ID="12345"
SECONDARY_API_ID="67890"
PRIMARY_API_REGION="us-east-1"
HEALTH_CHECK_RESOURCE_PATH="/dev/healthcheck"
PRIMARY_API_GATEWAY_FQDN="${PRIMARY_API_ID}.execute-api.localhost.localstack.cloud"
HEALTH_CHECK_PORT=4566

log "Primary API ID: $PRIMARY_API_ID"
log "Primary API FQDN: $PRIMARY_API_GATEWAY_FQDN"
log "Health Check Port: $HEALTH_CHECK_PORT"
log "Health Check Path: $HEALTH_CHECK_RESOURCE_PATH"

# Step 3: Create Health Check for the Primary API Gateway
log "Creating Route 53 health check..."
HEALTH_CHECK_RESOURCE_REGION="us-west-1"
HEALTH_CHECK_ID=$(lstk aws route53 create-health-check \
    --caller-reference "hc-app-${PRIMARY_API_ID}-$(date +%s)" \
    --region "$HEALTH_CHECK_RESOURCE_REGION" \
    --health-check-config "{\"FullyQualifiedDomainName\": \"${PRIMARY_API_GATEWAY_FQDN}\", \"Port\": ${HEALTH_CHECK_PORT}, \"ResourcePath\": \"${HEALTH_CHECK_RESOURCE_PATH}\", \"Type\": \"HTTP\", \"RequestInterval\": 10, \"FailureThreshold\": 2}" | jq -r .HealthCheck.Id)

log "Health check created with ID: $HEALTH_CHECK_ID in region $HEALTH_CHECK_RESOURCE_REGION"
export HEALTH_CHECK_ID
sleep 5

# Step 4: Verify Initial Health
log "Verifying primary health check endpoint (expect HTTP 200)..."
curl --connect-timeout 5 -v "http://${PRIMARY_API_GATEWAY_FQDN}:${HEALTH_CHECK_PORT}${HEALTH_CHECK_RESOURCE_PATH}" || true

log "Fetching health check status from Route 53 (may take a few seconds)..."
sleep 25
lstk aws route53 get-health-check-status \
    --health-check-id "$HEALTH_CHECK_ID" \
    --region "$HEALTH_CHECK_RESOURCE_REGION" >/dev/null

# Step 5: Create CNAME Records
log "Creating CNAME records for regional endpoints..."
PRIMARY_REGIONAL_DNS_NAME="${PRIMARY_API_ID}.${HOSTED_ZONE_NAME}"
SECONDARY_REGIONAL_DNS_NAME="${SECONDARY_API_ID}.${HOSTED_ZONE_NAME}"
PRIMARY_API_TARGET_FQDN="${PRIMARY_API_ID}.execute-api.localhost.localstack.cloud"
SECONDARY_API_TARGET_FQDN="${SECONDARY_API_ID}.execute-api.localhost.localstack.cloud"

CHANGE_BATCH_REGIONAL_CNAMES_JSON=$(cat <<EOF
{
  "Comment": "Creating CNAMEs for regional API endpoints",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$PRIMARY_REGIONAL_DNS_NAME",
        "Type": "CNAME",
        "TTL": 60,
        "ResourceRecords": [{ "Value": "$PRIMARY_API_TARGET_FQDN" }]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$SECONDARY_REGIONAL_DNS_NAME",
        "Type": "CNAME",
        "TTL": 60,
        "ResourceRecords": [{ "Value": "$SECONDARY_API_TARGET_FQDN" }]
      }
    }
  ]
}
EOF
)

lstk aws route53 change-resource-record-sets \
    --hosted-zone-id "$RAW_HOSTED_ZONE_ID" \
    --change-batch "$CHANGE_BATCH_REGIONAL_CNAMES_JSON" >/dev/null
log "CNAME records created."

# Step 6: Create Failover Alias Records
log "Creating failover alias records..."
FAILOVER_RECORD_NAME="test.${HOSTED_ZONE_NAME}"
PRIMARY_FAILOVER_SET_ID="primary-app-${PRIMARY_API_ID}"
SECONDARY_FAILOVER_SET_ID="secondary-app-${SECONDARY_API_ID}"

CHANGE_BATCH_FAILOVER_ALIASES_JSON=$(cat <<EOF
{
  "Comment": "Creating failover alias records for $FAILOVER_RECORD_NAME",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$FAILOVER_RECORD_NAME",
        "Type": "CNAME",
        "SetIdentifier": "$PRIMARY_FAILOVER_SET_ID",
        "Failover": "PRIMARY",
        "HealthCheckId": "$HEALTH_CHECK_ID",
        "AliasTarget": {
          "HostedZoneId": "$RAW_HOSTED_ZONE_ID",
          "DNSName": "$PRIMARY_REGIONAL_DNS_NAME",
          "EvaluateTargetHealth": true
        }
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$FAILOVER_RECORD_NAME",
        "Type": "CNAME",
        "SetIdentifier": "$SECONDARY_FAILOVER_SET_ID",
        "Failover": "SECONDARY",
        "AliasTarget": {
          "HostedZoneId": "$RAW_HOSTED_ZONE_ID",
          "DNSName": "$SECONDARY_REGIONAL_DNS_NAME",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOF
)

lstk aws route53 change-resource-record-sets \
    --hosted-zone-id "$RAW_HOSTED_ZONE_ID" \
    --change-batch "$CHANGE_BATCH_FAILOVER_ALIASES_JSON" >/dev/null
log "Failover alias records created."

# Final Output
echo
echo -e "${BLUE}Route 53 and failover setup completed successfully.${NC}"
echo -e "${BLUE}Hosted Zone:${NC} $HOSTED_ZONE_NAME"
echo -e "${BLUE}Primary API FQDN:${NC} $PRIMARY_API_GATEWAY_FQDN"
echo -e "${BLUE}Health Check ID:${NC} $HEALTH_CHECK_ID"
echo -e "${BLUE}Failover Domain:${NC} $FAILOVER_RECORD_NAME"
