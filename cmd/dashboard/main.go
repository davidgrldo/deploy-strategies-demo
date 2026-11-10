// Dashboard lokal untuk mengamati dan menjalankan demo deployment.
package main

import (
	"bufio"
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed web/*
var assets embed.FS

type pod struct {
	Name    string `json:"name"`
	App     string `json:"app"`
	Version string `json:"version"`
	Status  string `json:"status"`
	Ready   bool   `json:"ready"`
	Image   string `json:"-"`
}
type backend struct {
	Name     string `json:"name"`
	Weight   int    `json:"weight"`
	Ready    int    `json:"ready"`
	Desired  int    `json:"desired"`
	Strategy string `json:"strategy"`
}
type cluster struct {
	Pods     []pod     `json:"pods"`
	Backends []backend `json:"backends"`
	Gateway  bool      `json:"gateway"`
	Error    string    `json:"error"`
	Updated  time.Time `json:"updated"`
}
type request struct {
	Started time.Time `json:"-"`
	Time    time.Time `json:"time"`
	Status  int       `json:"status"`
	Version string    `json:"version"`
	Latency float64   `json:"latency"`
}
type bucket struct {
	Time   int64 `json:"time"`
	V1     int   `json:"v1"`
	V2     int   `json:"v2"`
	Other  int   `json:"other"`
	Errors int   `json:"errors"`
}
type metrics struct {
	Total    int       `json:"total"`
	Errors   int       `json:"errors"`
	V1       int       `json:"v1"`
	V2       int       `json:"v2"`
	Other    int       `json:"other"`
	Latency  float64   `json:"latency"`
	Downtime float64   `json:"downtime"`
	Since    time.Time `json:"since"`
}
type entry struct {
	Time time.Time `json:"time"`
	Text string    `json:"text"`
}
type run struct {
	ReleasePhase string      `json:"releasePhase"`
	Canary       observation `json:"canary"`
	ID           int         `json:"id"`
	Target       string      `json:"target"`
	Running      bool        `json:"running"`
	Phase        string      `json:"phase"`
	Step         int         `json:"step"`
	Result       string      `json:"result"`
	Started      time.Time   `json:"started"`
	Finished     time.Time   `json:"finished"`
	Logs         []entry     `json:"logs"`
}

type observation struct {
	Available bool    `json:"available"`
	Samples   int     `json:"samples"`
	Errors    int     `json:"errors"`
	Minimum   int     `json:"minimum"`
	Window    int     `json:"window"`
	Elapsed   int     `json:"elapsed"`
	Maximum   float64 `json:"maximum"`
	Reason    string  `json:"reason"`
}
type snapshot struct {
	Time    time.Time `json:"time"`
	Cluster cluster   `json:"cluster"`
	Metrics metrics   `json:"metrics"`
	History []bucket  `json:"history"`
	Recent  []request `json:"recent"`
	Run     run       `json:"run"`
}
type dashboard struct {
	mu          sync.Mutex
	clusterMu   sync.Mutex
	ctx         context.Context
	root        string
	gateway     string
	contextName string
	cluster     cluster
	metrics     metrics
	history     []bucket
	recent      []request
	run         run
	failedSince time.Time
}

var targets = map[string]bool{"recreate": true, "rolling": true, "rolling-naive": true, "bluegreen": true, "bluegreen-rollback": true, "canary": true, "canary-bad": true}
var ansi = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	root, err := findRoot()
	if err != nil {
		log.Fatal(err)
	}
	addr := env("DASHBOARD_ADDR", "127.0.0.1:9090")
	host, _, err := net.SplitHostPort(addr)
	if err != nil || (host != "localhost" && (net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback())) {
		log.Fatal("DASHBOARD_ADDR harus memakai alamat loopback, misalnya 127.0.0.1:9090")
	}
	d := &dashboard{ctx: ctx, root: root, gateway: strings.TrimRight(env("GATEWAY_URL", "http://localhost:8080"), "/"), contextName: "k3d-" + env("CLUSTER_NAME", "demo")}
	d.resetMetrics()
	go d.pollCluster()
	for i := 0; i < 6; i++ {
		go d.sampleTraffic()
	}
	srv := &http.Server{Addr: addr, Handler: d.handler(), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()
	log.Printf("Deployment Lab → http://%s (gateway %s)", addr, d.gateway)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
func env(key, fallback string) string {
	if s := os.Getenv(key); s != "" {
		return s
	}
	return fallback
}
func findRoot() (string, error) {
	p, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(p, "scripts", "pipeline.sh")); err == nil {
			return p, nil
		}
		parent := filepath.Dir(p)
		if parent == p {
			break
		}
		p = parent
	}
	return "", errors.New("jalankan dashboard dari dalam folder repo demo")
}
func (d *dashboard) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/state", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(d.snapshot())
	})
	mux.HandleFunc("GET /api/events", d.events)
	mux.HandleFunc("POST /api/run", d.startRun)
	web, _ := fs.Sub(assets, "web")
	mux.Handle("GET /", http.FileServer(http.FS(web)))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Local controls must not be reachable through a foreign Host/Origin.
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		if host != "localhost" && (net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback()) {
			http.Error(w, "local access only", http.StatusForbidden)
			return
		}
		if origin := r.Header.Get("Origin"); origin != "" {
			u, err := url.Parse(origin)
			if err != nil || u.Host != r.Host || u.Scheme != "http" {
				http.Error(w, "origin rejected", http.StatusForbidden)
				return
			}
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'")
		mux.ServeHTTP(w, r)
	})
}
func (d *dashboard) resetMetrics() {
	d.metrics = metrics{Since: time.Now()}
	d.failedSince = time.Time{}
	d.history = nil
	d.recent = nil
}
func (d *dashboard) snapshot() snapshot {
	d.mu.Lock()
	defer d.mu.Unlock()
	s := snapshot{Time: time.Now(), Cluster: d.cluster, Metrics: d.metrics, History: append([]bucket{}, d.history...), Recent: append([]request{}, d.recent...), Run: d.run}
	s.Run.Logs = append([]entry{}, d.run.Logs...)
	return s
}
func (d *dashboard) events(w http.ResponseWriter, r *http.Request) {
	f, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "stream unavailable", 500)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		data, _ := json.Marshal(d.snapshot())
		if _, err := fmt.Fprintf(w, "data: %s\n\n", data); err != nil {
			return
		}
		f.Flush()
		select {
		case <-r.Context().Done():
			return
		case <-d.ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
func (d *dashboard) sampleTraffic() {
	client := &http.Client{Timeout: 2 * time.Second}
	for {
		select {
		case <-d.ctx.Done():
			return
		default:
		}
		t0 := time.Now()
		req, err := http.NewRequestWithContext(d.ctx, "GET", d.gateway+"/version", nil)
		if err != nil {
			return
		}
		resp, err := client.Do(req)
		item := request{Started: t0, Time: time.Now(), Latency: float64(time.Since(t0).Microseconds()) / 1000}
		if err == nil {
			item.Status = resp.StatusCode
			item.Version = resp.Header.Get("X-Version")
			_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
			_ = resp.Body.Close()
		}
		d.record(item)
		select {
		case <-d.ctx.Done():
			return
		case <-time.After(300 * time.Millisecond):
		}
	}
}
func (d *dashboard) record(item request) {
	d.mu.Lock()
	defer d.mu.Unlock()
	// Ignore requests that started before a new release measurement window.
	if item.Time.Before(d.metrics.Since) || (!item.Started.IsZero() && item.Started.Before(d.metrics.Since)) {
		return
	}
	d.metrics.Total++
	d.metrics.Latency += (item.Latency - d.metrics.Latency) / float64(d.metrics.Total)
	sec := item.Time.Unix()
	if len(d.history) == 0 || d.history[len(d.history)-1].Time != sec {
		d.history = append(d.history, bucket{Time: sec})
		if len(d.history) > 90 {
			d.history = d.history[1:]
		}
	}
	b := &d.history[len(d.history)-1]
	if item.Status < 200 || item.Status >= 300 {
		d.metrics.Errors++
		b.Errors++
		if d.failedSince.IsZero() {
			d.failedSince = item.Time
		}
		// A successful request from another worker ends the error streak.
		if span := item.Time.Sub(d.failedSince).Seconds(); span > d.metrics.Downtime {
			d.metrics.Downtime = span
		}
	} else {
		if !d.failedSince.IsZero() {
			if span := item.Time.Sub(d.failedSince).Seconds(); span > d.metrics.Downtime {
				d.metrics.Downtime = span
			}
		}
		d.failedSince = time.Time{}
		switch item.Version {
		case "v1":
			d.metrics.V1++
			b.V1++
		case "v2":
			d.metrics.V2++
			b.V2++
		default:
			d.metrics.Other++
			b.Other++
		}
	}
	d.recent = append(d.recent, item)
	if len(d.recent) > 40 {
		d.recent = d.recent[1:]
	}
}

// Minimal Kubernetes representation: no client library, same kubectl as the demo.
type kubeItem struct {
	Kind     string `json:"kind"`
	Metadata struct {
		Name              string            `json:"name"`
		Labels            map[string]string `json:"labels"`
		DeletionTimestamp *time.Time        `json:"deletionTimestamp"`
	} `json:"metadata"`
	Spec struct {
		Replicas   int `json:"replicas"`
		Containers []struct {
			Image string `json:"image"`
		} `json:"containers"`
		Strategy struct {
			Type string `json:"type"`
		} `json:"strategy"`
		Rules []struct {
			BackendRefs []struct {
				Name   string `json:"name"`
				Weight *int   `json:"weight"`
			} `json:"backendRefs"`
		} `json:"rules"`
	} `json:"spec"`
	Status struct {
		Phase         string `json:"phase"`
		ReadyReplicas int    `json:"readyReplicas"`
		Conditions    []struct {
			Type   string `json:"type"`
			Status string `json:"status"`
		} `json:"conditions"`
		ContainerStatuses []struct {
			Ready bool `json:"ready"`
			State struct {
				Waiting *struct {
					Reason string `json:"reason"`
				} `json:"waiting"`
			} `json:"state"`
		} `json:"containerStatuses"`
	} `json:"status"`
}

func decodeCluster(raw []byte) (cluster, error) {
	var list struct {
		Items []kubeItem `json:"items"`
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		return cluster{}, err
	}
	c := cluster{Pods: []pod{}, Backends: []backend{}, Updated: time.Now()}
	weights := map[string]int{}
	for _, item := range list.Items {
		if item.Kind == "HTTPRoute" && item.Metadata.Name == "app" {
			for _, rule := range item.Spec.Rules {
				for _, ref := range rule.BackendRefs {
					weight := 1
					if ref.Weight != nil {
						weight = *ref.Weight
					}
					weights[ref.Name] = weight
				}
			}
		}
	}
	for _, item := range list.Items {
		if item.Metadata.Labels["app.kubernetes.io/part-of"] != "deploy-strategies-demo" && item.Kind != "Gateway" {
			continue
		}
		switch item.Kind {
		case "Gateway":
			if item.Metadata.Name == "demo" {
				for _, condition := range item.Status.Conditions {
					if condition.Type == "Programmed" && condition.Status == "True" {
						c.Gateway = true
					}
				}
			}
		case "Deployment":
			c.Backends = append(c.Backends, backend{Name: item.Metadata.Name, Weight: weights[item.Metadata.Name], Ready: item.Status.ReadyReplicas, Desired: item.Spec.Replicas, Strategy: item.Spec.Strategy.Type})
		case "Pod":
			p := pod{Name: item.Metadata.Name, App: item.Metadata.Labels["app"], Status: item.Status.Phase}
			if len(item.Spec.Containers) > 0 {
				p.Image = item.Spec.Containers[0].Image
			}
			for _, condition := range item.Status.Conditions {
				if condition.Type == "Ready" && condition.Status == "True" {
					p.Ready = true
				}
			}
			for _, container := range item.Status.ContainerStatuses {
				if container.State.Waiting != nil {
					p.Status = container.State.Waiting.Reason
				}
			}
			if item.Metadata.DeletionTimestamp != nil {
				p.Status = "Terminating"
				p.Ready = false
			} else if p.Ready {
				p.Status = "Ready"
			}
			c.Pods = append(c.Pods, p)
		}
	}
	sort.Slice(c.Backends, func(i, j int) bool { return c.Backends[i].Name < c.Backends[j].Name })
	sort.Slice(c.Pods, func(i, j int) bool { return c.Pods[i].Name < c.Pods[j].Name })
	return c, nil
}
func (d *dashboard) pollCluster() {
	for {
		d.refreshCluster()
		select {
		case <-d.ctx.Done():
			return
		case <-time.After(1500 * time.Millisecond):
		}
	}
}

func (d *dashboard) refreshCluster() {
	d.clusterMu.Lock()
	defer d.clusterMu.Unlock()
	ctx, cancel := context.WithTimeout(d.ctx, 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "kubectl", "--context", d.contextName, "get", "pods,deployments,httproutes,gateways", "-n", "default", "-o", "json")
	raw, err := cmd.Output()
	c := cluster{}
	if err == nil {
		c, err = decodeCluster(raw)
	}
	if err == nil {
		versions := d.imageVersions()
		for i := range c.Pods {
			if p := strings.Index(c.Pods[i].Image, "@sha256:"); p >= 0 {
				c.Pods[i].Version = versions[c.Pods[i].Image[p+1:]]
			}
		}
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if err != nil {
		d.cluster.Error = "Koneksi cluster gagal. Periksa Docker, kubectl, dan make cluster."
	} else {
		d.cluster = c
	}
}

// Pod templates carry image digests, not version tags. Resolve v1/v2 from
// the locally built Docker image metadata, retaining old Pod versions during rolling.
func (d *dashboard) imageVersions() map[string]string {
	ctx, cancel := context.WithTimeout(d.ctx, 3*time.Second)
	defer cancel()
	registry := env("REGISTRY_HOST", "localhost:5001")
	cmd := exec.CommandContext(ctx, "docker", "image", "inspect", registry+"/app:v1", registry+"/app:v2", "--format", "{{json .}}")
	raw, _ := cmd.Output()
	known := map[string]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		var image struct {
			RepoTags    []string
			RepoDigests []string
		}
		if json.Unmarshal([]byte(line), &image) != nil {
			continue
		}
		version := ""
		for _, tag := range image.RepoTags {
			if strings.HasSuffix(tag, ":v1") {
				version = "v1"
			}
			if strings.HasSuffix(tag, ":v2") {
				version = "v2"
			}
		}
		if version == "" {
			continue
		}
		for _, digest := range image.RepoDigests {
			if p := strings.Index(digest, "@sha256:"); p >= 0 {
				known[digest[p+1:]] = version
			}
		}
	}
	return known
}

func (d *dashboard) startRun(w http.ResponseWriter, r *http.Request) {
	if !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		http.Error(w, "application/json required", 415)
		return
	}
	var input struct {
		Target string `json:"target"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&input) != nil || !targets[input.Target] {
		http.Error(w, "unknown demo", 400)
		return
	}
	d.mu.Lock()
	if d.run.Running {
		d.mu.Unlock()
		http.Error(w, "Satu demo masih berjalan. Tunggu sampai selesai.", 409)
		return
	}
	if input.Target == "bluegreen-rollback" {
		ready := map[string]bool{}
		for _, b := range d.cluster.Backends {
			ready[b.Name] = b.Ready > 0
		}
		if d.cluster.Error != "" || !ready["app-blue"] || !ready["app-green"] {
			d.mu.Unlock()
			http.Error(w, "Rollback tersedia setelah kedua slot blue-green siap.", 409)
			return
		}
	}
	id := d.run.ID + 1
	d.run = run{ID: id, Target: input.Target, Running: true, Phase: "Menyiapkan baseline v1", Started: time.Now(), Logs: []entry{}}
	if input.Target == "bluegreen-rollback" {
		d.run.Phase = "Mengembalikan traffic ke slot sebelumnya"
		d.run.Step = 4
	}
	d.resetMetrics()
	d.mu.Unlock()
	go d.execute(input.Target)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_, _ = io.WriteString(w, `{"accepted":true}`)
}
func (d *dashboard) logLine(line string) {
	line = ansi.ReplaceAllString(line, "")
	if strings.TrimSpace(line) == "" {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if strings.HasPrefix(line, "@@demo ") {
		var event struct {
			Type    string  `json:"type"`
			Phase   string  `json:"phase"`
			Reason  string  `json:"reason"`
			Samples int     `json:"samples"`
			Errors  int     `json:"errors"`
			Minimum int     `json:"minimum"`
			Window  int     `json:"window"`
			Elapsed int     `json:"elapsed"`
			Maximum float64 `json:"maximum"`
		}
		if json.Unmarshal([]byte(strings.TrimPrefix(line, "@@demo ")), &event) == nil {
			switch event.Type {
			case "phase":
				d.run.ReleasePhase = event.Phase
			case "canary":
				d.run.Canary = observation{Available: true, Samples: event.Samples, Errors: event.Errors, Minimum: event.Minimum, Window: event.Window, Elapsed: event.Elapsed, Maximum: event.Maximum}
			case "decision":
				d.run.Canary.Reason = event.Reason
			}
		}
		return
	}
	d.run.Logs = append(d.run.Logs, entry{Time: time.Now(), Text: line})
	if len(d.run.Logs) > 350 {
		d.run.Logs = d.run.Logs[1:]
	}
	if strings.Contains(line, "▶ [1/5]") {
		d.run.Step = 1
		d.run.Phase = "Menguji aplikasi"
	}
	if strings.Contains(line, "▶ [2/5]") {
		d.run.Step = 2
		d.run.Phase = "Membangun image"
	}
	if strings.Contains(line, "▶ [3/5]") {
		d.run.Step = 3
		d.run.Phase = "Push image & pin digest"
	}
	if strings.Contains(line, "▶ [4/5]") {
		d.run.Step = 4
		d.run.Phase = "Release · mengalihkan traffic"
		d.resetMetrics()
	}
	if strings.Contains(line, "▶ [5/5]") {
		d.run.Step = 5
		d.run.Phase = "Verifikasi selesai"
	}
	if strings.Contains(line, "PROMOTED") {
		d.run.Result = "promoted"
	}
	if strings.Contains(line, "ROLLBACK:") {
		d.run.Result = "rolled-back"
	}
}
func (d *dashboard) execute(target string) {
	ctx, cancel := context.WithTimeout(d.ctx, 12*time.Minute)
	defer cancel()
	preflight := exec.CommandContext(ctx, "kubectl", "config", "current-context")
	current, err := preflight.Output()
	if err == nil && strings.TrimSpace(string(current)) != d.contextName {
		err = fmt.Errorf("context kubectl harus %s; jalankan make cluster dulu", d.contextName)
	}
	if err == nil {
		cmd := exec.CommandContext(ctx, "make", target)
		cmd.Dir = d.root
		cmd.Env = append(os.Environ(), "VERSION=v2", "CGO_ENABLED=0", "NO_COLOR=1", "DEMO_EVENTS=1")
		configureProcess(cmd)
		reader, writer := io.Pipe()
		cmd.Stdout = writer
		cmd.Stderr = writer
		done := make(chan struct{})
		go func() {
			defer close(done)
			scanner := bufio.NewScanner(reader)
			scanner.Buffer(make([]byte, 4096), 256*1024)
			for scanner.Scan() {
				d.logLine(scanner.Text())
			}
			_ = reader.Close()
		}()
		err = cmd.Run()
		_ = writer.Close()
		<-done
		// Publish the final route before announcing completion/rollback.
		d.refreshCluster()
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.run.Running = false
	d.run.Finished = time.Now()
	if err != nil && d.run.Result != "rolled-back" {
		d.run.Result = "failed"
		d.run.Phase = "Demo terhenti"
		d.run.Logs = append(d.run.Logs, entry{Time: time.Now(), Text: err.Error()})
	} else if d.run.Result == "rolled-back" {
		d.run.Step = 5
		d.run.Phase = "Rollback · error canary melewati batas"
		if d.run.Canary.Reason == "insufficient-samples" {
			d.run.Phase = "Rollback · bukti belum cukup"
		}
	} else {
		if d.run.Result == "" {
			d.run.Result = "success"
		}
		d.run.Step = 5
		d.run.Phase = "Selesai · traffic sudah dialihkan"
	}
	if d.run.Result != "failed" {
		d.run.ReleasePhase = "complete"
	}
}
