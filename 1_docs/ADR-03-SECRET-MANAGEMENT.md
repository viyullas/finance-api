# ADR-03: Secret Management

## Status
Accepted

## Context
The application requires two sensitive secrets:
- `DATABASE_URL`: PostgreSQL connection string (contains credentials)
- `API_SECRET_KEY`: 64-character internal authentication key

These secrets must NEVER be stored in Git, in values.yaml, or hardcoded.

## Decision

### External Secrets Operator (ESO) + AWS Secrets Manager

**Flow:**
```
AWS Secrets Manager          ESO (in-cluster)         Kubernetes Secret         Pod
┌─────────────────┐    sync  ┌───────────────┐  create  ┌────────────────┐   mount  ┌─────┐
│ production/      │ ──────→ │ ExternalSecret │ ──────→ │ Secret         │ ──────→ │ App │
│   spain/         │         │ CRD            │         │ (native K8s)   │         │     │
│   payment-api    │         └───────────────┘         └────────────────┘         └─────┘
└─────────────────┘
```

### Alternatives Evaluated

| Solution | Pros | Cons | Decision |
|----------|------|------|----------|
| **ESO + Secrets Manager** | Zero secrets in Git, automatic rotation, AWS-native, IRSA | Additional component in cluster | **Chosen** |
| Sealed Secrets | Encrypted secrets in Git | Requires key management, no automatic rotation | Discarded |
| Vault (HashiCorp) | Very powerful, multi-cloud | Operationally complex, overkill for this use case | Discarded |
| SOPS + KMS | Encrypted secrets in Git | Requires decryption in CI/CD, not K8s-native | Discarded |
| Environment variables in Deployment | Simple | Secrets in Git (values.yaml) | **Prohibited** |

## Implementation

### 1. Storage in AWS Secrets Manager
Each region handles two types of secrets:

**Managed by RDS** (automatic, with rotation):
```
rds!db-<identifier>          # Automatically created by RDS (manage_master_user_password = true)
  ├── username                # Master username (dbadmin)
  └── password                # Master password (automatically rotated)
```

**API_SECRET_KEY** (auto-generated on deploy):
```
production/spain/payment-latency-api-<random_hex>
  └── API_SECRET_KEY

production/mexico/payment-latency-api-<random_hex>
  └── API_SECRET_KEY
```

- Terraform creates an empty secret in Secrets Manager with a random suffix (`random_id`, 8 hex chars) to avoid name collisions during destroy/recreate cycles
- `make secrets` generates the value with `openssl rand -hex 32` and stores it via `put-secret-value`
- The secret name (with suffix) is obtained from the terraform output `app_secret_id` and injected into the ExternalSecret via ArgoCD `helm.parameters`

The `DATABASE_URL` is NO longer stored as a secret -- it is composed within the ExternalSecret using the ESO template, reading `username`/`password` from the RDS-managed secret and combining them with the endpoint (injected via ArgoCD `helm.parameters`). This eliminates password duplication and allows RDS automatic rotation to propagate without manual intervention.

### 2. ESO to AWS Authentication (IRSA)
ESO authenticates with AWS Secrets Manager using IRSA (IAM Roles for Service Accounts):
- No static AWS credentials in the cluster
- The IAM role has minimal permissions: only `secretsmanager:GetSecretValue` on specific ARNs (`production/<region>/*` + `rds!db-*`)
- Defined in Terraform (`modules/eks/main.tf` → `external_secrets_irsa`)

### 3. ClusterSecretStore
One `ClusterSecretStore` per cluster points to the AWS Secrets Manager in its region:
```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-south-2  # or us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
```

### 4. ExternalSecret with Template (DATABASE_URL composition)
Defined in the Helm chart (`templates/externalsecret.yaml`):
- References the `ClusterSecretStore`
- Syncs secrets every 1 hour
- Uses `target.template` (engine v2) to compose `DATABASE_URL` from:
  - `username` and `password` from the RDS-managed secret (via `remoteRef`)
  - `host`, `port`, `dbname`, and `sslmode` injected as Helm values (via ArgoCD `helm.parameters`)
- `API_SECRET_KEY` is read directly from the manual secret
- Creates a native Kubernetes Secret that the Deployment consumes via `envFrom`

**Advantages of this approach:**
- Zero duplication: the RDS password exists in only one place (the RDS secret)
- Transparent rotation: when RDS rotates the password, ESO syncs it on the next refresh
- Fewer manual steps: no need to copy the RDS password to another secret

### 5. Secret Rotation
- **RDS Password:** managed and automatically rotated by AWS (`manage_master_user_password = true`). ESO re-syncs according to `refreshInterval` (1h) and recomposes the `DATABASE_URL` with the new password
- **API_SECRET_KEY:** automatically generated during the initial deploy (`make secrets` → `openssl rand -hex 32`). To rotate: update the value in Secrets Manager and wait for the next ESO refresh (1h) or force it with `kubectl annotate externalsecret --overwrite force-sync=$(date +%s)`
- Pods pick up the new values on the next restart or with a rolling update

## Data Residency
- Spain secrets are stored in Secrets Manager in eu-south-2
- Mexico secrets are stored in Secrets Manager in us-east-1
- Each ESO instance only accesses secrets in its own region (restrictive IAM policy)
- No cross-region replication of secrets

## Consequences
- ESO is an additional dependency that must be healthy for pods to start with up-to-date secrets
- If ESO fails, existing pods continue to work (Kubernetes Secrets persist)
- New pods will not be able to start if the Secret does not exist and ESO is down
- Secret rotation requires a rolling restart of pods (no hot-reload)
