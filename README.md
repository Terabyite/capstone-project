# TaskApp — Production Kubernetes Deployment on AWS

A cloud-native task management application deployed to a production-grade Kubernetes cluster on AWS using Terraform, Kops, and Helm. The infrastructure spans 3 Availability Zones with automated deployment, SSL, high availability, and zero-downtime rolling updates.

**Live Demo:** `https://taskapp.yourdomain.com` (deploy with your own domain)

---

## Architecture

![alt text](Capstone.svg)

### Stack

| Layer | Technology |
|-------|-----------|
| Frontend | React (Vite) + NGINX |
| Backend | Python Flask REST API |
| Database | PostgreSQL 15 |
| Container Runtime | Docker (AMD64) |
| Orchestration | Kubernetes v1.29 (Kops) |
| Infrastructure | Terraform + AWS |
| Ingress | NGINX Ingress Controller |
| SSL/TLS | Let's Encrypt (cert-manager) |
| CNI | Calico |
| Secrets | Sealed Secrets |

### Infrastructure

- **3 Control Plane nodes** (t3.medium) across 3 AZs — etcd quorum, API server HA
- **3 Worker nodes** (t3.medium) across 3 AZs — application workloads
- **Private subnets** — all nodes have no public IPs
- **3 NAT Gateways** — one per AZ for outbound traffic
- **Network Load Balancer** — ingress traffic on ports 80/443
- **Route 53** — DNS management with automatic CNAME records
- **ECR** — private container registry with image scanning
- **S3** — Kops state, Terraform state, etcd backups
- **DynamoDB** — Terraform state locking

### Traffic Flow

```
User → HTTPS → Route 53 → NLB → NGINX Ingress → Frontend (/) or Backend (/api)
                                                          ↓
                                                    PostgreSQL
```

---

## Quick Start

### Prerequisites

