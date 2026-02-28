# ADR-01: Decisiones Globales de Arquitectura

## Estado
Aceptado

## Contexto
Pluxee/Cobee necesita una plataforma de pagos multi-regional con operaciones en España y México. La arquitectura debe cumplir con GDPR (UE) y Ley Federal de Protección de Datos (MX), garantizando residencia de datos por región y latencia < 100ms en transacciones.

## Decisiones

### 1. Multi-Región Independiente (No Multi-Cluster Federation)
**Decisión:** Cada región opera un cluster EKS independiente con su propia base de datos RDS.

**Justificación:**
- **Residencia de datos**: GDPR exige que los datos de ciudadanos EU no salgan de la UE. Con clusters independientes, los datos de España permanecen en eu-south-2 y los de México en us-east-1
- **Aislamiento de fallos**: Un problema en una región no afecta a la otra
- **Simplicidad operativa**: Federation añade complejidad sin beneficio real cuando no hay necesidad de compartir datos entre regiones

**Alternativas descartadas:**
- Multi-cluster federation (Kubernetes): complejidad excesiva, riesgo de fuga de datos entre regiones
- Región única con sharding lógico: no cumple GDPR por residencia física de datos

### 2. EKS Managed con Node Groups Separados (System + Application)
**Decisión:** Usar EKS managed con dos node groups diferenciados: `system` y `application`.

**Justificación:**
- Control plane gestionado por AWS reduce carga operativa
- Soporte nativo para IRSA (IAM Roles for Service Accounts)
- Fargate descartado como compute principal por limitaciones con DaemonSets (monitoring agents)

**Separación de node groups:**
- **System** (`t3.medium`, tamaño fijo ~2 nodos): ejecuta componentes de cluster (CoreDNS, ALB Controller, ESO, EBS CSI). Taint `dedicated=system:NoSchedule` impide que pods de aplicación se programen aquí
- **Application** (`t3.medium`, autoscaling): ejecuta workloads de negocio (payment-latency-api). Sin taints, con label `role=application` y nodeSelector en los pods

**Beneficios del aislamiento:**
- Un spike de tráfico en la aplicación no compite por recursos con componentes críticos del cluster
- Los nodos de sistema tienen tamaño fijo y predecible, los de aplicación escalan según demanda
- Permite ajustar instance types independientemente (compute-optimized para apps, general-purpose para sistema)

### 3. PostgreSQL en RDS (No Aurora)
**Decisión:** RDS PostgreSQL Multi-AZ en lugar de Aurora.

**Justificación:**
- Menor coste para el volumen de transacciones esperado
- Multi-AZ cubre la necesidad de alta disponibilidad
- Failover automático en < 60 segundos
- Aurora sería justificable si el volumen de escrituras crece significativamente

### 4. GitOps con ArgoCD
**Decisión:** ArgoCD como motor de despliegue GitOps.

**Justificación:**
- Reconciliación continua: detecta y corrige drift automáticamente
- Auditabilidad: cada cambio tiene un commit asociado en Git
- Multi-cluster nativo: soporta desplegar a múltiples clusters desde una instancia
- ApplicationSet para gestionar ambas regiones con un solo manifiesto

### 5. Helm como Herramienta de Templating
**Decisión:** Helm charts con values por región.

**Justificación:**
- Un solo chart, múltiples configuraciones (values-spain.yaml, values-mexico.yaml)
- Ecosistema maduro con amplia adopción
- Integración nativa con ArgoCD
- Kustomize descartado por menor flexibilidad en parametrización compleja

### 6. Módulos Terraform Públicos
**Decisión:** Usar módulos oficiales de la comunidad AWS para VPC, EKS y RDS.

**Justificación:**
- Ampliamente probados y mantenidos por HashiCorp y la comunidad
- Cubren best practices de AWS por defecto
- Reducen código custom y tiempo de desarrollo
- Fuentes documentadas en cada módulo

### 7. Escalado de Nodos — Karpenter (No implementado)
**Decisión:** Se ha valorado Karpenter como solución de autoscaling de nodos, pero queda fuera del alcance actual. Los ASGs de los node groups tienen rangos definidos (min/max) pero no hay un controlador activo que los escale automáticamente.

**Por qué Karpenter sobre Cluster Autoscaler nativo:**
- Cluster Autoscaler opera sobre ASGs predefinidos: solo puede escalar dentro de los instance types y configuraciones que ya existen en el node group. Si necesitas un tipo de instancia diferente, hay que modificar Terraform
- Karpenter provisiona nodos directamente vía la API de EC2, sin depender de ASGs. Selecciona el instance type óptimo en tiempo real según los recursos que piden los pods pendientes (right-sizing)
- Karpenter es más rápido en el scheduling (~30s vs ~2min del Cluster Autoscaler) porque no espera ciclos de reconciliación del ASG
- Consolidación automática: Karpenter detecta nodos infrautilizados, mueve pods y termina nodos sobrantes. Cluster Autoscaler es más conservador en scale-down
- Karpenter es el reemplazo recomendado por AWS para Cluster Autoscaler en EKS

