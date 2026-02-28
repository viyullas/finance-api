# Build stage
FROM golang:1.21-alpine AS builder

WORKDIR /app

# Cache dependencies
COPY go.mod go.sum ./
RUN go mod download

# Build static binary
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-s -w" \
    -o payment-api main.go

# Final stage - scratch for minimal image
FROM scratch

# Import CA certificates for HTTPS calls
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Non-root user (nobody)
COPY --from=builder /etc/passwd /etc/passwd
USER 65534

WORKDIR /app

COPY --from=builder /app/payment-api .

EXPOSE 8080

ENTRYPOINT ["/app/payment-api"]
