package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// get fires a single GET at a fresh server built from newMux() and returns the
// response with the body still open (close it via body()/io.ReadAll + Close).
func get(t *testing.T, path string) *http.Response {
	t.Helper()
	srv := httptest.NewServer(newMux())
	t.Cleanup(srv.Close)
	resp, err := http.Get(srv.URL + path)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func readBody(t *testing.T, r *http.Response) string {
	t.Helper()
	b, err := io.ReadAll(r.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return string(b)
}

// TestHealthzAlways200: liveness must answer 200 whenever the process is alive,
// no matter what state readiness is in (jangan cek dependensi di sini).
func TestHealthzAlways200(t *testing.T) {
	ready.Store(false)
	resp := get(t, "/healthz")
	if resp.StatusCode != http.StatusOK {
		t.Errorf("/healthz saat belum ready = %d, ingin 200", resp.StatusCode)
	}
	ready.Store(true)
	resp = get(t, "/healthz")
	if resp.StatusCode != http.StatusOK {
		t.Errorf("/healthz saat ready = %d, ingin 200", resp.StatusCode)
	}
}

// TestReadyzNotReady503: readiness answers 503 while ready == false.
func TestReadyzNotReady503(t *testing.T) {
	ready.Store(false)
	resp := get(t, "/readyz")
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("/readyz saat belum ready = %d, ingin 503", resp.StatusCode)
	}
}

// TestReadyzReady200: saat ready handler tidak menulis apa pun dan net/http
// otomatis mengirim 200 (persis seperti di slide).
func TestReadyzReady200(t *testing.T) {
	ready.Store(true)
	resp := get(t, "/readyz")
	if resp.StatusCode != http.StatusOK {
		t.Errorf("/readyz saat ready = %d, ingin 200", resp.StatusCode)
	}
}

// TestVersionDefault: tanpa -ldflags, /version mengembalikan nilai default "dev".
func TestVersionDefault(t *testing.T) {
	resp := get(t, "/version")
	if resp.StatusCode != http.StatusOK {
		t.Errorf("/version = %d, ingin 200", resp.StatusCode)
	}
	if got := readBody(t, resp); got != "dev" {
		t.Errorf("/version body = %q, ingin %q", got, "dev")
	}
}

// TestRootHelloFromVersion: / menjawab "hello from <version>".
func TestRootHelloFromVersion(t *testing.T) {
	resp := get(t, "/")
	if got := readBody(t, resp); got != "hello from dev" {
		t.Errorf("/ body = %q, ingin %q", got, "hello from dev")
	}
}

// TestXVersionOnAllEndpoints: semua respons membawa header X-Version.
func TestXVersionOnAllEndpoints(t *testing.T) {
	ready.Store(true)
	for _, path := range []string{"/", "/version", "/healthz", "/readyz"} {
		resp := get(t, path)
		if got := resp.Header.Get("X-Version"); got != "dev" {
			t.Errorf("%s: X-Version = %q, ingin %q", path, got, "dev")
		}
	}
}

// TestFailRateNeverAffectsHealth: dengan FAIL_RATE=1.0 (versi "rusak total"),
// endpoint health tetap 200 — health check lolos, user kena error. Itulah
// poin pembelajarannya: canary butuh analisis traffic, bukan cuma health.
func TestFailRateNeverAffectsHealth(t *testing.T) {
	t.Setenv("FAIL_RATE", "1.0")
	ready.Store(true)

	for i := 0; i < 25; i++ {
		if resp := get(t, "/healthz"); resp.StatusCode != http.StatusOK {
			t.Fatalf("/healthz ke-%d = %d, ingin selalu 200", i, resp.StatusCode)
		}
		if resp := get(t, "/readyz"); resp.StatusCode != http.StatusOK {
			t.Fatalf("/readyz ke-%d = %d, ingin selalu 200 saat ready", i, resp.StatusCode)
		}
	}

	// sanity check kebalikannya: dengan rate 1.0, /version pasti 500 —
	// dan respons 500 itu tetap membawa X-Version.
	resp := get(t, "/version")
	if resp.StatusCode != http.StatusInternalServerError {
		t.Errorf("/version dengan FAIL_RATE=1.0 = %d, ingin 500", resp.StatusCode)
	}
	if got := resp.Header.Get("X-Version"); got != "dev" {
		t.Errorf("respons 500 X-Version = %q, ingin %q", got, "dev")
	}
}
