# Makefile — satu perintah per skenario demo (§9).
# Semua target strategi MANDIRI: mereka me-reset kondisi awal dulu, jadi
# cukup jalankan `make <strategi>` (pastikan `make cluster` + `make watch`
# sudah jalan di terminal lain).
#
# Versi baru untuk semua target demo default v2 (bisa di-override):
#   make recreate VERSION=v3
S ?=
VERSION ?= v2

.PHONY: cluster dashboard watch reset recreate rolling rolling-naive bluegreen bluegreen-rollback canary canary-bad demo-shutdown clean

cluster: ## siapkan k3d + registry lokal + Envoy Gateway (idempoten)
	./scripts/setup-cluster.sh

watch: ## panel traffic live (terminal kiri)
	./scripts/watch.sh

dashboard: ## dashboard interaktif: http://localhost:9090 (jalankan dari WSL/Linux)
	CGO_ENABLED=0 go run ./cmd/dashboard

reset: ## kembalikan cluster ke kondisi awal v1 strategi tsb: make reset S=canary
	./scripts/reset.sh $(S)

recreate: ## demo recreate: downtime nyata (VERSION=v2 default)
	./scripts/reset.sh recreate
	VERSION=$(VERSION) ./scripts/pipeline.sh recreate

rolling: ## demo rolling: v1/v2 tercampur, nol error
	./scripts/reset.sh rolling
	VERSION=$(VERSION) ./scripts/pipeline.sh rolling

rolling-naive: ## demo rolling TANPA graceful shutdown: 5xx/ERR terlihat
	APP=naive ./scripts/reset.sh rolling
	APP=naive VERSION=$(VERSION) ./scripts/pipeline.sh rolling

bluegreen: ## demo blue-green: pindah 100% seketika
	./scripts/reset.sh bluegreen
	VERSION=$(VERSION) ./scripts/pipeline.sh bluegreen

bluegreen-rollback: ## kembalikan traffic ke slot sebelumnya, seketika
	./scripts/pipeline.sh bluegreen-rollback

canary: ## demo canary: 10% → diamati → PROMOTED
	./scripts/reset.sh canary
	VERSION=$(VERSION) ./scripts/pipeline.sh canary

canary-bad: ## demo canary versi rusak (FAIL_RATE=0.3): ROLLBACK otomatis, exit ≠ 0
	./scripts/reset.sh canary
	VERSION=$(VERSION) FAIL_RATE=0.3 ./scripts/pipeline.sh canary

demo-shutdown: ## naive vs graceful saat docker stop — Docker saja, tanpa Kubernetes
	./scripts/lib.sh demo-shutdown

clean: ## hapus cluster k3d demo
	k3d cluster delete demo
