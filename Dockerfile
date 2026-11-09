# Dockerfile — build satu image untuk dua program:
#   docker build --build-arg APP=main  --build-arg VERSION=v2 -t app:v2 .
#   docker build --build-arg APP=naive --build-arg VERSION=v2 -t naive:v2 .
#
# ARG APP memilih program (main = versi graceful, naive = tanpa graceful
# shutdown). VERSION masuk ke binary lewat -ldflags, persis seperti slide:
#   go build -ldflags "-X main.version=$(git rev-parse --short HEAD)"

# --- Tahap 1: builder ------------------------------------------------------
# CGO dimatikan supaya binary statis murni — bisa jalan di image runtime
# minimal tanpa dependensi libc.
FROM golang:1.22-alpine AS build
ARG APP=main
ARG VERSION=dev
WORKDIR /src
COPY go.mod ./
COPY main.go main_test.go ./
COPY naive/ ./naive/
RUN mkdir -p /out && CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X main.version=${VERSION}" \
    -o /out/app \
    $([ "${APP}" = "main" ] && echo "." || echo "./${APP}")

# --- Tahap 2: runtime ------------------------------------------------------
# distroless/static: tanpa shell, tanpa package manager — hanya binary statis.
# ENTRYPOINT bentuk exec (bukan shell) supaya binary jadi PID 1 dan menerima
# SIGTERM langsung dari `docker stop` / Kubernetes. Inilah yang membuat demo
# naive-vs-graceful jujur: sinyal tidak ditelan oleh shell wrapper.
FROM gcr.io/distroless/static-debian12
COPY --from=build /out/app /app
ENTRYPOINT ["/app"]
