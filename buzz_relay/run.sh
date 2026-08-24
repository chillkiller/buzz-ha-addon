#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Buzz Relay HA Add-on — Entrypoint
# Architecture (same as Hermes/OpenClaw addons):
#   nginx :3000 (Ingress) → buzz-relay :3001 (internal)
# nginx serves landing.html on / and proxies all other paths to the relay.
# Host header is rewritten to localhost:3001 so the relay's community always matches.
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# Clean up background services on exit
cleanup() {
    echo "[buzz] Shutting down..."
    redis-cli -a "${REDIS_PASSWORD:-}" shutdown nosave 2>/dev/null || true
    pkill minio 2>/dev/null || true
    su postgres -c "pg_ctl -D '${PGDATA:-/data/postgres}' stop -m fast" 2>/dev/null || true
    nginx -s stop 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── Read HA add-on options ───────────────────────────────────────────
OPTIONS_FILE="/data/options.json"
if [ ! -f "$OPTIONS_FILE" ]; then
    echo "[buzz] FATAL: $OPTIONS_FILE not found"
    exit 1
fi

opt()      { jq -r ".${1} // empty"    "$OPTIONS_FILE"; }
opt_bool() { jq -r ".${1} // false"    "$OPTIONS_FILE"; }
opt_or_gen() {
    local val
    val=$(jq -r ".${1} // empty" "$OPTIONS_FILE")
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        openssl rand -hex 32
    else
        echo "$val"
    fi
}

RELAY_PRIVATE_KEY=$(opt relay_private_key)
RELAY_OWNER_PUBKEY=$(opt relay_owner_pubkey)
REQUIRE_AUTH_TOKEN=$(opt_bool require_auth_token)
REQUIRE_RELAY_MEMBERSHIP=$(opt_bool require_relay_membership)
ALLOW_NIP_OA_AUTH=$(opt_bool allow_nip_oa_auth)
AUTO_MIGRATE=$(opt_bool auto_migrate)
RUST_LOG=$(opt rust_log)

# Generate stable secrets if not provided
POSTGRES_PASSWORD=$(opt_or_gen postgres_password)
REDIS_PASSWORD=$(opt_or_gen redis_password)
S3_ACCESS_KEY=$(opt_or_gen s3_access_key)
S3_SECRET_KEY=$(opt_or_gen s3_secret_key)

# Persist generated secrets
persist_secrets() {
    local tmp
    tmp=$(mktemp)
    jq --arg pg "$POSTGRES_PASSWORD" \
       --arg redis "$REDIS_PASSWORD" \
       --arg s3ak "$S3_ACCESS_KEY" \
       --arg s3sk "$S3_SECRET_KEY" \
       '.postgres_password = $pg | .redis_password = $redis | .s3_access_key = $s3ak | .s3_secret_key = $s3sk' \
       "$OPTIONS_FILE" > "$tmp" && mv "$tmp" "$OPTIONS_FILE"
}

generate_keys() {
    if [ -z "$RELAY_PRIVATE_KEY" ]; then
        echo "[buzz] Generating relay private key..."
        RELAY_PRIVATE_KEY=$(openssl rand -hex 32)
        local tmp
        tmp=$(mktemp)
        jq --arg rk "$RELAY_PRIVATE_KEY" '.relay_private_key = $rk' "$OPTIONS_FILE" > "$tmp" && mv "$tmp" "$OPTIONS_FILE"
        echo "[buzz] Relay private key generated and saved."
    fi
}

# ── Start Postgres ───────────────────────────────────────────────────
start_postgres() {
    echo "[buzz] Starting Postgres..."
    export PGDATA=/data/postgres

    if ! id postgres &>/dev/null; then
        useradd -r -m -d /var/lib/postgresql -s /bin/bash postgres
    fi
    mkdir -p "$PGDATA"
    touch /data/postgres.log
    chown postgres:postgres "$PGDATA" /data/postgres.log

    if [ ! -d "$PGDATA/pg_wal" ]; then
        echo "[buzz] Initializing Postgres database..."
        su postgres -c "initdb -D $PGDATA -U buzz --auth-local=trust --auth-host=trust"
    fi

    cat > "$PGDATA/postgresql.conf" << 'PGCONF'
listen_addresses = '127.0.0.1'
port = 5432
max_connections = 50
shared_buffers = 64MB
effective_cache_size = 256MB
work_mem = 4MB
maintenance_work_mem = 32MB
max_wal_size = 256MB
min_wal_size = 64MB
checkpoint_completion_target = 0.5
wal_buffers = 4MB
PGCONF
    chown postgres:postgres "$PGDATA/postgresql.conf"

    su postgres -c "pg_ctl -D $PGDATA -l /data/postgres.log start -o '-c config_file=$PGDATA/postgresql.conf'"
    sleep 2
    psql -h 127.0.0.1 -U buzz -d postgres -c "CREATE DATABASE buzz OWNER buzz;" 2>/dev/null || true
    echo "[buzz] Postgres ready"
}

# ── Start Redis ──────────────────────────────────────────────────────
start_redis() {
    echo "[buzz] Starting Redis..."
    mkdir -p /data/redis
    redis-server \
        --port 6379 --bind 127.0.0.1 \
        --requirepass "$REDIS_PASSWORD" \
        --appendonly yes --dir /data/redis \
        --maxmemory 64mb --maxmemory-policy allkeys-lru \
        --daemonize yes --save ""
    sleep 1
    echo "[buzz] Redis ready"
}

# ── Start MinIO ──────────────────────────────────────────────────────
start_minio() {
    echo "[buzz] Starting MinIO..."
    mkdir -p /data/minio
    MINIO_ROOT_USER="$S3_ACCESS_KEY" MINIO_ROOT_PASSWORD="$S3_SECRET_KEY" \
    minio server /data/minio --address 127.0.0.1:9000 --console-address 127.0.0.1:9001 \
        > /data/minio.log 2>&1 &
    sleep 3
    mc alias set local http://127.0.0.1:9000 "$S3_ACCESS_KEY" "$S3_SECRET_KEY" 2>/dev/null
    mc mb --ignore-existing local/buzz-media 2>/dev/null || true
    echo "[buzz] MinIO ready"
}

# ── Start nginx + Buzz Relay ─────────────────────────────────────────
start_relay() {
    echo "[buzz] Configuring nginx reverse proxy..."

    # Write nginx config
    cat > /etc/nginx/nginx.conf << 'NGINXCONF'
worker_processes 1;
pid /var/run/nginx.pid;
error_log stderr warn;

events {
    worker_connections 256;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 0;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    server {
        listen 3000;
        server_name _;

        # Root: WebSocket upgrade → relay, otherwise → landing.html
        location = / {
            if ($http_upgrade = websocket) {
                proxy_pass http://127.0.0.1:3001;
                proxy_http_version 1.1;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection "upgrade";
                proxy_set_header Host localhost:3001;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_buffering off;
                proxy_read_timeout 3600s;
            }
            root /var/www;
            try_files /landing.html =404;
            add_header Cache-Control "no-cache";
        }

        # Health check — return 200 directly (nginx running = addon starting)
        location = /health {
            access_log off;
            return 200 "OK\n";
            add_header Content-Type text/plain;
        }

        # API and WebSocket routes → proxy to relay on :3001
        # These are the relay's explicit API routes that must NOT be
        # intercepted by the SPA fallback.
        location ~ ^/(events|query|count|info|upload|media|hooks|workflows|operator|moderation|api|_liveness|_readiness|_status|_mesh|huddle|\.well-known|git|invite) {
            proxy_pass http://127.0.0.1:3001;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host localhost:3001;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }

        # Static assets → proxy to relay (ServeDir handles these)
        location /assets/ {
            proxy_pass http://127.0.0.1:3001;
            proxy_set_header Host localhost:3001;
            proxy_buffering off;
        }

        # All other paths → serve SPA index.html
        # The Buzz SPA uses TanStack Router for client-side routing.
        # nginx serves index.html for all non-API routes so /login,
        # /channels, /feed, /dms, /settings, /repos etc. all load the SPA.
        location / {
            root /srv/buzz/web;
            try_files $uri /index.html;
        }
    }
}
NGINXCONF

    # Start nginx
    nginx
    echo "[buzz] nginx listening on :3000 (Ingress)"

    # Configure and start relay
    export DATABASE_URL="postgres://buzz:${POSTGRES_PASSWORD}@127.0.0.1:5432/buzz"
    export REDIS_URL="redis://:${REDIS_PASSWORD}@127.0.0.1:6379"
    export BUZZ_S3_ENDPOINT="http://127.0.0.1:9000"
    export BUZZ_S3_ADDRESSING_STYLE="path"
    export BUZZ_S3_ACCESS_KEY="$S3_ACCESS_KEY"
    export BUZZ_S3_SECRET_KEY="$S3_SECRET_KEY"
    export BUZZ_S3_BUCKET="buzz-media"
    export BUZZ_GIT_REPO_PATH="/data/git"
    export BUZZ_BIND_ADDR="127.0.0.1:3001"
    export BUZZ_HEALTH_PORT="8080"
    export BUZZ_AUTO_MIGRATE="$AUTO_MIGRATE"
    export RUST_LOG="${RUST_LOG:-buzz_relay=info}"
    export BUZZ_WEB_DIR="/srv/buzz/web"
    export BUZZ_ADMIN_WEB_DIR="/srv/buzz/admin-web"
    export BUZZ_RELAY_PRIVATE_KEY="$RELAY_PRIVATE_KEY"
    export RELAY_OWNER_PUBKEY="$RELAY_OWNER_PUBKEY"
    export BUZZ_REQUIRE_AUTH_TOKEN="$REQUIRE_AUTH_TOKEN"
    export BUZZ_REQUIRE_RELAY_MEMBERSHIP="$REQUIRE_RELAY_MEMBERSHIP"
    export BUZZ_ALLOW_NIP_OA_AUTH="$ALLOW_NIP_OA_AUTH"
    export BUZZ_GIT_CONFORMANCE_PROBE="true"
    export BUZZ_CORS_ORIGINS=""
    export RELAY_URL="http://localhost:3001"
    export BUZZ_SERVE_GIT_WEB_GUI="true"

    # Wait for Postgres
    echo "[buzz] Waiting for Postgres..."
    for i in $(seq 1 60); do
        psql -h 127.0.0.1 -U buzz -d buzz -c "SELECT 1;" 2>/dev/null && break
        sleep 1
    done

    if [ "$AUTO_MIGRATE" = "true" ]; then
        echo "[buzz] Running database migrations..."
        buzz-admin migrate 2>&1 || echo "[buzz] buzz-admin migrate failed, relay will auto-migrate"
    fi

    echo "[buzz] Buzz Relay starting on :3001 (behind nginx :3000)"
    exec buzz-relay
}

# ── Main ─────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════╗"
echo "║  Buzz Relay HA Add-on                      ║"
echo "║  Nostr workspace for humans + agents      ║"
echo "╚══════════════════════════════════════════╝"

persist_secrets
generate_keys
start_postgres
start_redis
start_minio
start_relay