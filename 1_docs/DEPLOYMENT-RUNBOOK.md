# Runbook de Despliegue

Procedimiento completo para desplegar la plataforma desde cero. Cada fase depende de que la anterior haya finalizado correctamente.

## Quick Start (Makefile)

Con todas las herramientas instaladas y el bucket S3 creado (ver prerequisitos):

```bash
make up        # Despliega todo: terraform, kubeconfig, docker, helm, secrets, argocd, apps
make status    # Muestra estado de ambos clusters
make down      # Destruye todo sin confirmaciones (entorno de pruebas)
```

Para ejecutar fases individuales: `make help` muestra todos los targets disponibles.

> El resto de este documento describe el procedimiento manual paso a paso, útil como referencia o para depuración.

---

## Prerequisitos

- AWS CLI configurado con credenciales para ambas cuentas/regiones
- `terraform` >= 1.10.0
- `helm` >= 3.x
- `kubectl`
- `make` (GNU Make)
- `docker`
- `openssl` (para generar secretos aleatorios)
- Bucket S3 para el backend de Terraform (ver sección siguiente)

### Bucket S3 para Terraform State

Backend común para ambos entornos, cada uno con key independiente. El locking usa S3 native conditional writes (Terraform >= 1.10), no requiere DynamoDB.

El bucket debe crearse manualmente antes de ejecutar `terraform init`:

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

Características requeridas:
- **Región:** `eu-south-2`
- **Versionado:** activado (permite recuperar states anteriores)
- **Cifrado:** SSE-S3 (por defecto en buckets nuevos)
- **Acceso público:** bloqueado

---

## Fase 1 — Infraestructura (Terraform)

Crea VPC, EKS, RDS, RDS Proxy, KMS, CloudTrail, IRSA roles y secrets vacíos en Secrets Manager.

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

### Exportar outputs (una sola consulta por region)

```bash
# Spain — una sola llamada al state, todo en un JSON
cd 4_infrastructure/terraform/environments/spain
terraform output -json > /tmp/spain-outputs.json

# Mexico
cd ../mexico
terraform output -json > /tmp/mexico-outputs.json

# Volver a la raiz del proyecto (los comandos siguientes usan rutas relativas)
cd ../../../../
```

### Cargar variables de los outputs

Todas las fases siguientes usan estas variables. Ejecutar en la misma sesión de shell:

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

### Build y push de la imagen Docker a ECR

```bash
# Login en ECR (Spain) — variables ya cargadas del JSON
aws ecr get-login-password --region "$SPAIN_REGION" | docker login --username AWS --password-stdin ${SPAIN_ECR%%/*}

# Build y push
docker build -t ${SPAIN_ECR}:1.0.0 .
docker push ${SPAIN_ECR}:1.0.0

# Login en ECR (Mexico)
aws ecr get-login-password --region "$MEXICO_REGION" | docker login --username AWS --password-stdin ${MEXICO_ECR%%/*}

# Push a Mexico (misma imagen)
docker tag ${SPAIN_ECR}:1.0.0 ${MEXICO_ECR}:1.0.0
docker push ${MEXICO_ECR}:1.0.0
```

---

## Fase 2 — Configurar kubeconfig

> Las variables `$SPAIN_CLUSTER`, `$SPAIN_REGION`, `$MEXICO_CLUSTER`, `$MEXICO_REGION` ya están cargadas del JSON exportado en la Fase 1.

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

Verificar acceso a ambos clusters:

```bash
kubectl --context spain get nodes
kubectl --context mexico get nodes
```

---

## Fase 3 — Cluster Addons (ambas regiones)

Estos componentes deben instalarse en **ambos clusters** antes de que las aplicaciones puedan funcionar. Sin ellos, los Ingress no crean ALBs y los ExternalSecrets no sincronizan.

### 3.1 — AWS Load Balancer Controller

Necesario para que los recursos `Ingress` creen ALBs reales en AWS. Sin este controller, el Ingress queda sin efecto.

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Spain — $SPAIN_LB_ROLE_ARN ya cargada del JSON
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

