#!/bin/sh
# Runs inside LocalStack once it is ready. Creates the same SQS queues the
# Terraform sqs_messaging module provisions in AWS (price-sync + pdf-ingest,
# each with a DLQ). search-sync-worker consumes price-sync.
set -e
export AWS_DEFAULT_REGION=ap-south-1   # match the services' AWS__Region
for q in appstack-price-sync-dlq appstack-price-sync \
         appstack-pdf-ingest-dlq appstack-pdf-ingest; do
  awslocal sqs create-queue --queue-name "$q" --region ap-south-1 >/dev/null
  echo "created queue: $q (ap-south-1)"
done
