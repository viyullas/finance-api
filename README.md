# Payment Latency API - Multi-Regional Platform

Infraestructura cloud-native en AWS para una plataforma fintech de pagos con operaciones en **Spain** (`eu-south-2`, GDPR) y **Mexico** (`us-east-1`, Ley Federal MX). Arquitectura que segmenta datos sensibles por region con latencia objetivo < 100ms.

## Quick Start

### Prerequisitos

| Herramienta | Version minima | Para que |
|-------------|---------------|----------|
| AWS CLI | 2.x | Credenciales configuradas para ambas regiones |
| `terraform` | >= 1.10 | Infraestructura (VPC, EKS, RDS, etc.) |
| `helm` | >= 3.x | Instalar componentes en Kubernetes |
| `kubectl` | >= 1.28 | Gestionar clusters |
| `argocd` | >= 2.x | Registrar cluster Mexico en ArgoCD |
| `make` | GNU Make | Orquestacion de todo el proceso |
| `docker` | >= 20.x | Build y push de la imagen |
| `openssl` | cualquiera | Generar secretos aleatorios |

Ademas, antes del primer `make up`:
- **Bucket S3** para Terraform state (ver [Deployment Runbook](1_docs/DEPLOYMENT-RUNBOOK.md#bucket-s3-para-terraform-state))
  - Cambiar nombre en `4_infrastructure/terraform/environments/{spain,mexico}/main.tf` → bloque `backend "s3"` (actual: `aabella-terraform-backends`)
- **Hosted zone** en Route53 para certificados ACM
  - Cambiar en `4_infrastructure/terraform/environments/{spain,mexico}/variables.tf` → variables `hosted_zone_name` y `app_domain` (actual: `aws.lacloaca.com`)

### Uso

```bash
make up      # Despliega todo: terraform, docker, helm, secrets, argocd, apps
make status  # Estado de ambos clusters
make down    # Destruye todo (idempotente, safe to re-run)
make help    # Todos los targets disponibles
```

## Arquitectura

```
                     ┌──────────────────────────────────────┐
                     │           Git Repository              │
                     │  Helm Charts · Terraform · ArgoCD     │
                     └──────────┬──────────────┬────────────┘
                                │              │
                     ┌──────────▼──────────────┐
                     │     ArgoCD (Spain)       │
                     │  gestiona ambas regiones │
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

Los datos de cada region son completamente independientes: VPCs separadas, secrets separados, sin peering ni replicacion cross-region.

## Aplicacion

API Go (`payment-latency-api`) que simula procesamiento de pagos:

| Endpoint | Descripcion |
|----------|-------------|
| `GET /health` | Health check con metricas de latencia |
| `GET /metrics` | Metricas Prometheus |
| `GET /info` | Metadata (version, region, environment) |
| `GET /api/payment/simulate` | Simula procesamiento de pago |

**Variables de entorno:**
- `DATABASE_URL`, `API_SECRET_KEY` — gestionados por External Secrets Operator (zero secrets en Git)
- `REGION`, `ENVIRONMENT` — via ConfigMap

Ver [1_docs/APPLICATION.md](1_docs/APPLICATION.md) para detalles de la app (ejecucion local, test de endpoints).

## Estructura del Proyecto

```
.
├── Dockerfile                          # Multi-stage, scratch, <20MB, non-root (UID 65534)
├── Makefile                            # make up / make down / make status + targets individuales
├── 1_docs/
│   ├── APPLICATION.md                  # Documentacion de la aplicacion Go
│   ├── ADR-01-DECISIONS.md             # Decisiones de arquitectura (11 decisiones)
│   ├── ADR-02-LATENCY-STRATEGY.md      # Estrategia para <100ms (7 tacticas)
│   ├── ADR-03-SECRET-MANAGEMENT.md     # Gestion de secretos con ESO + Secrets Manager
│   ├── SECURITY-CHECKLIST.md           # Checklist de seguridad (52 items)
│   └── DEPLOYMENT-RUNBOOK.md           # Procedimiento manual paso a paso
├── 2_application/
│   └── helm-charts/
│       └── payment-latency-api/        # Helm Chart completo
│           ├── values.yaml             # Valores base
│           ├── values-spain.yaml       # Override España
│           ├── values-mexico.yaml      # Override México
│           └── templates/              # Deployment, Service, Ingress, ConfigMap,
│                                       # HPA, PDB, ServiceMonitor, ExternalSecret
├── 3_gitops/
│   └── argocd/
│       ├── application-spain.yaml      # ArgoCD Application para España
│       ├── application-mexico.yaml     # ArgoCD Application para México
│       └── applicationset.yaml         # Bonus: ambas regiones en un manifiesto
└── 4_infrastructure/
    └── terraform/
        ├── modules/
        │   ├── vpc/                    # VPC multi-AZ, 3 tiers de subnets
        │   ├── eks/                    # EKS + IRSA (ESO, ALB Controller, EBS CSI)
        │   └── rds/                    # PostgreSQL Multi-AZ + RDS Proxy
        └── environments/
            ├── spain/                  # eu-south-2 (GDPR)
            └── mexico/                 # us-east-1 (Ley Federal MX)
```

## Decisiones Clave

| Area | Eleccion | Justificacion |
|------|----------|---------------|
| Compute | EKS Managed | Control plane gestionado, IRSA nativo, addons managed |
| Node Groups | System + Application | Aislamiento con taints, escalado independiente |
| Base de datos | RDS PostgreSQL Multi-AZ | HA con failover < 60s, password auto-rotado |
| Connection pooling | RDS Proxy | Pool gestionado, -30/50ms handshake por request |
| Secretos | ESO + Secrets Manager | Zero secrets en Git, IRSA auth, refresh 1h |
| GitOps | ArgoCD + ApplicationSet | Multi-cluster desde Spain, auto-sync + self-heal |
| Templating | Helm | Un chart, N values por region |
| IaC | Terraform + modulos publicos | VPC ~5.0, EKS ~20.0, RDS ~6.0, IAM ~5.0 |
| Container | scratch image | ~8MB, 0 CVEs, non-root, read-only fs |

Detalle completo en [1_docs/ADR-01-DECISIONS.md](1_docs/ADR-01-DECISIONS.md).

## Regiones

| Region | AWS Region | Normativa | VPC CIDR |
|--------|-----------|-----------|----------|
| Spain | eu-south-2 | GDPR (UE) | 10.10.0.0/16 |
| Mexico | us-east-1* | Ley Federal MX | 10.20.0.0/16 |

*AWS no tiene region en Mexico; us-east-1 con etiquetado `DataResidency: MX`.

## Seguridad

- **Cifrado en reposo**: KMS por region (RDS, EBS, S3, K8s secrets envelope encryption)
- **Cifrado en transito**: TLS 1.2+ (ALB con certificado ACM, `sslmode=require` en PostgreSQL)
- **IAM**: Least privilege con IRSA por componente, sin credenciales estaticas
- **Red**: Pods en private subnets, RDS en database subnets aisladas (sin internet)
- **Auditoria**: CloudTrail + VPC Flow Logs en ambas regiones
- **Container**: scratch, non-root (UID 65534), read-only fs, capabilities dropped, seccomp RuntimeDefault

Checklist completo (52 items): [1_docs/SECURITY-CHECKLIST.md](1_docs/SECURITY-CHECKLIST.md).

## Latencia < 100ms

Latencia estimada intra-region: **~23-28ms** (margen amplio hasta el objetivo de 100ms).

| Tactica | Ahorro estimado |
|---------|-----------------|
| EKS + RDS en misma region | Evita cross-region (~50-100ms) |
| RDS Proxy (connection pooling) | -30/50ms handshake TCP+TLS |
| ALB con target type IP | -1/2ms (sin kube-proxy hop) |
| Nodos dedicados application | Elimina contencion con sistema |
| HPA al 70% CPU | Escala antes de saturacion |
| Pod anti-affinity por zona | HA sin sacrificar latencia significativa |

Estrategia detallada: [1_docs/ADR-02-LATENCY-STRATEGY.md](1_docs/ADR-02-LATENCY-STRATEGY.md).

## Despliegue

`make up` ejecuta 7 fases secuenciales:

1. **Terraform** — VPC, EKS, RDS, KMS, CloudTrail, ECR, Secrets Manager (Spain + Mexico)
2. **Kubeconfig** — Registra ambos clusters con alias `spain` / `mexico`
3. **Docker** — Build de la imagen y push a ECR de ambas regiones
4. **Helm deps** — Instala ALB Controller + External Secrets Operator en ambos clusters
5. **Secrets** — Genera `API_SECRET_KEY` aleatorio y lo almacena en Secrets Manager
6. **ArgoCD** — Instala en Spain, registra Mexico como cluster remoto
7. **Apps** — Aplica las ArgoCD Applications (Spain in-cluster, Mexico remoto)

`make down` es idempotente: detecta si los clusters existen antes de intentar operaciones K8s, y reintenta terraform destroy si falla por race conditions de AWS.

Procedimiento manual detallado: [1_docs/DEPLOYMENT-RUNBOOK.md](1_docs/DEPLOYMENT-RUNBOOK.md).

## Documentacion

| Documento | Contenido |
|-----------|-----------|
| [ADR-01: Decisiones](1_docs/ADR-01-DECISIONS.md) | 11 decisiones de arquitectura con justificacion |
| [ADR-02: Latencia](1_docs/ADR-02-LATENCY-STRATEGY.md) | Estrategia para < 100ms, analisis de cadena |
| [ADR-03: Secretos](1_docs/ADR-03-SECRET-MANAGEMENT.md) | ESO + Secrets Manager, flujo IRSA, rotacion |
| [Security Checklist](1_docs/SECURITY-CHECKLIST.md) | 52 items verificados: container, red, IAM, cifrado |
| [Deployment Runbook](1_docs/DEPLOYMENT-RUNBOOK.md) | Procedimiento manual de 6 fases |
| [Aplicacion](1_docs/APPLICATION.md) | Endpoints, variables, ejecucion local |
