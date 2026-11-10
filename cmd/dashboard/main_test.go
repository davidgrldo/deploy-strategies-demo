package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDecodeClusterTracksRoutesAndTerminatingPods(t *testing.T) {
	raw := []byte(`{"items":[
	 {"kind":"Gateway","metadata":{"name":"demo"},"status":{"conditions":[{"type":"Programmed","status":"True"}]}},
	 {"kind":"HTTPRoute","metadata":{"name":"app"},"spec":{"rules":[{"backendRefs":[{"name":"app-blue","weight":0},{"name":"app-green","weight":100}]}]}},
	 {"kind":"Deployment","metadata":{"name":"app-green","labels":{"app.kubernetes.io/part-of":"deploy-strategies-demo"}},"spec":{"replicas":3,"strategy":{"type":"RollingUpdate"}},"status":{"readyReplicas":2}},
	 {"kind":"Pod","metadata":{"name":"old-pod","labels":{"app":"app-green","app.kubernetes.io/part-of":"deploy-strategies-demo"},"deletionTimestamp":"2026-11-10T00:00:00Z"},"spec":{"containers":[{"image":"registry/app@sha256:abc"}]},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},
	 {"kind":"Pod","metadata":{"name":"unrelated"},"status":{"phase":"Running"}}
	]}`)
	c, err := decodeCluster(raw)
	if err != nil {
		t.Fatal(err)
	}
	if !c.Gateway || len(c.Backends) != 1 || c.Backends[0].Weight != 100 || c.Backends[0].Desired != 3 {
		t.Fatalf("unexpected routing: %+v", c)
	}
	if len(c.Pods) != 1 || c.Pods[0].Ready || c.Pods[0].Status != "Terminating" || c.Pods[0].Image != "registry/app@sha256:abc" {
		t.Fatalf("terminating Pod must not be counted as ready: %+v", c.Pods)
	}
}

func TestMetricsSeparateVersionsFromErrorsAndResetAtRelease(t *testing.T) {
	d := &dashboard{}
	d.resetMetrics()
	start := time.Now()
	d.record(request{Time: start, Status: 200, Version: "v1", Latency: 20})
	d.record(request{Time: start.Add(time.Second), Status: 500, Version: "v2", Latency: 40})
	d.record(request{Time: start.Add(3 * time.Second), Status: 0, Latency: 60})
	d.record(request{Time: start.Add(4 * time.Second), Status: 200, Version: "v2", Latency: 80})
	s := d.snapshot()
	if s.Metrics.Total != 4 || s.Metrics.Errors != 2 || s.Metrics.V1 != 1 || s.Metrics.V2 != 1 || s.Metrics.Downtime != 3 || s.Metrics.Latency != 50 {
		t.Fatalf("incorrect metrics: %+v", s.Metrics)
	}
	d.logLine("\x1b[36m▶ [4/5] Release: rolling\x1b[0m")
	s = d.snapshot()
	if s.Metrics.Total != 0 || s.Run.Step != 4 || strings.Contains(s.Run.Logs[0].Text, "\x1b") {
		t.Fatalf("release must start a clean measurement window: %+v", s)
	}
}

func TestLocalControlsRejectInvalidAndConcurrentRequests(t *testing.T) {
	d := &dashboard{ctx: context.Background(), run: run{Running: true}}
	handler := d.handler()
	for _, test := range []struct {
		name, body, origin, host, content string
		want                              int
	}{
		{"unknown target", `{"target":"clean"}`, "", "localhost:9090", "application/json", 400},
		{"concurrent demo", `{"target":"rolling"}`, "http://localhost:9090", "localhost:9090", "application/json", 409},
		{"foreign origin", `{"target":"rolling"}`, "http://example.com", "localhost:9090", "application/json", 403},
		{"foreign host", `{"target":"rolling"}`, "", "example.com", "application/json", 403},
		{"form post", `target=rolling`, "", "localhost:9090", "application/x-www-form-urlencoded", 415},
	} {
		t.Run(test.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "http://localhost:9090/api/run", strings.NewReader(test.body))
			req.Host = test.host
			req.Header.Set("Origin", test.origin)
			req.Header.Set("Content-Type", test.content)
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			if rec.Code != test.want {
				t.Fatalf("status=%d, want %d: %s", rec.Code, test.want, rec.Body.String())
			}
		})
	}
}

func TestSnapshotDoesNotAliasLiveSlices(t *testing.T) {
	d := &dashboard{run: run{Logs: []entry{{Text: "before"}}}}
	s := d.snapshot()
	d.run.Logs[0].Text = "after"
	if s.Run.Logs[0].Text != "before" {
		t.Fatal("SSE snapshot changed after serialization lock was released")
	}
}

func TestRollbackRequiresBothBlueGreenSlots(t *testing.T) {
	d := &dashboard{ctx: context.Background()}
	req := httptest.NewRequest(http.MethodPost, "http://localhost:9090/api/run", strings.NewReader(`{"target":"bluegreen-rollback"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	d.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict || d.run.Running {
		t.Fatal("rollback must not create routes to missing slots")
	}
}

func TestPipelineObservationUsesItsOwnSamplesAndReason(t *testing.T) {
	d := &dashboard{}
	d.resetMetrics()
	d.record(request{Time: time.Now(), Status: 200, Version: "v1"})
	d.logLine(`@@demo {"type":"phase","phase":"observe"}`)
	d.logLine(`@@demo {"type":"canary","samples":8,"errors":0,"minimum":20,"window":120,"elapsed":240,"maximum":0.01}`)
	d.logLine(`@@demo {"type":"decision","reason":"insufficient-samples"}`)
	d.logLine(`@@demo {"type":"phase","phase":"rollback"}`)
	s := d.snapshot()
	if s.Run.Canary.Samples != 8 || s.Run.Canary.Errors != 0 || s.Run.Canary.Reason != "insufficient-samples" || s.Run.ReleasePhase != "rollback" {
		t.Fatalf("observation lost: %+v", s.Run)
	}
	if s.Metrics.Total != 1 || len(s.Run.Logs) != 0 {
		t.Fatal("pipeline samples must not overwrite dashboard traffic or appear as JSON logs")
	}
	d.logLine(`@@demo {broken`)
	if d.snapshot().Run.Canary.Samples != 8 {
		t.Fatal("malformed event should not corrupt the last observation")
	}
}
