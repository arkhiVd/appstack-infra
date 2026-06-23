#!/bin/sh
# Runs after create-queues.sh (alphabetical). Creates the PDF/CSV ingest bucket
# and wires S3 ObjectCreated events to the pdf-ingest SQS queue — the same link
# the Terraform sqs_messaging module sets up in AWS.
set -e
export AWS_DEFAULT_REGION=ap-south-1
R=ap-south-1
BUCKET=appstack-pdf-ingest

awslocal s3api create-bucket --bucket "$BUCKET" --region "$R" \
  --create-bucket-configuration LocationConstraint="$R" >/dev/null
echo "created bucket: $BUCKET"

QURL=$(awslocal sqs get-queue-url --queue-name appstack-pdf-ingest --region "$R" --query QueueUrl --output text)
QARN=$(awslocal sqs get-queue-attributes --queue-url "$QURL" --region "$R" \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

awslocal s3api put-bucket-notification-configuration --bucket "$BUCKET" --region "$R" \
  --notification-configuration "{\"QueueConfigurations\":[{\"QueueArn\":\"$QARN\",\"Events\":[\"s3:ObjectCreated:*\"]}]}"
echo "wired s3://$BUCKET ObjectCreated -> $QARN"
