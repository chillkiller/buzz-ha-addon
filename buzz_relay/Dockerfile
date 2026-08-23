# ─────────────────────────────────────────────────────────────────────
# Buzz Relay HA Add-on — Dockerfile
# Multi-service container: Postgres + Redis + MinIO + buzz-relay + buzz-cli + buzz-acp
# Built for aarch64 (Raspberry Pi HAOS) and amd64
# ─────────────────────────────────────────────────────────────────────

ARG RUST_VERSION=1.95
ARG DEBIAN_VERSION=bookworm

# ── Stage 1: Build buzz-cli and buzz-acp from source ─────────────────
FROM rust:${RUST_VERSION}-${DEBIAN_VERSION} AS cli-builder
WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config libssl-dev ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# Shallow clone and build
RUN git clone --depth 1 https://github.com/block/buzz.git /build/buzz
WORKDIR /build/buzz
RUN cargo build --release --locked -p buzz-cli -p buzz-acp -p buzz-admin

# ── Stage 2: Extract buzz-relay + web UI from official image ─────────
FROM ghcr.io/block/buzz:main AS buzz-extract

# ── Stage 3: Runtime ─────────────────────────────────────────────────
FROM debian:${DEBIAN_VERSION}-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PATH="/usr/lib/postgresql/15/bin:${PATH}"

# Install runtime dependencies
# Postgres 15 ships with bookworm, no need for extra repos
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    openssl \
    postgresql-15 \
    redis-server \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Copy buzz-relay + buzz-pair-relay from the official image (pre-built for arm64)
COPY --from=buzz-extract /usr/local/bin/buzz-relay      /usr/local/bin/buzz-relay
COPY --from=buzz-extract /usr/local/bin/buzz-pair-relay /usr/local/bin/buzz-pair-relay

# Copy buzz-cli, buzz-acp, buzz-admin from our build stage
COPY --from=cli-builder /build/buzz/target/release/buzz       /usr/local/bin/buzz
COPY --from=cli-builder /build/buzz/target/release/buzz-acp   /usr/local/bin/buzz-acp
COPY --from=cli-builder /build/buzz/target/release/buzz-admin /usr/local/bin/buzz-admin

# Copy the Buzz Web-UI and Admin Web-UI from official image
COPY --from=buzz-extract /srv/buzz/web        /srv/buzz/web
COPY --from=buzz-extract /srv/buzz/admin-web  /srv/buzz/admin-web

ENV BUZZ_WEB_DIR=/srv/buzz/web
ENV BUZZ_ADMIN_WEB_DIR=/srv/buzz/admin-web

# Download MinIO (architecture-aware via TARGETARCH)
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      arm64)  MINIO_ARCH=arm64  ;; \
      amd64)  MINIO_ARCH=amd64  ;; \
      *)     echo "Unsupported arch: $TARGETARCH"; exit 1 ;; \
    esac && \
    curl -sSL -o /usr/local/bin/minio \
      "https://dl.min.io/server/minio/release/linux-${MINIO_ARCH}/minio" && \
    chmod +x /usr/local/bin/minio && \
    curl -sSL -o /usr/local/bin/mc \
      "https://dl.min.io/client/mc/release/linux-${MINIO_ARCH}/mc" && \
    chmod +x /usr/local/bin/mc

# Create data directories
RUN mkdir -p /data/postgres /data/redis /data/minio /data/git /data/keys

# Copy run script
COPY run.sh /run.sh
RUN chmod +x /run.sh

EXPOSE 3000

ENTRYPOINT ["/run.sh"]