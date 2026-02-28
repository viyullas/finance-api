# Deployment Runbook

Step-by-step manual procedure for deploying the platform from scratch. Each phase depends on the previous one completing successfully.

> For automated deployment (`make up` / `make down`), prerequisites and configuration, see the project [README](../README.md#quick-start).

---

## Prerequisites

This runbook assumes you have already configured all prerequisites listed in the [README](../README.md#prerequisites) (tools, S3 bucket, hosted zone).

### S3 Bucket for Terraform State

Shared backend for both environments, each with an independent key. Locking uses S3 native conditional writes (Terraform >= 1.10), no DynamoDB required.

The bucket must be created manually before running `terraform init`:

```bash
aws s3api create-bucket \
  --bucket aabella-terraform-backends \
  --region eu-south-2 \
  --create-bucket-configuration LocationConstraint=eu-south-2

aws s3api put-bucket-versioning \
  --bucket aabella-terraform-backends \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
  --bucket aabella-terraform-backends \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Required characteristics:
- **Region:** `eu-south-2`
- **Versioning:** enabled (allows recovery of previous states)
- **Encryption:** SSE-S3 (default on new buckets)
- **Public access:** blocked

> **To use your own bucket:** change the name in `4_infrastructure/terraform/environments/{spain,mexico}/main.tf` → `backend "s3"` block (current: `aabella-terraform-backends`).

### Hosted Zone in Route53

A Route53 hosted zone is required for ACM certificate DNS validation. It must exist before `terraform apply`.

> **To use your own domain:** change the `hosted_zone_name` and `app_domain` variables in `4_infrastructure/terraform/environments/{spain,mexico}/variables.tf` (current: `aws.lacloaca.com`, `api-es.aws.lacloaca.com`, `api-mx.aws.lacloaca.com`).

---

## Phase 1 — Infrastructure (Terraform)

Creates VPC, EKS, RDS, RDS Proxy, KMS, CloudTrail, IRSA roles and empty secrets in Secrets Manager.

```bash
# Spain (eu-south-2)
cd 4_infrastructure/terraform/environments/spain
terraform init
terraform plan -out=spain.tfplan
terraform apply spain.tfplan

# Mexico (us-east-1)
cd ../mexico
terraform init
terraform plan -out=mexico.tfplan
terraform apply mexico.tfplan
```

### Export outputs (single query per region)

```bash
# Spain — single state call, everything in one JSON
cd 4_infrastructure/terraform/environments/spain
terraform output -json > /tmp/spain-outputs.json

# Mexico
cd ../mexico
terraform output -json > /tmp/mexico-outputs.json

# Return to project root (subsequent commands use relative paths)
cd ../../../../
```

### Load variables from outputs

All subsequent phases use these variables. Run in the same shell session:

```bash
# Spain
SPAIN_CLUSTER=$(jq -r '.eks_cluster_name.value' /tmp/spain-outputs.json)
SPAIN_CLUSTER_URL=$(jq -r '.eks_cluster_endpoint.value' /tmp/spain-outputs.json)
SPAIN_ECR_REGISTRY=$(jq -r '.ecr_registry.value' /tmp/spain-outputs.json)
SPAIN_CERT_ARN=$(jq -r '.acm_certificate_arn.value' /tmp/spain-outputs.json)
SPAIN_RDS_SECRET_ARN=$(jq -r '.rds_master_secret_arn.value' /tmp/spain-outputs.json)
SPAIN_RDS_ENDPOINT=$(jq -r '.db_connection_endpoint.value' /tmp/spain-outputs.json)
SPAIN_ESO_ROLE_ARN=$(jq -r '.external_secrets_role_arn.value' /tmp/spain-outputs.json)
SPAIN_LB_ROLE_ARN=$(jq -r '.lb_controller_role_arn.value' /tmp/spain-outputs.json)
SPAIN_ECR=$(jq -r '.ecr_repository_url.value' /tmp/spain-outputs.json)
SPAIN_APP_SECRET_ID=$(jq -r '.app_secret_id.value' /tmp/spain-outputs.json)
SPAIN_REGION="eu-south-2"

# Mexico
MEXICO_CLUSTER=$(jq -r '.eks_cluster_name.value' /tmp/mexico-outputs.json)
MEXICO_CLUSTER_URL=$(jq -r '.eks_cluster_endpoint.value' /tmp/mexico-outputs.json)
MEXICO_ECR_REGISTRY=$(jq -r '.ecr_registry.value' /tmp/mexico-outputs.json)
MEXICO_CERT_ARN=$(jq -r '.acm_certificate_arn.value' /tmp/mexico-outputs.json)
MEXICO_RDS_SECRET_ARN=$(jq -r '.rds_master_secret_arn.value' /tmp/mexico-outputs.json)
MEXICO_RDS_ENDPOINT=$(jq -r '.db_connection_endpoint.value' /tmp/mexico-outputs.json)
MEXICO_ESO_ROLE_ARN=$(jq -r '.external_secrets_role_arn.value' /tmp/mexico-outputs.json)
MEXICO_LB_ROLE_ARN=$(jq -r '.lb_controller_role_arn.value' /tmp/mexico-outputs.json)
MEXICO_ECR=$(jq -r '.ecr_repository_url.value' /tmp/mexico-outputs.json)
MEXICO_APP_SECRET_ID=$(jq -r '.app_secret_id.value' /tmp/mexico-outputs.json)
MEXICO_REGION="us-east-1"
```

### Docker image build and push to ECR

```bash
# Login to ECR (Spain) — variables already loaded from JSON
aws ecr get-login-password --region "$SPAIN_REGION" | docker login --username AWS --password-stdin ${SPAIN_ECR%%/*}

# Build and push
docker build -t ${SPAIN_ECR}:1.0.0 .
docker push ${SPAIN_ECR}:1.0.0

# Login to ECR (Mexico)
aws ecr get-login-password --region "$MEXICO_REGION" | docker login --username AWS --password-stdin ${MEXICO_ECR%%/*}

# Push to Mexico (same image)
docker tag ${SPAIN_ECR}:1.0.0 ${MEXICO_ECR}:1.0.0
docker push ${MEXICO_ECR}:1.0.0
```

---

## Phase 2 — Configure kubeconfig

> Variables `$SPAIN_CLUSTER`, `$SPAIN_REGION`, `$MEXICO_CLUSTER`, `$MEXICO_REGION` are already loaded from the JSON exported in Phase 1.

```bash
# Spain
aws eks update-kubeconfig \
  --name "$SPAIN_CLUSTER" \
  --region "$SPAIN_REGION" \
  --alias spain

# Mexico
aws eks update-kubeconfig \
  --name "$MEXICO_CLUSTER" \
  --region "$MEXICO_REGION" \
  --alias mexico
```

Verify access to both clusters:

```bash
kubectl --context spain get nodes
kubectl --context mexico get nodes
```

---

## Phase 3 — Cluster Addons (both regions)

These components must be installed in **both clusters** before applications can function. Without them, Ingresses will not create ALBs and ExternalSecrets will not sync.

### 3.1 — AWS Load Balancer Controller

Required for `Ingress` resources to create real ALBs in AWS. Without this controller, the Ingress has no effect.

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Spain — $SPAIN_LB_ROLE_ARN already loaded from JSON
kubectl --context spain create namespace kube-system 2>/dev/null || true

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --kube-context spain \
  -n kube-system \
  --set clusterName="$SPAIN_CLUSTER" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$SPAIN_LB_ROLE_ARN" \
  --set nodeSelector.role=system \
  --set "tolerations[0].key=dedicated" \
  --set "tolerations[0].value=system" \
  --set "tolerations[0].effect=NoSchedule"

# Mexico — $MEXICO_LB_ROLE_ARN already loaded from JSON
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --kube-context mexico \
  -n kube-system \
  --set clusterName="$MEXICO_CLUSTER" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$MEXICO_LB_ROLE_ARN" \
  --set nodeSelector.role=system \
  --set "tolerations[0].key=dedicated" \
  --set "tolerations[0].value=system" \
  --set "tolerations[0].effect=NoSchedule"
```

Verify:

```bash
kubectl --context spain -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl --context mexico -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
```

### 3.2 — External Secrets Operator (ESO)

Required for `ExternalSecret` resources to sync secrets from AWS Secrets Manager. Without ESO, pods will not have `DATABASE_URL` or `API_SECRET_KEY`.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Spain — $SPAIN_ESO_ROLE_ARN already loaded from JSON
helm install external-secrets external-secrets/external-secrets \
  --kube-context spain \
  -n external-secrets --create-namespace \
  --set serviceAccount.create=true \
  --set serviceAccount.name=external-secrets-sa \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$SPAIN_ESO_ROLE_ARN" \
  --set nodeSelector.role=system \
  --set "tolerations[0].key=dedicated" \
  --set "tolerations[0].value=system" \
  --set "tolerations[0].effect=NoSchedule" \
  --set webhook.nodeSelector.role=system \
  --set "webhook.tolerations[0].key=dedicated" \
  --set "webhook.tolerations[0].value=system" \
  --set "webhook.tolerations[0].effect=NoSchedule" \
  --set certController.nodeSelector.role=system \
  --set "certController.tolerations[0].key=dedicated" \
  --set "certController.tolerations[0].value=system" \
  --set "certController.tolerations[0].effect=NoSchedule"

# Mexico — $MEXICO_ESO_ROLE_ARN already loaded from JSON
helm install external-secrets external-secrets/external-secrets \
  --kube-context mexico \
  -n external-secrets --create-namespace \
  --set serviceAccount.create=true \
  --set serviceAccount.name=external-secrets-sa \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$MEXICO_ESO_ROLE_ARN" \
  --set nodeSelector.role=system \
  --set "tolerations[0].key=dedicated" \
  --set "tolerations[0].value=system" \
  --set "tolerations[0].effect=NoSchedule" \
  --set webhook.nodeSelector.role=system \
  --set "webhook.tolerations[0].key=dedicated" \
  --set "webhook.tolerations[0].value=system" \
  --set "webhook.tolerations[0].effect=NoSchedule" \
  --set certController.nodeSelector.role=system \
  --set "certController.tolerations[0].key=dedicated" \
  --set "certController.tolerations[0].value=system" \
  --set "certController.tolerations[0].effect=NoSchedule"
```

Verify:

```bash
kubectl --context spain -n external-secrets get pods
kubectl --context mexico -n external-secrets get pods
```

### 3.3 — ClusterSecretStore (both regions)

After installing ESO, create the `ClusterSecretStore` that references the Helm chart in each region. This resource tells ESO how to connect to AWS Secrets Manager.

```bash
# Spain
kubectl --context spain apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: $SPAIN_REGION
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
EOF

# Mexico
kubectl --context mexico apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: $MEXICO_REGION
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
EOF
```

Verify:

```bash
kubectl --context spain get clustersecretstore aws-secrets-manager
kubectl --context mexico get clustersecretstore aws-secrets-manager
# STATUS should be "Valid"
```

---

## Phase 4 — Populate Secrets in AWS Secrets Manager

Terraform creates empty secrets. Only `API_SECRET_KEY` needs to be populated — database credentials are managed automatically by RDS via `manage_master_user_password = true` and ESO reads them directly from the RDS secret to compose `DATABASE_URL`.

```bash
# Spain
aws secretsmanager put-secret-value \
  --region "$SPAIN_REGION" \
  --secret-id "$SPAIN_APP_SECRET_ID" \
  --secret-string '{
    "API_SECRET_KEY": "'$(openssl rand -hex 32)'"
  }'

# Mexico
aws secretsmanager put-secret-value \
  --region "$MEXICO_REGION" \
  --secret-id "$MEXICO_APP_SECRET_ID" \
  --secret-string '{
    "API_SECRET_KEY": "'$(openssl rand -hex 32)'"
  }'
```

> **Note:** `DATABASE_URL` is automatically composed in the ExternalSecret using the ESO template: it reads `username` and `password` from the RDS-managed secret, and the connection endpoint is injected via ArgoCD `helm.parameters`. The `db_connection_endpoint` output returns the RDS Proxy endpoint (if enabled) or the direct RDS endpoint (if not). The app connects to the proxy, which maintains a pool of persistent connections to RDS — saving ~30-50ms of TCP+TLS handshake per request. If RDS rotates the password, both the proxy and ESO resolve it automatically.

---

## Phase 5 — ArgoCD (Spain only)

Centralised instance in the Spain cluster managing both regions.

### 5.1 — Install ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --kube-context spain \
  -n argocd --create-namespace \
  -f 3_gitops/argocd/install/values-argocd.yaml
```

Verify all pods start:

```bash
kubectl --context spain -n argocd get pods
```

### 5.2 — Get initial admin password

```bash
kubectl --context spain -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

### 5.3 — Login with CLI

ArgoCD has no Ingress configured (to avoid exposing the control plane and the cost of an additional ALB). Access is via port-forward:

```bash
kubectl --context spain -n argocd port-forward svc/argocd-server 8443:443 &
argocd login localhost:8443 --insecure --username admin --password <password>
```

> **Production:** For permanent access without port-forward, it is recommended to configure Ingress with WAF (rate limiting + IP allowlist) + SSO via Dex/OIDC (Google Workspace, Okta, Azure AD) and disable the local admin account.

### 5.4 — Register Mexico cluster as a destination

ArgoCD requires credentials to deploy to the Mexico cluster.

```bash
# Ensure the "mexico" context exists in kubeconfig
argocd cluster add mexico --name "$MEXICO_CLUSTER"
```

Verify:

```bash
argocd cluster list
# Should show:
#   in-cluster (Spain, default)
#   <mexico-cluster-name> (Mexico, added)
```

### 5.5 — Deploy the applications

ArgoCD manifests contain placeholders that are substituted on the fly with sed. The original files are not modified.

```bash
# Option A: ApplicationSet (recommended, manages both regions)
# Spain uses https://kubernetes.default.svc (in-cluster, already hardcoded in the template)
# Only infrastructure value placeholders are substituted
sed "s|ECR_REGISTRY_SPAIN|$SPAIN_ECR_REGISTRY|g; \
     s|ACM_ARN_SPAIN|$SPAIN_CERT_ARN|g; \
     s|RDS_SECRET_ARN_SPAIN|$SPAIN_RDS_SECRET_ARN|g; \
     s|RDS_ENDPOINT_SPAIN|$SPAIN_RDS_ENDPOINT|g; \
     s|APP_SECRET_ID_SPAIN|$SPAIN_APP_SECRET_ID|g; \
     s|CLUSTER_URL_MEXICO|$MEXICO_CLUSTER_URL|g; \
     s|ECR_REGISTRY_MEXICO|$MEXICO_ECR_REGISTRY|g; \
     s|ACM_ARN_MEXICO|$MEXICO_CERT_ARN|g; \
     s|RDS_SECRET_ARN_MEXICO|$MEXICO_RDS_SECRET_ARN|g; \
     s|RDS_ENDPOINT_MEXICO|$MEXICO_RDS_ENDPOINT|g; \
     s|APP_SECRET_ID_MEXICO|$MEXICO_APP_SECRET_ID|g" \
  3_gitops/argocd/applicationset.yaml | kubectl --context spain apply -f -

# Option B: Individual Applications (only if not using ApplicationSet)
# Spain: no cluster URL substitution needed (already in-cluster)
sed "s|ECR_REGISTRY_SPAIN|$SPAIN_ECR_REGISTRY|g; \
     s|ACM_ARN_SPAIN|$SPAIN_CERT_ARN|g; \
     s|RDS_SECRET_ARN_SPAIN|$SPAIN_RDS_SECRET_ARN|g; \
     s|RDS_ENDPOINT_SPAIN|$SPAIN_RDS_ENDPOINT|g; \
     s|APP_SECRET_ID_SPAIN|$SPAIN_APP_SECRET_ID|g" \
  3_gitops/argocd/application-spain.yaml | kubectl --context spain apply -f -

# Mexico: remote cluster, requires external URL
sed "s|CLUSTER_URL_MEXICO|$MEXICO_CLUSTER_URL|g; \
     s|ECR_REGISTRY_MEXICO|$MEXICO_ECR_REGISTRY|g; \
     s|ACM_ARN_MEXICO|$MEXICO_CERT_ARN|g; \
     s|RDS_SECRET_ARN_MEXICO|$MEXICO_RDS_SECRET_ARN|g; \
     s|RDS_ENDPOINT_MEXICO|$MEXICO_RDS_ENDPOINT|g; \
     s|APP_SECRET_ID_MEXICO|$MEXICO_APP_SECRET_ID|g" \
  3_gitops/argocd/application-mexico.yaml | kubectl --context spain apply -f -
```

Verify in ArgoCD:

```bash
argocd app list
argocd app get payment-latency-api-spain
argocd app get payment-latency-api-mexico
```

---

## Phase 6 — Verification

### Health checks

```bash
# Spain (via port-forward if no DNS)
kubectl --context spain -n payment-api port-forward svc/payment-latency-api-spain 8080:80 &
curl http://localhost:8080/health
curl http://localhost:8080/info

# Mexico
kubectl --context mexico -n payment-api port-forward svc/payment-latency-api-mexico 8081:80 &
curl http://localhost:8081/health
curl http://localhost:8081/info
```

### Secrets synced

```bash
kubectl --context spain -n payment-api get externalsecret
kubectl --context mexico -n payment-api get externalsecret
# STATUS should be "SecretSynced"
```

### ALB created

```bash
kubectl --context spain -n payment-api get ingress
kubectl --context mexico -n payment-api get ingress
# ADDRESS should show the ALB DNS name
```

### Payment simulate endpoint

```bash
# Get API_SECRET_KEY for Spain
API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "$SPAIN_APP_SECRET_ID" \
  --region "$SPAIN_REGION" \
  --query SecretString --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['API_SECRET_KEY'])")

# Spain
curl -s -H "X-API-Key: $API_KEY" https://api-es.aws.lacloaca.com/api/payment/simulate | python3 -m json.tool

# Mexico (repeat with MEXICO_APP_SECRET_ID and MEXICO_REGION)
curl -s -H "X-API-Key: $API_KEY" https://api-mx.aws.lacloaca.com/api/payment/simulate | python3 -m json.tool
```

### Prometheus metrics

```bash
curl http://localhost:8080/metrics | grep payment_processing
```

---

## Execution order summary

| Phase | What | Where | Dependency |
|-------|------|-------|------------|
| 1 | Terraform apply | Spain + Mexico | Prerequisites |
| 2 | Configure kubeconfig | Local | Phase 1 |
| 3.1 | ALB Controller | Spain + Mexico | Phase 2 |
| 3.2 | External Secrets Operator | Spain + Mexico | Phase 2 |
| 3.3 | ClusterSecretStore | Spain + Mexico | Phase 3.2 |
| 4 | Populate secrets in Secrets Manager | AWS | Phase 1 |
| 5.1 | Install ArgoCD | Spain | Phase 3.1 |
| 5.4 | Register Mexico cluster | Spain (ArgoCD) | Phase 5.1 + Phase 2 |
| 5.5 | Apply ApplicationSet | Spain (ArgoCD) | Phase 3.3 + Phase 4 + Phase 5.4 |
| 6 | Verification | Both clusters | Phase 5.5 |

> **Important:** All Phase 3 addons run on `system` nodes with toleration for the `dedicated=system:NoSchedule` taint. This is consistent with the system/application node group separation defined in the infrastructure.
