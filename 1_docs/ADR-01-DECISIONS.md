# ADR-01: Global Architecture Decisions

## Status
Accepted

## Context
Pluxee/Cobee needs a multi-regional payments platform with operations in Spain and Mexico. The architecture must comply with GDPR (EU) and the Federal Law on Personal Data Protection (MX), guaranteeing data residency per region and latency < 100ms per transaction.

## Decisions

### 1. Independent Multi-Region (No Multi-Cluster Federation)
**Decision:** Each region runs an independent EKS cluster with its own RDS database.

**Rationale:**
- **Data residency**: GDPR requires that EU citizens' data never leave the EU. With independent clusters, Spain's data stays in eu-south-2 and Mexico's in us-east-1
- **Failure isolation**: A problem in one region does not affect the other
- **Operational simplicity**: Federation adds complexity with no real benefit when there is no need to share data between regions

**Discarded alternatives:**
- Multi-cluster federation (Kubernetes): excessive complexity, risk of data leakage between regions
- Single region with logical sharding: does not comply with GDPR due to physical data residency requirements

### 2. Managed EKS with Separate Node Groups (System + Application)
**Decision:** Use managed EKS with two distinct node groups: `system` and `application`.

**Rationale:**
- AWS-managed control plane reduces operational burden
- Native IRSA support (IAM Roles for Service Accounts)
- Fargate discarded as primary compute due to limitations with DaemonSets (monitoring agents)

**Node group separation:**
- **System** (`t3.medium`, fixed size ~2 nodes): runs cluster components (CoreDNS, ALB Controller, ESO, EBS CSI). Taint `dedicated=system:NoSchedule` prevents application pods from being scheduled here
- **Application** (`t3.medium`, autoscaling): runs business workloads (payment-latency-api). No taints, with `role=application` label and nodeSelector on pods

**Isolation benefits:**
- A traffic spike in the application does not compete for resources with critical cluster components
- System nodes have a fixed and predictable size; application nodes scale with demand
- Allows instance types to be tuned independently (compute-optimized for apps, general-purpose for system)

### 3. PostgreSQL on RDS (Not Aurora)
**Decision:** RDS PostgreSQL Multi-AZ instead of Aurora.

**Rationale:**
- Lower cost for the expected transaction volume
- Multi-AZ covers high-availability requirements
- Automatic failover in < 60 seconds
- Aurora would be justified if write volume grows significantly

### 4. GitOps with ArgoCD
**Decision:** ArgoCD as the GitOps deployment engine.

**Rationale:**
- Continuous reconciliation: automatically detects and corrects drift
- Auditability: every change has an associated Git commit
- Native multi-cluster: supports deploying to multiple clusters from a single instance
- ApplicationSet to manage both regions with a single manifest

### 5. Helm as Templating Tool
**Decision:** Helm charts with per-region values.

**Rationale:**
- Single chart, multiple configurations (values-spain.yaml, values-mexico.yaml)
- Mature ecosystem with wide adoption
- Native ArgoCD integration
- Kustomize discarded due to lower flexibility for complex parameterisation

### 6. Public Terraform Modules
**Decision:** Use official AWS community modules for VPC, EKS and RDS.

**Rationale:**
- Widely tested and maintained by HashiCorp and the community
- Cover AWS best practices by default
- Reduce custom code and development time
- Sources documented in each module

### 7. Node Scaling — Karpenter (Not Implemented)
**Decision:** Karpenter has been evaluated as a node autoscaling solution but is out of the current scope. The node group ASGs have defined ranges (min/max) but there is no active controller to autoscale them.

**Why Karpenter over native Cluster Autoscaler:**
- Cluster Autoscaler operates on predefined ASGs: it can only scale within the instance types and configurations that already exist in the node group. Changing the instance type requires modifying Terraform
- Karpenter provisions nodes directly via the EC2 API, without relying on ASGs. It selects the optimal instance type in real time based on the resources requested by pending pods (right-sizing)
- Karpenter is faster at scheduling (~30s vs ~2min for Cluster Autoscaler) because it does not wait for ASG reconciliation cycles
- Automatic consolidation: Karpenter detects underutilised nodes, moves pods and terminates surplus nodes. Cluster Autoscaler is more conservative on scale-down
- Karpenter is the AWS-recommended replacement for Cluster Autoscaler on EKS

