# Payment Latency API - Infraestructura Multi-Regional

## Resumen

Infraestructura cloud-native en AWS para la plataforma de pagos de Pluxee/Cobee, con operaciones en **España** (eu-south-2) y **México** (us-east-1). La arquitectura segmenta datos sensibles por región cumpliendo GDPR y normativa local mexicana, con latencia objetivo < 100ms en transacciones financieras.

## Arquitectura

```
                    ┌─────────────────────────────────────────┐
                    │              Git Repository              │
                    │  (Helm Charts, Terraform, ArgoCD specs) │
                    └──────────┬──────────────┬───────────────┘
                               │              │
                    ┌──────────▼──────────────┐
                    │  ArgoCD (Spain)         │
                    │  gestiona ambas regiones│
                    └──────┬──────────┬───────┘
                           │          │
          ─ ─ ─ ─ ─ ─ ─ ─ ┼ ─ ─ ─ ─     ─ ─ ─┼ ─ ─ ─ ─ ─ ─
         │  eu-south-2     │        │   │  us-east-1    │
              (GDPR)       │              (Ley MX)
         │                 │        │   │               │
          ┌────────────────▼──────┐   ┌─▼──────────────────┐
         ││  EKS Cluster         ││ ││  EKS Cluster        ││
          │  ┌─────────────────┐ │   │  ┌─────────────────┐│
         ││  │ payment-api pods│ ││ ││  │ payment-api pods│ ││
          │  └────────┬────────┘ │   │  └────────┬────────┘│
         ││           │          ││ ││           │         ││
          │  ┌────────▼────────┐ │   │  ┌────────▼────────┐│
         ││  │ RDS PostgreSQL  │ ││ ││  │ RDS PostgreSQL  │ ││
          │  │ (Multi-AZ)      │ │   │  │ (Multi-AZ)      ││
         ││  └─────────────────┘ ││ ││  └─────────────────┘ ││
          └──────────────────────┘   └──────────────────────┘
         │                       │   │                      │
          ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─      ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
```

## Estructura del Proyecto

```
.
├── Dockerfile                          # Optimizado: scratch, <20MB, non-root
├── 1_docs/
│   ├── README.md                       # Este archivo
│   ├── ADR-01-DECISIONS.md             # Decisiones de arquitectura
│   ├── ADR-02-LATENCY-STRATEGY.md      # Estrategia para <100ms
│   ├── ADR-03-SECRET-MANAGEMENT.md     # Gestión de secretos con ESO
│   ├── SECURITY-CHECKLIST.md           # Checklist de seguridad
│   └── DEPLOYMENT-RUNBOOK.md           # Procedimiento de despliegue completo
├── 2_application/
│   └── helm-charts/
│       └── payment-latency-api/        # Helm Chart completo
│           ├── Chart.yaml
│           ├── values.yaml             # Valores base
│           ├── values-spain.yaml       # Override para España
│           ├── values-mexico.yaml      # Override para México
│           └── templates/
│               ├── _helpers.tpl
│               ├── deployment.yaml
│               ├── service.yaml
│               ├── ingress.yaml
│               ├── configmap.yaml
│               ├── hpa.yaml
│               ├── pdb.yaml
│               ├── serviceaccount.yaml
│               ├── servicemonitor.yaml
│               └── externalsecret.yaml
├── 3_gitops/
│   └── argocd/
│       ├── install/
│       │   └── values-argocd.yaml      # Values para instalar ArgoCD en Spain
│       ├── application-spain.yaml      # ArgoCD App para España
│       ├── application-mexico.yaml     # ArgoCD App para México
│       └── applicationset.yaml         # Multi-región en un manifiesto
└── 4_infrastructure/
    └── terraform/
        ├── modules/
        │   ├── vpc/                    # VPC multi-AZ con subnets aisladas
        │   ├── eks/                    # EKS + IRSA (ESO, LB Controller)
        │   └── rds/                    # PostgreSQL Multi-AZ cifrado
        └── environments/
            ├── spain/                  # eu-south-2 (GDPR)
            └── mexico/                 # us-east-1 (Ley Federal MX)
```

## Decisiones Clave

| Decisión | Elección | Justificación |
|----------|----------|---------------|
| Compute | EKS Managed | Control plane gestionado, IRSA nativo |
| Node Groups | System + Application | Aislamiento de workloads, taints para sistema |
| Base de datos | RDS PostgreSQL Multi-AZ | HA con failover < 60s, cifrado KMS |
| Secretos | ESO + AWS Secrets Manager | Zero secrets en Git, IRSA auth |
| GitOps | ArgoCD + ApplicationSet | Multi-cluster nativo, reconciliación continua |
| Templating | Helm | Un chart, múltiples values por región |
| IaC | Terraform + módulos públicos | Probados, mantenidos, best practices |
| Container | scratch image | < 20MB, 0 paquetes, non-root |

## Regiones

| Región | AWS Region | Normativa | CIDR VPC |
|--------|-----------|-----------|----------|
| España | eu-south-2 | GDPR (UE) | 10.10.0.0/16 |
| México | us-east-1 | Ley Federal MX | 10.20.0.0/16 |

## Seguridad

- **Cifrado**: KMS en reposo (RDS, EBS, S3, K8s secrets) + TLS 1.2+ en tránsito
- **IAM**: Least privilege con IRSA, sin credenciales estáticas
- **Red**: Pods en private subnets, RDS en database subnets aisladas
- **Auditoría**: CloudTrail + VPC Flow Logs en ambas regiones
- **Container**: scratch, non-root, read-only fs, capabilities dropped

Ver [SECURITY-CHECKLIST.md](./SECURITY-CHECKLIST.md) para el checklist completo.

## Latencia < 100ms

Estrategia detallada en [ADR-02-LATENCY-STRATEGY.md](./ADR-02-LATENCY-STRATEGY.md):
- Co-localización EKS + RDS en misma región/AZ
- Connection pooling via RDS Proxy
- ALB con target type IP (sin kube-proxy hop)
- Nodos dedicados `application` para pods de negocio (sin contención con componentes de sistema)
- HPA con threshold de CPU al 70%
- Pod anti-affinity por zona para distribución

## Despliegue

El despliegue completo tiene 6 fases: infraestructura (Terraform), configuración de kubeconfig, instalación de addons (ALB Controller, ESO), secretos, ArgoCD y verificación.

Ver **[DEPLOYMENT-RUNBOOK.md](./DEPLOYMENT-RUNBOOK.md)** para el procedimiento detallado paso a paso.

## Módulos Terraform Utilizados

| Módulo | Fuente | Versión |
|--------|--------|---------|
| VPC | [terraform-aws-modules/vpc/aws](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws) | ~> 5.0 |
| EKS | [terraform-aws-modules/eks/aws](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws) | ~> 20.0 |
| RDS | [terraform-aws-modules/rds/aws](https://registry.terraform.io/modules/terraform-aws-modules/rds/aws) | ~> 6.0 |
| IAM (IRSA) | [terraform-aws-modules/iam/aws](https://registry.terraform.io/modules/terraform-aws-modules/iam/aws) | ~> 5.0 |
