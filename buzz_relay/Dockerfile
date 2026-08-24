# ─────────────────────────────────────────────────────────────────────
# Buzz Relay HA Add-on — Dockerfile
# Build everything from source (official ghcr.io image is private)
# ─────────────────────────────────────────────────────────────────────

ARG RUST_VERSION=1.95
ARG DEBIAN_VERSION=bookworm

# ── Stage 1: Build all Rust binaries from source ─────────────────────
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

# ── Stage 2: Runtime ─────────────────────────────────────────────────
FROM debian:${DEBIAN_VERSION}-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PATH="/usr/lib/postgresql/15/bin:${PATH}"

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    openssl \
    postgresql-15 \
    redis-server \
    jq \
    nginx \
    && rm -rf /var/lib/apt/lists/*

# Copy all binaries
COPY --from=rust-builder /build/buzz/target/release/buzz-relay      /usr/local/bin/buzz-relay
COPY --from=rust-builder /build/buzz/target/release/buzz            /usr/local/bin/buzz
COPY --from=rust-builder /build/buzz/target/release/buzz-acp        /usr/local/bin/buzz-acp
COPY --from=rust-builder /build/buzz/target/release/buzz-admin      /usr/local/bin/buzz-admin
COPY --from=rust-builder /build/buzz/target/release/buzz-pair-relay /usr/local/bin/buzz-pair-relay

# Download MinIO (architecture-aware)
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

# Create data and web directories
RUN mkdir -p /data/postgres /data/redis /data/minio /data/git /data/keys /var/www

# Copy files
COPY run.sh /run.sh
COPY landing.html /var/www/landing.html
RUN chmod +x /run.sh

EXPOSE 3000

ENTRYPOINT ["/run.sh"]