**How it would be implemented:**
- Deploy Karpenter via Helm on `system` nodes (with toleration for the `dedicated=system` taint)
- Create a `NodePool` for application workloads with constraints: instance families (`m6i`, `m6a`, `c6i`), capacity type `on-demand`, and total CPU/memory limit
- Create an `EC2NodeClass` with the EKS AMI, private subnets and cluster security groups
- The `application` node group in Terraform would become a minimal bootstrap (or be removed), with Karpenter managing real scaling
- The `system` node group would remain ASG-managed at a fixed size, as its workloads are predictable

**Current state:** Node groups have autodiscovery tags (`k8s.io/cluster-autoscaler`) and min/max ranges configured, allowing Karpenter or Cluster Autoscaler to be added in the future without Terraform changes.

### 8. DB Credentials Managed by RDS + Composition with ESO
**Decision:** Use `manage_master_user_password = true` in RDS so AWS manages and automatically rotates the master user password. The `DATABASE_URL` is composed in the ExternalSecret using the ESO template, combining RDS credentials with the endpoint injected via ArgoCD.

**Rationale:**
- Eliminates password duplication between the RDS secret and a manual application secret
- Automatic credential rotation works transparently — ESO syncs the new password on each `refreshInterval`
- Reduces manual deployment steps: no need to copy RDS credentials to another secret
- The only secret requiring manual population is `API_SECRET_KEY`

**Discarded alternative:**
- Manual secret with a full `DATABASE_URL`: requires copying the RDS password manually, breaks after each rotation, and duplicates sensitive information across two different secrets

### 9. NAT Gateway — Single vs One-per-AZ (Configurable)
**Decision:** A single NAT Gateway is used by default (`single_nat_gateway = true`). The variable allows switching to one-per-AZ for high-availability production environments.

**Cost:**
- 1 NAT Gateway: ~$1.08/day ($32.40/month) — fixed price $0.045/h + data transfer
- 3 NAT Gateways (one per AZ): ~$3.24/day ($97.20/month)

**Trade-off:**
- **Single NAT Gateway**: saves ~$65/month per region. If the AZ hosting the NAT goes down, private subnets in other AZs lose internet access (does not affect internal traffic or the EKS endpoint). Acceptable for development, testing and workloads tolerating minutes of outbound unavailability
- **One-per-AZ**: each private subnet routes through its own NAT. Eliminates cross-AZ dependency. Recommended for production with strict SLA

**To switch to one-per-AZ:**
```hcl
single_nat_gateway = false
```

### 10. EKS Control Plane Access — Public Endpoint with IP Restriction
**Decision:** The EKS API server has both public and private access enabled, with CIDRs configurable via the `cluster_endpoint_public_access_cidrs` variable.

**Rationale:**
- The public endpoint is required to operate the cluster from outside the VPC (development, CI/CD, administration)
- The private endpoint allows nodes and pods to communicate with the control plane without leaving the VPC
- CIDR restriction limits which IPs can reach the public endpoint (reduces attack surface)
- IAM/RBAC authentication remains mandatory — IP restriction is an additional layer

**Default:** `0.0.0.0/0` (open). To restrict:
```hcl
cluster_endpoint_public_access_cidrs = ["OFFICE_IP/32", "VPN_IP/32"]
```

**For strict production** (access only via VPN/bastion):
```hcl
cluster_endpoint_public_access = false  # Requires change in the EKS module
```

### 11. Infrastructure as Code Segregated by Environment
**Decision:** One Terraform directory per region/environment with independent state.

**Rationale:**
- Separate states prevent an error in one region from corrupting the other
- Changes can be applied to one region without affecting the other
- Enables per-region rollback

## Consequences
- Partial duplication of Terraform code between environments (mitigated with shared modules)
- Need to maintain parity between regions manually or via CI/CD
- Higher operational cost from duplicated infrastructure (acceptable for compliance reasons)