# Mexico — $MEXICO_LB_ROLE_ARN ya cargada del JSON
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

Verificar:

```bash
kubectl --context spain -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl --context mexico -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
```

### 3.2 — External Secrets Operator (ESO)

Necesario para que los recursos `ExternalSecret` sincronicen secretos desde AWS Secrets Manager. Sin ESO, los pods no tendrán `DATABASE_URL` ni `API_SECRET_KEY`.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Spain — $SPAIN_ESO_ROLE_ARN ya cargada del JSON
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

# Mexico — $MEXICO_ESO_ROLE_ARN ya cargada del JSON
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

Verificar:

```bash
kubectl --context spain -n external-secrets get pods
kubectl --context mexico -n external-secrets get pods
```

### 3.3 — ClusterSecretStore (ambas regiones)

Después de instalar ESO, hay que crear el `ClusterSecretStore` que referencia el Helm chart en cada región. Este es el recurso que le dice a ESO cómo conectar con AWS Secrets Manager.

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

Verificar:

```bash
kubectl --context spain get clustersecretstore aws-secrets-manager
kubectl --context mexico get clustersecretstore aws-secrets-manager
# STATUS debe ser "Valid"
```

---

## Fase 4 — Poblar secretos en AWS Secrets Manager

Terraform crea los secrets vacíos. Solo hay que poblar `API_SECRET_KEY` — las credenciales de la base de datos las gestiona RDS automáticamente via `manage_master_user_password = true` y ESO las lee directamente del secret de RDS para componer el `DATABASE_URL`.

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

> **Nota:** El `DATABASE_URL` se compone automáticamente en el ExternalSecret usando el template de ESO: lee `username` y `password` del secret gestionado por RDS, y el endpoint de conexión se inyecta via ArgoCD `helm.parameters`. El output `db_connection_endpoint` devuelve el endpoint del RDS Proxy (si está habilitado) o el de RDS directo (si no). La app conecta al proxy, que mantiene un pool de conexiones persistentes a RDS — esto elimina ~30-50ms de handshake TCP+TLS por request. Si RDS rota el password, tanto el proxy como ESO lo resuelven automáticamente.

---

## Fase 5 — ArgoCD (solo Spain)

Instancia centralizada en el cluster de Spain que gestiona ambas regiones.

### 5.1 — Instalar ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --kube-context spain \
  -n argocd --create-namespace \
  -f 3_gitops/argocd/install/values-argocd.yaml
```

Verificar que todos los pods arrancan:

```bash
kubectl --context spain -n argocd get pods
```

### 5.2 — Obtener password inicial de admin

```bash
kubectl --context spain -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

### 5.3 — Login con CLI

ArgoCD no tiene Ingress configurado (para evitar exponer el control plane y el coste de un ALB adicional). El acceso es via port-forward:

```bash
kubectl --context spain -n argocd port-forward svc/argocd-server 8443:443 &
argocd login localhost:8443 --insecure --username admin --password <password>
```

> **Produccion:** Para acceso permanente sin port-forward, se recomienda configurar Ingress con WAF (rate limiting + IP allowlist) + SSO via Dex/OIDC (Google Workspace, Okta, Azure AD) y deshabilitar la cuenta admin local.

### 5.4 — Registrar cluster de Mexico como destino

ArgoCD necesita credenciales para desplegar en el cluster de Mexico.

```bash
# Asegurarse de que el context "mexico" existe en kubeconfig
argocd cluster add mexico --name "$MEXICO_CLUSTER"
```

Verificar:

```bash
argocd cluster list
# Debe mostrar:
#   in-cluster (Spain, default)
#   <mexico-cluster-name> (Mexico, agregado)
```

### 5.5 — Desplegar las aplicaciones

Los manifiestos ArgoCD contienen placeholders que se sustituyen al vuelo con sed. Los ficheros originales no se modifican.