**Cómo se implementaría:**
- Desplegar Karpenter via Helm en los nodos `system` (con toleration al taint `dedicated=system`)
- Crear un `NodePool` para workloads de aplicación con constraints: instance families (`m6i`, `m6a`, `c6i`), capacity type `on-demand`, y límite de CPU/memoria total
- Crear un `EC2NodeClass` con la AMI de EKS, subnets privadas y security groups del cluster
- El node group `application` de Terraform pasaría a ser el bootstrap mínimo (o se eliminaría), y Karpenter gestionaría el escalado real
- El node group `system` seguiría gestionado por el ASG con tamaño fijo, ya que sus workloads son predecibles

**Estado actual:** Los node groups tienen tags de autodiscovery (`k8s.io/cluster-autoscaler`) y rangos min/max configurados, lo que permite añadir Karpenter o Cluster Autoscaler en el futuro sin cambios en Terraform.

### 8. Credenciales de BD Gestionadas por RDS + Composición con ESO
**Decisión:** Usar `manage_master_user_password = true` en RDS para que AWS gestione y rote automáticamente el password del master user. El `DATABASE_URL` se compone en el ExternalSecret usando el template de ESO, combinando las credenciales del secret de RDS con el endpoint inyectado via ArgoCD.

**Justificación:**
- Elimina la duplicación del password entre el secret de RDS y un secret manual de la aplicación
- La rotación automática de credenciales funciona de forma transparente — ESO sincroniza el nuevo password en cada `refreshInterval`
- Reduce los pasos manuales de despliegue: ya no hay que copiar credenciales de RDS a otro secret
- El único secret que requiere población manual es `API_SECRET_KEY`

**Alternativa descartada:**
- Secret manual con `DATABASE_URL` completo: requiere copiar el password de RDS manualmente, se rompe tras cada rotación, y duplica información sensible en dos secrets diferentes

### 9. NAT Gateway — Single vs One-per-AZ (Configurable)
**Decisión:** Por defecto se usa un único NAT Gateway (`single_nat_gateway = true`). La variable permite cambiar a uno por AZ para producción con alta disponibilidad.

**Coste:**
- 1 NAT Gateway: ~$1.08/día ($32.40/mes) — precio fijo $0.045/h + transferencia
- 3 NAT Gateways (uno por AZ): ~$3.24/día ($97.20/mes)

**Tradeoff:**
- **Single NAT Gateway**: ahorra ~$65/mes por región. Si la AZ donde está el NAT se cae, las subnets privadas de las otras AZs pierden acceso a internet (no afecta tráfico interno ni al endpoint de EKS). Aceptable para desarrollo, testing y cargas de trabajo que toleren minutos de indisponibilidad de salida
- **One-per-AZ**: cada subnet privada sale por su propio NAT. Elimina la dependencia cross-AZ. Recomendado para producción con SLA estricto

**Para cambiar a uno por AZ:**
```hcl
single_nat_gateway = false
```

### 10. Acceso al Control Plane de EKS — Endpoint Público con Restricción de IP
**Decisión:** El API server de EKS tiene acceso público y privado habilitados, con restricción de CIDRs configurable via variable `cluster_endpoint_public_access_cidrs`.

**Justificación:**
- El endpoint público es necesario para operar el cluster desde fuera de la VPC (desarrollo, CI/CD, administración)
- El endpoint privado permite que los nodos y pods se comuniquen con el control plane sin salir de la VPC
- La restricción de CIDRs limita qué IPs pueden alcanzar el endpoint público (reduce superficie de ataque)
- La autenticación IAM/RBAC sigue siendo obligatoria — la restricción de IP es una capa adicional

**Default:** `0.0.0.0/0` (abierto). Para restringir:
```hcl
cluster_endpoint_public_access_cidrs = ["OFICINA_IP/32", "VPN_IP/32"]
```

**Para producción estricta** (solo acceso vía VPN/bastion):
```hcl
cluster_endpoint_public_access = false  # Requiere cambio en el módulo EKS
```

### 11. Infraestructura como Código Segregada por Entorno
**Decisión:** Un directorio de Terraform por región/entorno con state independiente.

**Justificación:**
- States separados evitan que un error en una región corrompa la otra
- Permite aplicar cambios en una región sin afectar la otra
- Facilita el rollback por región

## Consecuencias
- Duplicación parcial de código Terraform entre environments (mitigado con módulos compartidos)
- Necesidad de mantener paridad entre regiones manualmente o con CI/CD
- Mayor coste operativo por tener infraestructura duplicada (aceptable por compliance)
