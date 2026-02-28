# ADR-02: Latency < 100ms Strategy

## Status
Accepted

## Context
The requirement is for payment transactions to be processed with end-to-end latency < 100ms. This covers the time from when the request reaches the load balancer until the response is returned.

## Latency Chain Analysis

```
Client → ALB → EKS Pod → RDS → EKS Pod → ALB → Client
  ~1ms    ~2ms   ~1ms     ~5-15ms  ~1ms    ~2ms   ~1ms
                                                    ≈ 23-28ms (intra-region)
```

### Identified Latency Factors

| Component | Estimated Latency | Controllable |
|-----------|------------------|-------------|
| DNS + TLS handshake | 10-50ms (first request) | Partially |
| ALB routing | 1-3ms | No |
| Pod processing | 1-5ms | Yes |
| DB query | 5-15ms | Yes |
| Network hops | 1-3ms | Partially |

## Decisions

### 1. EKS + RDS Co-location (Same Region)
**Decision:** EKS and RDS in the same AWS region.

**Implementation:**
- RDS Multi-AZ with primary in the first AZ
- Intra-AZ network latency: < 1ms vs inter-AZ: 1-3ms

**Not implemented:** pod affinity to prefer the RDS primary AZ. Discarded because with RDS Multi-AZ the primary can change AZ after a failover, invalidating the affinity. The inter-AZ difference (1-3ms) does not justify the complexity of keeping the affinity in sync with the current primary.

### 2. Connection Pooling with RDS Proxy
**Decision:** Do not use a PgBouncer sidecar; use the managed RDS Proxy.

**Rationale:**
- RDS Proxy maintains a pool of persistent connections to RDS
- Eliminates TCP+TLS connection establishment overhead per request (~30-50ms saved)
- Managed by AWS, no additional pods to maintain
- Transparent failover when the RDS primary changes AZ

**Implemented:** RDS Proxy enabled in both environments (`rds_proxy_enabled = true`). The `db_connection_endpoint` output returns the proxy endpoint, which the app receives via `DATABASE_URL`. Backend RDS connections are transparently reused with no application changes.

### 3. AWS ALB (Not NLB) as Ingress
**Decision:** Application Load Balancer via AWS Load Balancer Controller.

**Rationale:**
- ALB operates at L7, more efficient for HTTP/HTTPS than NLB (L4)
- TLS termination at the ALB reduces pod load
- IP target type (direct to pod, no additional kube-proxy hop)
- Native HTTP health checks

### 4. Dedicated Nodes for the Application
**Decision:** payment-latency-api pods run exclusively on `application` node group nodes, separate from system components.

**Implementation:**
- `nodeSelector: { role: application }` in the Deployment
- `application` nodes without taints (default scheduling for pods with the nodeSelector)
- `system` nodes with taint `dedicated=system:NoSchedule` excluding business workloads

**Rationale:**
- Avoids CPU/memory contention between the app and critical components (CoreDNS, ALB Controller)
- Application nodes scale independently based on traffic load
- Eliminates the risk of a system pod competing for resources during transaction spikes

### 5. HPA to Scale Under Load
**Decision:** Horizontal Pod Autoscaler based on CPU and memory.

**Implementation:**
- CPU target: 70%
- Memory target: 80%
- Min replicas: 2-3 (per region)
- Max replicas: 10-15 (per region)

**Rationale:**
- Scale horizontally before pods become saturated
- Maintain CPU headroom to absorb spikes without degrading latency
- 70% CPU is the threshold where latency starts degrading on Go HTTP servers

### 6. Optimised Probes
**Decision:** Aggressive readiness probe, conservative liveness probe.

**Implementation:**
- Readiness: `/health`, period 5s, failure threshold 3
- Liveness: `/health`, period 10s, failure threshold 3, initial delay 5s

**Rationale:**
- Fast readiness removes not-ready pods from the Service quickly (avoids requests to slow pods)
- Conservative liveness avoids unnecessary restarts during load spikes

### 7. Pod Anti-Affinity by Zone
**Decision:** Distribute pods across AZs with preference (not requirement).

**Implementation:**
- `preferredDuringSchedulingIgnoredDuringExecution` with weight 100 by `topology.kubernetes.io/zone`

**Rationale:**
- If an AZ fails, pods in other AZs continue serving traffic
- "Preferred" (not "required") prevents pods from becoming pending if an AZ is full

## Monitoring Metrics

The application exposes specific Prometheus metrics:
- `http_request_duration_seconds` — end-to-end latency per endpoint
- `payment_processing_duration_seconds` — payment processing latency
- `http_requests_total` — request volume for correlation

### Recommended Alerts
```
# P50 > 50ms
histogram_quantile(0.5, rate(payment_processing_duration_seconds_bucket[5m])) > 0.05

# P99 > 100ms
histogram_quantile(0.99, rate(payment_processing_duration_seconds_bucket[5m])) > 0.1
```

## Consequences
- RDS Proxy adds an additional component (~$15/month on db.t4g.micro) and ~1ms to the chain, but saves ~30-50ms of handshake per request — net positive balance
- No AZ affinity to the RDS primary is implemented: inter-AZ latency (1-3ms) is acceptable and avoids operational complexity during failovers
- The 70% CPU threshold for HPA may cause over-provisioning during low-traffic periods (acceptable given the latency requirement)
- Pod anti-affinity distributes pods across AZs for HA, but may place pods in a different AZ from the RDS primary (+1-3ms); this trade-off is accepted in favour of availability
