echo "--- Step 7: Verify Initial DNS Resolution (Primary) ---"
echo "Waiting a bit for DNS changes to apply..."
sleep 15
echo "Querying $FAILOVER_RECORD_NAME (should point to primary CNAME/target):"
dig @127.0.0.1 "$FAILOVER_RECORD_NAME" CNAME +short
echo

echo "--- Step 8: Simulate Primary API Gateway & Lambda Failure in $PRIMARY_API_REGION using Chaos API ---"
echo "Injecting faults for apigateway and lambda services in $PRIMARY_API_REGION..."
curl -L --request POST 'http://localhost:4566/_localstack/chaos/faults' \
--header 'Content-Type: application/json' \
--data "[
    {\"service\": \"apigateway\", \"region\": \"${PRIMARY_API_REGION}\"},
    {\"service\": \"lambda\", \"region\": \"${PRIMARY_API_REGION}\"}
]"
echo # for newline
echo

echo "Waiting for Route 53 to detect health check failure and failover (approx 30-40s)..."
sleep 40

echo "--- Step 9: Verify DNS Failover to Secondary ---"
echo "Querying $FAILOVER_RECORD_NAME (should now point to secondary CNAME/target):"
dig @127.0.0.1 "$FAILOVER_RECORD_NAME" CNAME +short
echo
echo "You can also try fetching the health check status again:"
lstk aws route53 get-health-check-status --health-check-id "$HEALTH_CHECK_ID" --region "$HEALTH_CHECK_RESOURCE_REGION"
echo
echo

echo "--- Step 10: Clear Service-Specific Faults (Simulate Primary Recovery) ---"
echo "Clearing faults for apigateway and lambda services in $PRIMARY_API_REGION..."
curl --location --request POST 'http://localhost.localstack.cloud:4566/_localstack/chaos/faults' \
--header 'Content-Type: application/json' \
--data '[]'

echo # for newline
echo

echo "Waiting for Route 53 to detect health check recovery and failback (approx 30-40s)..."
sleep 40

echo "--- Step 11: Verify DNS Failback to Primary ---"
echo "Querying $FAILOVER_RECORD_NAME (should point back to primary CNAME/target):"
dig @127.0.0.1 "$FAILOVER_RECORD_NAME" CNAME +short
echo
echo "Final health check status:"
lstk aws route53 get-health-check-status --health-check-id "$HEALTH_CHECK_ID" --region "$HEALTH_CHECK_RESOURCE_REGION"
echo

echo "Script finished."
