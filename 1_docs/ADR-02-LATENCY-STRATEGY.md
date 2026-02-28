# ADR-02: Estrategia para Latencia < 100ms

## Estado
Aceptado

## Contexto
El requisito es que las transacciones de pago se procesen con latencia < 100ms de extremo a extremo. Esto incluye el tiempo desde que la request llega al load balancer hasta que se devuelve la response.

## Análisis de la Cadena de Latencia

```
Cliente → ALB → EKS Pod → RDS → EKS Pod → ALB → Cliente
  ~1ms    ~2ms   ~1ms     ~5-15ms  ~1ms    ~2ms   ~1ms
                                                    ≈ 23-28ms (intra-region)
```

### Factores de Latencia Identificados

| Componente | Latencia Estimada | Controlable |
|-----------|------------------|-------------|
| DNS + TLS handshake | 10-50ms (primera request) | Parcialmente |
| ALB routing | 1-3ms | No |
| Pod processing | 1-5ms | Sí |
| DB query | 5-15ms | Sí |
| Network hops | 1-3ms | Parcialmente |

## Decisiones

### 1. Co-localización EKS + RDS (Misma Región y AZ Preferente)
**Decisión:** EKS y RDS en la misma región AWS, con preferencia de AZ.

**Implementación:**
- RDS Multi-AZ con primary en la primera AZ
- Pod affinity para preferir la AZ del RDS primary
- Latencia red intra-AZ: < 1ms vs inter-AZ: 1-3ms

### 2. Connection Pooling con RDS Proxy
**Decisión:** No usar PgBouncer sidecar; usar RDS Proxy gestionado.

**Justificación:**
- RDS Proxy mantiene pool de conexiones persistentes a RDS
- Elimina overhead de establecer conexión TCP+TLS por request (~30-50ms ahorrados)
- Gestionado por AWS, sin pods adicionales que mantener
- Failover transparente en caso de cambio de AZ del primary RDS

**Nota:** La aplicación actual no implementa connection pooling interno. Con RDS Proxy, las conexiones desde la app se reutilizan de forma transparente.

### 3. AWS ALB (No NLB) como Ingress
**Decisión:** Application Load Balancer vía AWS Load Balancer Controller.

**Justificación:**
- ALB opera en L7, más eficiente para HTTP/HTTPS que NLB (L4)
- Terminación TLS en el ALB reduce carga en los pods
- Target type IP (directo a pod, sin kube-proxy hop adicional)
- Health checks HTTP nativos

### 4. Nodos Dedicados para la Aplicación
**Decisión:** Los pods de payment-latency-api corren exclusivamente en nodos del node group `application`, separados de los componentes de sistema.

**Implementación:**
- `nodeSelector: { role: application }` en el Deployment
- Nodos `application` sin taints (default scheduling para pods con el nodeSelector)
- Nodos `system` con taint `dedicated=system:NoSchedule` que excluye workloads de negocio

**Justificación:**
- Evita contención de CPU/memoria entre la app y componentes críticos (CoreDNS, ALB Controller)
- Los nodos de aplicación escalan independientemente según carga de tráfico
- Elimina el riesgo de que un pod de sistema compita por recursos durante picos de transacciones

### 5. HPA para Escalar bajo Carga
**Decisión:** Horizontal Pod Autoscaler basado en CPU y memoria.

**Implementación:**
- Target CPU: 70%
- Target Memory: 80%
- Min replicas: 2-3 (según región)
- Max replicas: 10-15 (según región)

**Justificación:**
- Escalar horizontalmente antes de que los pods se saturen
- Mantener headroom de CPU para absorber picos sin degradar latencia
- CPU al 70% es el umbral donde la latencia empieza a degradarse en Go HTTP servers

### 6. Probes Optimizados
**Decisión:** Readiness probe agresiva, liveness probe conservadora.

**Implementación:**
- Readiness: `/health`, period 5s, failure threshold 3
- Liveness: `/health`, period 10s, failure threshold 3, initial delay 5s

**Justificación:**
- Readiness rápida saca pods no-ready del Service rápidamente (evita requests a pods lentos)
- Liveness conservadora evita reinicios innecesarios durante picos de carga

### 7. Pod Anti-Affinity por Zona
**Decisión:** Distribuir pods entre AZs con preferencia (no requisito).

**Implementación:**
- `preferredDuringSchedulingIgnoredDuringExecution` con weight 100 por `topology.kubernetes.io/zone`

**Justificación:**
- Si una AZ falla, hay pods en otras AZs para servir tráfico
- "Preferred" (no "required") evita que pods queden pending si una AZ está llena

## Métricas de Monitorización

La aplicación expone métricas Prometheus específicas:
- `http_request_duration_seconds` — latencia end-to-end por endpoint
- `payment_processing_duration_seconds` — latencia del procesamiento de pago
- `http_requests_total` — volumen de requests para correlación

### Alertas Recomendadas
```
# P50 > 50ms
histogram_quantile(0.5, rate(payment_processing_duration_seconds_bucket[5m])) > 0.05

# P99 > 100ms
histogram_quantile(0.99, rate(payment_processing_duration_seconds_bucket[5m])) > 0.1
```

## Consecuencias
- RDS Proxy añade un componente adicional (y coste) en la cadena
- La preferencia de AZ no garantiza co-localización (puede haber drift)
- El threshold de 70% CPU en HPA puede causar sobre-provisioning en periodos de baja carga (aceptable por el requisito de latencia)
