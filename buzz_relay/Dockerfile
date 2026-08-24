# ─────────────────────────────────────────────────────────────────────
# Buzz Relay HA Add-on — Dockerfile
# Builds from source following the official Buzz Dockerfile pattern.
# Official ghcr.io/block/buzz image is private (401).
# ─────────────────────────────────────────────────────────────────────

ARG RUST_VERSION=1.95
ARG NODE_VERSION=24
ARG DEBIAN_VERSION=bookworm

# ── Stage 1: Build all Rust binaries ────────────────────────────────
FROM rust:${RUST_VERSION}-${DEBIAN_VERSION} AS rust-builder
WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config libssl-dev ca-certificates git \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/block/buzz.git /build/buzz
WORKDIR /build/buzz
RUN cargo build --release --locked \
    -p buzz-relay --bin buzz-relay \
    -p buzz-cli --bin buzz \
    -p buzz-acp --bin buzz-acp \
    -p buzz-admin --bin buzz-admin \
    -p buzz-pair-relay --bin buzz-pair-relay

# ── Stage 2: Build web UI (follows official Buzz Dockerfile exactly) ─
FROM node:${NODE_VERSION}-${DEBIAN_VERSION}-slim AS web-builder
WORKDIR /build
RUN corepack enable
# Copy only the files needed for pnpm install (same as official Dockerfile)
COPY --from=rust-builder /build/buzz/package.json /build/buzz/pnpm-lock.yaml /build/buzz/pnpm-workspace.yaml ./
COPY --from=rust-builder /build/buzz/patches/ patches/
COPY --from=rust-builder /build/buzz/web/package.json web/
COPY --from=rust-builder /build/buzz/admin-web/package.json admin-web/
# Install with --frozen-lockfile --filter to skip the desktop package
RUN pnpm install --frozen-lockfile --filter buzz-web --filter buzz-admin-web
# Copy web source and build
COPY --from=rust-builder /build/buzz/web/ web/
COPY --from=rust-builder /build/buzz/admin-web/ admin-web/
RUN pnpm -C web build && pnpm -C admin-web build
# HARD VERIFY
RUN test -f /build/web/dist/index.html || (echo "FATAL: web/dist/index.html missing" && exit 1)
RUN test -f /build/admin-web/dist/index.html || (echo "FATAL: admin-web/dist/index.html missing" && exit 1)

# ── Stage 3: Runtime ────────────────────────────────────────────────
FROM debian:${DEBIAN_VERSION}-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PATH="/usr/lib/postgresql/15/bin:${PATH}"

# HA OCI labels (required when not using HA GitHub builder actions)
LABEL io.hass.type="app" \
      io.hass.arch="aarch64 amd64"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git openssl \
    postgresql-15 redis-server jq nginx \
    && rm -rf /var/lib/apt/lists/*

# Copy Rust binaries
COPY --from=rust-builder /build/buzz/target/release/buzz-relay      /usr/local/bin/buzz-relay
COPY --from=rust-builder /build/buzz/target/release/buzz            /usr/local/bin/buzz
COPY --from=rust-builder /build/buzz/target/release/buzz-acp        /usr/local/bin/buzz-acp
COPY --from=rust-builder /build/buzz/target/release/buzz-admin      /usr/local/bin/buzz-admin
COPY --from=rust-builder /build/buzz/target/release/buzz-pair-relay /usr/local/bin/buzz-pair-relay

# Copy web UI (verified to exist in Stage 2)
COPY --from=web-builder /build/web/dist        /srv/buzz/web
COPY --from=web-builder /build/admin-web/dist  /srv/buzz/admin-web

ENV BUZZ_WEB_DIR=/srv/buzz/web
ENV BUZZ_ADMIN_WEB_DIR=/srv/buzz/admin-web

# Download MinIO (architecture-aware)
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      arm64)  MINIO_ARCH=arm64  ;; \
      amd64)  MINIO_ARCH=amd64  ;; \
      *)     echo "Unsupported: $TARGETARCH"; exit 1 ;; \
    esac && \
    curl -sSL -o /usr/local/bin/minio \
      "https://dl.min.io/server/minio/release/linux-${MINIO_ARCH}/minio" && \
    chmod +x /usr/local/bin/minio && \
    curl -sSL -o /usr/local/bin/mc \
      "https://dl.min.io/client/mc/release/linux-${MINIO_ARCH}/mc" && \
    chmod +x /usr/local/bin/mc

RUN mkdir -p /data/postgres /data/redis /data/minio /data/git /data/keys /var/www

COPY run.sh /run.sh
COPY landing.html /var/www/landing.html
RUN chmod +x /run.sh

EXPOSE 3000
ENTRYPOINT ["/run.sh"]