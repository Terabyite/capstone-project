set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[-] $1${NC}"; exit 1; }
info() { echo -e "${CYAN}[>] $1${NC}"; }

export AWS_REGION="${AWS_REGION:-us-east-1}"
export DOMAIN_NAME="${DOMAIN_NAME:?Set DOMAIN_NAME env var}"
export PROJECT_NAME="${PROJECT_NAME:-taskapp}"
export CLUSTER_NAME="${PROJECT_NAME}.k8s.${DOMAIN_NAME}"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export KOPS_STATE_STORE="s3://${PROJECT_NAME}-kops-state-${AWS_ACCOUNT_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

preflight() {
    info "Running pre-flight checks..."
    for cmd in terraform kops kubectl aws helm docker jq; do
        command -v "$cmd" &>/dev/null || err "$cmd is not installed"
    done
    log "All tools installed"
    aws sts get-caller-identity &>/dev/null || err "AWS credentials not configured"
    log "AWS credentials valid (Account: ${AWS_ACCOUNT_ID})"
}

phase1_terraform() {
    info "Phase 1: Provisioning AWS infrastructure with Terraform..."
    cd "$PROJECT_DIR/terraform/environments/prod"

    terraform init
    terraform validate
    terraform plan -out=tfplan

    warn "Review the plan above. Continue? (y/n)"
    read -r confirm
    [[ "$confirm" == "y" ]] || err "Aborted by user"

    terraform apply tfplan
    rm -f tfplan

    export VPC_ID=$(terraform output -raw vpc_id)
    export ETCD_BUCKET=$(terraform output -raw etcd_backups_bucket)
    PRIV_A=$(terraform output -json private_subnet_ids | jq -r '.[0]')
    PRIV_B=$(terraform output -json private_subnet_ids | jq -r '.[1]')
    PRIV_C=$(terraform output -json private_subnet_ids | jq -r '.[2]')
    PUB_A=$(terraform output -json public_subnet_ids | jq -r '.[0]')
    PUB_B=$(terraform output -json public_subnet_ids | jq -r '.[1]')
    PUB_C=$(terraform output -json public_subnet_ids | jq -r '.[2]')

    log "Terraform apply complete"
    warn "Copy these Route53 nameservers to your domain registrar:"
    echo ""
    terraform output route53_nameservers
    echo ""
    warn "After updating nameservers, wait 2-3 minutes then press Enter..."
    read -r

    info "Verifying DNS propagation..."
    for i in $(seq 1 10); do
        NS_RESULT=$(dig NS "${DOMAIN_NAME}" @8.8.8.8 +short 2>/dev/null | grep awsdns || true)
        if [ -n "$NS_RESULT" ]; then
            log "DNS propagated!"
            break
        fi
        info "Waiting for DNS... ($i/10)"
        sleep 15
    done

    cd "$PROJECT_DIR"
}

phase2_docker() {
    info "Phase 2: Building Docker images & pushing to ECR..."

    for repo in taskapp-backend taskapp-frontend; do
        aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" 2>/dev/null || \
        aws ecr create-repository \
            --repository-name "$repo" \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256 \
            --region "$AWS_REGION"
    done
    log "ECR repositories ready"

    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

    info "Building backend image..."
    cp dockerfiles/Dockerfile.backend taskapp_backend/Dockerfile
    cd taskapp_backend
    docker build --platform linux/amd64 -t taskapp-backend:v1.0.0 .
    docker tag taskapp-backend:v1.0.0 "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/taskapp-backend:v1.0.0"
    docker push "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/taskapp-backend:v1.0.0"
    rm -f Dockerfile
    cd "$PROJECT_DIR"

    info "Building frontend image..."
    cp dockerfiles/Dockerfile.frontend taskapp_frontend/Dockerfile
    cp dockerfiles/nginx.conf taskapp_frontend/nginx.conf
    cd taskapp_frontend
    docker build --platform linux/amd64 \
        --build-arg VITE_API_URL="https://taskapp.${DOMAIN_NAME}/api" \
        -t taskapp-frontend:v1.0.0 .
    docker tag taskapp-frontend:v1.0.0 "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/taskapp-frontend:v1.0.0"
    docker push "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/taskapp-frontend:v1.0.0"
    rm -f Dockerfile nginx.conf
    cd "$PROJECT_DIR"

    log "Docker images pushed to ECR"
}

phase3_kops() {
    info "Phase 3: Creating Kubernetes cluster with Kops..."

    sed -e "s|DOMAIN_PLACEHOLDER|${DOMAIN_NAME}|g" \
        -e "s|VPC_ID_PLACEHOLDER|${VPC_ID}|g" \
        -e "s|PRIV_SUBNET_A|${PRIV_A}|g" \
        -e "s|PRIV_SUBNET_B|${PRIV_B}|g" \
        -e "s|PRIV_SUBNET_C|${PRIV_C}|g" \
        -e "s|PUB_SUBNET_A|${PUB_A}|g" \
        -e "s|PUB_SUBNET_B|${PUB_B}|g" \
        -e "s|PUB_SUBNET_C|${PUB_C}|g" \
        -e "s|ETCD_BUCKET_PLACEHOLDER|${ETCD_BUCKET}|g" \
        kops/cluster.yaml > /tmp/cluster-final.yaml

    kops create -f /tmp/cluster-final.yaml --state="${KOPS_STATE_STORE}"

    if [ ! -f ~/.ssh/kops_rsa ]; then
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/kops_rsa -N ""
    fi
    kops create secret --name "${CLUSTER_NAME}" sshpublickey admin \
        -i ~/.ssh/kops_rsa.pub --state="${KOPS_STATE_STORE}"

    kops update cluster --name "${CLUSTER_NAME}" --state="${KOPS_STATE_STORE}" --yes --admin

    log "Cluster creation initiated. Waiting for cluster to be ready (5-10 min)..."

    ATTEMPTS=0
    MAX_ATTEMPTS=30
    until kops validate cluster --name "${CLUSTER_NAME}" --state="${KOPS_STATE_STORE}" 2>/dev/null; do
        ATTEMPTS=$((ATTEMPTS + 1))
        if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
            err "Cluster did not become ready in time"
        fi
        info "Attempt $ATTEMPTS/$MAX_ATTEMPTS - Waiting 30s..."
        sleep 30
    done

    log "Kubernetes cluster is READY!"
    kubectl get nodes
}

