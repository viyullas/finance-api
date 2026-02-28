# ADR-03: Gestión de Secretos

## Estado
Aceptado

## Contexto
La aplicación requiere dos secretos sensibles:
- `DATABASE_URL`: connection string a PostgreSQL (contiene credenciales)
- `API_SECRET_KEY`: clave de autenticación interna de 64 caracteres

Estos secretos NUNCA deben estar en Git, ni en values.yaml, ni hardcodeados.

## Decisión

### External Secrets Operator (ESO) + AWS Secrets Manager

**Flujo:**
```
AWS Secrets Manager          ESO (in-cluster)         Kubernetes Secret         Pod
┌─────────────────┐    sync  ┌───────────────┐  create  ┌────────────────┐   mount  ┌─────┐
│ production/      │ ──────→ │ ExternalSecret │ ──────→ │ Secret         │ ──────→ │ App │
│   spain/         │         │ CRD            │         │ (native K8s)   │         │     │
│   payment-api    │         └───────────────┘         └────────────────┘         └─────┘
└─────────────────┘
```

### Alternativas Evaluadas

| Solución | Pros | Contras | Decisión |
|----------|------|---------|----------|
| **ESO + Secrets Manager** | Zero secrets en Git, rotación automática, nativo AWS, IRSA | Componente adicional en cluster | **Elegida** |
| Sealed Secrets | Secrets cifrados en Git | Requiere gestión de claves, no rotación automática | Descartada |
| Vault (HashiCorp) | Muy potente, multi-cloud | Operacionalmente complejo, sobredimensionado para este caso | Descartada |
| SOPS + KMS | Secrets cifrados en Git | Requiere descifrar en CI/CD, no nativo K8s | Descartada |
| Variables de entorno en Deployment | Simple | Secrets en Git (values.yaml) | **Prohibida** |

## Implementación

### 1. Almacenamiento en AWS Secrets Manager
Cada región maneja dos tipos de secrets:

**Gestionado por RDS** (automático, con rotación):
```
rds!db-<identifier>          # Creado automáticamente por RDS (manage_master_user_password = true)
  ├── username                # Master username (dbadmin)
  └── password                # Master password (rotado automáticamente)
```

**API_SECRET_KEY** (auto-generado en el deploy):
```
production/spain/payment-latency-api-<random_hex>
  └── API_SECRET_KEY

production/mexico/payment-latency-api-<random_hex>
  └── API_SECRET_KEY
```

- Terraform crea el secret vacío en Secrets Manager con un sufijo aleatorio (`random_id`, 8 hex chars) para evitar colisiones de nombre en ciclos destroy/recreate
- `make secrets` genera el valor con `openssl rand -hex 32` y lo almacena via `put-secret-value`
- El nombre del secret (con sufijo) se obtiene del terraform output `app_secret_id` y se inyecta en el ExternalSecret via ArgoCD `helm.parameters`

El `DATABASE_URL` ya NO se almacena como secret — se compone en el ExternalSecret usando el template de ESO, leyendo `username`/`password` del secret de RDS y combinándolos con el endpoint (inyectado via ArgoCD `helm.parameters`). Esto elimina la duplicación del password y permite que la rotación automática de RDS se propague sin intervención manual.

### 2. Autenticación ESO → AWS (IRSA)
ESO se autentica con AWS Secrets Manager mediante IRSA (IAM Roles for Service Accounts):
- No hay credenciales AWS estáticas en el cluster
- El rol IAM tiene permisos mínimos: solo `secretsmanager:GetSecretValue` sobre los ARNs específicos (`production/<region>/*` + `rds!db-*`)
- Definido en Terraform (`modules/eks/main.tf` → `external_secrets_irsa`)

### 3. ClusterSecretStore
Un `ClusterSecretStore` por cluster apunta a AWS Secrets Manager de su región:
```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-south-2  # o us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
```

### 4. ExternalSecret con Template (composición de DATABASE_URL)
Definido en el Helm chart (`templates/externalsecret.yaml`):
- Referencia el `ClusterSecretStore`
- Sincroniza los secretos cada 1 hora
- Usa `target.template` (engine v2) para componer `DATABASE_URL` a partir de:
  - `username` y `password` del secret gestionado por RDS (vía `remoteRef`)
  - `host`, `port`, `dbname` y `sslmode` inyectados como Helm values (vía ArgoCD `helm.parameters`)
- `API_SECRET_KEY` se lee directamente del secret manual
- Crea un Kubernetes Secret nativo que el Deployment consume via `envFrom`

**Ventajas de este enfoque:**
- Zero duplicación: el password de RDS existe solo en un lugar (el secret de RDS)
- Rotación transparente: cuando RDS rota el password, ESO lo sincroniza en el siguiente refresh
- Menos pasos manuales: no hay que copiar el password de RDS a otro secret

### 5. Rotación de Secretos
- **Password de RDS:** gestionado y rotado automáticamente por AWS (`manage_master_user_password = true`). ESO re-sincroniza según `refreshInterval` (1h) y recompone el `DATABASE_URL` con el nuevo password
- **API_SECRET_KEY:** generado automáticamente durante el deploy inicial (`make secrets` → `openssl rand -hex 32`). Para rotar: actualizar el valor en Secrets Manager y esperar al siguiente refresh de ESO (1h) o forzar con `kubectl annotate externalsecret --overwrite force-sync=$(date +%s)`
- Los pods obtienen los nuevos valores en el siguiente restart o con un rolling update

## Residencia de Datos
- Los secretos de España se almacenan en Secrets Manager de eu-south-2
- Los secretos de México se almacenan en Secrets Manager de us-east-1
- Cada ESO solo accede a los secretos de su propia región (policy IAM restrictiva)
- No hay replicación cross-region de secretos

## Consecuencias
- ESO es una dependencia adicional que debe estar saludable para que los pods arranquen con secretos actualizados
- Si ESO falla, los pods existentes siguen funcionando (los Kubernetes Secrets persisten)
- Nuevos pods no podrán arrancar si el Secret no existe y ESO está caído
- La rotación de secretos requiere un rolling restart de pods (no es hot-reload)