```bash
# Opcion A: ApplicationSet (recomendado, gestiona ambas regiones)
# Spain usa https://kubernetes.default.svc (in-cluster, ya hardcodeado en el template)
# Solo se sustituyen placeholders de valores de infraestructura
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

# Opcion B: Applications individuales (solo si no se usa ApplicationSet)
# Spain: no necesita sustitucion de cluster URL (ya es in-cluster)
sed "s|ECR_REGISTRY_SPAIN|$SPAIN_ECR_REGISTRY|g; \
     s|ACM_ARN_SPAIN|$SPAIN_CERT_ARN|g; \
     s|RDS_SECRET_ARN_SPAIN|$SPAIN_RDS_SECRET_ARN|g; \
     s|RDS_ENDPOINT_SPAIN|$SPAIN_RDS_ENDPOINT|g; \
     s|APP_SECRET_ID_SPAIN|$SPAIN_APP_SECRET_ID|g" \
  3_gitops/argocd/application-spain.yaml | kubectl --context spain apply -f -

# Mexico: cluster remoto, necesita URL externa
sed "s|CLUSTER_URL_MEXICO|$MEXICO_CLUSTER_URL|g; \
     s|ECR_REGISTRY_MEXICO|$MEXICO_ECR_REGISTRY|g; \
     s|ACM_ARN_MEXICO|$MEXICO_CERT_ARN|g; \
     s|RDS_SECRET_ARN_MEXICO|$MEXICO_RDS_SECRET_ARN|g; \
     s|RDS_ENDPOINT_MEXICO|$MEXICO_RDS_ENDPOINT|g; \
     s|APP_SECRET_ID_MEXICO|$MEXICO_APP_SECRET_ID|g" \
  3_gitops/argocd/application-mexico.yaml | kubectl --context spain apply -f -
```

Verificar en ArgoCD:

```bash
argocd app list
argocd app get payment-latency-api-spain
argocd app get payment-latency-api-mexico
```

---

## Fase 6 — Verificacion

### Health checks

```bash
# Spain (via port-forward si no hay DNS)
kubectl --context spain -n payment-api port-forward svc/payment-latency-api-spain 8080:80 &
curl http://localhost:8080/health
curl http://localhost:8080/info

# Mexico
kubectl --context mexico -n payment-api port-forward svc/payment-latency-api-mexico 8081:80 &
curl http://localhost:8081/health
curl http://localhost:8081/info
```

### Secrets sincronizados

```bash
kubectl --context spain -n payment-api get externalsecret
kubectl --context mexico -n payment-api get externalsecret
# STATUS debe ser "SecretSynced"
```

### ALB creado

```bash
kubectl --context spain -n payment-api get ingress
kubectl --context mexico -n payment-api get ingress
# ADDRESS debe mostrar el DNS del ALB
```

### Metricas Prometheus

```bash
curl http://localhost:8080/metrics | grep payment_processing
```

---

## Resumen de orden de ejecucion

| Fase | Que | Donde | Dependencia |
|------|-----|-------|-------------|
| 1 | Terraform apply | Spain + Mexico | Prerequisitos |
| 2 | Configurar kubeconfig | Local | Fase 1 |
| 3.1 | ALB Controller | Spain + Mexico | Fase 2 |
| 3.2 | External Secrets Operator | Spain + Mexico | Fase 2 |
| 3.3 | ClusterSecretStore | Spain + Mexico | Fase 3.2 |
| 4 | Poblar secretos en Secrets Manager | AWS | Fase 1 |
| 5.1 | Instalar ArgoCD | Spain | Fase 3.1 |
| 5.4 | Registrar cluster Mexico | Spain (ArgoCD) | Fase 5.1 + Fase 2 |
| 5.5 | Aplicar ApplicationSet | Spain (ArgoCD) | Fase 3.3 + Fase 4 + Fase 5.4 |
| 6 | Verificacion | Ambos clusters | Fase 5.5 |

> **Importante:** Todos los addons de la Fase 3 corren en nodos `system` con toleration al taint `dedicated=system:NoSchedule`. Esto es coherente con la separacion de node groups system/application definida en la infraestructura.
