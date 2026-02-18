package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Configuration from environment variables
type Config struct {
	DatabaseURL  string // SENSITIVE - Never log this
	APISecretKey string // SENSITIVE - Never log this
	Region       string // Non-sensitive
	Environment  string // Non-sensitive
	Port         string
}

// Application metadata
type AppInfo struct {
	Name        string    `json:"name"`
	Version     string    `json:"version"`
	Region      string    `json:"region"`
	Environment string    `json:"environment"`
	Timestamp   time.Time `json:"timestamp"`
}

// Health check response
type HealthResponse struct {
	Status      string        `json:"status"`
	Region      string        `json:"region"`
	Latency     string        `json:"latency_ms"`
	Database    string        `json:"database"`
	Timestamp   time.Time     `json:"timestamp"`
	Environment string        `json:"environment"`
	Uptime      time.Duration `json:"uptime_seconds"`
}

// Payment simulation response
type PaymentResponse struct {
	TransactionID  string    `json:"transaction_id"`
	Status         string    `json:"status"`
	ProcessingTime string    `json:"processing_time_ms"`
	Region         string    `json:"region"`
	Timestamp      time.Time `json:"timestamp"`
}

var (
	config    Config
	startTime time.Time

	// Prometheus metrics
	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests",
		},
		[]string{"method", "endpoint", "status"},
	)

	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency in seconds",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"method", "endpoint"},
	)

	paymentProcessingDuration = prometheus.NewHistogram(
		prometheus.HistogramOpts{
			Name:    "payment_processing_duration_seconds",
			Help:    "Payment processing latency in seconds",
			Buckets: []float64{0.1, 0.2, 0.3, 0.5, 1.0, 2.0, 5.0},
		},
	)
)

func init() {
	// Register Prometheus metrics
	prometheus.MustRegister(httpRequestsTotal)
	prometheus.MustRegister(httpRequestDuration)
	prometheus.MustRegister(paymentProcessingDuration)
}

func main() {
	startTime = time.Now()

	// Load configuration from environment variables
	config = loadConfig()

	// Validate configuration (don't log sensitive values!)
	if config.DatabaseURL == "" {
		log.Fatal("❌ DATABASE_URL environment variable is required")
	}
	if config.APISecretKey == "" {
		log.Fatal("❌ API_SECRET_KEY environment variable is required")
	}
	if config.Region == "" {
		log.Println("⚠️  REGION not set, defaulting to 'unknown'")
		config.Region = "unknown"
	}
	if config.Environment == "" {
		log.Println("⚠️  ENVIRONMENT not set, defaulting to 'dev'")
		config.Environment = "dev"
	}

	// Log startup (safe values only)
	log.Printf("🚀 Starting Payment Latency API")
	log.Printf("   Region: %s", config.Region)
	log.Printf("   Environment: %s", config.Environment)
	log.Printf("   Port: %s", config.Port)
	log.Printf("   Database: %s", maskConnectionString(config.DatabaseURL))

	// Setup HTTP routes
	http.HandleFunc("/health", metricsMiddleware(healthHandler))
	http.HandleFunc("/info", metricsMiddleware(infoHandler))
	http.HandleFunc("/api/payment/simulate", metricsMiddleware(authMiddleware(paymentHandler)))
	http.Handle("/metrics", promhttp.Handler()) // Prometheus metrics

	// Start server
	addr := fmt.Sprintf(":%s", config.Port)
	log.Printf("✅ Server listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}

// loadConfig loads configuration from environment variables
func loadConfig() Config {
	return Config{
		DatabaseURL:  os.Getenv("DATABASE_URL"),
		APISecretKey: os.Getenv("API_SECRET_KEY"),
		Region:       os.Getenv("REGION"),
		Environment:  os.Getenv("ENVIRONMENT"),
		Port:         getEnvOrDefault("PORT", "8080"),
	}
}

// healthHandler returns health status with latency metrics
func healthHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	// Simulate database health check (in real app, would ping database)
	dbStatus := "connected"
	if config.DatabaseURL == "" {
		dbStatus = "not_configured"
	}

	response := HealthResponse{
		Status:      "healthy",
		Region:      config.Region,
		Latency:     fmt.Sprintf("%.2f", float64(time.Since(start).Microseconds())/1000),
		Database:    dbStatus,
		Timestamp:   time.Now(),
		Environment: config.Environment,
		Uptime:      time.Since(startTime).Round(time.Second),
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// infoHandler returns application metadata
func infoHandler(w http.ResponseWriter, r *http.Request) {
	info := AppInfo{
		Name:        "payment-latency-api",
		Version:     "1.0.0",
		Region:      config.Region,
		Environment: config.Environment,
		Timestamp:   time.Now(),
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(info)
}

// paymentHandler simulates payment processing with latency
func paymentHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	// Simulate payment processing time (varies by region)
	var processingTime time.Duration
	switch config.Region {
	case "eu-west-1", "eu-south-2":
		processingTime = time.Duration(50+time.Now().UnixNano()%50) * time.Millisecond
	case "us-east-1", "us-east-2":
		processingTime = time.Duration(100+time.Now().UnixNano()%100) * time.Millisecond
	case "sa-east-1":
		processingTime = time.Duration(80+time.Now().UnixNano()%80) * time.Millisecond
	default:
		processingTime = 100 * time.Millisecond
	}

	time.Sleep(processingTime)

	// Record metrics
	paymentProcessingDuration.Observe(processingTime.Seconds())

	response := PaymentResponse{
		TransactionID:  fmt.Sprintf("txn_%d", time.Now().UnixNano()),
		Status:         "approved",
		ProcessingTime: fmt.Sprintf("%.2f", float64(processingTime.Microseconds())/1000),
		Region:         config.Region,
		Timestamp:      time.Now(),
	}

	elapsed := time.Since(start)
	log.Printf("✅ Payment processed in %s (region: %s)", elapsed, config.Region)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// authMiddleware validates API key from header
func authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		apiKey := r.Header.Get("X-API-Key")

		if apiKey == "" {
			http.Error(w, `{"error": "Missing X-API-Key header"}`, http.StatusUnauthorized)
			return
		}

		if apiKey != config.APISecretKey {
			http.Error(w, `{"error": "Invalid API key"}`, http.StatusForbidden)
			return
		}

		next(w, r)
	}
}

// metricsMiddleware records metrics for all requests
func metricsMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		// Create a response writer wrapper to capture status code
		wrapped := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}

		next(wrapped, r)

		duration := time.Since(start).Seconds()
		statusCode := fmt.Sprintf("%d", wrapped.statusCode)

		httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, statusCode).Inc()
		httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)
	}
}

// responseWriter wraps http.ResponseWriter to capture status code
type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}

// Helper functions

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func maskConnectionString(connStr string) string {
	if len(connStr) < 20 {
		return "***MASKED***"
	}
	return connStr[:15] + "...***MASKED***"
}
