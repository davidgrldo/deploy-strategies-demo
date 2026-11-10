---
prd_id: PRD-20261109-deploy-strategies-demo
title: Tech spec — demo repo empat strategi deployment Go (recreate/rolling/blue-green/canary) untuk sharing session 'Deploy Tanpa Deg-degan'
status: VALIDATED
input_mode: sparse
primary_deliverable: A public-ready, locally-runnable demo repo (Go app + k3d/Envoy Gateway cluster + bash pipeline) where one pipeline with a swappable release stage demonstrates the four deployment strategies — recreate, rolling, blue-green, canary — each visibly distinguishable in a live traffic panel and consistent with the supplied 'Deploy Tanpa Deg-degan' slide deck (deck.html), for the 10 Nov 2026 sharing session.
primary_deliverable_figma_anchor: null
primary_deliverable_route_or_path: scripts/pipeline.sh
figma_required: false
figma_strict_mode: false
figma_file_key: null
figma_nodes: []
target_repo:
  source_repo_url: https://github.com/davidgrldo/deploy-strategies-demo
  source_repo_url_note: 'IDENTITY REFRESH (2026-11-09, post-SA): origin remote is now configured on the local working tree — https://github.com/davidgrldo/deploy-strategies-demo — and the human is pushing branch main to it (initial snapshot commit 541bdb1 ''chore: initial snapshot — spec + slide deck inputs'' + this tech_spec; verified post-SA: `git remote -v` shows origin, `git ls-remote origin` exits 0 with the remote still empty — push pending; at SA time the remote was absent and `source_repo_url` was null). /vibe-coding setup: auto-clone/refresh from this URL to remote HEAD as usual (requires main pushed; if the clone lands on an empty repo the push has not happened yet — fall back to the local working tree at the case dir as repo root). The local case dir remains a valid working tree / repo root (greenfield build target — tracked content is only the two inputs demo-strategies.md + deck.html). demo-strategies.md and deck.html are inputs, not deliverables: their byte-preservation guards (AC-17, Verification Commands) remain binding. PRD OQ-003 scope unchanged — the build itself must not push/publish to any git host; origin setup and the initial push were done manually by the human.'
  slug: deploy-strategies-demo
  role: 'Greenfield teaching/demo repo: Go HTTP app (graceful vs naive shutdown) + k3d/Envoy Gateway local cluster + one bash pipeline with swappable release stage (recreate/rolling/blue-green/canary) + live traffic panel; public-ready material for the ''Deploy Tanpa Deg-degan'' sharing session (10 Nov 2026).'
  analyzed_at_commit: 541bdb1
secondary_deliverables:
- 'Traffic watch panel scripts/watch.sh: per-request status+version lines, ~2s mix summary, downtime-duration detection, gateway-outage resilience, --compact mode (§7)'
- 'Naive-vs-graceful comparison: naive/main.go variant (no signal handling, /readyz always 200, immediate SIGTERM exit) + make demo-shutdown docker-stop demo without Kubernetes (§4, §8)'
- Prometheus-free automated canary analysis with promote/auto-rollback thresholds, all knobs env-overridable (§6)
- Makefile one-command targets for every demo scenario incl. rolling-naive, bluegreen-rollback, canary-bad (§9)
- Public-facing README in Bahasa Indonesia with slide-consistent analogies (exact deck slide-3 wording), 'pakai kalau...' guidance, prerequisites, 'Kenapa kodenya begini?', 'Tanpa Kubernetes?', troubleshooting (§11); plus MIT LICENSE so the repo is share-ready (OQ-003)
source:
  vibe_req_workspace: /home/davidgrldo/vibe-coding-tasks/vibe-req-demo-strategies-20261109-080813
  vibe_req_instance_id: vibe-req-demo-strategies-20261109-080813
  prd_sources:
  - 0-input/business_input.md (verbatim copy of /home/davidgrldo/sandbox/golang/sharing-session/deploy-strategies-demo/demo-strategies.md — requirement source-of-truth; section refs '§N' below point into it)
  - /home/davidgrldo/sandbox/golang/sharing-session/deploy-strategies-demo/deck.html (slide deck 'Deploy Tanpa Deg-degan', 8 slides — canonical slide reference for code/README consistency per OQ-001 clarification answer)
  - 0-input/supplement-speaker-context.md (copy of /home/davidgrldo/vibe-coding-tasks/vibe-req-inputs/input-20261109-speaker-context.md; supplementary speaker context, 2026-11-09)
  - 1-po/output/open-question-answers.md + open-question-answers.json (human answers to PO OQ-001..005 at the PO clarification gate, recorded 2026-11-09T08:32:11Z)
  - 0-input/source.json
  generated_at: '2026-11-09T09:25:53+00:00'
  prd_mr_url: null
  spec_mr_url: null
---

## Summary

This tech_spec designs a **greenfield, public-ready demo repo** that teaches the four Kubernetes deployment strategies — recreate, rolling, blue-green, canary — through one runnable pipeline whose **deploy stages are identical and whose release stage is swappable**. The repo reinforces the session's core message: *deploy = memasang versi baru, release = memindahkan traffic ke versi itu*; the four strategies differ only in how they release. The primary user-facing entrypoint is `scripts/pipeline.sh` (PRD `primary_deliverable_route_or_path`), normally invoked via `make <strategy>` targets, with the strategy signature made visible in the live traffic panel `scripts/watch.sh` against `http://localhost:8080/version`.

The deliverable set is: (1) a Go 1.22+ standard-library HTTP application at repo root whose graceful-shutdown block is **identical to the canonical slide reference** (deck.html slide 5 = business_input.md §4), plus a `naive/` variant without graceful shutdown as the "Celah" (leak) counterexample; (2) an idempotent k3d + local-registry + Envoy Gateway cluster setup exposing the Gateway at `http://localhost:8080`, using Gateway API `HTTPRoute` `backendRefs.weight` for traffic splitting — no service mesh, no Argo Rollouts/Flagger, no Prometheus; (3) the bash pipeline `scripts/pipeline.sh recreate|rolling|bluegreen|canary` with a Prometheus-free canary analysis (the pipeline itself sends traffic, counts canary-version errors, promotes or auto-rolls-back); (4) the traffic panel, a Docker-only `make demo-shutdown` comparison, a Makefile with one-command targets for every demo scenario, a Bahasa-Indonesia README using the deck's exact slide-3 analogies, and an MIT LICENSE.

Everything runs locally on a laptop (Linux acceptance machine; README documents Linux/macOS/Windows-WSL2). The repo already contains exactly two files that are **inputs, not deliverables, and must remain untouched**: `demo-strategies.md` (the requirement spec) and `deck.html` (the canonical slide deck). Mechanical preservation guards for both are in `## Verification Commands`.

**Environment note (verified at SA time, 2026-11-09):** the acceptance machine has Go 1.22.5 (as a GOROOT tree at `$HOME/go` requiring `GOROOT=$HOME/go`, off default PATH), kubectl, make 4.3, bash 5.1, curl 7.81, envsubst 0.21 — but **no Docker Engine and no k3d**. Cluster-dependent ACs (AC-1..AC-8) need those prerequisites installed first (OQ-SA-001); static ACs are runnable now. Verification commands embed the Go toolchain prefix so they run as-is on this machine.

**Amendment round 1 (design review 2026-11-09-01; human-approved `_state/human-amendment-20261109T0855-round1.md`):** this revision folds five dispositions into the contract — **(WARNING-1, required)** R6 now owns the ±300 ms `RESPONSE_DELAY_MS` demo-manifest setting for all four strategies (§4; previously only a passing statement inside R1); **(INFO-2, accepted shape)** the accepted envsubst image-template shape `image: ${REGISTRY}/app@sha256:${DIGEST}` is documented and enforced in the digest guard; **(INFO-3, clarified)** the blue-green `🔀 SWITCH` marker is direction-aware (prints actual `from → to` slots); **(INFO-4)** `reset.sh` builds/pushes the initial v1 image via the shared build path before creating starting shapes; **(INFO-5, accepted decision)** `VERSION=v2` is the default for all demo targets, not a `recreate`-only literal. No new OQs; no design change — placement/ownership fixes and recorded decisions.

## Primary Implementation

