# TaskApp Production Architecture

## Overview

TaskApp is a cloud-native task management application deployed on AWS using a production-grade Kubernetes cluster. The architecture follows industry best practices for high availability, security, and scalability across three Availability Zones in the us-east-1 (N. Virginia) region.

**Live URL:** https://taskapp.terabbyte.online
**API Endpoint:** https://api.terabbyte.online/api/health
**Domain Registrar:** Namecheap (terabbyte.online)

## Architecture Diagram

![TaskApp Architecture](screenshots/architecture-diagram.png)

---

## Application Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Frontend | React (Vite) + nginx | Single Page Application served on port 8080 |
| Backend | Python Flask | REST API served on port 5000 |
| Database | PostgreSQL 15 | Persistent data storage on port 5432 |
| Reverse Proxy | NGINX Ingress Controller | TLS termination, path-based routing |

---

## Infrastructure Components

### Networking

- **VPC:** 10.0.0.0/16 CIDR block with DNS hostnames enabled
- **Public Subnets:** 10.0.1.0/24 (us-east-1a), 10.0.2.0/24 (us-east-1b), 10.0.3.0/24 (us-east-1c) — host NAT Gateways and receive internet traffic via Internet Gateway
- **Private Subnets:** 10.0.10.0/24 (us-east-1a), 10.0.11.0/24 (us-east-1b), 10.0.12.0/24 (us-east-1c) — host all Kubernetes nodes (masters and workers), no direct internet access
- **NAT Gateways:** 3 (one per AZ) with Elastic IPs — allow private subnet nodes to pull container images and system updates
- **Internet Gateway:** Routes inbound traffic to the Network Load Balancer
- **Network Load Balancer (NLB):** TCP passthrough on ports 80/443, distributes traffic to NGINX Ingress Controller pods

### DNS

- **Route 53 Hosted Zone (terabbyte.online):** Main domain zone with CNAME records pointing taskapp.terabbyte.online and api.terabbyte.online to the NLB
- **Route 53 Hosted Zone (k8s.terabbyte.online):** Subdomain zone delegated from the main zone, used by Kops for Kubernetes API and internal DNS
- **Namecheap:** NS records point to AWS Route 53 nameservers

### Compute

- **3x Control Plane Nodes (t3.medium):** One per AZ for HA. Run kube-apiserver, etcd, kube-controller-manager, kube-scheduler
- **3x Worker Nodes (t3.medium):** One per AZ, min 1 / max 3 per AZ via Cluster Autoscaler. Run application workloads and addon pods

### Storage

- **EBS gp3 Volumes:** etcd data (6 volumes), PostgreSQL PersistentVolume (10Gi), node root volumes
- **S3 Buckets:** kops-state (cluster state), terraform-state (IaC state), etcd-backups (automated backups with 30-day lifecycle)
- **DynamoDB:** Terraform state locking table

### Container Registry

- **Amazon ECR:** Two repositories — taskapp-backend and taskapp-frontend. Images built with `--platform linux/amd64` for compatibility with x86 worker nodes. Image scanning enabled on push.

---

## Kubernetes Architecture

### Cluster Configuration

| Setting | Value |
|---------|-------|
| Cluster Name | taskapp.k8s.terabbyte.online |
| Kubernetes Version | v1.29.6 |
| CNI | Calico (network policies enabled) |
| Topology | Private (all nodes in private subnets) |
| API Access | NLB with public access (kubernetesApiAccess: 0.0.0.0/0) |
| Container Registry Access | iam.allowContainerRegistry: true |

### Namespaces

| Namespace | Purpose |
|-----------|---------|
| taskapp | Application workloads (frontend, backend, postgres, jobs) |
| ingress-nginx | NGINX Ingress Controller |
| kube-system | Cluster addons (cert-manager, calico, ebs-csi, coredns, kops-controller, sealed-secrets) |

### Application Pods (namespace: taskapp)

| Workload | Type | Replicas | Image | Port |
|----------|------|----------|-------|------|
| frontend | Deployment | 2 | taskapp-frontend:v1.0.0 | 8080 |
| backend | Deployment | 2 | taskapp-backend:v1.0.0 | 5000 |
| postgres-0 | StatefulSet | 1 | postgres:15-alpine | 5432 |
| db-init | Job | 1 (completed) | taskapp-backend:v1.0.0 | — |

### Cluster Addon Pods

| Pod | Namespace | Replicas | Purpose |
|-----|-----------|----------|---------|
| ingress-nginx-controller | ingress-nginx | 2 | TLS termination, HTTP routing |
| cert-manager | kube-system | 1 | Automatic Let's Encrypt SSL certificates |
| cert-manager-cainjector | kube-system | 1 | CA bundle injection |
| cert-manager-webhook | kube-system | 1 | Certificate validation webhook |
| calico-node | kube-system | 6 (DaemonSet) | Network policy enforcement, pod networking |
| calico-kube-controllers | kube-system | 1 | Calico policy controller |
| cluster-autoscaler | kube-system | 1 | Auto-scale worker nodes based on demand |
| ebs-csi-controller | kube-system | 2 | EBS volume provisioning |
| ebs-csi-node | kube-system | 6 (DaemonSet) | EBS volume mounting on each node |
| coredns | kube-system | 1+ | Cluster DNS resolution |
| coredns-autoscaler | kube-system | 1 | Scale CoreDNS based on cluster size |
| kops-controller | kube-system | 1 | Node bootstrapping and configuration |
| sealed-secrets-controller | kube-system | 1 | Decrypt SealedSecrets into Kubernetes Secrets |

### Services

