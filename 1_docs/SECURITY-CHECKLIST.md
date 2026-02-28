# Security Checklist - Payment Latency API

## Container Security

- [x] **Minimal base image**: `scratch` (0 packages, 0 potential CVEs)
- [x] **Multi-stage build**: Binary compiled in builder stage, only binary copied to production
- [x] **Non-root**: Container runs as UID 65534 (nobody)
- [x] **Image < 20MB**: Static Go binary ~8MB + CA certificates
- [x] **No secrets in image**: Environment variables injected at runtime
- [x] **Read-only filesystem**: `readOnlyRootFilesystem: true` in securityContext
- [x] **No privilege escalation**: `allowPrivilegeEscalation: false`
- [x] **Capabilities dropped**: `drop: ALL`
- [x] **Seccomp profile**: `RuntimeDefault`

## Secrets Management

- [x] **Zero secrets in Git**: No secrets in code, Dockerfile, values.yaml or manifests
- [x] **External Secrets Operator**: Secrets synchronised from AWS Secrets Manager
- [x] **IRSA authentication**: ESO authenticates with IAM role, no static credentials
- [x] **Secrets per region**: Spain in eu-south-2, Mexico in us-east-1
- [x] **Rotation supported**: Configurable refreshInterval in ExternalSecret
- [x] **Encrypted in Secrets Manager**: Secrets encrypted with dedicated KMS key

## Network Security

- [x] **TLS in transit**: ALB terminates TLS 1.2+, Ingress enforces HTTPS redirect
- [x] **Private subnets**: EKS pods in private subnets, no public IP
- [x] **Isolated database**: RDS in database subnets with no internet access
- [x] **Restrictive security groups**: RDS only accepts traffic from EKS nodes
- [x] **VPC Flow Logs**: Enabled for traffic auditing
- [x] **Restrictable EKS endpoint**: `cluster_endpoint_public_access_cidrs` configurable (default open, restrict in production)

## Encryption

- [x] **At rest - RDS**: `storage_encrypted = true` with KMS
- [x] **At rest - EBS**: KMS encryption for EKS node volumes
- [x] **At rest - K8s secrets**: Envelope encryption with KMS in EKS
- [x] **At rest - S3**: CloudTrail buckets encrypted with KMS
- [x] **In transit**: TLS enforced on ALB, RDS with `ssl = 1`
- [x] **KMS key rotation**: `enable_key_rotation = true`

## Identity & Access Management

- [x] **Least privilege**: IAM roles with minimal permissions per service
- [x] **IRSA**: Each K8s component with its own IAM role (ESO, LB Controller, EBS CSI)
- [x] **No static credentials**: Everything based on assumed roles
- [x] **Dedicated service accounts**: One service account per application

## Data Residency & Compliance

- [x] **GDPR (Spain)**: EU data in eu-south-2, tags `DataResidency=EU`, `Compliance=GDPR`
- [x] **Federal Law MX (Mexico)**: MX data in us-east-1, tags `DataResidency=MX`, `Compliance=LeyFederalMX`
- [x] **No cross-region replication**: Data and secrets are not replicated between regions
- [x] **Resource tagging**: All AWS resources tagged with region and compliance

## Auditing & Monitoring

- [x] **CloudTrail**: Enabled in both regions with log file validation
- [x] **CloudTrail encrypted**: Logs in S3 encrypted with KMS
- [x] **VPC Flow Logs**: Stored in CloudWatch with dedicated IAM role
- [x] **Prometheus metrics**: ServiceMonitor for application metrics scraping
- [x] **Application logging**: Structured logs, connection strings masked

## Kubernetes Security

- [x] **Pod Security Context**: `runAsNonRoot`, `runAsUser`, `fsGroup`
- [x] **Container Security Context**: capabilities dropped, no escalation, read-only fs
- [x] **Resource limits**: CPU and memory defined to prevent noisy neighbours
- [x] **Probes configured**: Liveness and readiness for health checking
- [x] **HPA**: Auto-scaling to absorb spikes without degrading security
- [x] **PodDisruptionBudget**: `minAvailable: 1` protects availability during voluntary disruptions
- [x] **Rolling update strategy**: `maxUnavailable: 0` guarantees zero downtime on deploys

## Supply Chain

- [x] **Documented Terraform modules**: Source and version of each public module
- [x] **go.sum**: Go dependency checksums verified
- [x] **Base images with fixed tags**: `golang:1.21-alpine` (not latest)
