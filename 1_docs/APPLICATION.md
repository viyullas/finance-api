# Payment Latency API - Sample Application

## Overview

This is a sample Go application for the technical assessment. Your task is to:
1. ✅ Containerize it with Docker (optimize the Dockerfile)
2. ✅ Package it with Helm (create production-ready chart)
3. ✅ Deploy it with ArgoCD (multi-region deployment)

## Application Features

This API provides:
- **`GET /health`**: Health check with latency metrics and region info
- **`GET /metrics`**: Prometheus metrics endpoint
- **`GET /info`**: Application metadata (version, region, environment)
- **`GET /api/payment/simulate`**: Simulates payment processing with latency

## Configuration

The application requires **4 environment variables**:

### Sensitive Variables (MUST use secrets management):
1. **`DATABASE_URL`**: PostgreSQL connection string
   - Example: `postgres://user:password@rds-endpoint:5432/payments`
   - ⚠️ NEVER commit this to Git
   - ⚠️ MUST use proper secrets management (research available options)

2. **`API_SECRET_KEY`**: Secret key for internal API authentication
   - Example: `sk_prod_abc123def456...` (64 characters)
   - ⚠️ NEVER commit this to Git
   - ⚠️ MUST use proper secrets management (research available options)

### Non-Sensitive Variables (can use ConfigMap):
3. **`REGION`**: AWS region identifier
   - Used for latency metrics and logging

4. **`ENVIRONMENT`**: Deployment environment
   - Used for feature flags and logging level

## Running Locally
```bash
# Set environment variables
export DATABASE_URL="postgres://user:pass@localhost:5432/payments"
export API_SECRET_KEY="your-secret-key-here"
export REGION="eu-west-1"
export ENVIRONMENT="dev"

# Run the application
go run main.go

# Test endpoints
curl http://localhost:8080/health
curl http://localhost:8080/metrics
curl http://localhost:8080/info
curl -H "X-API-Key: $API_SECRET_KEY" http://localhost:8080/api/payment/simulate
```

## Your Tasks

### 1. Create Production-Ready Dockerfile

We've provided `Dockerfile.example` as a starting point, but you should optimize it.

### 2. Create Helm Chart

Create chart: `2_application/helm-charts/payment-latency-api/`

Multi-region values:

### 3. Secrets Management Strategy

You MUST implement a proper secrets management solution:
- Document your choice and rationale in `DECISIONS.md`

### 4. ArgoCD Configuration

Create ArgoCD `Application` manifest:
Bonus: Create `ApplicationSet` for multi-region deployment (Spain + Mexico).

### 5. CI/CD Pipeline Integration

Create and add stages to `.gitlab-ci.yml`
