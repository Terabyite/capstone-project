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

## Deploy from Scratch

### Step 1: Set Your Domain

```bash
cd capstone-project-novara
export DOMAIN_NAME="yourdomain.com"   # Replace with your actual domain
```

### Step 2: Run the Deploy Script

```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

### What the Script Does

| Phase | Action | Duration |
|-------|--------|----------|
| 1 | Terraform creates VPC, S3, IAM, Route 53 | ~3 min |
| 2 | Docker builds frontend + backend, pushes to ECR | ~3 min |
| 3 | Kops creates Kubernetes cluster (3 masters, 3 workers) | ~8 min |
| 4 | Helm installs ingress-nginx + sealed-secrets, updates DNS | ~3 min |
| 5 | Deploys PostgreSQL, backend, frontend, SSL certificate | ~3 min |

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

### Full Teardown

```bash
export DOMAIN_NAME="yourdomain.com"   # Replace with your domain
export CLUSTER_NAME="taskapp.k8s.${DOMAIN_NAME}"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export KOPS_STATE_STORE="s3://taskapp-kops-state-${AWS_ACCOUNT_ID}"

# 1. Delete K8s namespaces (releases load balancers)
kubectl delete namespace taskapp --ignore-not-found
kubectl delete namespace ingress-nginx --ignore-not-found
sleep 30

# 2. Delete Kops cluster
kops delete cluster --name "${CLUSTER_NAME}" --state="${KOPS_STATE_STORE}" --yes

# 3. Delete ECR repositories
aws ecr delete-repository --repository-name taskapp-backend --force --region us-east-1
aws ecr delete-repository --repository-name taskapp-frontend --force --region us-east-1

# 4. Empty S3 buckets (including versioned objects)
for bucket in "taskapp-kops-state-${AWS_ACCOUNT_ID}" "taskapp-terraform-state-${AWS_ACCOUNT_ID}" "taskapp-etcd-backups-${AWS_ACCOUNT_ID}"; do
  aws s3 rm "s3://${bucket}" --recursive 2>/dev/null
  aws s3api delete-objects --bucket "$bucket" --delete "$(aws s3api list-object-versions --bucket "$bucket" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)" 2>/dev/null
  aws s3api delete-objects --bucket "$bucket" --delete "$(aws s3api list-object-versions --bucket "$bucket" --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)" 2>/dev/null
done

# 5. Terraform destroy
cd terraform/environments/prod
terraform destroy -auto-approve
cd -

# 6. Clean up anything Terraform missed
for policy in AmazonEC2FullAccess AmazonRoute53FullAccess AmazonS3FullAccess IAMFullAccess AmazonVPCFullAccess AmazonSQSFullAccess AmazonEventBridgeFullAccess; do
  aws iam detach-user-policy --user-name taskapp-kops-admin --policy-arn "arn:aws:iam::aws:policy/${policy}" 2>/dev/null
done
aws iam list-access-keys --user-name taskapp-kops-admin --query "AccessKeyMetadata[*].AccessKeyId" --output text 2>/dev/null | tr '\t' '\n' | xargs -I{} aws iam delete-access-key --user-name taskapp-kops-admin --access-key-id {}
aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/taskapp-ebs-csi-policy" 2>/dev/null
aws iam delete-user --user-name taskapp-kops-admin 2>/dev/null

# 7. Delete remaining S3 buckets
for bucket in "taskapp-kops-state-${AWS_ACCOUNT_ID}" "taskapp-terraform-state-${AWS_ACCOUNT_ID}" "taskapp-etcd-backups-${AWS_ACCOUNT_ID}"; do
  aws s3 rb "s3://${bucket}" --force 2>/dev/null
done

# 8. Release orphaned Elastic IPs
aws ec2 describe-addresses --query "Addresses[?AssociationId==null].AllocationId" --output text | tr '\t' '\n' | xargs -I{} aws ec2 release-address --allocation-id {}

