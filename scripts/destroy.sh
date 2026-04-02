set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

export AWS_REGION="${AWS_REGION:-us-east-1}"
export DOMAIN_NAME="${DOMAIN_NAME:?Set DOMAIN_NAME}"
export PROJECT_NAME="${PROJECT_NAME:-taskapp}"
export CLUSTER_NAME="${PROJECT_NAME}.k8s.${DOMAIN_NAME}"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export KOPS_STATE_STORE="s3://${PROJECT_NAME}-kops-state-${AWS_ACCOUNT_ID}"

echo -e "${RED}"
echo "---"
echo "  WARNING: This will destroy all infrastructure"
echo "  This will DELETE all infrastructure:"
echo "  - Kubernetes cluster (all pods, services)"
echo "  - VPC, subnets, NAT gateways"
echo "  - Route53 zones"
echo "  - S3 buckets"
echo "  - IAM resources"
echo "---"
echo -e "${NC}"
echo ""
echo "Type 'DESTROY' to confirm:"
read -r confirm
[[ "$confirm" == "DESTROY" ]] || { echo "Aborted."; exit 1; }

# Step 1: Delete K8s resources (releases LBs, EBS volumes)
echo -e "${YELLOW}[1/4] Deleting Kubernetes resources...${NC}"
kubectl delete namespace taskapp --ignore-not-found=true 2>/dev/null || true
kubectl delete namespace ingress-nginx --ignore-not-found=true 2>/dev/null || true
sleep 30  # Wait for LBs to be released

# Step 2: Delete Kops cluster
echo -e "${YELLOW}[2/4] Deleting Kops cluster...${NC}"
kops delete cluster --name "${CLUSTER_NAME}" --state="${KOPS_STATE_STORE}" --yes 2>/dev/null || \
    echo "Kops cluster already deleted or not found"

# Step 3: Delete ECR repos
echo -e "${YELLOW}[3/4] Deleting ECR repositories...${NC}"
for repo in taskapp-backend taskapp-frontend; do
    aws ecr delete-repository --repository-name "$repo" --force --region "$AWS_REGION" 2>/dev/null || true
done

# Step 4: Terraform destroy
echo -e "${YELLOW}[4/4] Destroying Terraform infrastructure...${NC}"
cd terraform/environments/prod

# Empty S3 buckets first (terraform can't destroy non-empty buckets)
for bucket in "${PROJECT_NAME}-kops-state-${AWS_ACCOUNT_ID}" \
              "${PROJECT_NAME}-terraform-state-${AWS_ACCOUNT_ID}" \
              "${PROJECT_NAME}-etcd-backups-${AWS_ACCOUNT_ID}"; do
    echo "Emptying bucket: $bucket"
    aws s3 rm "s3://${bucket}" --recursive 2>/dev/null || true
    # Delete versioned objects too
    aws s3api list-object-versions --bucket "$bucket" --output json 2>/dev/null | \
        jq -r '.Versions[]? | "\(.Key) \(.VersionId)"' | \
        while read -r key vid; do
            aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$vid" 2>/dev/null || true
        done
    aws s3api list-object-versions --bucket "$bucket" --output json 2>/dev/null | \
        jq -r '.DeleteMarkers[]? | "\(.Key) \(.VersionId)"' | \
        while read -r key vid; do
            aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$vid" 2>/dev/null || true
        done
done

terraform destroy -auto-approve
cd ../../..

echo ""
echo ""
echo -e "${GREEN}  All infrastructure destroyed.${NC}"
echo -e "${GREEN}  Don't forget to remove NS records${NC}"
echo -e "${GREEN}  from your domain registrar.${NC}"
echo ""