**(a) Where the primary deliverable mounts.** The primary deliverable is a CLI entrypoint, not a routed UI: `scripts/pipeline.sh` (repo-relative exact path — contractual, matching the PRD's `primary_deliverable_route_or_path` and business_input.md §1). The user experiences it as `./scripts/pipeline.sh <strategy>` or, canonically for the demo, through the Makefile targets (`make recreate`, `make rolling`, `make bluegreen`, `make canary`, plus `make bluegreen-rollback`) defined in §9. The pipeline's stages print colored numbered headers with durations (e.g. `▶ [2/5] Build sekali`): (1) `go test ./...` → (2) build once via `docker build` with `-ldflags "-X main.version=<short-sha>"` (overridable via env `VERSION`, e.g. `v2`; `APP=naive` builds the naive variant) → (3) push to the local registry and capture the image **digest** — from this stage on, only the digest is used → (4) `release_<strategy>` → (5) summary (strategy, version, digest, total duration). Its observable effect lands on the traffic panel: `make watch` runs `scripts/watch.sh`, workers curl `http://localhost:8080/version` continuously, and each strategy prints its signature there (see R7).

**(b) Fresh build vs extend.** This is a **fresh build**: the target repo is greenfield — git-tracked content at the analyzed commit (`541bdb1`) is exactly `demo-strategies.md` + `deck.html`, with no code, no `go.mod`, no Makefile, nothing to extend. The entire repo layout in business_input.md §3 is therefore contractual (file paths are part of the spec, and the ACs reference scripts by path). The two existing files are inputs to preserve byte-identically, never to modify or move (AC-17 guard).

**(c) Element Inventory.** Omitted — `figma_required: false`, no Figma file exists for this case; all 17 ACs are prose-only. The functional equivalent of the element inventory is the **repo layout contract** (R4) and the **per-strategy observable-signature table** (R7) below; both decompose the primary deliverable completely.

Architectural spine (why this shape): one shared deploy path (test → build once → push digest) and four swappable release functions is itself the teaching artifact — it physically demonstrates "deploy sama, release beda" (deck slide 7). Every strategy therefore shares stages 1–3 and 5 byte-for-byte; only `release_<strategy>` differs. The pipeline must be a **bash script** (not GitHub Actions) so it can be run and recorded live on a laptop; each stage is a clearly-named bash function and each strategy is exactly one function `release_<strategy>` (§2). Application code must stay consistent with the slide deck (§2) — the deck (deck.html) was reconciled slide-by-slide against the spec by PO with **no material discrepancies** (PRD "Slide-deck reconciliation"; re-verified by SA — see Source Evidence), so §4's code block and the deck are a single canonical reference.

## Business Contract

All requirements below cite `business_input.md` (verbatim copy of `demo-strategies.md` in the repo root) as `§N`, and `deck.html` slides/speaker-notes as `deck N`. `§N` quotes are binding business behavior, not suggestions. File paths are repo-relative and contractual per §3.

### Requirement R1: Go application (root `main.go`)

Source:
- business_input.md §4; deck.html slides 5–6 (canonical slide reference per OQ-001 answer); PRD In-scope "Go application"

Trigger:
- User starts the built container / binary (in cluster, in `docker run`, or directly). Build-time injection of `version` via `go build -ldflags "-X main.version=$(git rev-parse --short HEAD)"`; runtime behavior driven by env vars.

Inputs:
- Env `PORT` — listen port; default `8080`. Required vs optional: optional, always defaulted.
- Env `FAIL_RATE` — float 0–1, default `0`. Broken-version simulation.
- Env `RESPONSE_DELAY_MS` — integer ms, default `0`. Artificial latency for `/` and `/version` only.
- Env `SHUTDOWN_DELAY` — seconds, default `5` (deck slide 5 step 3).
- Env `SHUTDOWN_TIMEOUT` — seconds, default `20` (deck slide 5 step 4).
- Build-time variable `version` (string, default `"dev"`), exactly as deck slide 6 shows: `// go build -ldflags "-X main.version=$(git rev-parse --short HEAD)"` + `var version = "dev"`.
- Invalid/absent env values fall back to defaults; no crash on bad input.

Behavior:
- Go 1.22+, **standard library only**, `http.ServeMux` with `"GET /path"` routing pattern registration.
- `GET /` → `200`, body `hello from <version>`.
- `GET /version` → `200`, body exactly the `version` value.
- `GET /healthz` → liveness; **always 200 while the process is alive; checks no dependencies** (deck note 6: "Jangan cek database di sini").
- `GET /readyz` → readiness; when `ready` is false → `503`; when ready, the handler **writes nothing** (net/http auto-200), exactly as deck slide 6 renders the handler: `mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) { if !ready.Load() { w.WriteHeader(http.StatusServiceUnavailable) } })`.
- `GET /slow` → sleep exactly 3 s, then `200`. Used only by the `docker stop` demo (R9).
- **All responses** carry header `X-Version: <version>` — including 500 responses produced by `FAIL_RATE` (§4: "tetap dengan header X-Version") and health endpoints.
- `FAIL_RATE` p: each `/` and `/version` request independently returns `500` with probability p; `/healthz` and `/readyz` are **never** affected (this is the teaching point: health checks pass while users see errors — deck note 7 clip 5).
- `RESPONSE_DELAY_MS`: `/` and `/version` wait that many ms before answering; other endpoints unaffected. Demo manifests set ±300 ms so in-flight requests always exist when pods die — **the ±300 ms manifest setting is owned by R6**, the requirement that renders the manifests/reset templates (design review WARNING-1).
- **Graceful shutdown — must follow the §4/deck slide 5 block exactly** (this order, these variable names — AC-10):
  1. `ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)`; `defer stop()` (`os.Interrupt` included so Ctrl+C on a laptop also triggers graceful shutdown — deck note 5).
  2. Start serving: `go srv.ListenAndServe()` — repo version checks `errors.Is(err, http.ErrServerClosed)` and log-fatals on any other error (deck-acknowledged addition; deck note 5: "error handling ListenAndServe di slide sengaja disingkat. Versi lengkapnya (cek errors.Is(err, http.ErrServerClosed)) ada di repo demo"); then `ready.Store(true)`.
  3. `<-ctx.Done()` — comment `// 1. SIGTERM masuk`.
  4. `ready.Store(false)` — comment `// 2. /readyz → 503`.
  5. `time.Sleep(5 * time.Second)` — comment `// 3. tunggu LB mencabut pod`; 5 s replaced by `SHUTDOWN_DELAY`.
  6. `sctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)`; `defer cancel()`; `srv.Shutdown(sctx)` — comment `// 4. selesaikan request yang sedang jalan`; 20 s replaced by `SHUTDOWN_TIMEOUT`.
- `ready` is an `atomic.Bool`; the named variables `ready`, `version`, `srv`, `stop`, `sctx`, `cancel` are contractual (§12-10).
- Per-step logs at each shutdown stage, format `[shutdown] 1. signal received`, `[shutdown] 2. ...`, `[shutdown] 3. ...`, `[shutdown] 4. ...`.
- The 5 + 20 = 25 s arithmetic must stay below the manifest `terminationGracePeriodSeconds: 30` (deck slide 5 states the same inequality; manifest carries comment `# 5 + 20 = 25 < 30` — R6).

State/Data:
- In-memory only: `ready` (atomic.Bool), `version` (build-time string), server state. No persistence; nothing written to disk.

External Effects:
- none — the app makes no outbound calls; it only listens on `PORT`.

Negative Scope:
- No third-party Go dependencies (standard library only, §4); no database, no external config service; no metrics endpoint; no Prometheus client (§2).

Acceptance Criteria:
- AC-10 (shutdown logic identical to slide: 4-step order + variable names + `atomic.Bool` + env-tunable 5 s/20 s defaults + `errors.Is` repo addition); AC-14 (header/probe semantics interplay: `FAIL_RATE` never affects `/healthz` `/readyz`); AC-9 (`go vet` / `go test` clean); AC-6/AC-7 depend on `FAIL_RATE` + `X-Version` semantics.

### Requirement R2: Naive variant (`naive/main.go`)

Source:
- business_input.md §4 ("naive/main.go"), §1 bonus (rolling-naive), deck.html slide 4 ("Celah") + note 4

Trigger:
- Built via the same Dockerfile with `ARG APP=naive`; deployed by `make rolling-naive` (and usable anywhere the graceful app is). Also runnable as a plain local `docker run` process.

Inputs:
- Same env surface as R1: `PORT` (default 8080), `FAIL_RATE` (default 0), `RESPONSE_DELAY_MS` (default 0). `SHUTDOWN_*` knobs are irrelevant (no graceful shutdown) — accepted but unused.

Behavior:
- **Same endpoints and semantics as R1** (`/`, `/version`, `/healthz`, `/slow`, `X-Version` on all responses, `FAIL_RATE` on `/` and `/version` only, `RESPONSE_DELAY_MS` delay) with exactly two differences:
  1. Serving is a plain `http.ListenAndServe` (or `http.ListenAndServe` + `log.Fatal`) with **no signal handling** — no `signal.NotifyContext`, no shutdown steps.
  2. `/readyz` **always returns 200** (never 503).
- The process must genuinely **exit immediately on SIGTERM inside a container as PID 1** (§4: "Pastikan prosesnya benar-benar langsung exit saat menerima SIGTERM di dalam container (sebagai PID 1)"). This is the "Celah" counterexample: SIGTERM kills the process while the load balancer still routes to it for a few seconds → 502/connection-reset to users (deck slide 4 + note 4).

State/Data:
- In-memory only; no persistence.

External Effects:
- none.

Negative Scope:
- Do NOT copy any graceful-shutdown code into the naive variant — its entire purpose is its absence. No `signal` import.

Acceptance Criteria:
- AC-15 (immediate SIGTERM exit as PID 1; `/readyz` always 200; supports `RESPONSE_DELAY_MS` + `FAIL_RATE`); AC-4 (rolling-naive shows 5xx/ERR reproducibly); AC-8 (naive leg of demo-shutdown).

### Requirement R3: Automated checks (root `main_test.go`, static gates)

Source:
- business_input.md §3 ("main_test.go # test /healthz, /readyz, /version"), §12-9

Trigger:
- `go test ./...` (also pipeline stage 1) and CI-equivalent local runs.

Inputs:
- The R1 handlers under test.

Behavior:
- Tests cover `GET /healthz`, `GET /readyz`, `GET /version` (all three named by §3; version default `dev` when not injected; readyz both states when testable via the same handlers).
- `go vet ./...` exits 0; `go test ./...` exits 0 ("bersih").
- Sources format-clean per `gofmt` (repo hygiene; enforced by the verification block).

State/Data:
- none (unit tests only, no cluster fixtures).

External Effects:
- none.

Negative Scope:
- No integration tests requiring Docker/k3d (§12 gates those via the demo targets, not `go test`); no external test frameworks — standard library `testing` + `net/http/httptest` suffice.

Acceptance Criteria:
- AC-9.

### Requirement R4: Repo skeleton, Dockerfile, and preservation of the two input files

Source:
- business_input.md §3 (layout), §3 Dockerfile line; PRD OQ-002/OQ-003 decisions; AC-17

Trigger:
- Any build (`docker build`) or repo-level command.

Inputs:
- `Dockerfile` build args: `ARG APP=main|naive` selecting which program builds; version string passed through to `-ldflags`.

Behavior:
- Repo layout exactly as §3 lists (paths contractual): `main.go`, `main_test.go`, `go.mod`, `Dockerfile`, `Makefile`, `naive/main.go`, `deploy/gateway.yaml`, `deploy/base/` (generic Deployment+Service templates, substituted via envsubst), `deploy/httproute.yaml` (template, weights substituted), `deploy/README.md` (short explanation of each manifest), `scripts/setup-cluster.sh`, `scripts/lib.sh` (shared functions: colored logging, `set_weights`, `wait_rollout`, etc.), `scripts/pipeline.sh`, `scripts/reset.sh`, `scripts/watch.sh`, root `README.md` (R11), `LICENSE` (MIT).
- Dockerfile: multi-stage; builder stage compiles a **static** binary (CGO disabled, `netgo`/pure stdlib — no cgo); final stage runs on distroless or scratch; `ARG APP=main|naive` builds the corresponding program; final image runs as PID 1 so R2's immediate-exit property is real.
- `go.mod` declares Go 1.22+ and no third-party requires.
- `demo-strategies.md` and `deck.html` remain in place at repo root, **byte-identical** — never modified, moved, renamed, or deleted. Mechanically guarded (see Verification Commands).

State/Data:
- The local git repo (branch `main`, initial snapshot commit) gains new files only; the two input files stay untouched in the worktree.

External Effects:
- `docker build` pulls public base images (builder Go image matching 1.22+, minimal runtime image) from Docker Hub at build time.

Negative Scope:
- No `.github/workflows` or any hosted-CI config (§2 — pipeline is deliberately bash). No cloud-provider config. No service-mesh manifests. No modifications to `deck.html` (including its slide-8 `[link repo demo]` placeholder — OQ-SA-003) or `demo-strategies.md`.

Acceptance Criteria:
- AC-17; enables AC-1..AC-8 (build stage).

### Requirement R5: Local cluster setup (`scripts/setup-cluster.sh` + `deploy/gateway.yaml`)

Source:
- business_input.md §5 (cluster bullets), §2 (local-only constraint); deck note 7 ("weight di HTTPRoute Gateway API, tanpa service mesh")

Trigger:
- `make cluster` (first run and every re-run); acceptance AC-1 "from zero on a clean laptop".

Inputs:
- Host prerequisites: Docker, k3d, kubectl (README documents install + version checks). Cluster name, registry port, gateway port are script-internal constants (registry host-visible at `localhost:5001` per §5 example).

Behavior:
- **Idempotent**: running the script again on an existing setup converges instead of failing (re-create-or-reuse logic; AC-1 requires repeatable runs alongside every `reset`).
- Create a k3d cluster with a **local registry** (e.g. host-visible `localhost:5001`) so images can be pushed from the host and referenced **by digest**.
- Handle the host-visible vs in-cluster registry name difference (k3d registry config/alias): the host pushes to `localhost:5001/...`; manifests inside the cluster reference the same image **by the same digest** under the in-cluster registry prefix; the pipeline rewrites only the prefix (§5: "Digest-nya tetap sama, jadi pipeline cukup mengganti prefix registry").
- Disable K3s' bundled Traefik (conflicts with Envoy Gateway on ingress).
- Install **Envoy Gateway** (latest stable, Gateway API **v1 standard channel** CRDs), then create `GatewayClass` + `Gateway` (`deploy/gateway.yaml`).
- Expose the Gateway at **`http://localhost:8080`** on the host — this exact URL is the traffic target of the panel (R8), the canary analysis (R7), and the ACs.
- Print progress/wait-for-ready output so a live demo audience can follow along.

State/Data:
- Creates the k3d cluster, registry, `envoy-gateway-system` install, Gateway API resources — all local; no external state.

External Effects:
- Pulls k3d/K3s images, Envoy Gateway helm/OCI chart + Gateway API CRD bundles from public registries at setup time. Nothing leaves the laptop otherwise.

Negative Scope:
- No cloud provider, no managed Kubernetes (§2). No Traefik ingress resources. No service mesh (Istio/Linkerd/etc.), no Argo Rollouts, no Flagger, no Prometheus (§2) — mechanically guarded in Verification Commands. `deploy/gateway.yaml` does not create application routes (those are R6/R7).

Acceptance Criteria:
- AC-1; prerequisite for AC-2..AC-7.

### Requirement R6: Kubernetes manifests and per-strategy initial shapes (`deploy/base/`, `deploy/httproute.yaml`, `scripts/reset.sh`)

Source:
- business_input.md §5 (manifest conventions + per-strategy table + canary weight example), §3 (deploy/ layout); deck slide 5 (25 < 30 arithmetic)

Trigger:
- `make reset S=recreate|rolling|bluegreen|canary` (always (re)creates the strategy's initial shape **starting at v1**), and the pipeline's release functions applying updates.

Inputs:
- Templates substituted via envsubst: deployment/service name, image (digest form; accepted template shape `image: ${REGISTRY}/app@sha256:${DIGEST}` — see Behavior), replica count, strategy-specific fields, route weights, and the demo-latency env `RESPONSE_DELAY_MS` (demo default `300`, all four strategies — see Behavior).

Behavior:
- **Images are always pinned by digest** (`registry-prefix/app@sha256:...`) — never by tag — everywhere a workload image is referenced (§5; slide note 6: build once, promote the same digest). **Accepted envsubst template shape (design review INFO-2): `image: ${REGISTRY}/app@sha256:${DIGEST}`** — the literal `@sha256:` prefix lives in the template itself, so the digest guard in `## Verification Commands` passes both before and after substitution; any `image:` line lacking `@sha256:` fails that guard.
- **Demo manifests set `RESPONSE_DELAY_MS=300` on all four strategies' workloads** (§4: "Di manifest demo, set ±300 ms untuk semua strategi, supaya selalu ada request yang sedang berjalan saat pod dimatikan… Tanpa ini, celahnya bisa terlalu singkat untuk tertangkap di rekaman" — design review WARNING-1). The `deploy/base/` templates (or the `reset.sh` substitution defaults) carry this env into every demo workload, reaching the app as the R1/R2 container env. This setting is what guarantees in-flight requests exist when pods die — the premise under AC-3's 0-error claim and AC-4's reproducibility.
- Probes on every application Deployment: `livenessProbe` → `/healthz`, `readinessProbe` → `/readyz`, both with `periodSeconds: 2` (fast demo convergence).
- Explicit `terminationGracePeriodSeconds: 30` carrying the literal comment `# 5 + 20 = 25 < 30`.
- Default replicas **3** (canary's workloads: stable 3, canary 1 once scaled up; initial canary shape has canary at 0).
- Per-strategy initial shapes created by `reset.sh <strategy>`, always starting at v1:

  | Strategy | Workload shape | HTTPRoute weights |
  |---|---|---|
  | recreate | 1 Deployment `app`, `strategy.type: Recreate` | `app` 100 |
  | rolling | 1 Deployment `app`, `RollingUpdate` (`maxSurge: 1`, `maxUnavailable: 0`) | `app` 100 |
  | bluegreen | `app-blue` (v1, active) + `app-green` (0 replicas) | blue 100 / green 0 |
  | canary | `app-stable` (v1) + `app-canary` (0 replicas) | stable 100 / canary 0 |

- Canary weight split example (§5, verbatim shape): `backendRefs` with `app-stable` port 80 `weight: 90` and `app-canary` port 80 `weight: 10`. Route `port: 80` targets the application Service (which forwards to container port 8080 — R1's `PORT`).
- `reset` is repeatable: each run returns the cluster to the same initial v1 state for that strategy (AC-1). **Initial v1 image provenance (design review INFO-4):** `reset.sh` builds and pushes the initial v1 image through the same shared build path as pipeline stages 1–3 (`go test` → build once → push digest, via `scripts/lib.sh`) before creating the starting shapes — so the initial v1 is digest-pinned exactly like every later workload image (System Boundary digest obligation).
- `deploy/README.md` explains each manifest briefly (Bahasa Indonesia appropriate — it is part of the public teaching repo).

State/Data:
- Cluster-local Kubernetes objects only (Deployments, Services, HTTPRoute, Gateway from R5).

External Effects:
- kubectl applies against the local cluster; image pulls from the local k3d registry (digest-pinned).

Negative Scope:
- No HPA, no PDB, no mesh objects, no Argo Rollouts CRs, no Prometheus Operator/ServiceMonitor. No ConfigMaps/Secrets (the app needs none). Templates must not hardcode build-specific digests — digests arrive by substitution at deploy time.

Acceptance Criteria:
- AC-14 (manifest conventions); AC-1 (reset repeatability); underpins AC-2..AC-7.

### Requirement R7: Pipeline and the four release behaviors (`scripts/pipeline.sh`, `scripts/lib.sh`)

Source:
- business_input.md §6 (pipeline stages + per-strategy release), §1 (signature table), §2 (bash, no GHA); deck slide 7 + note 7; PRD primary_deliverable

Trigger:
- `./scripts/pipeline.sh <strategy>` — strategies: `recreate` | `rolling` | `bluegreen` | `canary`; extra command: `./scripts/pipeline.sh bluegreen-rollback`. Normally via Makefile targets (R10).

Inputs:
- Positional arg: strategy or `bluegreen-rollback`.
- Env overrides (all optional, defaults in parens): `VERSION` (short git SHA — build-time version string, e.g. `v2` for readable demos), `APP` (`main`; `naive` builds the naive variant), `FAIL_RATE` (unset — forwarded to the canary workload when set), `SWITCH_PAUSE` (5 s), `CANARY_WEIGHT` (10), `OBSERVE_SECONDS` (120), `MAX_ERROR_RATE` (0.01), `MIN_SAMPLES` (20).

Behavior:
- Common stages, each printing a colored numbered header with duration (format e.g. `▶ [2/5] Build sekali`):
  1. **Test** — `go test ./...` must pass or the pipeline stops.
  2. **Build sekali** — one `docker build` with `-ldflags "-X main.version=<version>"`; `VERSION` overrides the short-sha default; `APP=naive` builds the naive program.
  3. **Push & ambil digest** — push to the local registry; print `image: …@sha256:…`; **from this point only the digest is used** (no tags).
  4. **Release** — exactly one `release_<strategy>` function runs (below).
  5. **Ringkasan** — print strategy, version, digest, total duration.
- `release_recreate`: update Deployment `app` image to the digest; wait for rollout; print the literal warning `⚠ downtime diharapkan`.
- `release_rolling`: update Deployment `app` image; wait `kubectl rollout status`; print pod progress lines as they advance (`updated 1/3 … 3/3` shape).
- `release_bluegreen`: deploy the digest to the **inactive** slot; wait until all its pods are ready; print `green siap, belum terima traffic`; pause `SWITCH_PAUSE` seconds (default 5); set weights to `0/100` (old/new); print `🔀 SWITCH <from> → <to>` with the **actual** slot pair — `🔀 SWITCH blue → green` on the first invocation (the §6 example wording), `🔀 SWITCH green → blue` after alternation — the marker is direction-aware, never a hardcoded literal (design review INFO-3); **remember the active slot** (e.g. a field/annotation on the HTTPRoute) so the next invocation alternates slots (blue→green→blue…).
- `pipeline.sh bluegreen-rollback`: switch weights back to the previous slot **instantly** (no rebuild, no re-deploy — weights only).
- `release_canary`: deploy the digest to `app-canary` (setting `FAIL_RATE` on that workload when the env is set); wait ready; set weights `100-CANARY_WEIGHT / CANARY_WEIGHT` (default 90/10); then **analysis without Prometheus** (§2): for `OBSERVE_SECONDS`, send requests to `localhost:8080/version`, count **only responses whose `X-Version` equals the canary version**, print roughly every 10 s a line of the shape `canary: 42 req, 1 error (2.4%)`; decide:
  - error rate ≤ `MAX_ERROR_RATE` with samples ≥ `MIN_SAMPLES` → **promote**: update `app-stable` to the **same digest** (no rebuild — deck note 7: "dipromosikan ke 100% dengan digest yang sama, bukan build ulang"), wait rollout, set weights `100/0`, scale canary to 0, print `✅ PROMOTED <version> → 100%`.
  - error rate above threshold → **rollback**: set weights `100/0`, scale canary to 0, print `❌ ROLLBACK: error rate X% > Y%`, **exit non-zero**; early stop is allowed once failure is clear ("Boleh berhenti lebih awal begitu jelas gagal").
- Every strategy's observable signature in the panel (§1 table — the demo's whole point):

  | Strategy | Must be visible in the traffic panel |
  |---|---|
  | recreate | an ERR/5xx gap (downtime) between v1 and v2; **downtime duration printed** |
  | rolling | v1 and v2 mix gradually, **0 errors** |
  | blue-green | 100% v1 → 100% v2 instantly; rollback to v1 instantly |
  | canary | ~10% v2, observed, then promoted; broken version auto-rolls-back |

State/Data:
- Cluster state mutations only (Deployment images by digest, HTTPRoute weights, replica counts, active-slot annotation for bluegreen). No files written outside the repo; no external state.

External Effects:
- Sends HTTP requests to `http://localhost:8080/version` during canary analysis (the pipeline itself is the load generator + analyzer — deliberately, §2 "tanpa Prometheus"). Runs `go test`, `docker build`, `docker push`, `kubectl` against the local cluster/registry.

Negative Scope:
- No GitHub Actions, no hosted CI (§2). No Prometheus queries, no metrics server dependency. No Argo Rollouts/Flagger analysis. Never references images by tag after stage 3. Never rebuilds for promote/rollback (digest reuse only).

Acceptance Criteria:
- AC-2..AC-7 (panel signatures), AC-12 (env knobs), AC-16 (slot alternation + instant rollback); AC-4 via `APP=naive` path; AC-7 exit-code contract.

### Requirement R8: Traffic watch panel (`scripts/watch.sh`)

Source:
- business_input.md §7; deck slide 7 ("Kiri: panel traffic") + note 7 ("panel mencetak berapa detik downtime-nya")

Trigger:
- `make watch` (or `./scripts/watch.sh [--compact]`), typically in the left tmux pane while the pipeline runs in the right.

Inputs:
- Env `WORKERS` — parallel worker count, default `6`. Flag `--compact` — summary-only mode. Target URL fixed at `localhost:8080/version`.

Behavior:
- `WORKERS` parallel workers each loop `curl` to `localhost:8080/version` with ~300 ms pacing (aggregate ~20 req/s) and a short timeout (~2 s); parallelism maximizes the chance of catching the kill-window.
- One line per response: `HH:MM:SS  200  v1`.
- Colors: v1 grey/white; v2 cyan; any other version yellow; 5xx and `ERR` bold red.
- Every ~2 s print a mix summary line: `v1 62% · v2 38% · err 0`.
- **Downtime detection**: when traffic recovers after a consecutive-error span, print `⛔ downtime 3.4s` (the span's duration). This number is the headline stat for recreate and rolling-naive (deck note 7).
- **Never crash when the gateway is down**: connection failures/timeouts print `ERR` and the loop continues.
- `--compact` prints only the summary lines (for narrow recording windows).

State/Data:
- none persisted; rolling counters in memory/temp only.

External Effects:
- Continuous read-only HTTP traffic to `http://localhost:8080/version`.

Negative Scope:
- No metrics backend, no scraping, no web UI — terminal output only. Does not modify cluster state.

Acceptance Criteria:
- AC-11; observable substrate of AC-2..AC-7.

### Requirement R9: Docker-stop demo, no Kubernetes (`make demo-shutdown`)

Source:
- business_input.md §8; deck note 8 ("Harus pakai Kubernetes?" → "Tidak. Graceful shutdown berlaku di mana pun: Docker…")

Trigger:
- `make demo-shutdown` — Docker only, no k3d/kubectl needed.

Inputs:
- The two R1/R2 images (or ad-hoc `docker build` of them); the `/slow` endpoint's fixed 3 s.

Behavior:
- Leg 1 (naive): start the naive container; fire a request to `/slow`; while it is in flight, `docker stop` the container → the request **breaks**.
- Leg 2 (graceful): repeat with the graceful image → the in-flight request **completes with 200** (after its 3 s), and the container logs show shutdown steps 1–4 (`[shutdown] 1.` … `[shutdown] 4.`).
- The output **compares the two legs clearly**, e.g. `naive: curl: (52) Empty reply` vs `graceful: 200 OK after 3s`.

State/Data:
- Ephemeral containers; cleaned up after the demo (no leftover containers).

External Effects:
- Local Docker daemon only.

Negative Scope:
- No Kubernetes involvement; no cluster required. Does not run the watch panel.

Acceptance Criteria:
- AC-8.

### Requirement R10: Makefile — one command per demo scenario

Source:
- business_input.md §9 (exact target list); PRD secondary deliverable "Makefile one-command targets"

Trigger:
- `make <target>` by the presenter (right tmux pane during recording).

Inputs:
- `S=<strategy>` variable for `reset`.

Behavior:
- Targets exactly as §9 lists (names contractual):
  - `cluster` → `scripts/setup-cluster.sh`
  - `watch` → traffic panel
  - `reset S=<strategy>` → prepare the v1 initial state for that strategy
  - `recreate` → reset + `pipeline.sh recreate` (VERSION=v2)
  - `rolling` → reset + `pipeline.sh rolling`
  - `rolling-naive` → reset with the **naive** app as v1, then rolling to **naive v2** → 502s visible
  - `bluegreen` → reset + switch to green
  - `bluegreen-rollback` → switch back instantly
  - `canary` → reset + canary success path
  - `canary-bad` → reset + canary with `FAIL_RATE=0.3` → rollback
  - `demo-shutdown` → R9
  - `clean` → delete the k3d cluster
- Strategy targets imply their own reset (self-contained one-command demos). **Accepted decision (design review 2026-11-09-01, INFO-5): `VERSION=v2` is the default for ALL demo targets** — `make recreate`, `make rolling`, `make rolling-naive`, `make bluegreen`, `make canary`, `make canary-bad` — not a `recreate`-only literal (§9 annotates it on `recreate` as an example, not a scoping). Rationale: the panel color contract (R8/§1 — v1 grey/white, **v2 cyan**, any other version yellow) needs the literal string `v2` on the new version so recordings read v1→v2.

State/Data:
- none of its own; delegates to the scripts.

External Effects:
- Delegates to R5–R9 commands.

Negative Scope:
- No `test`/`lint` wrappers beyond what the pipeline already runs; no targets that modify `deck.html`/`demo-strategies.md`.

Acceptance Criteria:
- AC-1..AC-8 invocation surface; named by every demo AC.

### Requirement R11: README (Bahasa Indonesia) + MIT LICENSE

Source:
- business_input.md §11; deck.html slide 3 (exact analogy wording — binding per OQ-001) + slides 3/8 (decision guidance); PRD OQ-003 (MIT)

Trigger:
- A public visitor reads the repo; the presenter links it after the session.

Inputs:
- Deck slide-3 exact analogy strings (quoted in Behavior).

Behavior:
- **README.md entirely in Bahasa Indonesia** (audience: SMK students, university students, professionals — must be easy to read), containing every §11-required piece:
  - One paragraph per strategy using the **exact deck slide-3 wording** for the analogy column: recreate = "Tutup toko, renovasi"; rolling = "Ganti kasir satu-satu"; blue-green = "Buka toko kembar"; canary = "Menu baru ke 10% tamu".
  - Per-strategy "pakai kalau…" matching deck slides 3/8: recreate kalau v1 & v2 tidak bisa jalan bersamaan; rolling sebagai default untuk service stateless; blue-green kalau butuh rollback instan; canary kalau traffic besar dan metrik bisa dipercaya.
  - Prerequisites with version-check commands: Docker, k3d, kubectl, Go 1.22+; bash on Linux, macOS, or Windows via WSL2.
  - Quick start: `make cluster` → open two terminals (`make watch` + `make <strategy>`).
  - Section "Kenapa kodenya begini?": the 4 graceful-shutdown steps, liveness vs readiness, `-ldflags` versioning, why digest pinning.
  - Section "Tanpa Kubernetes?": `make demo-shutdown` with Docker only.
  - Short troubleshooting: port 8080 in use, Envoy Gateway not ready, etc.
- **LICENSE** at repo root: MIT license text, copyright the speaker (David Geraldo — deck slide 1), so the repo is share-ready.

State/Data:
- none.

External Effects:
- none.

Negative Scope:
- No publishing/push to any git host (OQ-003). No changes to `deck.html` to fill its slide-8 repo link (OQ-SA-003). README is not a slide-deck copy — it references the deck's wording for the analogy strings only.

Acceptance Criteria:
- AC-13; AC-17 (LICENSE + untouched inputs).

### Requirement R12: Negative scope — what this repo must never contain

Source:
- business_input.md §2; PRD Out-of-scope; OQ-002/OQ-003/OQ-005 decisions

Trigger:
- Always (guard rails evaluated at every stage).

Inputs:
- none.

Behavior:
- The following are excluded and mechanically guarded (Verification Commands): cloud provider/infra manifests; service mesh (Istio/Linkerd/etc.); Argo Rollouts / Flagger; Prometheus or any external metrics stack; GitHub Actions or any hosted CI (`.github/workflows`); image references by mutable tag after the push stage; edits to `demo-strategies.md` or `deck.html`.

State/Data:
- none.

External Effects:
- none.

Negative Scope:
- Also out of scope per PRD: producing screen recordings/video (repo only needs recording-friendly output: `--compact`, env overrides like `OBSERVE_SECONDS=30`, tmux-friendly output — OQ-005); publishing/hosting the repo publicly (OQ-003); modifying the slide deck (it is the speaker's own material).

Acceptance Criteria:
- AC-17; guards in `## Verification Commands`.

## Source Evidence

All citations verified by SA in this run (files read end-to-end):

- **`demo-strategies.md`** (repo root, 14,639 bytes, commit `541bdb1`) — read in full; §1–§12 are the binding requirement sections cited throughout as `§N`. Its verbatim workspace copy is `0-input/business_input.md`.
- **`deck.html`** (repo root, 645,675 bytes) — SA independently extracted all 8 slide sections and all 8 speaker-note attributes (base64 data-URIs stripped). Verified the PRD's reconciliation claims:
  - Slide 5 code block is the graceful-shutdown 4-step sequence with the exact comments (`// 1. SIGTERM masuk` … `// 4. selesaikan request yang sedang jalan`) and the line `5 + 20 = 25 detik < terminationGracePeriodSeconds (default 30)` — identical in substance to §4.
  - Slide 5 speaker note (verbatim): "error handling ListenAndServe di slide sengaja disingkat. Versi lengkapnya (cek errors.Is(err, http.ErrServerClosed)) ada di repo demo." → R1's `errors.Is` addition is deck-sanctioned, not a deviation.
  - Slide 6 shows the `/readyz` handler writing `http.StatusServiceUnavailable` only when `!ready.Load()`, and `var version = "dev"` with the `-ldflags` comment → R1 endpoint semantics.
  - Slide 3 analogy column exact strings: "Tutup toko, renovasi" / "Ganti kasir satu-satu" / "Buka toko kembar" / "Menu baru ke 10% tamu" → R11 binding wording.
  - Slide 7 note (verbatim): "panel mencetak berapa detik downtime-nya", "10% traffic ke versi baru lewat weight di HTTPRoute Gateway API, tanpa service mesh", "[ganti dengan ambang Anda, misalnya di bawah 1%]" (presenter-adjustable threshold — consistent with §6 default `MAX_ERROR_RATE=0.01`), "dipromosikan ke 100% dengan digest yang sama, bukan build ulang".
  - Slide 8 decision tree + "Coba minggu ini" (graceful shutdown, /readyz, /version) → R11 "pakai kalau…" guidance.
- **`1-po/output/open-question-answers.md`** (+ JSON) — OQ-001..005 decisions (deck supplied as canonical reference; repo root = case dir; public-ready + MIT; Linux acceptance; recordings out of scope) — all folded above.
- **`0-input/supplement-speaker-context.md`** — session context: 10 Nov 2026 19:00, 10–12 min live webinar, mixed SMK/university/professional audience, each speaker authors own material.
- **`0-input/source.json`** — `source_type: local_file`, `detected_mode: sparse`, no repo binding → greenfield confirmed.
- **`_state/human-amendment-20261109T0855-round1.md`** — human-approved amendments from design review 2026-11-09-01 (read in full, all five dispositions folded into this revision): WARNING-1 — R6 owns the ±300 ms `RESPONSE_DELAY_MS` demo-manifest setting for all four strategies, citing §4's "Di manifest demo, set ±300 ms untuk semua strategi…" sentence (re-verified against `0-input/business_input.md` in this run); INFO-2 — accepted digest-guard template shape `image: ${REGISTRY}/app@sha256:${DIGEST}`; INFO-3 — direction-aware `🔀 SWITCH` marker; INFO-4 — reset's initial-v1 build/push via the shared build path; INFO-5 — `VERSION=v2` as the demo-target default (required by the panel color contract). Fold sites: R1 pointer, R6 Inputs/Behavior, R7 `release_bluegreen`, R10, AC-14/AC-16 guidance, Task phase 5, `## Verification Commands`, Planner Verification #3.
- **Target repo git state** — `git log --oneline -5` → single commit `541bdb1` "chore: initial snapshot — spec + slide deck inputs"; `git remote -v` → empty (no origin; see frontmatter `source_repo_url_note`); worktree clean; branch `main`. Tracked files: exactly `demo-strategies.md` + `deck.html`.
- **Acceptance-machine toolchain (probed 2026-11-09)** — `make` 4.3, `bash` 5.1.16, `curl` 7.81.0, `envsubst` 0.21, `kubectl` present; `go` 1.22.5 at `$HOME/go/bin/go` (GOROOT tree, needs `GOROOT=$HOME/go`, off default PATH); **`docker` and `k3d` absent** (no dpkg packages, no `/var/run/docker.sock`, no binary) — OQ-SA-001.

## System Boundary

**This repo owns:**
- The Go application source (graceful + naive variants), its tests, `go.mod`, Dockerfile.
- The local-cluster provisioning script, Gateway manifests, workload/route templates, reset semantics.
- The pipeline (test → build → push digest → release strategy → summary), the traffic panel, the docker-stop demo, the Makefile, README, LICENSE.

**This repo accepts:**
- User input only via CLI args (`<strategy>`, `S=<strategy>`, `--compact`) and environment variables (`PORT`, `FAIL_RATE`, `RESPONSE_DELAY_MS`, `SHUTDOWN_DELAY`, `SHUTDOWN_TIMEOUT`, `VERSION`, `APP`, `WORKERS`, `SWITCH_PAUSE`, `CANARY_WEIGHT`, `OBSERVE_SECONDS`, `MAX_ERROR_RATE`, `MIN_SAMPLES`). HTTP requests on its served port.

**This repo emits:**
- Terminal output (colored pipeline stages, panel lines, summaries, downtime/promote/rollback markers); container images to the local k3d registry (digest-addressable); Kubernetes objects in the local cluster; logs (`[shutdown] N. ...`).

**This repo calls:**
- Local binaries: `docker` (build/push/run/stop), `k3d` (cluster), `kubectl` (apply/patch/scale/rollout), `go` (test), `curl` (panel + canary analysis), `envsubst` (templates), `git` (short SHA). HTTP to `localhost:8080` and `localhost:5001` only.

**This repo does NOT own / does NOT touch:**
- `demo-strategies.md` and `deck.html` (inputs, byte-identical preservation). Any cloud provider. Any service mesh, Argo Rollouts/Flagger, Prometheus. GitHub Actions/hosted CI. The session's recordings/video. Publishing to a public git host. Anything outside the case dir `/home/davidgrldo/sandbox/golang/sharing-session/deploy-strategies-demo`.

**Cross-system data obligations:**
- Image digest is the contract between build stage and every release stage: digest string must flow unchanged from `docker push` output into manifests/patches; only the registry prefix differs between host and cluster (R5). `X-Version` header is the contract between the app and both the panel and the canary analysis (version strings must match exactly what `-ldflags` injected).

## Acceptance Criteria

Inherited verbatim from PRD (which adopted the §12 checklist as backbone); `§N` cites business_input.md, `deck` cites deck.html. Implementation guidance follows each AC.

- **AC-1 [primary]** `make cluster` succeeds from zero on a clean laptop, and every `make reset S=…` is repeatable. Acceptance environment is Linux (this machine) per OQ-004; README still documents Linux, macOS, and Windows via WSL2. (§12-1)
  Guidance: idempotency is the test — run `make cluster` twice, `make reset S=canary` twice; second runs must converge. Prerequisites (Docker, k3d) must be installed first on this machine (OQ-SA-001).
- **AC-2 [primary]** `make recreate`: the traffic panel shows downtime of more than 0 s — an ERR/5xx gap between v1 and v2, with the downtime duration printed. (§1 table, §7, §12-2; deck slide 7 clip 1)
  Guidance: recreate strategy (`strategy.type: Recreate`) guarantees old pods die before new pods start; the panel's consecutive-ERR span detector prints `⛔ downtime X.Xs` on recovery.
- **AC-3 [primary]** `make rolling`: v1 and v2 mix gradually during the rollout with 0 errors. (§1 table, §12-3; deck slide 7 clip 2)
  Guidance: `maxUnavailable: 0` + graceful shutdown (readiness gate + 5 s drain + 20 s finish) is what makes 0 errors achievable; with ±300 ms `RESPONSE_DELAY_MS` in the manifest there are always in-flight requests to protect.
- **AC-4 [primary]** `make rolling-naive`: 5xx/ERR appear during the rollout, reproducibly across 3 consecutive attempts (if not, raise `WORKERS` or `RESPONSE_DELAY_MS`). (§1 bonus, §12-4; deck slide 4 + slide 7 clip 2)
  Guidance: naive pods die instantly on SIGTERM while the gateway still routes to them → visible ERR burst; the retry/escalation rule is part of the AC (§12-4 parenthetical).
- **AC-5 [primary]** `make bluegreen`: 100% v1 to 100% v2 within ≤ 2 s; `make bluegreen-rollback` returns to v1 within ≤ 2 s; 0 errors throughout. (§1 table, §12-5; deck slide 7 clip 3)
  Guidance: switch is a weights-only change (no pod churn) — speed comes from not touching workloads; measure from the `🔀 SWITCH` line to the panel flipping.
- **AC-6 [primary]** `make canary`: ~10% v2 during the observation window, ends with `PROMOTED`, 0 errors during promote. (§1 table, §6, §12-6; deck slide 7 clip 4)
  Guidance: promote must reuse the same digest (no rebuild); weight flip stable 100/canary 0 then scale-to-zero.
- **AC-7 [primary]** `make canary-bad`: ends with `ROLLBACK` and exit code ≠ 0; the panel returns to 100% v1. (§1 table, §6, §12-7; deck slide 7 clip 5)
  Guidance: `FAIL_RATE=0.3` on the canary workload only; `/healthz`+`/readyz` stay green (R1) while `/version` 500s — that contrast is the clip's teaching point; early-stop once clearly failing is allowed.
- **AC-8 [secondary]** `make demo-shutdown` clearly shows the naive-vs-graceful difference (naive request breaks; graceful completes 200 with shutdown steps 1–4 logged). (§8, §12-8)
- **AC-9 [primary]** `go vet ./...` and `go test ./...` are clean. (§12-9)
- **AC-10 [primary]** `main.go` shutdown logic is identical to the canonical slide reference (deck.html slide 5 = §4 code block): 4-step order and variable names `ready`, `version`, `srv`, `stop`, `sctx`, `cancel`; `ready` is `atomic.Bool`; delays env-tunable with 5 s / 20 s defaults — plus the deck-acknowledged repo addition: `ListenAndServe` error check via `errors.Is(err, http.ErrServerClosed)` with log-fatal on other errors. (§4, §12-10; deck slide 5 speaker notes)
  Guidance: "identical" means steps 1–4 order, comments, and the named variables — the `errors.Is` wrapper around the goroutine's error is the ONLY sanctioned addition.
- **AC-11 [secondary]** Traffic panel robustness: never crashes when the gateway is unresponsive (prints `ERR` and continues); prints downtime duration on recovery; `--compact` shows summary only. (§7)
- **AC-12 [secondary]** All knobs env-overridable: `OBSERVE_SECONDS`, `MAX_ERROR_RATE`, `MIN_SAMPLES`, `CANARY_WEIGHT`, `SWITCH_PAUSE`, plus `VERSION`, `APP`, `WORKERS`. (§6, §7)
- **AC-13 [secondary]** README (Bahasa Indonesia) contains all §11-required sections: per-strategy analogies using the deck slide-3 exact wording ("Tutup toko, renovasi" / "Ganti kasir satu-satu" / "Buka toko kembar" / "Menu baru ke 10% tamu"), "pakai kalau…" matching deck slides 3/8, prerequisites with version checks, quick start, "Kenapa kodenya begini?", "Tanpa Kubernetes?", troubleshooting. (§11; OQ-001)
- **AC-14 [secondary]** Manifest conventions hold: images referenced by digest only after the push stage; probes on `/healthz` + `/readyz` with `periodSeconds: 2`; explicit `terminationGracePeriodSeconds: 30` with the `# 5 + 20 = 25 < 30` comment; replicas 3 (canary 1); `FAIL_RATE` never affects `/healthz` / `/readyz`. (§4, §5)
  Guidance: demo manifests additionally carry `RESPONSE_DELAY_MS=300` on all four strategies' workloads (R6, §4 — design review WARNING-1); without guaranteed in-flight requests, AC-3's 0-error and AC-4's reproducibility premises weaken. Mechanically guarded in `## Verification Commands`.
- **AC-15 [secondary]** Naive process exits immediately on SIGTERM as PID 1 inside the container; its `/readyz` always returns 200; it supports `RESPONSE_DELAY_MS` and `FAIL_RATE`. (§4)
- **AC-16 [secondary]** Blue-green slot alternation: the pipeline records the active slot (e.g. HTTPRoute annotation) so consecutive `bluegreen` invocations alternate slots, and `bluegreen-rollback` switches back instantly. (§6)
  Guidance: the `🔀 SWITCH` marker is direction-aware (R7 — design review INFO-3): on a second consecutive `make bluegreen` it must print `green → blue`. Checkers must NOT hardcode `blue → green` as the only valid literal — the §6 string is first-switch example wording.
- **AC-17 [secondary]** An MIT `LICENSE` file exists at the repo root (copyright the speaker) so the repo is public-ready; no publishing/push to any git host is performed by this case, and the pre-existing `demo-strategies.md` + `deck.html` in the repo root remain untouched. (OQ-002, OQ-003)

## Tasks

Phases at architectural granularity; ordering encodes dependencies. File paths below are the §3 contractual layout, not suggestions.

1. **Repo skeleton + Go application** — `go.mod` (Go 1.22+, stdlib only), root `main.go` implementing R1 exactly (endpoints, `X-Version` everywhere, `FAIL_RATE`, `RESPONSE_DELAY_MS`, `PORT`, the 4-step graceful shutdown with contractual variable names + `[shutdown] N.` logs + `errors.Is` wrapper, `SHUTDOWN_DELAY`/`SHUTDOWN_TIMEOUT` knobs), `main_test.go` covering `/healthz`, `/readyz`, `/version`. Why first: every other phase consumes this binary; AC-9/AC-10 are provable immediately. Exit gate: `go vet` + `go test` + `gofmt` clean.
2. **Naive variant** — `naive/main.go` per R2 (same endpoints/envs, plain `ListenAndServe`, `/readyz` always 200, no signal handling). Depends on phase 1's endpoint semantics only (copy the handler bodies, strip the shutdown scaffolding). Exit gate: compiles; `go vet ./...` still clean repo-wide.
3. **Dockerfile** — multi-stage static build (CGO off), distroless/scratch runtime, `ARG APP=main|naive`, `-ldflags` version wiring, PID-1-faithful entrypoint. Depends on phases 1–2. Exit gate: `docker build` twice (`APP=main`, `APP=naive`) succeeds (requires Docker — OQ-SA-001).
4. **Cluster setup + gateway** — `scripts/setup-cluster.sh` (k3d + local registry + host/in-cluster registry-prefix handling + Traefik disabled + Envoy Gateway via Gateway API v1 standard channel + idempotent) and `deploy/gateway.yaml` (GatewayClass + Gateway). Exit gate: `make cluster` twice; `curl http://localhost:8080` reaches the gateway (404/no-route is fine at this stage).
5. **Workload/route templates + reset** — `deploy/base/` generic Deployment+Service templates (envsubst; image shape `image: ${REGISTRY}/app@sha256:${DIGEST}`), `deploy/httproute.yaml` weight template, digest-pinning + probes (`periodSeconds: 2`) + `terminationGracePeriodSeconds: 30` with `# 5 + 20 = 25 < 30` comment + per-strategy shapes **each carrying `RESPONSE_DELAY_MS=300`** (R6, §4 — design review WARNING-1), `scripts/reset.sh <strategy>` (builds/pushes the initial v1 via the shared build path before creating the shapes — INFO-4), `deploy/README.md`. Depends on phase 4. Exit gate: `make reset S=<each>` repeatable; rendered manifests show digest refs, the `RESPONSE_DELAY_MS` env (300), and the literal comment.
6. **Shared script library + traffic panel** — `scripts/lib.sh` (colored stage headers with durations, `set_weights`, `wait_rollout`, registry-prefix rewrite, digest capture) and `scripts/watch.sh` (workers, colors, ~2 s summaries, downtime detection, ERR resilience, `--compact`). Panel is independent of the pipeline; build it now so later phases are observable. Exit gate: `bash -n` clean; panel runs against a dead gateway without crashing.
7. **Pipeline + release strategies** — `scripts/pipeline.sh` with common stages 1–5 and `release_recreate` / `release_rolling` / `release_bluegreen` (slot memory + `SWITCH_PAUSE`) / `release_canary` (analysis loop, promote/rollback, exit codes) + `bluegreen-rollback`. Depends on phases 3–6. Exit gate: AC-2..AC-7 panel signatures observable.
8. **Makefile + docker-stop demo** — all §9 targets exactly named, including `rolling-naive`, `bluegreen-rollback`, `canary-bad` (`FAIL_RATE=0.3`), `demo-shutdown` two-leg comparison with cleanup, `clean`. Exit gate: AC-8 output comparison; `make -n` dry-runs resolve every target.
9. **README + LICENSE** — Bahasa-Indonesia README with every §11 section and the exact deck slide-3 analogy strings; MIT LICENSE (copyright David Geraldo). Last because it documents the final surface. Exit gate: AC-13 checklist + AC-17.

## Implementation Hints

Non-binding candidates — Planner must verify before adoption. No Figma; hints derive from the spec's own suggestions, the deck's speaker notes, and this machine's verified toolchain.

- `verified_candidate` — **Toolchain facts on the acceptance machine** (probed 2026-11-09): `envsubst` 0.21 present (the §3 template-substitution mechanism works as specified); `make` 4.3, `bash` 5.1.16, `curl` 7.81.0 present; `kubectl` present; Go 1.22.5 at `$HOME/go/bin/go` with `GOROOT=$HOME/go` required (see OQ-SA-002 for the invocation prefix); `docker`/`k3d` absent (OQ-SA-001). Evidence: version probes in Source Evidence.
- `unverified_candidate` — **k3d cluster creation flags**: `k3d cluster create --port "8080:80@loadbalancer"` to map host 8080 to the Envoy Gateway's LoadBalancer service, plus `--registry-create` (or a `registries.yaml` with an alias) for the localhost:5001 registry and its in-cluster name; `--k3s-arg "--disable=traefik@server:0"` (or `--disable-traefik`) to drop bundled Traefik. Standard k3d patterns, unverifiable offline (Docker absent) — Planner verifies against the k3d version actually installed.
- `unverified_candidate` — **Envoy Gateway install**: helm OCI chart `oci://docker.io/envoyproxy/gateway-helm` (namespace `envoy-gateway-system`) + Gateway API v1 **standard** channel CRDs from the official Gateway API release YAML; pin a chart/app version in the script for reproducibility even though §5 says "latest stable". Verify current stable version at implementation time.
- `unverified_candidate` — **Docker base images**: builder `golang:1.22-alpine` (or `golang:1.22` with apk cache considerations) and runtime `gcr.io/distroless/static-debian12` or plain `scratch` (pure-stdlib Go binary with CGO off needs nothing else — no CA certs required since the app makes no outbound TLS calls). Verify pullability at implementation time.
- `unverified_candidate` — **Digest capture**: parse the `digest: sha256:...` line from `docker push` output, or `docker image inspect --format '{{index .RepoDigests 0}}'` after push. Either is fine; only the digest string may flow onward (R7).
- `unverified_candidate` — **HTTPRoute weight mutation**: re-render the `deploy/httproute.yaml` template via envsubst and `kubectl apply` (simple, matches §3's "template, weight di-substitusi"), or `kubectl patch` the `backendRefs`. Template re-apply is the more demo-legible choice (audience sees the YAML change).
- `unverified_candidate` — **Blue-green slot memory** (§6 suggests "mis. di annotation HTTPRoute"): store the active slot in an HTTPRoute annotation (`demo/active-slot: blue|green`) read/written via `kubectl annotate --overwrite`; `bluegreen-rollback` reads it and flips. §6 marks the mechanism as example ("mis."), so any durable equivalent satisfies AC-16 — but the annotation keeps state visible in-cluster for the demo.
- `unverified_candidate` — **Rolling progress lines** (`updated 1/3 … 3/3`): parse `kubectl rollout status` output, or poll `kubectl get deployment -o jsonpath` over `updatedReplicas`/`readyReplicas`. JSONpath polling is more robust across kubectl versions.
- `unverified_candidate` — **Canary analysis loop**: single bash loop `curl -sS -D -` to `localhost:8080/version`, read the `X-Version` header, count only canary-version responses and their non-2xx status; `sleep` pacing; progress print every ~10 s. The pipeline's own loop replaces Prometheus by design (§2) — keep it visibly simple (teaching artifact).
- `unverified_candidate` — **Watch panel architecture**: `WORKERS` background subshells appending `ts status version` lines to a temp file/FIFO, one aggregator printing per-response colored lines and a ~2 s windowed summary; consecutive-ERR span tracked with epoch timestamps to print `⛔ downtime X.Xs` at recovery. Any equivalent structure satisfies R8.
- `unverified_candidate` — **Naive immediate-exit as PID 1**: the Go runtime installs its own signal handling, so a program with no `signal.Notify` still dies on SIGTERM even as PID 1 — no extra code needed in `naive/main.go` (the absence of handling IS the behavior). Widely-documented Go behavior; verify empirically via AC-15/AC-8 once Docker is available.
- `unverified_candidate` — **`go.mod` module name**: any valid module path works (stdlib-only, no imports across modules beyond `naive` being its own program in the same module or a nested one — simplest: one module at root, `naive/main.go` as a second main fileset built by path). Planner picks; nothing in the requirement constrains it.
- `rejected_candidate` — **Argo Rollouts / Flagger for canary analysis** — explicitly banned by §2 ("tanpa Argo Rollouts/Flagger"); deck note 8 mentions them only as alternatives the AUDIENCE could choose, not this repo.
- `rejected_candidate` — **Prometheus + recording rules for canary metrics** — explicitly banned by §2; the pipeline's own traffic counting is the analysis mechanism (R7).
- `rejected_candidate` — **GitHub Actions workflow for the pipeline** — explicitly banned by §2 (bash so it can run/record live); `.github/workflows` must not exist.
- `rejected_candidate` — **K3s bundled Traefik as the Gateway** — explicitly disabled by §5; Envoy Gateway + Gateway API HTTPRoute is the mandated traffic-splitting mechanism.
- `rejected_candidate` — **Editing deck.html to fill slide-8's "[link repo demo]" placeholder** — AC-17 forbids any deck modification; the placeholder is the speaker's post-publish concern (OQ-SA-003).

## Verification Commands

Run from the repo root (`/home/davidgrldo/sandbox/golang/sharing-session/deploy-strategies-demo`). Static block requires nothing beyond this machine's current state; cluster block requires Docker Engine + k3d installed first (OQ-SA-001). Expectations stated per command.

```bash
# --- Static checks (runnable now) -----------------------------------------
cd /home/davidgrldo/sandbox/golang/sharing-session/deploy-strategies-demo

# Go toolchain on this machine lives at $HOME/go (trimmed GOROOT tree) —
# export the prefix below once per shell; on a normal install plain `go` works.
export PATH="$HOME/go/bin:$PATH" GOROOT="$HOME/go"
go version          # expect: go version go1.22.5 linux/amd64 (or newer 1.22+)

go vet ./...        # AC-9: expect exit 0, no output
go test ./...       # AC-9: expect exit 0, all tests pass
test -z "$(gofmt -l . )" && echo "gofmt: clean" || { echo "gofmt: UNFORMATTED FILES"; gofmt -l .; }

bash -n scripts/pipeline.sh scripts/lib.sh scripts/reset.sh scripts/setup-cluster.sh scripts/watch.sh
# expect: exit 0, no output (all shell scripts syntactically valid)

make -n cluster watch recreate rolling rolling-naive bluegreen bluegreen-rollback canary canary-bad demo-shutdown clean
# expect: exit 0 — every AC-named target exists and resolves (dry run; no cluster needed)
make -n reset S=recreate     # expect: exit 0 — reset target honors the S variable

# --- Negative / no-change guards (AC-17, R12) ------------------------------
git status --porcelain -- demo-strategies.md deck.html   # expect: no output (both untouched)
git diff --stat -- demo-strategies.md deck.html          # expect: no output (zero line changes)

grep -rniE "flagger|argo|prometheus|istio|linkerd" \
  --include="*.yaml" --include="*.yml" --include="*.go" \
  deploy/ naive/ main.go main_test.go Dockerfile 2>/dev/null \
  && echo "FAIL: forbidden tooling reference in code/manifests" \
  || echo "PASS: no forbidden tooling in code/manifests"

grep -rnE "helm (install|upgrade)[^|;]*(argo|flagger|prometheus)|kubectl apply[^|;]*(argo|flagger)" scripts/ \
  && echo "FAIL: forbidden tooling install in scripts" \
  || echo "PASS: no forbidden tooling installs"

test ! -d .github/workflows && echo "PASS: no hosted CI (no .github/workflows)" || echo "FAIL: .github/workflows exists"

head -1 LICENSE && grep -qi "MIT" LICENSE && echo "PASS: MIT LICENSE present" || echo "FAIL: LICENSE missing/not MIT"

# --- Digest-only convention (AC-14) — rendered manifests must pin digests --
# Accepted envsubst template shape (design review INFO-2): image: ${REGISTRY}/app@sha256:${DIGEST}
# — the literal "@sha256:" lives in the template; any image: line lacking it fails the guard.
grep -R "image:" deploy/ | grep -v "@sha256:" \
  && echo "FAIL: image line without @sha256: — use the accepted shape image: \${REGISTRY}/app@sha256:\${DIGEST}" \
  || echo "PASS: templates carry digest-pinned images"
grep -R "RESPONSE_DELAY_MS" deploy/ scripts/reset.sh | grep -q "300" \
  && echo "PASS: ±300 ms demo latency (RESPONSE_DELAY_MS) present in manifests/reset defaults (R6, WARNING-1)" \
  || echo "FAIL: RESPONSE_DELAY_MS=300 missing from deploy/ templates and reset.sh defaults"
grep -R "terminationGracePeriodSeconds: 30" deploy/ >/dev/null && echo "PASS: TGP 30 present"
grep -R "5 + 20 = 25" deploy/ >/dev/null && echo "PASS: arithmetic comment present (full literal: 5 + 20 = 25 < 30)"

# --- Cluster + demo acceptance (requires Docker Engine + k3d — OQ-SA-001) --
make cluster && make cluster        # AC-1: idempotent — both runs succeed
make reset S=recreate && make reset S=recreate   # AC-1: reset repeatable
make recreate                       # AC-2: panel shows ERR gap + downtime line (run make watch alongside)
make rolling                        # AC-3: v1/v2 mix, 0 errors
make rolling-naive                  # AC-4: ERR/5xx visible — repeat 3x to confirm reproducibility
make bluegreen && make bluegreen-rollback   # AC-5: each switch within 2 s, 0 errors
make canary                         # AC-6: ~10% v2 window, ends PROMOTED
make canary-bad; echo "exit=$?"     # AC-7: ends ROLLBACK, exit non-zero; panel back to 100% v1
make demo-shutdown                  # AC-8: naive broken vs graceful 200 + [shutdown] 1-4 logs
make clean                          # teardown works
```

## Planner Verification Requirements

Plain-English checks SA knows the intent of but which need a live cluster or human eyes; Planner/Coder/Tester translate them after reading the actual repo:

1. **Slide-conformance of `main.go` (AC-10)**: place deck.html slide 5's code block and the repo's shutdown sequence side by side; steps 1–4, their numbered comments, and the identifiers `ready`, `version`, `srv`, `stop`, `sctx`, `cancel` must match exactly, `ready` is `atomic.Bool`, and the only difference is the deck-acknowledged `errors.Is(err, http.ErrServerClosed)` wrapper with log-fatal on other errors.
2. **Panel signatures under live traffic (AC-2..AC-7)**: with `make watch` in one pane, each `make <strategy>` in another must produce its §1-table signature — recreate: bold-red ERR span between v1 and v2 lines and a `⛔ downtime X.Xs` line on recovery; rolling: interleaved v1/v2 lines with `err 0` in every ~2 s summary; bluegreen: summary flips 100%→100% essentially between two summary lines and back on rollback; canary: ~10% v2 share during observation, then `✅ PROMOTED ... → 100%`; canary-bad: `❌ ROLLBACK: ...` and the panel returns to 100% v1.
3. **Timing claims (AC-5)**: the bluegreen switch and rollback each complete within 2 s as observed from the `🔀 SWITCH` print to the panel flip — if weights-only switching is implemented correctly this holds trivially; if pod churn sneaks in, it won't. The `🔀 SWITCH` marker itself is direction-aware (design review INFO-3): on a second consecutive `make bluegreen` invocation it must read `green → blue` (slot alternation, AC-16) — never a hardcoded `blue → green`.
4. **Reproducibility escalation rule (AC-4)**: run `make rolling-naive` three consecutive times; if the ERR burst fails to appear in any run, raise `WORKERS` or `RESPONSE_DELAY_MS` per §12-4 rather than weakening the check.
5. **Env knobs actually override (AC-12)**: spot-check at least `VERSION=v2` (panel shows v2 not a SHA), `APP=naive` (naive build path), `OBSERVE_SECONDS=30` (canary window visibly ~30 s), `SWITCH_PAUSE=1` (bluegreen pause shortens).
6. **Digest-only flow (AC-14)**: after the push stage prints `image: …@sha256:…`, no subsequent command or manifest references a tag; the canary promote step reuses the same digest string as the canary deploy step (diff the two printed digests — must be equal).
7. **Idempotency (AC-1)**: `make cluster` and each `make reset S=…` run twice in a row without error and converge to the same state.
8. **README completeness vs deck (AC-13)**: check each §11 bullet is present, the four analogy strings match deck slide 3 exactly, and the "pakai kalau…" guidance matches deck slides 3/8; prerequisites section shows working version-check commands.
9. **Recording-friendliness (OQ-005)**: `make watch --compact`-equivalent (`./scripts/watch.sh --compact`) shows only summary lines; pipeline output fits a tmux right pane without horizontal scrolling.
10. **Exit-code contract (AC-7)**: `make canary-bad` must exit non-zero (rollback is a failure outcome for the pipeline), while `make canary` exits zero.

## Open Questions

All five PO OQs were resolved at the PO clarification gate (2026-11-09T08:32; see `1-po/output/open-question-answers.md`) and are folded into the contract above — none remain open. SA-derived questions (full JSON in `open-questions.json`):

- **OQ-SA-001 (important, verified)** — Docker Engine + k3d are absent on the acceptance machine (Linux, this machine) at SA time; AC-1..AC-8 need them installed before live acceptance. Environment-prep gap, not a spec ambiguity — static checks run now. Evidence: dpkg/`command -v`/docker.sock probes, all empty.
- **OQ-SA-002 (INFO, verified)** — Go 1.22.5 lives at `$HOME/go` as a trimmed GOROOT tree: binary `$HOME/go/bin/go`, requires `GOROOT=$HOME/go`, off default PATH. Verification commands embed the prefix; README keeps normal-user `go version` checks.
- **OQ-SA-003 (INFO, verified)** — deck.html slide 8's `[link repo demo]` placeholder stays unresolved by design (AC-17 forbids deck edits; publishing is out of scope). Do not "fix" it.
