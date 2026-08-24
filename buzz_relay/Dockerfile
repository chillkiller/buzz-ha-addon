# ─────────────────────────────────────────────────────────────────────
# Buzz Relay HA Add-on — Dockerfile (single-stage build to avoid cache issues)
# Build everything from source (official ghcr.io image is private)
# ─────────────────────────────────────────────────────────────────────

FROM rust:1.95-bookworm AS builder
WORKDIR /build

# Install build deps for both Rust AND Node
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config libssl-dev ca-certificates git \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Node 24 for the web build
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*
RUN corepack enable

# Clone the repo
RUN git clone --depth 1 https://github.com/block/buzz.git /build/buzz
WORKDIR /build/buzz

# Build Rust binaries
RUN cargo build --release --locked \
    -p buzz-relay --bin buzz-relay \
    -p buzz-cli --bin buzz \
    -p buzz-acp --bin buzz-acp \
    -p buzz-admin --bin buzz-admin \
    -p buzz-pair-relay --bin buzz-pair-relay

# Build web UI (in the same stage — no cache issues)
RUN pnpm install --filter buzz-web --filter buzz-admin-web 2>&1
RUN pnpm -C web build 2>&1 && pnpm -C admin-web build 2>&1

# HARD VERIFY — fail the build if web UI wasn't produced
RUN test -f /build/buzz/web/dist/index.html || \
    (echo "FATAL: web/dist/index.html missing" && exit 1)
RUN test -f /build/buzz/admin-web/dist/index.html || \
    (echo "FATAL: admin-web/dist/index.html missing" && exit 1)

# ── Runtime stage ────────────────────────────────────────────────────
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PATH="/usr/lib/postgresql/15/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git openssl \
    postgresql-15 redis-server jq nginx \
    && rm -rf /var/lib/apt/lists/*

# Copy Rust binaries
COPY --from=builder /build/buzz/target/release/buzz-relay      /usr/local/bin/buzz-relay
COPY --from=builder /build/buzz/target/release/buzz            /usr/local/bin/buzz
COPY --from=builder /build/buzz/target/release/buzz-acp        /usr/local/bin/buzz-acp
COPY --from=builder /build/buzz/target/release/buzz-admin      /usr/local/bin/buzz-admin
COPY --from=builder /build/buzz/target/release/buzz-pair-relay /usr/local/bin/buzz-pair-relay

# Copy web UI (verified to exist above)
COPY --from=builder /build/buzz/web/dist        /srv/buzz/web
COPY --from=builder /build/buzz/admin-web/dist  /srv/buzz/admin-web

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