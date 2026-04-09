#!/bin/bash
set -uo pipefail
export AWS_PAGER=""

export AWS_REGION="${AWS_REGION:-us-east-1}"
export DOMAIN_NAME="${DOMAIN_NAME:?Set DOMAIN_NAME env var}"
export PROJECT_NAME="${PROJECT_NAME:-taskapp}"
export CLUSTER_NAME="${PROJECT_NAME}.k8s.${DOMAIN_NAME}"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export KOPS_STATE_STORE="s3://${PROJECT_NAME}-kops-state-${AWS_ACCOUNT_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "========================================="
echo "  TaskApp Full Destroy"
echo "  Domain: ${DOMAIN_NAME}"
echo "  Account: ${AWS_ACCOUNT_ID}"
echo "========================================="
echo ""
echo "This will destroy ALL infrastructure and stop AWS charges."
echo "Press Enter to continue or Ctrl+C to cancel..."
read

echo "[>] Deleting Kubernetes namespaces..."
kubectl delete namespace taskapp --ignore-not-found 2>/dev/null
kubectl delete namespace ingress-nginx --ignore-not-found 2>/dev/null
sleep 30

echo "[>] Deleting Kops cluster..."
kops delete cluster --name "${CLUSTER_NAME}" --state="${KOPS_STATE_STORE}" --yes 2>/dev/null

echo "[>] Deleting ECR repositories..."
aws ecr delete-repository --repository-name ${PROJECT_NAME}-backend --force --region ${AWS_REGION} 2>/dev/null
aws ecr delete-repository --repository-name ${PROJECT_NAME}-frontend --force --region ${AWS_REGION} 2>/dev/null

echo "[>] Emptying S3 buckets (including versioned objects)..."
for bucket in "${PROJECT_NAME}-kops-state-${AWS_ACCOUNT_ID}" "${PROJECT_NAME}-terraform-state-${AWS_ACCOUNT_ID}" "${PROJECT_NAME}-etcd-backups-${AWS_ACCOUNT_ID}"; do
  aws s3 rm "s3://${bucket}" --recursive 2>/dev/null
  aws s3api delete-objects --bucket "$bucket" --delete "$(aws s3api list-object-versions --bucket "$bucket" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)" 2>/dev/null
  aws s3api delete-objects --bucket "$bucket" --delete "$(aws s3api list-object-versions --bucket "$bucket" --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)" 2>/dev/null
done

echo "[>] Running Terraform destroy..."
cd "$PROJECT_DIR/terraform/environments/prod"
terraform destroy -auto-approve 2>/dev/null
cd "$PROJECT_DIR"

echo "[>] Cleaning up IAM resources..."
for policy in AmazonEC2FullAccess AmazonRoute53FullAccess AmazonS3FullAccess IAMFullAccess AmazonVPCFullAccess AmazonSQSFullAccess AmazonEventBridgeFullAccess; do
  aws iam detach-user-policy --user-name ${PROJECT_NAME}-kops-admin --policy-arn "arn:aws:iam::aws:policy/${policy}" 2>/dev/null
done
aws iam list-access-keys --user-name ${PROJECT_NAME}-kops-admin --query "AccessKeyMetadata[*].AccessKeyId" --output text 2>/dev/null | tr '\t' '\n' | xargs -I{} aws iam delete-access-key --user-name ${PROJECT_NAME}-kops-admin --access-key-id {}
aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${PROJECT_NAME}-ebs-csi-policy" 2>/dev/null
aws iam delete-user --user-name ${PROJECT_NAME}-kops-admin 2>/dev/null

echo "[>] Deleting S3 buckets..."
for bucket in "${PROJECT_NAME}-kops-state-${AWS_ACCOUNT_ID}" "${PROJECT_NAME}-terraform-state-${AWS_ACCOUNT_ID}" "${PROJECT_NAME}-etcd-backups-${AWS_ACCOUNT_ID}"; do
  aws s3 rb "s3://${bucket}" --force 2>/dev/null
done

echo "[>] Releasing orphaned Elastic IPs..."
aws ec2 describe-addresses --query "Addresses[?AssociationId==null].AllocationId" --output text | tr '\t' '\n' | xargs -I{} aws ec2 release-address --allocation-id {} 2>/dev/null

echo "[>] Deleting orphaned Route 53 hosted zones..."
aws route53 list-hosted-zones --query "HostedZones[*].Id" --output text | tr '\t' '\n' | sed 's|/hostedzone/||' | while read zone; do
  aws route53 list-resource-record-sets --hosted-zone-id "$zone" --query "ResourceRecordSets[?Type!='NS'&&Type!='SOA']" --output json 2>/dev/null | \
  jq -c '.[]' 2>/dev/null | while read record; do
    aws route53 change-resource-record-sets --hosted-zone-id "$zone" --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":$record}]}" 2>/dev/null
  done
  aws route53 delete-hosted-zone --id "$zone" 2>/dev/null
done

echo "[>] Deleting DynamoDB lock table..."
aws dynamodb delete-table --table-name ${PROJECT_NAME}-terraform-locks 2>/dev/null

echo ""
echo "========================================="
echo "  Verifying clean slate..."
echo "========================================="
echo ""
echo "VPCs:"
aws ec2 describe-vpcs --query "Vpcs[*].[VpcId,Tags[?Key=='Name'].Value|[0]]" --output table 2>/dev/null
echo ""
echo "Route53 Zones:"
aws route53 list-hosted-zones --query "HostedZones[*].[Name,Id]" --output table 2>/dev/null
echo ""
echo "S3 Buckets:"
aws s3 ls 2>/dev/null | grep taskapp || echo "  None"
echo ""
echo "Elastic IPs:"
aws ec2 describe-addresses --query "Addresses[*].[AllocationId,PublicIp]" --output table 2>/dev/null || echo "  None"
echo ""
echo "DynamoDB Tables:"
aws dynamodb list-tables --query "TableNames" --output text 2>/dev/null || echo "  None"
echo ""
echo "========================================="
echo "  Destroy complete!"
echo "========================================="
