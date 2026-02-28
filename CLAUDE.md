# Technical Assessment: Senior Platform Engineer - Pluxee/Cobee

## Contexto del Proyecto
Diseño e implementación de una infraestructura cloud multi-regional en AWS para una plataforma fintech de pagos con operaciones activas en España y México.

**Objetivo principal:** Arquitectura cloud-native que segmente datos sensibles por región cumpliendo GDPR (EU) y normativa local (México), con latencia < 100ms en transacciones financieras.

## Aplicación Base
- Repositorio: https://github.com/cobee-io/platform-sample-go-application
- Es una API Go llamada `payment-latency-api`
- Puerto: 8080
- Endpoints: `/health`, `/metrics`, `/info`, `/api/payment/simulate`

### Variables de entorno requeridas
**Secretos (NUNCA en Git):**
- `DATABASE_URL` → PostgreSQL connection string
- `API_SECRET_KEY` → clave de autenticación interna (64 chars)

**No sensibles (ConfigMap):**
- `REGION` → identificador de región AWS
- `ENVIRONMENT` → entorno de despliegue

---

## Estructura de Entregables

```
.
├── Dockerfile                          # Optimizado (<20MB, multi-stage, non-root)
├── CLAUDE.md                           # Este archivo
├── 1_docs/
│   ├── ADR-01-DECISIONS.md             # Decisiones globales de arquitectura
│   ├── ADR-02-LATENCY-STRATEGY.md      # Estrategia para <100ms
│   ├── ADR-03-SECRET-MANAGEMENT.md     # Gestión de secretos
│   ├── SECURITY-CHECKLIST.md           # Checklist de seguridad completado
│   └── README.md                       # Resumen de implementación
├── 2_application/
│   └── helm-charts/
│       └── payment-latency-api/        # Helm Chart completo
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
│       └── applicationset.yaml         # Bonus: multi-region en un solo manifiesto
└── 4_infrastructure/
    └── terraform/
        ├── modules/
        │   ├── vpc/                    # VPC multi-AZ
        │   ├── eks/                    # Cluster + node groups
        │   └── rds/                    # PostgreSQL
        └── environments/
            ├── spain/                  # eu-south-1
            └── mexico/                 # us-east-1 (región proxy para MX)
```

---

## Requisitos Técnicos por Área

### 1. Dockerfile
- Multi-stage build
- Imagen final < 20MB (usar `scratch` o `distroless`)
- Usuario non-root (UID 65532 o similar)
- Sin secretos hardcodeados

### 2. Helm Chart
Debe incluir todos estos recursos:
- `Deployment` con probes (liveness, readiness), resources limits/requests
- `Service` (ClusterIP)
- `Ingress` con TLS
- `ConfigMap` para variables no sensibles
- `HPA` (Horizontal Pod Autoscaler)
- `ServiceMonitor` para Prometheus
- Integración con External Secrets Operator (NO secretos en Git)

### 3. Infraestructura Terraform
- **VPC:** multi-AZ, subnets públicas/privadas, NAT Gateway
- **EKS:** cluster managed, node groups con auto-scaling
- **RDS:** PostgreSQL, Multi-AZ, encrypted, en subnet privada
- Usar módulos públicos documentando la fuente
- Ejecutar `terraform validate` antes de entregar

### 4. GitOps - ArgoCD
- `Application` manifest para España (`eu-south-1`)
- `Application` manifest para México (`us-east-1`)
- Bonus: `ApplicationSet` que gestione ambas regiones

### 5. Seguridad y Compliance
- **Residencia de datos:** datos EU solo en España, datos MX solo en México
- **Cifrado:** en reposo (KMS) y en tránsito (TLS 1.2+)
- **IAM:** least privilege, roles por servicio (IRSA en EKS)
- **Auditoría:** CloudTrail habilitado en ambas regiones

---

## Restricciones Absolutas
- ❌ NUNCA secrets en Git (ni hardcodeados, ni en values.yaml)
- ❌ NUNCA ejecutar el contenedor como root
- ❌ NUNCA sin documentación
- ❌ NUNCA sin cifrado

## Shortcuts Permitidos
- ✅ Usar módulos Terraform públicos (documentar fuente)
- ✅ Implementar una región completamente y documentar la segunda
- ✅ Usar herramientas de IA

---

## Regiones AWS
| Región  | AWS Region  | Normativa       |
|---------|-------------|-----------------|
| España  | eu-south-2  | GDPR (EU)       |
| México  | us-east-1*  | Ley Federal MX  |

*AWS no tiene región en México, usar us-east-1 con etiquetado de datos.

---

## Gestión de Secretos - Solución Recomendada
Usar **External Secrets Operator (ESO)** + **AWS Secrets Manager**:
1. Secretos almacenados en AWS Secrets Manager por región
2. ESO sincroniza los secretos como Kubernetes Secrets nativos
3. Las apps consumen Kubernetes Secrets normalmente
4. Zero secretos en Git

## Estrategia de Latencia < 100ms
- EKS en la misma región que RDS (misma AZ preferiblemente)
- Connection pooling en la app (PgBouncer o similar)
- RDS Proxy para gestión de conexiones
- HPA para escalar pods bajo carga
- Ingress con AWS ALB (menor latencia que NLB para HTTP)

---

## Contacto y Entrega
- Email: platform.cb@pluxeegroup.com
- Plazo: 7 días naturales desde recepción
- Formato: cualquier forma conveniente (zip, repo privado, etc.)
