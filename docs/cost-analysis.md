# TaskApp Infrastructure Cost Analysis

## Architecture Overview

| Component | Service | Specification |
|-----------|---------|---------------|
| Kubernetes Control Plane | 3x EC2 (t3.medium) | 2 vCPU, 4GB RAM each |
| Kubernetes Worker Nodes | 3x EC2 (t3.medium) | 2 vCPU, 4GB RAM each |
| Load Balancer | Network Load Balancer | Ingress traffic routing |
| NAT Gateways | 3x NAT Gateway | One per AZ for private subnets |
| Elastic IPs | 3x EIP | Attached to NAT Gateways |
| Container Registry | Amazon ECR | 2 repositories (backend + frontend) |
| DNS | Route 53 | 2 hosted zones + records |
| Storage | EBS gp3 | 6x etcd volumes + 1x PostgreSQL PV |
| State Storage | S3 | 3 buckets (kops, terraform, etcd backups) |
| State Locking | DynamoDB | 1 table (on-demand) |
| SSL Certificates | Let's Encrypt | Free via cert-manager |

---

## Monthly Cost Breakdown (us-east-1)

> Based on **AWS Pricing Calculator** estimate. See screenshots below.

### Total Monthly Cost: **$286.60 USD**
### Total 12-Month Cost: **$3,439.20 USD**

| Service | Monthly Cost | Notes |
|---------|-------------|-------|
| Amazon EC2 | $54.66 | 6x t3.medium (Shared Tenancy, On-Demand) |
| Amazon VPC (NAT Gateways) | $205.20 | 3x NAT Gateways across 3 AZs |
| Elastic Load Balancing | $16.87 | 1x Network Load Balancer |
| Amazon S3 | $0.23 | 3 buckets (kops-state, terraform-state, etcd-backups) |
| Amazon Route 53 | $1.04 | 2 hosted zones + DNS queries |
| Amazon ECR | $0.20 | 2 container image repositories |
| Amazon EBS | $8.39 | gp3 volumes (etcd, PostgreSQL, node root) |
| Amazon DynamoDB | $0.01 | 1 table for Terraform state locking |
| SSL/TLS (Let's Encrypt) | $0.00 | Free via cert-manager |
| **Total** | **$286.60** | |

---

## Cost Distribution

NAT Gateways account for **71.6%** of total infrastructure cost ($205.20 out of $286.60). This is the primary cost driver and the first target for optimization.

| Category | Cost | % of Total |
|----------|------|-----------|
| Networking (NAT + NLB) | $222.07 | 77.5% |
| Compute (EC2) | $54.66 | 19.1% |
| Storage (EBS + S3) | $8.62 | 3.0% |
| DNS + Registry + DB | $1.25 | 0.4% |

---

## AWS Pricing Calculator Screenshots

![Estimate Summary](screenshots/aws-calculator-summary.png)
*AWS Pricing Calculator — Total estimate: $286.60/month ($3,439.20/year)*

![Service Breakdown](screenshots/aws-calculator-services.png)
*AWS Pricing Calculator — Per-service cost breakdown*

---

## Cost Optimization Recommendations

### Quick Wins (Save ~60%)

1. **Single NAT Gateway** — Use one NAT Gateway instead of three. Saves **~$137/month**. Tradeoff: single AZ dependency for outbound traffic from private subnets. Acceptable for non-critical workloads.

2. **Reserved Instances (1-year)** — Switch EC2 to 1-year No Upfront RI. Saves ~35% on compute (~$19/month).

3. **Spot Instances for Workers** — Use Spot for worker nodes (up to 90% savings on 3 worker instances). Kops supports mixed instance groups. Saves ~$25/month.

### Medium-Term Optimizations

4. **Right-size Instances** — Monitor CPU/memory with CloudWatch. t3.small may suffice for worker nodes, halving worker compute cost.

5. **Single Control Plane** — For dev/staging, a single master saves ~$36/month. Not recommended for production HA.

6. **Graviton (ARM) Instances** — t4g.medium is ~20% cheaper than t3.medium. Requires ARM-compatible container images (change `--platform linux/amd64` to `--platform linux/arm64` in deploy.sh).

### Optimized Cost Estimates

| Scenario | Monthly Cost | Savings |
|----------|-------------|---------|
| Current (production HA, 3 AZs) | $286.60 | — |
| Single NAT Gateway | $149.40 | 48% |
| Single NAT + Spot workers | $124.40 | 57% |
| Single NAT + Reserved Instances | $130.40 | 54% |
| Dev/staging (1 master, 2 workers, 1 NAT) | $85.00 | 70% |

---

## Cost Monitoring Recommendations

- **AWS Cost Explorer** — Enable to track daily spend by service and tag
- **Billing Alerts** — Set CloudWatch billing alarm at $300/month threshold
- **Resource Tagging** — All resources tagged with `Project: taskapp`, `Environment: production`, `ManagedBy: terraform` for cost allocation reports
- **AWS Budgets** — Create a monthly budget with email notifications at 80% and 100% thresholds

---

## Notes

- All prices based on AWS published On-Demand rates for us-east-1 (N. Virginia) as of April 2026
- Actual costs may vary based on data transfer volumes, autoscaling events, and usage patterns
- The cluster autoscaler can scale worker nodes from 1-3 per AZ based on demand, which may increase compute costs during peak usage
- Data transfer costs (inter-AZ, internet egress) are not included and are typically minimal for this workload
