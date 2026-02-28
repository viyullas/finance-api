# Security Checklist - Payment Latency API

## Container Security

- [x] **Imagen base mínima**: `scratch` (0 paquetes, 0 CVEs potenciales)
- [x] **Multi-stage build**: Binario compilado en builder, solo binario copiado a producción
- [x] **Non-root**: Container ejecuta como UID 65534 (nobody)
- [x] **Imagen < 20MB**: Binario estático Go ~8MB + certificados CA
- [x] **Sin secretos en imagen**: Variables de entorno inyectadas en runtime
- [x] **Read-only filesystem**: `readOnlyRootFilesystem: true` en securityContext
- [x] **Sin privilege escalation**: `allowPrivilegeEscalation: false`
- [x] **Capabilities dropped**: `drop: ALL`
- [x] **Seccomp profile**: `RuntimeDefault`

## Secrets Management

- [x] **Zero secrets en Git**: Ningún secreto en código, Dockerfile, values.yaml ni manifiestos
- [x] **External Secrets Operator**: Secretos sincronizados desde AWS Secrets Manager
- [x] **IRSA authentication**: ESO se autentica con IAM role, sin credenciales estáticas
- [x] **Secretos por región**: España en eu-south-2, México en us-east-1
- [x] **Rotación soportada**: refreshInterval configurable en ExternalSecret
- [x] **Cifrado en Secrets Manager**: Secrets cifrados con KMS key dedicada

## Network Security

- [x] **TLS en tránsito**: ALB termina TLS 1.2+, Ingress fuerza HTTPS redirect
- [x] **Subnets privadas**: Pods EKS en private subnets, sin IP pública
- [x] **Database aislada**: RDS en database subnets sin acceso a internet
- [x] **Security groups restrictivos**: RDS solo acepta tráfico desde EKS nodes
- [x] **VPC Flow Logs**: Habilitados para auditoría de tráfico
- [x] **EKS endpoint restringible**: `cluster_endpoint_public_access_cidrs` configurable (default abierto, restringir en producción)

## Encryption

- [x] **En reposo - RDS**: `storage_encrypted = true` con KMS
- [x] **En reposo - EBS**: Cifrado con KMS para volúmenes de nodos EKS
- [x] **En reposo - K8s secrets**: Envelope encryption con KMS en EKS
- [x] **En reposo - S3**: Buckets de CloudTrail cifrados con KMS
- [x] **En tránsito**: TLS forzado en ALB, RDS con `ssl = 1`
- [x] **KMS key rotation**: `enable_key_rotation = true`

## Identity & Access Management

- [x] **Least privilege**: Roles IAM con permisos mínimos por servicio
- [x] **IRSA**: Cada componente K8s con su propio IAM role (ESO, LB Controller, EBS CSI)
- [x] **No credenciales estáticas**: Todo basado en roles asumidos
- [x] **Service accounts dedicados**: Un service account por aplicación

## Data Residency & Compliance

- [x] **GDPR (España)**: Datos EU en eu-south-2, tags `DataResidency=EU`, `Compliance=GDPR`
- [x] **Ley Federal MX (México)**: Datos MX en us-east-1, tags `DataResidency=MX`, `Compliance=LeyFederalMX`
- [x] **Sin replicación cross-region**: Datos y secretos no se replican entre regiones
- [x] **Etiquetado de recursos**: Todos los recursos AWS etiquetados con región y compliance

## Auditing & Monitoring

- [x] **CloudTrail**: Habilitado en ambas regiones con log file validation
- [x] **CloudTrail cifrado**: Logs en S3 cifrados con KMS
- [x] **VPC Flow Logs**: Almacenados en CloudWatch con IAM role dedicado
- [x] **Prometheus metrics**: ServiceMonitor para scraping de métricas de la app
- [x] **Application logging**: Logs estructurados, connection strings enmascarados

## Kubernetes Security

- [x] **Pod Security Context**: `runAsNonRoot`, `runAsUser`, `fsGroup`
- [x] **Container Security Context**: capabilities dropped, no escalation, read-only fs
- [x] **Resource limits**: CPU y memoria definidos para prevenir noisy neighbors
- [x] **Probes configurados**: Liveness y readiness para health checking
- [x] **HPA**: Auto-scaling para absorber picos sin degradar seguridad
- [x] **PodDisruptionBudget**: `minAvailable: 1` protege disponibilidad durante disrupciones voluntarias
- [x] **Rolling update strategy**: `maxUnavailable: 0` garantiza zero downtime en deploys

## Supply Chain

- [x] **Módulos Terraform documentados**: Fuente y versión de cada módulo público
- [x] **go.sum**: Checksums de dependencias Go verificados
- [x] **Imágenes base con tags fijos**: `golang:1.21-alpine` (no latest)