# 9. Delete orphaned Route 53 zones
aws route53 list-hosted-zones --query "HostedZones[*].Id" --output text | tr '\t' '\n' | sed 's|/hostedzone/||' | while read zone; do
  aws route53 list-resource-record-sets --hosted-zone-id "$zone" --query "ResourceRecordSets[?Type!='NS'&&Type!='SOA']" --output json | \
  jq -c '.[]' | while read record; do
    aws route53 change-resource-record-sets --hosted-zone-id "$zone" --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":$record}]}" 2>/dev/null
  done
  aws route53 delete-hosted-zone --id "$zone" 2>/dev/null
done

# 10. Delete DynamoDB lock table
aws dynamodb delete-table --table-name taskapp-terraform-locks 2>/dev/null
```

### Verify Clean Slate

```bash
aws ec2 describe-vpcs --query "Vpcs[*].[VpcId,Tags[?Key=='Name'].Value|[0]]" --output table
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query "Reservations[*].Instances[*].InstanceId" --output text
aws ec2 describe-addresses --output table
aws s3 ls | grep taskapp
aws route53 list-hosted-zones --query "HostedZones[*].[Name,Id]" --output table
aws dynamodb list-tables --query "TableNames" --output text
```

All commands should return empty or show no taskapp resources. If anything remains, delete it manually using the AWS Console.

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
| ImagePullBackOff | Node can't pull from ECR | Verify `iam.allowContainerRegistry: true` in kops cluster.yaml, then `kops update cluster --yes` and `kops rolling-update cluster --yes` |
| CrashLoopBackOff | App is crashing | Check logs with `kubectl logs <pod> -n taskapp`. Common: wrong env vars, DB not ready |
| Pending | No node capacity | Check `kubectl describe pod` for events. May need to scale nodes or wait for autoscaler |
| ErrImagePull | Wrong image tag/name | Verify image exists: `aws ecr describe-images --repository-name taskapp-backend` |

### Frontend Returns 503

The frontend nginx must listen on port 8080 (not 80) because it runs as non-root.

```bash
# Verify frontend pods are running
kubectl get pods -l app=frontend -n taskapp

# Check the service port matches (should be 8080)
kubectl get svc frontend-service -n taskapp

# Check ingress routes to correct port
kubectl describe ingress taskapp-ingress -n taskapp
```

### SSL Certificate Not Issuing

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

### Docker Build Fails on Apple Silicon Mac

```bash
# Apple Silicon (M1/M2/M3) builds ARM images by default
# K8s worker nodes are AMD64 — images will crash with "exec format error"
# Always use:
docker build --platform linux/amd64 -t myimage:tag .
```

### Multiple DNS Zones Error (Kops)

```bash
# Error: "found multiple DNS Zones matching k8s.yourdomain.com"
# Old zones from previous deploys still exist

# List all zones
aws route53 list-hosted-zones --query "HostedZones[*].[Name,Id]" --output table

# Delete old zones (keep only the one matching your current terraform output)
# First delete non-NS/SOA records, then delete the zone
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
```

### Duplicate VPC Error (Kops)

```bash
# Error: "found multiple VPCs for cluster"
# Delete the old VPC that's not managed by current Terraform state

aws ec2 describe-vpcs --query "Vpcs[*].[VpcId,Tags[?Key=='Name'].Value|[0]]" --output table
# Identify the old VPC and delete its resources (NAT GWs, subnets, IGW, route tables) then the VPC itself
```

---

## Disaster Recovery

### Database Backup

```bash
# Create a backup
kubectl exec postgres-0 -n taskapp -- pg_dump -U taskapp_user taskapp > backup-$(date +%Y%m%d).sql

# Restore from backup
cat backup-20260402.sql | kubectl exec -i postgres-0 -n taskapp -- psql -U taskapp_user taskapp
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
| Check pods | `kubectl get pods -n taskapp` |
| View backend logs | `kubectl logs -l app=backend -n taskapp -f` |
| Scale backend | `kubectl scale deployment backend --replicas=4 -n taskapp` |
| Access database | `kubectl exec -it postgres-0 -n taskapp -- psql -U taskapp_user -d taskapp` |
| Check SSL cert | `kubectl get certificates -n taskapp` |
| Check nodes | `kubectl get nodes -o wide` |
| Validate cluster | `kops validate cluster --state="${KOPS_STATE_STORE}"` |
| Destroy everything | Run the [Destroy Everything](#destroy-everything) section |
