#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Buzz Relay HA Add-on — Entrypoint
# Starts: Postgres → Redis → MinIO → buzz-relay (with Web-UI on :3000)
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Read HA add-on options ───────────────────────────────────────────
OPTIONS_FILE="/data/options.json"
if [ ! -f "$OPTIONS_FILE" ]; then
    echo "[buzz] FATAL: $OPTIONS_FILE not found"
    exit 1
fi

opt()  { jq -r ".${1} // empty"    "$OPTIONS_FILE"; }
opt_bool() { jq -r ".${1} // false" "$OPTIONS_FILE"; }
opt_or_gen() {
    local val
    val=$(jq -r ".${1} // empty" "$OPTIONS_FILE")
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        # Generate a random secret
        openssl rand -hex 32
    else
        echo "$val"
    fi
}

TIMEZONE=$(opt timezone)
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

# Persist generated secrets back so they survive restarts
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

# ── Generate keys if not provided ───────────────────────────────────
generate_keys() {
    if [ -z "$RELAY_PRIVATE_KEY" ]; then
        echo "[buzz] Generating relay keypair..."
        local keys
        keys=$(/usr/local/bin/buzz-admin generate-key 2>/dev/null || openssl rand -hex 32)
        RELAY_PRIVATE_KEY=$(echo "$keys" | jq -r '.secret // .private_key // empty' 2>/dev/null || echo "$keys")
        if [ -z "$RELAY_PRIVATE_KEY" ] || [ ${#RELAY_PRIVATE_KEY} -lt 32 ]; then
            RELAY_PRIVATE_KEY=$(openssl rand -hex 32)
        fi
        # Persist the key
        local tmp
        tmp=$(mktemp)
        jq --arg rk "$RELAY_PRIVATE_KEY" '.relay_private_key = $rk' "$OPTIONS_FILE" > "$tmp" && mv "$tmp" "$OPTIONS_FILE"
        echo "[buzz] Relay private key generated and saved."
    fi

    if [ -z "$RELAY_OWNER_PUBKEY" ]; then
        echo "[buzz] No owner pubkey set — relay will run in open mode."
        echo "[buzz] Set relay_owner_pubkey in add-on config for closed mode."
    fi
}

# ── Start Postgres ───────────────────────────────────────────────────
start_postgres() {
    echo "[buzz] Starting Postgres..."
    # Use /data for persistence
    export PGDATA=/data/postgres
    export POSTGRES_PASSWORD

    # Initialize if needed
    if [ ! -d "$PGDATA/pg_wal" ]; then
        mkdir -p "$PGDATA"
        chown -R postgres:postgres "$PGDATA" 2>/dev/null || true
        su - postgres -c "initdb -D $PGDATA -U buzz --auth-local=trust --auth-host=md5" 2>/dev/null || \
            initdb -D "$PGDATA" -U buzz --auth-local=trust --auth-host=md5
    fi

    # Configure
    cat > "$PGDATA/postgresql.conf" << PGCONF
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

    # Start
    su - postgres -c "pg_ctl -D $PGDATA -l /data/postgres.log start -o '-c config_file=$PGDATA/postgresql.conf'" 2>/dev/null || \
        pg_ctl -D "$PGDATA" -l /data/postgres.log start -o "-c config_file=$PGDATA/postgresql.conf"

    # Create database and user
    sleep 2
    psql -h 127.0.0.1 -U postgres -c "CREATE USER buzz WITH PASSWORD '$POSTGRES_PASSWORD' SUPERUSER;" 2>/dev/null || true
    psql -h 127.0.0.1 -U postgres -c "CREATE DATABASE buzz OWNER buzz;" 2>/dev/null || true
    psql -h 127.0.0.1 -U buzz -d buzz -c "SELECT 1;" 2>/dev/null && echo "[buzz] Postgres ready" || echo "[buzz] Postgres starting..."
}

# ── Start Redis ──────────────────────────────────────────────────────
start_redis() {
    echo "[buzz] Starting Redis..."
    redis-server \
        --port 6379 \
        --bind 127.0.0.1 \
        --requirepass "$REDIS_PASSWORD" \
        --appendonly yes \
        --dir /data/redis \
        --maxmemory 64mb \
        --maxmemory-policy allkeys-lru \
        --daemonize yes \
        --save ""
    sleep 1
    redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG && echo "[buzz] Redis ready" || echo "[buzz] Redis starting..."
}

# ── Start MinIO ──────────────────────────────────────────────────────
start_minio() {
    echo "[buzz] Starting MinIO..."
    export MINIO_ROOT_USER="$S3_ACCESS_KEY"
    export MINIO_ROOT_PASSWORD="$S3_SECRET_KEY"

    minio server /data/minio \
        --address 127.0.0.1:9000 \
        --console-address 127.0.0.1:9001 \
        > /data/minio.log 2>&1 &

    sleep 2

    # Create bucket
    mc alias set local http://127.0.0.1:9000 "$S3_ACCESS_KEY" "$S3_SECRET_KEY" 2>/dev/null
    mc mb --ignore-existing local/buzz-media 2>/dev/null || true
    mc anonymous set none local/buzz-media 2>/dev/null || true
    echo "[buzz] MinIO ready"
}

# ── Start Buzz Relay ─────────────────────────────────────────────────
start_relay() {
    echo "[buzz] Starting Buzz Relay..."

    export DATABASE_URL="postgres://buzz:${POSTGRES_PASSWORD}@127.0.0.1:5432/buzz"
    export REDIS_URL="redis://:${REDIS_PASSWORD}@127.0.0.1:6379"
    export BUZZ_S3_ENDPOINT="http://127.0.0.1:9000"
    export BUZZ_S3_ADDRESSING_STYLE="path"
    export BUZZ_S3_ACCESS_KEY="$S3_ACCESS_KEY"
    export BUZZ_S3_SECRET_KEY="$S3_SECRET_KEY"
    export BUZZ_S3_BUCKET="buzz-media"
    export BUZZ_GIT_REPO_PATH="/data/git"
    export BUZZ_BIND_ADDR="0.0.0.0:3000"
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
    export BUZZ_CORS_ORIGINS="*"

    # Wait for Postgres
    for i in $(seq 1 30); do
        psql -h 127.0.0.1 -U buzz -d buzz -c "SELECT 1;" 2>/dev/null && break
        sleep 1
    done

    # Run migrations if auto-migrate
    if [ "$AUTO_MIGRATE" = "true" ]; then
        echo "[buzz] Running database migrations..."
        buzz-admin migrate 2>/dev/null || echo "[buzz] Migration via buzz-admin failed, relay will auto-migrate"
    fi

    # Start relay (foreground)
    echo "[buzz] Buzz Relay starting on :3000"
    exec buzz-relay
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
    echo "╔══════════════════════════════════════════╗"
    echo "║  Buzz Relay HA Add-on v0.1.0              ║"
    echo "║  Nostr workspace for humans + agents     ║"
    echo "╚══════════════════════════════════════════╝"

    # Persist generated secrets
    persist_secrets

    # Generate Nostr keys if needed
    generate_keys

    # Start services in order
    start_postgres
    start_redis
    start_minio

    # Start relay (this blocks — it's the main process)
    start_relay
}

main "$@"