| Service | Type | Port | Target |
|---------|------|------|--------|
| frontend-service | ClusterIP | 8080 | Frontend pods |
| backend-service | ClusterIP | 5000 | Backend pods |
| postgres-service | ClusterIP | 5432 | PostgreSQL pod |
| ingress-nginx-controller | LoadBalancer | 80, 443 | NLB → Ingress pods |

### Ingress Routing

| Host | Path | Backend | Port |
|------|------|---------|------|
| taskapp.terabbyte.online | /api | backend-service | 5000 |
| taskapp.terabbyte.online | / | frontend-service | 8080 |
| api.terabbyte.online | / | backend-service | 5000 |

---

## Security

### Network Security

- All Kubernetes nodes run in **private subnets** with no public IP addresses
- Outbound internet access via **NAT Gateways** only
- Inbound traffic flows through **NLB → Ingress Controller** only
- **Calico network policies** enforce pod-to-pod communication rules
- **Security Groups** restrict traffic between node types (masters, workers, API ELB)

### TLS/SSL

- **Let's Encrypt** production certificates via cert-manager ClusterIssuer
- Automatic certificate renewal before expiry
- HTTPS enforced with `nginx.ingress.kubernetes.io/force-ssl-redirect: "true"`
- Certificate covers both taskapp.terabbyte.online and api.terabbyte.online (SAN)

### Secrets Management

- **Sealed Secrets** for GitOps-safe secret encryption
- Database credentials stored as Kubernetes Secrets (not committed to Git)
- **kubelet.anonymousAuth: false** — prevents unauthenticated kubelet API access

### Container Security

- All containers run as **non-root users**
- nginx runs as `nginx` user on port 8080 (unprivileged)
- Backend runs as `taskapp` user
- Resource limits enforced on all pods (CPU and memory)

---

## High Availability

| Component | HA Strategy |
|-----------|-------------|
| Control Plane | 3 masters across 3 AZs with etcd quorum |
| Worker Nodes | 3 nodes across 3 AZs with topology spread constraints |
| Frontend | 2 replicas with anti-affinity across AZs |
| Backend | 2 replicas with anti-affinity across AZs |
| Ingress | 2 replicas for load distribution |
| PostgreSQL | Single replica (StatefulSet with EBS PV for data durability) |
| NAT Gateways | 3 (one per AZ) for independent outbound paths |

### Deployment Strategy

All application deployments use **RollingUpdate** with zero-downtime configuration:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```

This ensures at least the full replica count is always running during updates.

---

## Scaling

### Horizontal Pod Autoscaling

Application deployments can be scaled manually or with HPA:

```bash
kubectl scale deployment frontend --replicas=4 -n taskapp
kubectl scale deployment backend --replicas=4 -n taskapp
```

### Cluster Autoscaler

Worker nodes auto-scale from 1 to 3 per AZ (3-9 total) based on pod scheduling demand. Configured via Kops addon.

---

## Infrastructure as Code

| Tool | Purpose | State Storage |
|------|---------|--------------|
| Terraform | VPC, S3, IAM, Route 53, DynamoDB | Local (terraform.tfstate) |
| Kops | Kubernetes cluster lifecycle | S3 (taskapp-kops-state) |
| Helm | Ingress NGINX, Sealed Secrets | In-cluster (Kubernetes) |
| kubectl/Kustomize | Application manifests | Git repository |
| Docker | Container image builds | Amazon ECR |

### Terraform Modules

| Module | Resources |
|--------|-----------|
| vpc | VPC, subnets (public/private), IGW, NAT GWs, EIPs, route tables |
| s3 | S3 buckets (kops, terraform, etcd), DynamoDB lock table |
| iam | Kops admin user, access keys, policy attachments, EBS CSI policy |
| dns | Route 53 hosted zones, NS delegation, CNAME records |

---

## CI/CD Pipeline

### Deployment Flow

```
Developer pushes code
        ↓
deploy.sh Phase 1: Terraform provisions AWS infrastructure
        ↓
deploy.sh Phase 2: Docker builds images (--platform linux/amd64) → pushes to ECR
        ↓
deploy.sh Phase 3: Kops creates/updates Kubernetes cluster
        ↓
deploy.sh Phase 4: Helm installs addons (ingress-nginx, sealed-secrets) → updates DNS
        ↓
deploy.sh Phase 5: kubectl applies K8s manifests → cert-manager issues SSL
        ↓
Application live at https://taskapp.terabbyte.online
```

### Automated in deploy.sh

- Infrastructure provisioning (Terraform)
- Container image builds with cross-platform support (ARM → AMD64)
- Kubernetes cluster creation and validation
- Addon installation and DNS configuration
- Application deployment with health checks
- SSL certificate provisioning with automatic retry

---

## Monitoring and Observability

| Aspect | Tool | Status |
|--------|------|--------|
| Pod Health | Liveness & Readiness Probes | Configured on all app pods |
| Node Health | Kops validation | Automated in deploy script |
| DNS Health | Route 53 health checks | Available via AWS Console |
| Certificate Expiry | cert-manager | Automatic renewal |
| Resource Usage | kubectl top pods/nodes | Manual (metrics-server available) |

---

## Cost Summary

**Monthly estimate: $286.60 USD** (see [cost-analysis.md](cost-analysis.md) for full breakdown)

| Category | Monthly Cost | % of Total |
|----------|-------------|-----------|
| Networking (NAT + NLB) | $222.07 | 77.5% |
| Compute (EC2) | $54.66 | 19.1% |
| Storage (EBS + S3) | $8.62 | 3.0% |
| DNS + Registry + DB | $1.25 | 0.4% |
