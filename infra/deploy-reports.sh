#!/usr/bin/env bash
# Deploys the weekly meetings report infrastructure (S3, SQS, EventBridge, builder & mailer Lambdas).
# Run via `make deploy-reports` after setting AWS credentials and RECIPIENT_EMAIL in .env.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  REPORTS_STACK="$PROJECT_NAME-reports"

  # Ensure backend stack is deployed first
  if ! stack_exists "$BACKEND_STACK"; then
    echo "Error: Backend stack '$BACKEND_STACK' does not exist. Run 'make deploy-backend' first." >&2
    exit 1
  fi

  account="$(aws sts get-caller-identity --query Account --output text)"
  echo "==> Deploying '$REPORTS_STACK' in account $account ($AWS_REGION)"

  # 1. Image URI: reuse current backend container image
  image="$(aws lambda get-function-configuration --function-name "$PROJECT_NAME-backend" --query "Code.ImageUri" --output text 2>/dev/null || true)"
  if [ -z "$image" ] || [ "$image" = "None" ]; then
    repository="$(output "$ECR_STACK" RepositoryUri)"
    TAG="$(git rev-parse --short HEAD)"
    image="$repository:$TAG"
  fi
  echo "    Image URI: $image"

  # 2. VPC, Subnets, Security Group from Backend stack resources
  echo "==> Resolving VPC & network resources from $BACKEND_STACK"
  vpc_id="$(aws cloudformation describe-stack-resources --stack-name "$BACKEND_STACK" \
    --logical-resource-id Vpc --query "StackResources[0].PhysicalResourceId" --output text)"
  subnet_a="$(aws cloudformation describe-stack-resources --stack-name "$BACKEND_STACK" \
    --logical-resource-id PrivateSubnetA --query "StackResources[0].PhysicalResourceId" --output text)"
  subnet_b="$(aws cloudformation describe-stack-resources --stack-name "$BACKEND_STACK" \
    --logical-resource-id PrivateSubnetB --query "StackResources[0].PhysicalResourceId" --output text)"
  subnet_ids="$subnet_a,$subnet_b"
  sg_id="$(aws cloudformation describe-stack-resources --stack-name "$BACKEND_STACK" \
    --logical-resource-id FunctionSecurityGroup --query "StackResources[0].PhysicalResourceId" --output text)"

  # 3. Route table for S3 Gateway Endpoint
  route_table_id="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" "Name=association.main,Values=true" \
    --query "RouteTables[0].RouteTableId" --output text)"
  echo "    VpcId: $vpc_id"
  echo "    Subnets: $subnet_ids"
  echo "    SecurityGroup: $sg_id"
  echo "    RouteTable: $route_table_id"

  # 4. Database URL from backend function environment
  database_url="$(aws lambda get-function-configuration --function-name "$PROJECT_NAME-backend" \
    --query "Environment.Variables.DATABASE_URL" --output text)"

  # 5. SES sender and recipient emails
  # If RECIPIENT_EMAIL is not passed, attempt to find a verified SES identity
  recipient="${RECIPIENT_EMAIL:-${REPORT_EMAIL:-}}"
  if [ -z "$recipient" ]; then
    verified_identity="$(aws sesv2 list-email-identities --query "EmailIdentities[0].IdentityName" --output text 2>/dev/null || true)"
    if [ -n "$verified_identity" ] && [ "$verified_identity" != "None" ]; then
      recipient="$verified_identity"
      echo "    Using verified SES identity as recipient: $recipient"
    else
      echo "Error: RECIPIENT_EMAIL is not set in .env and no verified SES identity was found." >&2
      echo "Please set RECIPIENT_EMAIL in .env or verify an email in Amazon SES." >&2
      exit 1
    fi
  fi
  sender="${SENDER_EMAIL:-$recipient}"
  echo "    Sender email: $sender"
  echo "    Recipient email: $recipient"

  echo "==> Deploying CloudFormation stack '$REPORTS_STACK'..."
  aws cloudformation deploy \
    --stack-name "$REPORTS_STACK" \
    --template-file infra/reports.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
      "ProjectName=$PROJECT_NAME" \
      "ImageUri=$image" \
      "VpcId=$vpc_id" \
      "SubnetIds=$subnet_ids" \
      "SecurityGroupId=$sg_id" \
      "RouteTableId=$route_table_id" \
      "DatabaseUrl=$database_url" \
      "SenderEmail=$sender" \
      "RecipientEmail=$recipient" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  bucket="$(output "$REPORTS_STACK" ReportsBucket)"
  queue="$(output "$REPORTS_STACK" ReportRequestsQueueUrl)"
  echo
  echo "==> Reports stack deployed successfully!"
  echo "    Reports Bucket: s3://$bucket"
  echo "    SQS Queue:      $queue"
  echo "    Builder Lambda: $(output "$REPORTS_STACK" BuilderFunction)"
  echo "    Mailer Lambda:  $(output "$REPORTS_STACK" MailerFunction)"
  echo
  echo "To trigger an on-demand report, run:"
  echo "    make report-now WEEK=2026-W41"
}

main "$@"
