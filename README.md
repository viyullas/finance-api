# Payment Latency API - Multi-Regional Platform

Cloud-native infrastructure on AWS for a fintech payments platform with operations in **Spain** (`eu-south-2`, GDPR) and **Mexico** (`us-east-1`, Ley Federal MX). Architecture that segments sensitive data by region with a target latency of < 100ms.

## Quick Start

### Prerequisites

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| AWS CLI | 2.x | Credentials configured for both regions |
| `terraform` | >= 1.10 | Infrastructure (VPC, EKS, RDS, etc.) |
| `helm` | >= 3.x | Install components on Kubernetes |
| `kubectl` | >= 1.28 | Manage clusters |
| `argocd` | >= 2.x | Register Mexico cluster in ArgoCD |
| `make` | GNU Make | Orchestration of the entire process |
| `docker` | >= 20.x | Build and push the image |
| `openssl` | any | Generate random secrets |

Additionally, before the first `make up`:
- **S3 Bucket** for Terraform state (see [Deployment Runbook](1_docs/DEPLOYMENT-RUNBOOK.md#bucket-s3-para-terraform-state))
  - Change the name in `4_infrastructure/terraform/environments/{spain,mexico}/main.tf` → `backend "s3"` block (current: `aabella-terraform-backends`)
- **Hosted zone** in Route53 for ACM certificates
  - Change in `4_infrastructure/terraform/environments/{spain,mexico}/variables.tf` → variables `hosted_zone_name` and `app_domain` (current: `aws.lacloaca.com`)

### Usage

```bash
make up      # Deploy everything: terraform, docker, helm, secrets, argocd, apps
make status  # Status of both clusters
make down    # Destroy everything (idempotent, safe to re-run)
make help    # All available targets
```

## Architecture

```
                     ┌──────────────────────────────────────┐
                     │           Git Repository              │
                     │  Helm Charts · Terraform · ArgoCD     │
                     └──────────┬──────────────┬────────────┘
                                │              │
                     ┌──────────▼──────────────┐
                     │     ArgoCD (Spain)       │
                     │  manages both regions    │
                     └──────┬──────────┬───────┘
                            │          │
       ── ── ── ── ── ── ──┼── ── ──  │  ── ── ── ── ── ──
      │  eu-south-2 (GDPR) │       │  │  us-east-1 (MX)   │
                            │
      │  ┌──────────────────▼───┐  │  ┌──▼────────────────┐│
         │  EKS Cluster         │     │  EKS Cluster       │
      │  │  ├ system nodes (2)  │  │  │  ├ system nodes (2)││
         │  └ app nodes (2-6)   │     │  └ app nodes (2-6) │
      │  │       │              │  │  │       │            ││
         │  ┌────▼────────────┐ │     │  ┌────▼──────────┐ │
      │  │  │ RDS PostgreSQL  │ │  │  │  │ RDS PostgreSQL│ ││
         │  │ via RDS Proxy   │ │     │  │ via RDS Proxy │ │
      │  │  └─────────────────┘ │  │  │  └───────────────┘ ││
         └──────────────────────┘     └────────────────────┘
      │                            │                        │
       ── ── ── ── ── ── ── ── ──   ── ── ── ── ── ── ── ─
```

Each region's data is completely independent: separate VPCs, separate secrets, no peering or cross-region replication.

## Application

Go API (`payment-latency-api`) that simulates payment processing:

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Health check with latency metrics |
| `GET /metrics` | Prometheus metrics |
| `GET /info` | Metadata (version, region, environment) |
| `GET /api/payment/simulate` | Simulates payment processing |

**Environment variables:**
- `DATABASE_URL`, `API_SECRET_KEY` — managed by External Secrets Operator (zero secrets in Git)
- `REGION`, `ENVIRONMENT` — via ConfigMap

See [1_docs/APPLICATION.md](1_docs/APPLICATION.md) for application details (local execution, endpoint testing).

## Project Structure

```
.
├── Dockerfile                          # Multi-stage, scratch, <20MB, non-root (UID 65534)
├── Makefile                            # make up / make down / make status + individual targets
├── 1_docs/
│   ├── APPLICATION.md                  # Go application documentation
│   ├── ADR-01-DECISIONS.md             # Architecture decisions (11 decisions)
│   ├── ADR-02-LATENCY-STRATEGY.md      # Strategy for <100ms (7 tactics)
│   ├── ADR-03-SECRET-MANAGEMENT.md     # Secret management with ESO + Secrets Manager
│   ├── SECURITY-CHECKLIST.md           # Security checklist (52 items)
│   └── DEPLOYMENT-RUNBOOK.md           # Step-by-step manual procedure
├── 2_application/
│   └── helm-charts/
│       └── payment-latency-api/        # Complete Helm Chart
│           ├── values.yaml             # Base values
│           ├── values-spain.yaml       # Spain override
│           ├── values-mexico.yaml      # Mexico override
│           └── templates/              # Deployment, Service, Ingress, ConfigMap,
│                                       # HPA, PDB, ServiceMonitor, ExternalSecret
├── 3_gitops/
│   └── argocd/
│       ├── application-spain.yaml      # ArgoCD Application for Spain
│       ├── application-mexico.yaml     # ArgoCD Application for Mexico
│       └── applicationset.yaml         # Bonus: both regions in a single manifest
└── 4_infrastructure/
    └── terraform/
        ├── modules/
        │   ├── vpc/                    # VPC multi-AZ, 3 subnet tiers
        │   ├── eks/                    # EKS + IRSA (ESO, ALB Controller, EBS CSI)
        │   └── rds/                    # PostgreSQL Multi-AZ + RDS Proxy
        └── environments/
            ├── spain/                  # eu-south-2 (GDPR)
            └── mexico/                 # us-east-1 (Ley Federal MX)
```

## Key Decisions

| Area | Choice | Justification |
|------|--------|---------------|
| Compute | EKS Managed | Managed control plane, native IRSA, managed addons |
| Node Groups | System + Application | Isolation with taints, independent scaling |
| Database | RDS PostgreSQL Multi-AZ | HA with failover < 60s, auto-rotated password |
| Connection pooling | RDS Proxy | Managed pool, -30/50ms TCP+TLS handshake per request |
| Secrets | ESO + Secrets Manager | Zero secrets in Git, IRSA auth, 1h refresh |
| GitOps | ArgoCD + ApplicationSet | Multi-cluster from Spain, auto-sync + self-heal |
| Templating | Helm | One chart, N values per region |
| IaC | Terraform + public modules | VPC ~5.0, EKS ~20.0, RDS ~6.0, IAM ~5.0 |
| Container | scratch image | ~8MB, 0 CVEs, non-root, read-only fs |

Full details in [1_docs/ADR-01-DECISIONS.md](1_docs/ADR-01-DECISIONS.md).

## Regions

| Region | AWS Region | Regulation | VPC CIDR |
|--------|-----------|------------|----------|
| Spain | eu-south-2 | GDPR (EU) | 10.10.0.0/16 |
| Mexico | us-east-1* | Ley Federal MX | 10.20.0.0/16 |

*AWS does not have a region in Mexico; us-east-1 with `DataResidency: MX` tagging.

## Security

- **Encryption at rest**: KMS per region (RDS, EBS, S3, K8s secrets envelope encryption)
- **Encryption in transit**: TLS 1.2+ (ALB with ACM certificate, `sslmode=require` on PostgreSQL)
- **IAM**: Least privilege with IRSA per component, no static credentials
- **Network**: Pods in private subnets, RDS in isolated database subnets (no internet access)
- **Auditing**: CloudTrail + VPC Flow Logs in both regions
- **Container**: scratch, non-root (UID 65534), read-only fs, capabilities dropped, seccomp RuntimeDefault

Full checklist (52 items): [1_docs/SECURITY-CHECKLIST.md](1_docs/SECURITY-CHECKLIST.md).

## Latency < 100ms

Estimated intra-region latency: **~23-28ms** (wide margin to the 100ms target).

| Tactic | Estimated savings |
|--------|-------------------|
| EKS + RDS in the same region | Avoids cross-region (~50-100ms) |
| RDS Proxy (connection pooling) | -30/50ms TCP+TLS handshake |
| ALB with target type IP | -1/2ms (no kube-proxy hop) |
| Dedicated application nodes | Eliminates contention with system workloads |
| HPA at 70% CPU | Scales before saturation |
| Pod anti-affinity by zone | HA without significantly sacrificing latency |

Detailed strategy: [1_docs/ADR-02-LATENCY-STRATEGY.md](1_docs/ADR-02-LATENCY-STRATEGY.md).

## Deployment

`make up` executes 7 sequential phases:

1. **Terraform** — VPC, EKS, RDS, KMS, CloudTrail, ECR, Secrets Manager (Spain + Mexico)
2. **Kubeconfig** — Registers both clusters with aliases `spain` / `mexico`
3. **Docker** — Image build and push to ECR in both regions
4. **Helm deps** — Installs ALB Controller + External Secrets Operator in both clusters
5. **Secrets** — Generates a random `API_SECRET_KEY` and stores it in Secrets Manager
6. **ArgoCD** — Installs in Spain, registers Mexico as a remote cluster
7. **Apps** — Applies the ArgoCD Applications (Spain in-cluster, Mexico remote)

`make down` is idempotent: it detects whether the clusters exist before attempting K8s operations, and retries terraform destroy if it fails due to AWS race conditions.

Detailed manual procedure: [1_docs/DEPLOYMENT-RUNBOOK.md](1_docs/DEPLOYMENT-RUNBOOK.md).

## Documentation

| Document | Contents |
|----------|----------|
| [ADR-01: Decisions](1_docs/ADR-01-DECISIONS.md) | 11 architecture decisions with justification |
| [ADR-02: Latency](1_docs/ADR-02-LATENCY-STRATEGY.md) | Strategy for < 100ms, chain analysis |
| [ADR-03: Secrets](1_docs/ADR-03-SECRET-MANAGEMENT.md) | ESO + Secrets Manager, IRSA flow, rotation |
| [Security Checklist](1_docs/SECURITY-CHECKLIST.md) | 52 verified items: container, network, IAM, encryption |
| [Deployment Runbook](1_docs/DEPLOYMENT-RUNBOOK.md) | 6-phase manual procedure |
| [Application](1_docs/APPLICATION.md) | Endpoints, variables, local execution |