| Tool | Version | macOS | Linux (Ubuntu/Debian) | Windows |
|------|---------|-------|----------------------|---------|
| AWS CLI | v2+ | `brew install awscli` | [AWS Docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-linux.html) | [AWS Docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-windows.html) |
| Terraform | v1.5+ | `brew install terraform` | [HashiCorp Docs](https://developer.hashicorp.com/terraform/install) | Use WSL2 |
| Kops | v1.28+ | `brew install kops` | [Kops Releases](https://github.com/kubernetes/kops/releases) | Use WSL2 |
| kubectl | v1.29+ | `brew install kubectl` | [K8s Docs](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) | Use WSL2 |
| Helm | v3+ | `brew install helm` | [Helm Docs](https://helm.sh/docs/intro/install/) | Use WSL2 |
| Docker | Desktop | [Docker Desktop](https://docker.com/products/docker-desktop) | [Docker Engine](https://docs.docker.com/engine/install/ubuntu/) | [Docker Desktop](https://docker.com/products/docker-desktop) + WSL2 |
| jq | latest | `brew install jq` | `sudo apt install jq` | Use WSL2 |

> **Windows users:** Install [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install) with Ubuntu, then follow the Linux instructions inside WSL2. Docker Desktop integrates with WSL2 automatically.

> **Apple Silicon (M1/M2/M3/M4) users:** The deploy script handles cross-platform builds automatically with `--platform linux/amd64`. No extra setup needed.

You also need:
- An **AWS account** with IAM credentials configured (`aws configure`)
- A **registered domain** (Namecheap, GoDaddy, Route 53, etc.)
- **Docker Desktop running** (macOS/Windows) or **Docker Engine running** (Linux) before deploying

### Deploy

```bash
git clone https://github.com/onlydurodola/capstone-project-novara.git
cd capstone-project-novara

export DOMAIN_NAME="yourdomain.com"
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

The script will:
1. Provision AWS infrastructure with Terraform (~3 min)
2. Build and push Docker images to ECR (~3 min)
3. Create a 6-node Kubernetes cluster with Kops (~8 min)
4. Install ingress-nginx, sealed-secrets, and configure DNS (~3 min)
5. Deploy PostgreSQL, backend, frontend, and SSL certificate (~3 min)

**Total: ~20 minutes from zero to live HTTPS application.**

During deployment you'll need to:
- Update your domain registrar's nameservers (shown in terminal)
- Enter a database password and Flask secret key

### Verify

```bash
kubectl get pods -n taskapp
curl -s https://taskapp.yourdomain.com/api/health
```

### Destroy

```bash
export DOMAIN_NAME="yourdomain.com"
./scripts/destroy.sh
```

Tears down all AWS resources to stop charges. Takes ~5 minutes.

---

## Project Structure

```
├── terraform/
│   ├── modules/
│   │   ├── vpc/                # VPC, subnets, NAT GWs, IGW, route tables
│   │   ├── s3/                 # S3 buckets, DynamoDB lock table
│   │   ├── iam/                # Kops IAM user, policies, access keys
│   │   └── dns/                # Route 53 zones, NS delegation, CNAME records
│   └── environments/prod/      # Production tfvars and backend config
│
├── kops/
│   └── cluster.yaml            # Kubernetes cluster definition (3 masters, 3 workers)
│
├── k8s/
│   ├── base/                   # Core manifests
│   │   ├── namespace.yaml      # taskapp namespace
│   │   ├── configmap.yaml      # Application configuration
│   │   ├── postgres.yaml       # PostgreSQL StatefulSet + Service
│   │   ├── backend.yaml        # Flask Deployment (2 replicas) + Service
│   │   ├── frontend.yaml       # NGINX Deployment (2 replicas) + Service
│   │   ├── db-init-job.yaml    # Database migration Job
│   │   └── storage-class.yaml  # gp3 encrypted StorageClass
│   └── production/
│       ├── cert-issuer.yaml    # Let's Encrypt ClusterIssuer
│       └── ingress.yaml        # Ingress rules + TLS
│
├── dockerfiles/
│   ├── Dockerfile.backend      # Python 3.11 multi-stage, non-root
│   ├── Dockerfile.frontend     # Node 20 build + NGINX 1.25, non-root
│   └── nginx.conf              # NGINX config (port 8080)
│
├── scripts/
│   ├── deploy.sh               # Full automated deployment
│   ├── destroy.sh              # Full automated teardown
│   └── validate.sh             # Cluster validation
│
├── taskapp_backend/            # Flask REST API source
├── taskapp_frontend/           # React (Vite) frontend source
│
└── docs/
    ├── architecture.md         # Detailed architecture documentation
    ├── cost-analysis.md        # AWS cost breakdown ($286.60/month)
    ├── runbook.md              # Operations runbook
    └── screenshots/            # Architecture diagram, AWS calculator
```

---

## Key Features

### High Availability

- **3 master nodes** across 3 AZs — survives loss of any single master
- **3 worker nodes** across 3 AZs — survives loss of any single worker
- **2 replicas** for frontend and backend — zero downtime during pod failures
- **Topology spread constraints** — pods distributed across AZs
- **etcd quorum** — 3-node etcd cluster tolerates 1 node failure

### Security

- **Private subnets** — all K8s nodes run in private subnets with no public IPs
- **Non-root containers** — frontend runs as `nginx` user, backend as `taskapp` user
- **HTTPS enforced** — Let's Encrypt SSL with automatic renewal via cert-manager
- **Calico CNI** — network policy support for pod-level firewall rules
- **Sealed Secrets** — encrypt secrets for safe Git storage
- **kubelet anonymous auth disabled** — prevents unauthenticated kubelet API access
- **ECR image scanning** — vulnerability scanning on push

### Zero-Downtime Deployments

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```

New pods are created before old ones are terminated. All requests continue to be served during updates.

### Auto-Scaling

- **Cluster Autoscaler** — worker nodes scale from 1-3 per AZ based on pod demand
- **CoreDNS Autoscaler** — DNS pods scale with cluster size

### Automated SSL

cert-manager automatically provisions Let's Encrypt certificates. The deploy script includes a retry mechanism that handles the common case where DNS hasn't fully propagated when the certificate is first requested.

---

## Cost

**Monthly estimate: $286.60 USD** ([full breakdown](docs/cost-analysis.md))

| Category | Cost | % |
|----------|------|---|
| Networking (NAT GWs + NLB) | $222.07 | 77.5% |
| Compute (6x t3.medium) | $54.66 | 19.1% |
| Storage (EBS + S3) | $8.62 | 3.0% |
| DNS + ECR + DynamoDB | $1.25 | 0.4% |

**Optimization:** A single NAT Gateway reduces cost to ~$150/month. See [cost-analysis.md](docs/cost-analysis.md) for details.

---

## Deployment Validation Screenshots

### Terraform Plan
![alt text](<Terraform Plan.png>)
*Terraform plan executes without errors and shows all 51 expected resources*

### Kops Cluster Validation
![alt text](<kops validate cluster.png>)
*kops validate cluster reports "Your cluster is ready" with 3 masters and 3 workers*

### Kubernetes Nodes
![alt text](<Kubectl get nodes.png>)
*kubectl get nodes shows 3 control-plane and 3 worker nodes, all in Ready state with private IPs*

### HTTPS with Valid SSL Certificate
![alt text](<task app.png>)
![alt text](<Task SSL.png>)
*Application accessible via HTTPS at taskapp.terabbyte.online with valid Let's Encrypt certificate*

### Database Persistence Test
![alt text](<delete pod postgres-ø.png>)
*PostgreSQL pod deleted and recreated — data survives because the PersistentVolumeClaim reattaches the same EBS gp3 volume*

### API Health Check
![alt text](<health check.png>)
*Both endpoints return healthy: taskapp.terabbyte.online/api/health and api.terabbyte.online/api/health*

---

## Demo

### Run the Demo Script

```bash
chmod +x demo.sh
./demo.sh
```

The demo shows:
1. **Cluster validation** — kops validate + kubectl get nodes
2. **HTTPS verification** — valid SSL certificate + API health check
3. **Kill a worker node** — app stays live, pods rescheduled automatically
4. **Kill a master node** — app stays live, etcd quorum maintained
5. **Rolling update** — new image deployed with 10/10 requests returning HTTP 200

---

## Platform Compatibility

| OS | Status | Notes |
|----|--------|-------|
| macOS (Intel) | ✅ Fully tested | Primary development platform |
| macOS (Apple Silicon) | ✅ Fully tested | `--platform linux/amd64` handled automatically |
| Ubuntu / Debian | ✅ Supported | Use `apt` or `snap` for tool installation |
| Amazon Linux / CentOS | ✅ Supported | Use `yum` for tool installation |
| Windows (WSL2) | ✅ Supported | Install WSL2 with Ubuntu, run all commands inside WSL2 |
| Windows (native) | ❌ Not supported | Bash scripts require WSL2 or a Linux VM |

---

## Documentation

| Document | Description |
|----------|-------------|
| [architecture.md](docs/architecture.md) | Full architecture details, pod inventory, security, HA strategy |
| [cost-analysis.md](docs/cost-analysis.md) | AWS cost breakdown with optimization recommendations |
| [runbook.md](docs/runbook.md) | Operations guide: deploy, destroy, scale, troubleshoot, recover |

---

## Challenges Encountered & Solutions

### 1. Docker ARM vs AMD64 — Container Architecture Mismatch

**Problem:** Development was done on a MacBook with Apple Silicon (M-series chip), which builds ARM64 Docker images by default. The Kubernetes worker nodes on AWS run AMD64 (x86_64). When pods tried to start, they crashed immediately with `exec format error` because the ARM binary couldn't run on AMD64 hardware.

**Solution:** Added `--platform linux/amd64` flag to all `docker build` commands in `deploy.sh`. This forces Docker to build AMD64 images regardless of the host architecture. The flag is harmless on native AMD64 machines, so the script works on both macOS and Linux.

```bash
# Before (broken on Apple Silicon)
docker build -t taskapp-backend:v1.0.0 .

# After (works everywhere)
docker build --platform linux/amd64 -t taskapp-backend:v1.0.0 .
```

---

### 2. NGINX Port 80 Permission Denied — Non-Root Container Security

**Problem:** The frontend container ran as a non-root `nginx` user for security best practices. However, ports below 1024 are privileged on Linux, so nginx failed to start with `bind() to 0.0.0.0:80 failed (13: Permission denied)`.

**Solution:** Changed nginx to listen on port 8080 instead of 80. Updated four files to match:
- `dockerfiles/nginx.conf` — `listen 8080`
- `dockerfiles/Dockerfile.frontend` — `EXPOSE 8080`
- `k8s/base/frontend.yaml` — `containerPort: 8080`, service `targetPort: 8080`, probe ports
- `k8s/production/ingress.yaml` — frontend backend port `8080`

This is actually more secure than running as root on port 80. The NGINX Ingress Controller handles external port 80/443 and forwards to 8080 internally.

---

### 3. NLB Security Group — Kubernetes API Access Blocked

**Problem:** After the Kops cluster was created, `kubectl` commands timed out. The Network Load Balancer for the Kubernetes API had a security group that didn't allow inbound TCP 443 from outside the VPC. This meant `kubectl` from the local machine couldn't reach the API server.

**Solution:** Added `kubernetesApiAccess: ["0.0.0.0/0"]` and `sshAccess: ["0.0.0.0/0"]` to `kops/cluster.yaml`. This configures the Kops-managed security group to allow external access to the API server NLB. In a production environment, this would be restricted to specific IP ranges.

---

### 4. ECR Image Pull Failure — Missing IAM Permissions

**Problem:** Pods were stuck in `ImagePullBackOff` because the Kubernetes worker nodes didn't have permission to pull images from Amazon ECR. Kops creates its own IAM roles for nodes, and by default these don't include ECR access.

**Solution:** Added `iam.allowContainerRegistry: true` to the Kops cluster spec in `kops/cluster.yaml`. This attaches the `AmazonEC2ContainerRegistryReadOnly` policy to the node IAM role, allowing workers to pull from any ECR repository in the account.

---

### 5. SSL Certificate Timing — DNS Propagation Race Condition

**Problem:** cert-manager attempted to validate the Let's Encrypt certificate immediately after the ingress was created, but DNS CNAME records hadn't fully propagated yet. The ACME challenge failed with `404 urn:ietf:params:acme:error:malformed: No such authorization`, and the certificate remained in a failed state.

**Solution:** Added an auto-retry loop in `deploy.sh` that checks the certificate status every 15 seconds for up to 3 minutes. If the certificate hasn't been issued after 6 attempts, the script deletes the failed certificate, secret, orders, and certificate requests, then reapplies the ingress to trigger a fresh certificate request. By this point DNS has propagated and the certificate issues successfully.

```bash
# Retry logic in deploy.sh
for i in $(seq 1 12); do
    CERT_READY=$(kubectl get certificate taskapp-tls-cert -n taskapp -o jsonpath='{.status.conditions[0].status}')
    if [ "$CERT_READY" = "True" ]; then break; fi
    if [ $i -eq 6 ]; then
        # Delete and retry
        kubectl delete certificate taskapp-tls-cert -n taskapp
        kubectl apply -f k8s/production/ingress.yaml
    fi
    sleep 15
done
```

---

### 6. Kops DNS Lookup Timeout — Local DNS Resolver Too Slow

**Problem:** When running `kops update cluster`, it performs a DNS lookup for the `k8s.terabbyte.online` NS records using the local machine's DNS resolver. On some networks (especially corporate/university networks), this lookup timed out with `error doing DNS lookup for NS records: i/o timeout`, even though the Route 53 zone was correctly configured.

**Solution:** Added `dnsZone: DNS_ZONE_PLACEHOLDER` to `kops/cluster.yaml`. The deploy script replaces this with the actual Route 53 zone ID from Terraform output. When kops sees a zone ID instead of a domain name, it skips the DNS lookup entirely and uses the zone directly, eliminating the timeout issue.

---

### 7. Multiple DNS Zones — Stale Route 53 Zones from Previous Deployments

**Problem:** After multiple deploy/destroy cycles, old Route 53 hosted zones for `k8s.terabbyte.online` were left behind. When Kops tried to find the correct zone, it found multiple matches and refused to proceed with `found multiple DNS Zones matching k8s.terabbyte.online`.

**Solution:** The `destroy.sh` script now cleans up all Route 53 hosted zones during teardown — it deletes non-required records first (CNAME, A records), then deletes the zone itself. Combined with the `dnsZone` fix above (which uses zone ID instead of name), this issue is fully resolved.

---

### 8. Elastic IP Limit Exceeded — AWS Default Quota

**Problem:** AWS accounts have a default limit of 5 Elastic IPs per region. The infrastructure requires 3 EIPs (one per NAT Gateway). After a few deploy/destroy cycles where EIPs weren't properly released, the limit was reached and Terraform failed with `AddressLimitExceeded`.

**Solution:** The `destroy.sh` script now explicitly releases all unassociated Elastic IPs as part of the teardown process. Added this as a cleanup step:

```bash
aws ec2 describe-addresses --query "Addresses[?AssociationId==null].AllocationId" --output text | \
  tr '\t' '\n' | xargs -I{} aws ec2 release-address --allocation-id {}
```

---

### 9. S3 Versioned Bucket Deletion — Kops State Bucket Won't Delete

**Problem:** The Kops state S3 bucket has versioning enabled (required by Kops). A normal `aws s3 rb --force` can't delete versioned buckets because it only removes current objects, not version history and delete markers. Terraform destroy also fails because the bucket isn't empty.

**Solution:** The `destroy.sh` script deletes all object versions and delete markers before removing the bucket:

```bash
aws s3api delete-objects --bucket "$bucket" --delete \
  "$(aws s3api list-object-versions --bucket "$bucket" \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)"
```

---

### 10. AWS CLI Pager Flooding Terminal — JSON Output Opens Less

**Problem:** Long AWS CLI JSON output (like S3 versioned object deletion) opened in the `less` pager, causing the destroy script to hang waiting for user input. The terminal appeared frozen with `(END)` at the bottom.

**Solution:** Added `export AWS_PAGER=""` at the top of `destroy.sh` to disable the pager for all AWS CLI commands in the script. This makes all output stream directly to the terminal without blocking.

---

### Lessons Learned

1. **Always build for the target architecture.** Cross-platform container builds are a real issue when developing on ARM Macs for AMD64 Kubernetes clusters.

2. **Non-root containers are worth the extra configuration.** Port 8080 instead of 80 is a minor change that significantly improves the security posture.

3. **DNS propagation is not instant.** Any automation that depends on DNS records must include retry logic, not assume immediate availability.

4. **Clean teardown is as important as clean deployment.** Leftover resources (EIPs, Route 53 zones, VPCs, versioned S3 objects) cause failures on subsequent deployments. The destroy script must be thorough.

5. **Infrastructure as Code saves time, but debugging infrastructure takes patience.** Every issue we encountered is now baked into the scripts so it never happens again.

See [runbook.md](docs/runbook.md) for the full operations guide with step-by-step solutions for each issue.

---

## Tech Stack

**Infrastructure:** AWS (VPC, EC2, S3, Route 53, ECR, DynamoDB, NLB, NAT Gateway, EBS, EIP)

**Kubernetes:** Kops, kubectl, Helm, Calico, NGINX Ingress, cert-manager, Sealed Secrets, Cluster Autoscaler, EBS CSI Driver, CoreDNS

**IaC:** Terraform (4 modules: vpc, s3, iam, dns)

**CI/CD:** Automated deploy.sh script (Terraform → Docker → Kops → Helm → kubectl)

**Application:** React 18 (Vite), Python Flask, PostgreSQL 15, NGINX 1.25

---

## Author

**Udeh Innocent**
