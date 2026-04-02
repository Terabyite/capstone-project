set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check() {
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        echo -e "${GREEN}  ✔ ${desc}${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}  ✘ ${desc}${NC}"
        FAIL=$((FAIL + 1))
    fi
}

warn_check() {
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        echo -e "${GREEN}  ✔ ${desc}${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${YELLOW}  ⚠ ${desc} (warning)${NC}"
        WARN=$((WARN + 1))
    fi
}

DOMAIN_NAME="${DOMAIN_NAME:?Set DOMAIN_NAME}"
CLUSTER_NAME="${PROJECT_NAME:-taskapp}.k8s.${DOMAIN_NAME}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
KOPS_STATE_STORE="s3://${PROJECT_NAME:-taskapp}-kops-state-${AWS_ACCOUNT_ID}"

echo ""
echo "---"
echo "  TaskApp Validation Suite"
echo "  Domain: ${DOMAIN_NAME}"
echo "---"
echo ""

# ---- 1. Cluster Health ----
echo "1. CLUSTER HEALTH"
check "kops validate cluster" \
    kops validate cluster --name "${CLUSTER_NAME}" --state="${KOPS_STATE_STORE}"

MASTER_COUNT=$(kubectl get nodes --selector='node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l)
WORKER_COUNT=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l)

check "3+ master nodes (found: ${MASTER_COUNT})" [ "$MASTER_COUNT" -ge 3 ]
check "3+ worker nodes (found: ${WORKER_COUNT})" [ "$WORKER_COUNT" -ge 3 ]
check "All nodes Ready" \
    bash -c '[ $(kubectl get nodes --no-headers | grep -c "Ready") -eq $(kubectl get nodes --no-headers | wc -l) ]'

echo ""

# ---- 2. Multi-AZ Distribution ----
echo "2. MULTI-AZ DISTRIBUTION"
AZ_COUNT=$(kubectl get nodes -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' | tr ' ' '\n' | sort -u | wc -l)
check "Nodes spread across 3+ AZs (found: ${AZ_COUNT})" [ "$AZ_COUNT" -ge 3 ]
echo ""

# ---- 3. Application Pods ----
echo "3. APPLICATION PODS"
check "Namespace taskapp exists" kubectl get namespace taskapp
check "Backend pods running (2+ replicas)" \
    bash -c '[ $(kubectl get pods -n taskapp -l app=backend --field-selector=status.phase=Running --no-headers | wc -l) -ge 2 ]'
check "Frontend pods running (2+ replicas)" \
    bash -c '[ $(kubectl get pods -n taskapp -l app=frontend --field-selector=status.phase=Running --no-headers | wc -l) -ge 2 ]'
check "Postgres pod running" \
    bash -c '[ $(kubectl get pods -n taskapp -l app=postgres --field-selector=status.phase=Running --no-headers | wc -l) -ge 1 ]'
echo ""

# ---- 4. Resource Limits ----
echo "4. RESOURCE LIMITS"
BACKEND_MEM=$(kubectl get deployment backend -n taskapp -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null)
check "Backend memory limit is 526Mi (found: ${BACKEND_MEM})" [ "$BACKEND_MEM" = "526Mi" ]
echo ""

# ---- 5. HTTPS & SSL ----
echo "5. HTTPS & SSL"
check "Frontend HTTPS responds 200" \
    bash -c 'curl -sSf -o /dev/null -w "%{http_code}" "https://taskapp.${DOMAIN_NAME}" | grep -q 200'
check "Backend health (taskapp host)" \
    bash -c 'curl -sSf "https://taskapp.${DOMAIN_NAME}/api/health" | grep -q healthy'
check "Backend health (api host)" \
    bash -c 'curl -sSf "https://api.${DOMAIN_NAME}/api/health" | grep -q healthy'
check "SSL certificate valid (not self-signed)" \
    bash -c 'echo | openssl s_client -connect "taskapp.${DOMAIN_NAME}:443" -servername "taskapp.${DOMAIN_NAME}" 2>/dev/null | openssl x509 -noout -issuer | grep -i "let.s.encrypt\|amazon\|digicert"'
check "SSL certificate covers api subdomain" \
    bash -c 'echo | openssl s_client -connect "api.${DOMAIN_NAME}:443" -servername "api.${DOMAIN_NAME}" 2>/dev/null | openssl x509 -noout -issuer | grep -i "let.s.encrypt\|amazon\|digicert"'
check "HTTP redirects to HTTPS" \
    bash -c 'curl -sI "http://taskapp.${DOMAIN_NAME}" | grep -qi "301\|302\|location.*https"'
echo ""

# ---- 6. Persistent Storage ----
echo "6. PERSISTENT STORAGE"
check "PersistentVolumeClaim bound" \
    bash -c 'kubectl get pvc -n taskapp --no-headers | grep -q Bound'
check "StorageClass gp3-encrypted exists" \
    kubectl get storageclass gp3-encrypted
echo ""

# ---- 7. Secrets Management ----
echo "7. SECRETS MANAGEMENT"
check "Secrets exist in namespace" kubectl get secret taskapp-secrets -n taskapp
warn_check "Sealed Secrets controller running" \
    kubectl get deployment sealed-secrets-controller -n kube-system
echo ""

# ---- 8. Terraform State ----
echo "8. INFRASTRUCTURE AS CODE"
check "Terraform state bucket exists" \
    aws s3api head-bucket --bucket "${PROJECT_NAME:-taskapp}-terraform-state-${AWS_ACCOUNT_ID}"
check "No terraform drift" \
    bash -c 'cd terraform/environments/prod && terraform plan -detailed-exitcode 2>/dev/null; [ $? -eq 0 ]'
echo ""

# ---- 9. Ingress ----
echo "9. INGRESS"
check "Ingress resource exists" kubectl get ingress taskapp-ingress -n taskapp
check "NGINX Ingress controller running" \
    kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --field-selector=status.phase=Running --no-headers
echo ""

# ---- Summary ----
TOTAL=$((PASS + FAIL + WARN))
echo "---"
echo "  Results: ${PASS}/${TOTAL} passed, ${FAIL} failed, ${WARN} warnings"
echo "---"

if [ $FAIL -gt 0 ]; then
    echo -e "${RED}  Some checks failed. Review and fix before submission.${NC}"
    exit 1
else
    echo -e "${GREEN}  All critical checks passed!${NC}"
fi
