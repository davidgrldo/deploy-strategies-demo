// Command naive adalah versi TANPA graceful shutdown — pembanding untuk slide
// "Celah". Endpoint dan env-nya sama dengan aplikasi utama, tapi tidak ada
// penanganan sinyal sama sekali: begitu SIGTERM masuk (docker stop, rolling
// update Kubernetes), proses langsung mati dan request yang sedang berjalan
// terputus. Perbandingannya: versi graceful menyelesaikan request itu.
package main

import (
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"time"
)

// go build -ldflags "-X main.version=$(git rev-parse --short HEAD)"
var version = "dev"

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

// newMux merakit router — handler-nya sama dengan versi graceful, kecuali
// /readyz yang di sini selalu 200 (varian ini tidak pernah drain).
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
		// liveness: selalu 200 selama proses hidup
	})

	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Version", version)
		// selalu 200: varian naive tidak pernah bersiap berhenti —
		// inilah celahnya, LB terus mengirim traffic sampai proses dibunuh
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

	// ListenAndServe polos: tidak ada langkah bersiap berhenti — tanpa context
	// pembatal sinyal, tanpa ready=false, tanpa drain, tanpa srv.Shutdown.
	// SIGTERM = proses mati seketika.
	if err := http.ListenAndServe(":"+strconv.Itoa(port), newMux()); err != nil {
		log.Fatal(err)
	}
}