phase4_addons() {
    info "Phase 4: Installing cluster addons..."

    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx --create-namespace \
        --set controller.replicaCount=2 \
        --set controller.service.type=LoadBalancer \
        --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb \
        --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-cross-zone-load-balancing-enabled"=true

    INGRESS_LB=""
    for i in $(seq 1 20); do
        INGRESS_LB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
        if [ -n "$INGRESS_LB" ]; then break; fi
        info "Waiting for Ingress LB... ($i/20)"
        sleep 15
    done
    [ -n "$INGRESS_LB" ] || err "Ingress LB hostname not available"
    log "Ingress LB: ${INGRESS_LB}"

    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
    helm install sealed-secrets sealed-secrets/sealed-secrets \
        --namespace kube-system \
        --set-string fullnameOverride=sealed-secrets-controller

    log "All addons installed"

    info "Updating Route53 DNS records..."
    cd "$PROJECT_DIR/terraform/environments/prod"
    terraform apply -var="ingress_lb_hostname=${INGRESS_LB}" -auto-approve
    cd "$PROJECT_DIR"

    log "DNS records updated: taskapp.${DOMAIN_NAME} + api.${DOMAIN_NAME} -> ${INGRESS_LB}"
}

phase5_deploy_app() {
    info "Phase 5: Deploying TaskApp to Kubernetes..."

    ECR="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

    kubectl apply -f k8s/base/storage-class.yaml
    kubectl apply -f k8s/base/namespace.yaml
    sed "s|terabbyte.online|${DOMAIN_NAME}|g" k8s/base/configmap.yaml | kubectl apply -f -

    warn "Creating Kubernetes secrets..."
    echo "Enter database password for production:"
    read -rs DB_PASSWORD
    echo ""
    echo "Enter Flask secret key:"
    read -rs FLASK_SECRET
    echo ""

    kubectl create secret generic taskapp-secrets \
        --namespace=taskapp \
        --from-literal=DATABASE_USER=taskapp_user \
        --from-literal=DATABASE_PASSWORD="${DB_PASSWORD}" \
        --from-literal=SECRET_KEY="${FLASK_SECRET}" \
        --dry-run=client -o yaml | kubectl apply -f -

    info "Deploying PostgreSQL..."
    kubectl apply -f k8s/base/postgres.yaml
    kubectl rollout status statefulset/postgres -n taskapp --timeout=180s

    info "Initializing database..."
    sed "s|ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com|${ECR}|g" k8s/base/db-init-job.yaml | kubectl apply -f -
    kubectl wait --for=condition=complete job/db-init -n taskapp --timeout=120s

    info "Deploying backend..."
    sed "s|ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com|${ECR}|g" k8s/base/backend.yaml | kubectl apply -f -
    kubectl rollout status deployment/backend -n taskapp --timeout=180s

    info "Deploying frontend..."
    sed "s|ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com|${ECR}|g" k8s/base/frontend.yaml | kubectl apply -f -
    kubectl rollout status deployment/frontend -n taskapp --timeout=180s

    info "Configuring SSL and Ingress..."
    sed "s|terabbyte.online|${DOMAIN_NAME}|g" k8s/production/cert-issuer.yaml | kubectl apply -f -
    sed "s|terabbyte.online|${DOMAIN_NAME}|g" k8s/production/ingress.yaml | kubectl apply -f -

    info "Waiting for SSL certificate..."
    for i in $(seq 1 12); do
        CERT_READY=$(kubectl get certificate taskapp-tls-cert -n taskapp -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || echo "False")
        if [ "$CERT_READY" = "True" ]; then
            log "SSL certificate issued!"
            break
        fi
        if [ $i -eq 6 ]; then
            info "Retrying certificate issuance..."
            kubectl delete certificate taskapp-tls-cert -n taskapp 2>/dev/null || true
            kubectl delete secret taskapp-tls-cert -n taskapp 2>/dev/null || true
            kubectl delete order --all -n taskapp 2>/dev/null || true
            kubectl delete certificaterequest --all -n taskapp 2>/dev/null || true
            sleep 5
            sed "s|terabbyte.online|${DOMAIN_NAME}|g" k8s/production/ingress.yaml | kubectl apply -f -
        fi
        info "Waiting for cert... ($i/12)"
        sleep 15
    done

    log "Deployment complete!"
    echo ""
    log "Frontend: https://taskapp.${DOMAIN_NAME}"
    log "API:      https://api.${DOMAIN_NAME}/api/health"
    echo ""
    kubectl get pods -n taskapp
}

main() {
    echo ""
    echo "  TaskApp Production Deployment"
    echo "  Domain: ${DOMAIN_NAME}"
    echo "  Region: ${AWS_REGION}"
    echo ""

    preflight
    phase1_terraform
    phase2_docker
    phase3_kops
    phase4_addons
    phase5_deploy_app
}

main "$@"
