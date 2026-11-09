// Command deploy-strategies-demo adalah aplikasi demo untuk sharing session
// "Deploy Tanpa Deg-degan": aplikasi HTTP sederhana dengan graceful shutdown
// yang identik dengan slide, supaya audiens bisa mencocokkan repo dengan slide.
package main

import (
	"context"
	"errors"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"
)

// go build -ldflags "-X main.version=$(git rev-parse --short HEAD)"
var version = "dev"

// ready ditanya oleh /readyz. atomic.Bool supaya aman dibaca handler
// saat goroutine utama menuliskannya saat shutdown.
var ready atomic.Bool

// envInt membaca env var integer; nilai kosong/rusak jatuh ke default.
func envInt(name string, def int) int {
	raw, ok := os.LookupEnv(name)
	if !ok {
		return def
	}
	v, err := strconv.Atoi(raw)
	if err != nil || v < 0 {
		return def
	}
	return v
}

// envFloat membaca env var float; nilai kosong/rusak jatuh ke default.
func envFloat(name string, def float64) float64 {
	raw, ok := os.LookupEnv(name)
	if !ok {
		return def
	}
	v, err := strconv.ParseFloat(raw, 64)
	if err != nil || v < 0 {
		return def
	}
	if v > 1 {
		return 1
	}
	return v
}

// newMux merakit router. Semua handler memasang header X-Version;
// FAIL_RATE dan RESPONSE_DELAY_MS hanya berlaku untuk / dan /version —
// endpoint health tidak pernah terpengaruh (itu poin pembelajarannya).
func newMux() *http.ServeMux {
	mux := http.NewServeMux()

	failRate := envFloat("FAIL_RATE", 0)
	delay := time.Duration(envInt("RESPONSE_DELAY_MS", 0)) * time.Millisecond

	// simulate a broken version: / and /version answer 500 with probability
	// failRate (still carrying X-Version). Health endpoints are never affected.
	maybeBreak := func(w http.ResponseWriter) bool {
		if failRate > 0 && rand.Float64() < failRate {
			w.WriteHeader(http.StatusInternalServerError)
			return false
		}
		return true
	}

	mux.HandleFunc("GET /", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Version", version)
		time.Sleep(delay)
		if !maybeBreak(w) {
			return
		}
		io.WriteString(w, "hello from "+version)
	})

	mux.HandleFunc("GET /version", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Version", version)
		time.Sleep(delay)
		if !maybeBreak(w) {
			return
		}
		io.WriteString(w, version)
	})

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Version", version)
		// liveness: selalu 200 selama proses hidup — jangan cek dependensi di sini
	})

	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Version", version)
		if !ready.Load() {
			w.WriteHeader(http.StatusServiceUnavailable) // keluar dari LB
		}
	})

	mux.HandleFunc("GET /slow", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Version", version)
		time.Sleep(3 * time.Second)
		w.WriteHeader(http.StatusOK)
	})

	return mux
}

func main() {
	port := envInt("PORT", 8080)
	shutdownDelay := envInt("SHUTDOWN_DELAY", 5)      // detik; slide: tunggu LB mencabut pod
	shutdownTimeout := envInt("SHUTDOWN_TIMEOUT", 20) // detik; slide: batas menyelesaikan request

	srv := &http.Server{Addr: ":" + strconv.Itoa(port), Handler: newMux()}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		// versi repo: cek errors.Is(err, http.ErrServerClosed), log fatal kalau error lain
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	ready.Store(true)

	<-ctx.Done() // 1. SIGTERM masuk
	log.Println("[shutdown] 1. signal received")
	ready.Store(false) // 2. /readyz → 503
	log.Println("[shutdown] 2. ready=false, /readyz → 503 (keluar dari LB)")
	time.Sleep(time.Duration(shutdownDelay) * time.Second) // 3. tunggu LB mencabut pod
	log.Println("[shutdown] 3. drain delay selesai")
	sctx, cancel := context.WithTimeout(context.Background(), time.Duration(shutdownTimeout)*time.Second)
	defer cancel()
	srv.Shutdown(sctx) // 4. selesaikan request yang sedang jalan
	log.Println("[shutdown] 4. semua in-flight request tuntas, proses berhenti")
}
