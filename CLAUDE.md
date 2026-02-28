# Technical Assessment: Senior Platform Engineer - Pluxee/Cobee

## Project Context
Design and implementation of a multi-regional cloud infrastructure on AWS for a fintech payments platform with active operations in Spain and Mexico.

**Main objective:** Cloud-native architecture that segments sensitive data by region, complying with GDPR (EU) and local regulations (Mexico), with latency < 100ms on financial transactions.

## Base Application
- Repository: https://github.com/cobee-io/platform-sample-go-application
- A Go API called `payment-latency-api`
- Port: 8080
- Endpoints: `/health`, `/metrics`, `/info`, `/api/payment/simulate`

### Required environment variables
**Secrets (NEVER in Git):**
- `DATABASE_URL` → PostgreSQL connection string
- `API_SECRET_KEY` → internal authentication key (64 chars)

**Non-sensitive (ConfigMap):**
- `REGION` → AWS region identifier
- `ENVIRONMENT` → deployment environment

---

## Deliverables Structure

```
.
├── Dockerfile                          # Optimised (<20MB, multi-stage, non-root)
├── CLAUDE.md                           # This file
├── 1_docs/
│   ├── ADR-01-DECISIONS.md             # Global architecture decisions
│   ├── ADR-02-LATENCY-STRATEGY.md      # Strategy for <100ms
│   ├── ADR-03-SECRET-MANAGEMENT.md     # Secret management
│   ├── SECURITY-CHECKLIST.md           # Completed security checklist
│   └── README.md                       # Implementation summary
├── 2_application/
│   └── helm-charts/
│       └── payment-latency-api/        # Complete Helm Chart
│           ├── Chart.yaml
│           ├── values.yaml
│           ├── values-spain.yaml
│           ├── values-mexico.yaml
│           └── templates/
│               ├── deployment.yaml
│               ├── service.yaml
│               ├── ingress.yaml
│               ├── configmap.yaml
│               ├── hpa.yaml
│               ├── servicemonitor.yaml
│               └── externalsecret.yaml
├── 3_gitops/
│   └── argocd/
│       ├── application-spain.yaml
│       ├── application-mexico.yaml
│       └── applicationset.yaml         # Bonus: multi-region in a single manifest
└── 4_infrastructure/
    └── terraform/
        ├── modules/
        │   ├── vpc/                    # Multi-AZ VPC
        │   ├── eks/                    # Cluster + node groups
        │   └── rds/                    # PostgreSQL
        └── environments/
            ├── spain/                  # eu-south-2
            └── mexico/                 # us-east-1 (proxy region for MX)
```

---

## Technical Requirements by Area

### 1. Dockerfile
- Multi-stage build
- Final image < 20MB (use `scratch` or `distroless`)
- Non-root user (UID 65532 or similar)
- No hardcoded secrets

### 2. Helm Chart
Must include all of the following resources:
- `Deployment` with probes (liveness, readiness), resource limits/requests
- `Service` (ClusterIP)
- `Ingress` with TLS
- `ConfigMap` for non-sensitive variables
- `HPA` (Horizontal Pod Autoscaler)
- `ServiceMonitor` for Prometheus
- External Secrets Operator integration (NO secrets in Git)

### 3. Terraform Infrastructure
- **VPC:** multi-AZ, public/private subnets, NAT Gateway
- **EKS:** managed cluster, node groups with auto-scaling
- **RDS:** PostgreSQL, Multi-AZ, encrypted, in private subnet
- Use public modules documenting the source
- Run `terraform validate` before delivery

### 4. GitOps - ArgoCD
- `Application` manifest for Spain (`eu-south-2`)
- `Application` manifest for Mexico (`us-east-1`)
- Bonus: `ApplicationSet` managing both regions

### 5. Security & Compliance
- **Data residency:** EU data only in Spain, MX data only in Mexico
- **Encryption:** at rest (KMS) and in transit (TLS 1.2+)
- **IAM:** least privilege, per-service roles (IRSA on EKS)
- **Auditing:** CloudTrail enabled in both regions

---

## Absolute Constraints
- ❌ NEVER secrets in Git (neither hardcoded nor in values.yaml)
- ❌ NEVER run the container as root
- ❌ NEVER without documentation
- ❌ NEVER without encryption

## Allowed Shortcuts
- ✅ Use public Terraform modules (document source)
- ✅ Implement one region fully and document the second
- ✅ Use AI tools

---

## AWS Regions
| Region  | AWS Region  | Regulation      |
|---------|-------------|-----------------|
| Spain   | eu-south-2  | GDPR (EU)       |
| Mexico  | us-east-1*  | Ley Federal MX  |

*AWS has no region in Mexico; use us-east-1 with data tagging.

---

## Secret Management - Recommended Solution
Use **External Secrets Operator (ESO)** + **AWS Secrets Manager**:
1. Secrets stored in AWS Secrets Manager per region
2. ESO synchronises secrets as native Kubernetes Secrets
3. Apps consume Kubernetes Secrets normally
4. Zero secrets in Git

## Latency < 100ms Strategy
- EKS in the same region as RDS (same AZ preferred)
- Connection pooling in the app (PgBouncer or similar)
- RDS Proxy for connection management
- HPA to scale pods under load
- Ingress with AWS ALB (lower latency than NLB for HTTP)

---

## Contact & Delivery
- Email: platform.cb@pluxeegroup.com
- Deadline: 7 calendar days from receipt
- Format: any convenient format (zip, private repo, etc.)

# currentDate
Today's date is 2026-02-24.
