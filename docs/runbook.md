# TaskApp Operations Runbook

## Table of Contents

1. [Getting Started](#getting-started)
2. [Deploy from Scratch](#deploy-from-scratch)
3. [Destroy Everything](#destroy-everything)
4. [Common Operations](#common-operations)
5. [Troubleshooting](#troubleshooting)
6. [Disaster Recovery](#disaster-recovery)

---

## Getting Started

### Prerequisites

Install the following tools before starting:

| Tool | Version | Install (macOS) | Install (Linux) |
|------|---------|-----------------|-----------------|
| AWS CLI | v2+ | `brew install awscli` | [AWS Docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-linux.html) |
| Terraform | v1.5+ | `brew install terraform` | [Terraform Docs](https://developer.hashicorp.com/terraform/install) |
| Kops | v1.28+ | `brew install kops` | [Kops Releases](https://github.com/kubernetes/kops/releases) |
| kubectl | v1.29+ | `brew install kubectl` | [K8s Docs](https://kubernetes.io/docs/tasks/tools/) |
| Helm | v3+ | `brew install helm` | [Helm Docs](https://helm.sh/docs/intro/install/) |
| Docker | Desktop | [Docker Desktop](https://docker.com/products/docker-desktop) | [Docker Engine](https://docs.docker.com/engine/install/) |
| jq | latest | `brew install jq` | `sudo apt install jq` |

### AWS Account Setup

1. Create an AWS account or use an existing one
2. Create an IAM user with **AdministratorAccess** (or at minimum: EC2, VPC, S3, Route53, IAM, ECR, DynamoDB, ELB, SQS, EventBridge)
3. Configure the CLI:

```bash
aws configure
# AWS Access Key ID: <your-access-key>
# AWS Secret Access Key: <your-secret-key>
# Default region: us-east-1
# Default output format: json
```

4. Verify:

```bash
aws sts get-caller-identity
```

### Domain Setup

You need a registered domain. This project was built with Namecheap, but any registrar works.

1. Register a domain (e.g., `yourdomain.com`)
2. Set the registrar to use **Custom DNS / Custom Nameservers** (you'll update these during deployment)

### Clone the Repository

```bash
git clone https://github.com/onlydurodola/capstone-project-novara.git
cd capstone-project-novara
```

### Project Structure

```
├── terraform/                  # AWS infrastructure (VPC, S3, IAM, DNS)
│   ├── modules/               # Reusable Terraform modules
│   │   ├── vpc/               # VPC, subnets, NAT GWs, IGW
│   │   ├── s3/                # S3 buckets, DynamoDB lock table
│   │   ├── iam/               # Kops IAM user and policies
│   │   └── dns/               # Route 53 hosted zones and records
│   └── environments/prod/     # Production environment config
├── kops/
│   └── cluster.yaml           # Kubernetes cluster definition
├── k8s/
│   ├── base/                  # Core K8s manifests (namespace, postgres, backend, frontend)
│   └── production/            # Production overlays (ingress, cert-issuer)
├── dockerfiles/               # Dockerfiles and nginx config
│   ├── Dockerfile.backend
│   ├── Dockerfile.frontend
│   └── nginx.conf
├── scripts/
│   ├── deploy.sh              # One-command full deployment
│   ├── destroy.sh             # One-command full teardown
│   └── validate.sh            # Cluster validation
├── taskapp_backend/           # Flask REST API source code
├── taskapp_frontend/          # React (Vite) frontend source code
└── docs/                      # Documentation
    ├── architecture.md
    ├── cost-analysis.md
    └── runbook.md             # This file
```

---

## Deploy from Scratch

### Step 1: Set Your Domain

```bash
cd capstone-project-novara
export DOMAIN_NAME="yourdomain.com"   # Replace with your actual domain
```

### Step 2: Make Sure Docker Desktop is Running

On macOS, open Docker Desktop and wait for it to be ready before running the deploy script.

### Step 3: Run the Deploy Script

```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

### What the Script Does

| Phase | Action | Duration |
|-------|--------|----------|
| 1 | Terraform creates VPC, S3, IAM, Route 53 | ~3 min |
| 2 | Docker builds frontend + backend (--platform linux/amd64), pushes to ECR | ~3 min |
| 3 | Kops creates Kubernetes cluster (3 masters, 3 workers) using Route 53 zone ID | ~8 min |
| 4 | Helm installs ingress-nginx + sealed-secrets, updates DNS CNAMEs | ~3 min |
| 5 | Deploys PostgreSQL, backend, frontend, SSL certificate with auto-retry | ~3 min |

**Total: ~20 minutes**

### Manual Steps During Deployment

**Nameserver Update (Phase 1):**

The script will display 4 AWS nameservers. You must update your domain registrar:

- **Namecheap:** Domain List → Manage → Nameservers → Custom DNS → paste the 4 values
- **GoDaddy:** My Domains → DNS → Change Nameservers → Enter custom
- **Cloudflare:** Remove domain from Cloudflare first, then point NS to AWS
- **Route 53 Registrar:** Registered Domains → your domain → Add/edit name servers

Wait 2-3 minutes for propagation, then press Enter.

**Database Credentials (Phase 5):**

When prompted, enter:
- **Database password:** Choose a strong password (e.g., `openssl rand -base64 24`)
- **Flask secret key:** Any random string (e.g., `openssl rand -hex 32`)

Remember these — you'll need them if you redeploy.

### Verify Deployment

```bash
# All pods should be Running (db-init will be Completed)
kubectl get pods -n taskapp

# Health check should return {"status":"healthy"}
curl -s https://taskapp.${DOMAIN_NAME}/api/health

# Frontend should return 200
curl -s -o /dev/null -w "%{http_code}" https://taskapp.${DOMAIN_NAME}

# API endpoint should return {"status":"healthy"}
curl -s https://api.${DOMAIN_NAME}/api/health
```

Open in browser: `https://taskapp.yourdomain.com`

---

## Destroy Everything

**Important:** Run this when you're done to avoid ongoing AWS charges (~$286/month).

### Using the Destroy Script

```bash
cd capstone-project-novara
export DOMAIN_NAME="yourdomain.com"   # Replace with your domain
./scripts/destroy.sh
```

The script will:
1. Ask for confirmation before proceeding
2. Delete Kubernetes namespaces (releases load balancers)
3. Delete the Kops cluster (EC2 instances, security groups, volumes, ELBs)
4. Delete ECR repositories
5. Empty and delete S3 buckets (including versioned objects)
6. Run Terraform destroy (VPC, Route 53, IAM, DynamoDB)
7. Clean up any remaining IAM resources
8. Release orphaned Elastic IPs
9. Delete orphaned Route 53 hosted zones
10. Delete the DynamoDB lock table
11. Run verification checks and display results

### Verify Clean Slate

The destroy script runs verification automatically at the end. If you want to check manually:

```bash
aws ec2 describe-vpcs --query "Vpcs[*].[VpcId,Tags[?Key=='Name'].Value|[0]]" --output table
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query "Reservations[*].Instances[*].InstanceId" --output text
aws ec2 describe-addresses --output table
aws s3 ls | grep taskapp
aws route53 list-hosted-zones --query "HostedZones[*].[Name,Id]" --output table
aws dynamodb list-tables --query "TableNames" --output text
```

All commands should return empty. If anything remains, delete it manually using the AWS Console.

---

## Common Operations

### View Application Logs

```bash
# Frontend logs
kubectl logs -l app=frontend -n taskapp --tail=50

# Backend logs
kubectl logs -l app=backend -n taskapp --tail=50

# PostgreSQL logs
kubectl logs postgres-0 -n taskapp --tail=50

# Follow logs in real time
kubectl logs -l app=backend -n taskapp -f
```

### Scale Application

```bash
# Scale frontend
kubectl scale deployment frontend --replicas=4 -n taskapp

# Scale backend
kubectl scale deployment backend --replicas=4 -n taskapp

# Check status
kubectl get deployment -n taskapp
```

### Update Application Image

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"

# Login to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR

# Build and push new version (IMPORTANT: use --platform linux/amd64 on Apple Silicon Macs)
cd taskapp_backend
cp ../dockerfiles/Dockerfile.backend Dockerfile
docker build --platform linux/amd64 -t taskapp-backend:v1.1.0 .
docker tag taskapp-backend:v1.1.0 $ECR/taskapp-backend:v1.1.0
docker push $ECR/taskapp-backend:v1.1.0
rm Dockerfile
cd ..

# Rolling update (zero downtime)
kubectl set image deployment/backend backend=$ECR/taskapp-backend:v1.1.0 -n taskapp
kubectl rollout status deployment/backend -n taskapp
```

### Rollback a Deployment

```bash
# View history
kubectl rollout history deployment/backend -n taskapp

# Rollback to previous version
kubectl rollout undo deployment/backend -n taskapp

# Rollback to specific revision
kubectl rollout undo deployment/backend --to-revision=2 -n taskapp
```

### Restart Pods Without Image Change

```bash
kubectl rollout restart deployment/frontend -n taskapp
kubectl rollout restart deployment/backend -n taskapp
```

### Access PostgreSQL

```bash
# Interactive psql shell
kubectl exec -it postgres-0 -n taskapp -- psql -U taskapp_user -d taskapp

# Run a single query
kubectl exec postgres-0 -n taskapp -- psql -U taskapp_user -d taskapp -c "SELECT count(*) FROM tasks;"
```

### Check SSL Certificate

```bash
kubectl get certificates -n taskapp
kubectl describe certificate taskapp-tls-cert -n taskapp
```

### Renew SSL Certificate Manually

```bash
kubectl delete certificate taskapp-tls-cert -n taskapp
kubectl delete secret taskapp-tls-cert -n taskapp
kubectl apply -f k8s/production/ingress.yaml
# cert-manager will automatically request a new certificate within 1-2 minutes
```

### View Cluster Health

```bash
# Node status
kubectl get nodes -o wide

# Resource usage (requires metrics-server)
kubectl top nodes
kubectl top pods -n taskapp

# Kops cluster validation
export KOPS_STATE_STORE="s3://taskapp-kops-state-$(aws sts get-caller-identity --query Account --output text)"
kops validate cluster --name taskapp.k8s.${DOMAIN_NAME} --state="${KOPS_STATE_STORE}"
```

---

## Troubleshooting

### Pod Not Starting

```bash
kubectl get pods -n taskapp
kubectl describe pod <pod-name> -n taskapp
kubectl logs <pod-name> -n taskapp
```

| Status | Cause | Fix |
|--------|-------|-----|
| ImagePullBackOff | Node can't pull from ECR | Verify `iam.allowContainerRegistry: true` in kops/cluster.yaml, then `kops update cluster --yes` and `kops rolling-update cluster --yes` |
| CrashLoopBackOff | App is crashing | Check logs with `kubectl logs <pod> -n taskapp`. Common: wrong env vars, DB not ready |
| Pending | No node capacity | Check `kubectl describe pod` for events. May need to scale nodes or wait for autoscaler |
| ErrImagePull | Wrong image tag/name | Verify image exists: `aws ecr describe-images --repository-name taskapp-backend` |

### Frontend Returns 503

The frontend nginx listens on port 8080 (not 80) because it runs as non-root.

```bash
# Verify frontend pods are running
kubectl get pods -l app=frontend -n taskapp

# Check the service port matches (should be 8080)
kubectl get svc frontend-service -n taskapp

# Check ingress routes to correct port
kubectl describe ingress taskapp-ingress -n taskapp
```

### SSL Certificate Not Issuing

The deploy script has an auto-retry that handles this. If you need to fix it manually:

```bash
# Check status
kubectl get certificates -n taskapp
kubectl get challenges -n taskapp

# Check cert-manager logs
kubectl logs -l app=cert-manager -n kube-system --tail=30

# Delete and retry (DNS must be propagated first)
kubectl delete certificate taskapp-tls-cert -n taskapp
kubectl delete secret taskapp-tls-cert -n taskapp
kubectl delete order --all -n taskapp
kubectl delete certificaterequest --all -n taskapp
sleep 10
kubectl apply -f k8s/production/ingress.yaml
sleep 60
kubectl get certificates -n taskapp
```

### kubectl Connection Refused

```bash
# Error: "The connection to the server localhost:8080 was refused"
# Means cluster is down or kubeconfig not set

# If cluster exists, re-export kubeconfig:
export KOPS_STATE_STORE="s3://taskapp-kops-state-$(aws sts get-caller-identity --query Account --output text)"
kops export kubeconfig --name taskapp.k8s.${DOMAIN_NAME} --state="${KOPS_STATE_STORE}" --admin
kubectl cluster-info

# If cluster was destroyed, this error is expected — just ignore it
```

### DNS Not Resolving

```bash
# Check nameservers are set correctly
dig NS yourdomain.com @8.8.8.8 +short
# Should show 4 awsdns nameservers

# Check CNAME records
dig taskapp.yourdomain.com @8.8.8.8 +short
# Should show NLB hostname

# If empty, nameservers haven't propagated yet — wait 5 minutes and retry
# Or check your domain registrar has the correct NS values
```

### Kops DNS Lookup Timeout

```bash
# Error: "error doing DNS lookup for NS records for k8s.yourdomain.com: i/o timeout"
# Your local DNS resolver is too slow for kops

# The deploy script handles this by passing the Route 53 zone ID via the
# dnsZone field in kops/cluster.yaml, which skips DNS lookup entirely.
# If you still see this error, verify the zone ID is correct:
cd terraform/environments/prod
terraform output k8s_zone_id
```

### Docker Build Fails on Apple Silicon Mac

```bash
# Apple Silicon (M1/M2/M3/M4) builds ARM images by default
# K8s worker nodes are AMD64 — images will crash with "exec format error"
# The deploy script handles this with --platform linux/amd64
# If building manually, always use:
docker build --platform linux/amd64 -t myimage:tag .
```

### Multiple DNS Zones Error (Kops)

```bash
# Error: "found multiple DNS Zones matching k8s.yourdomain.com"
# Old zones from previous deploys still exist

# List all zones
aws route53 list-hosted-zones --query "HostedZones[*].[Name,Id]" --output table

# Delete old zones (keep only the one matching your current terraform output)
# The destroy script handles this automatically
# For manual cleanup, first delete non-NS/SOA records, then delete the zone
aws route53 delete-hosted-zone --id <OLD_ZONE_ID>
```

### Elastic IP Limit Reached

```bash
# Error: "AddressLimitExceeded"
# AWS default limit is 5 EIPs per region

# Release unused EIPs
aws ec2 describe-addresses --query "Addresses[?AssociationId==null].[AllocationId,PublicIp]" --output table
aws ec2 describe-addresses --query "Addresses[?AssociationId==null].AllocationId" --output text | tr '\t' '\n' | xargs -I{} aws ec2 release-address --allocation-id {}
```

### Terraform "Already Exists" Errors

```bash
# Resources exist in AWS but not in Terraform state
# Import them:
cd terraform/environments/prod
terraform import module.iam.aws_iam_user.kops taskapp-kops-admin
terraform import module.s3.aws_s3_bucket.kops_state taskapp-kops-state-<YOUR_ACCOUNT_ID>
terraform import module.s3.aws_s3_bucket.terraform_state taskapp-terraform-state-<YOUR_ACCOUNT_ID>
terraform import module.s3.aws_s3_bucket.etcd_backups taskapp-etcd-backups-<YOUR_ACCOUNT_ID>
terraform import module.s3.aws_dynamodb_table.terraform_locks taskapp-terraform-locks
terraform import module.iam.aws_iam_policy.ebs_csi arn:aws:iam::<YOUR_ACCOUNT_ID>:policy/taskapp-ebs-csi-policy
```

### Duplicate VPC Error (Kops)

```bash
# Error: "found multiple VPCs for cluster"
# Delete the old VPC that's not managed by current Terraform state

aws ec2 describe-vpcs --query "Vpcs[*].[VpcId,Tags[?Key=='Name'].Value|[0]]" --output table
# Identify the old VPC and delete its resources (NAT GWs, subnets, IGW, route tables) then the VPC itself
# Or run destroy.sh which handles all cleanup automatically
```

### AWS CLI JSON Output Flooding the Screen

```bash
# If AWS CLI commands open a pager (less) for long JSON output, disable it:
export AWS_PAGER=""

# Or add to your shell profile permanently:
echo 'export AWS_PAGER=""' >> ~/.zshrc
source ~/.zshrc

# The destroy.sh script has this built in already
```

---

## Disaster Recovery

### Database Backup

```bash
# Create a backup
kubectl exec postgres-0 -n taskapp -- pg_dump -U taskapp_user taskapp > backup-$(date +%Y%m%d).sql

# Restore from backup
cat backup-20260407.sql | kubectl exec -i postgres-0 -n taskapp -- psql -U taskapp_user taskapp
```

### etcd Backup

Kops automatically backs up etcd to S3 (`taskapp-etcd-backups-<ACCOUNT_ID>`). Backups have a 30-day retention policy. No manual action needed.

### Full Cluster Recovery

If the cluster is destroyed but S3 kops-state bucket still exists:

```bash
export KOPS_STATE_STORE="s3://taskapp-kops-state-$(aws sts get-caller-identity --query Account --output text)"

kops update cluster --name taskapp.k8s.${DOMAIN_NAME} --state="${KOPS_STATE_STORE}" --yes
kops validate cluster --wait 10m --state="${KOPS_STATE_STORE}"

# Redeploy app
kubectl apply -f k8s/base/
kubectl apply -f k8s/production/
```

### Complete Rebuild from Zero

If everything is gone, the deploy script handles full recreation:

```bash
export DOMAIN_NAME="yourdomain.com"
./scripts/deploy.sh
```

This recreates all infrastructure and deploys the application in approximately 20 minutes.

---

## Quick Reference

| Task | Command |
|------|---------|
| Deploy everything | `export DOMAIN_NAME="yourdomain.com" && ./scripts/deploy.sh` |
| Destroy everything | `export DOMAIN_NAME="yourdomain.com" && ./scripts/destroy.sh` |
| Check pods | `kubectl get pods -n taskapp` |
| View backend logs | `kubectl logs -l app=backend -n taskapp -f` |
| Scale backend | `kubectl scale deployment backend --replicas=4 -n taskapp` |
| Rolling update | `kubectl set image deployment/backend backend=$ECR/taskapp-backend:v1.1.0 -n taskapp` |
| Rollback | `kubectl rollout undo deployment/backend -n taskapp` |
| Access database | `kubectl exec -it postgres-0 -n taskapp -- psql -U taskapp_user -d taskapp` |
| Check SSL cert | `kubectl get certificates -n taskapp` |
| Check nodes | `kubectl get nodes -o wide` |
| Validate cluster | `kops validate cluster --state="${KOPS_STATE_STORE}"` |
| Health check | `curl -s https://taskapp.yourdomain.com/api/health` |
