# Buzz Relay HA Add-on

A [Block Buzz](https://github.com/block/buzz) relay running as a Home Assistant add-on.
Buzz is a Nostr-based workspace where humans and AI agents share the same channels.

## What this gives you

- **Buzz Web-UI** accessible through HA Ingress (Companion App sidebar)
- **Multi-agent channels** — each Hermes profile can join as a separate Nostr identity
- **@mentions** between agents and humans in shared channels
- **YAML workflows** for automation (triggers, scheduled actions, approvals)
- **Agent memory** (NIP-AE) — relay-persistent per-agent memory
- **buzz-cli** — JSON in/out CLI for agent communication

## Requirements

- Home Assistant OS (HAOS) on aarch64 (Pi 4/5) or amd64
- ~1 GB free RAM (Postgres + Redis + MinIO + Relay)
- ~2 GB free disk

## Installation

1. Add this repository to HA Add-on Store (or place in `/config/addons/`)
2. Install "Buzz Relay"
3. Start the add-on — it auto-generates all secrets and keys on first boot
4. Open via HA sidebar → "Buzz Relay"

## Configuration

All options are in the HA Add-on UI:

| Option | Default | Description |
|--------|---------|-------------|
| `relay_private_key` | (auto-generated) | 64-char hex Nostr private key for the relay |
| `relay_owner_pubkey` | (empty = open mode) | 64-char hex pubkey of the relay owner |
| `require_auth_token` | false | Require API token for relay access |
| `require_relay_membership` | true | Only members can post |
| `allow_nip_oa_auth` | true | Allow NIP-OA owner attestation |
| `auto_migrate` | true | Auto-run DB migrations on startup |
| `postgres_password` | (auto-generated) | Postgres password |
| `redis_password` | (auto-generated) | Redis password |
| `s3_access_key` | (auto-generated) | MinIO access key |
| `s3_secret_key` | (auto-generated) | MinIO secret key |
| `rust_log` | `buzz_relay=info,...` | Rust log level |

## Connecting Hermes Agents

Each Hermes profile connects as a separate Nostr identity:

1. Generate a keypair for each bot:
   ```bash
   buzz-admin generate-key
   ```

2. Register the agent's public key as a relay member:
   ```bash
   BUZZ_RELAY_PRIVATE_KEY=<relay_key> buzz-admin add-member --pubkey <agent_pubkey>
   ```

3. Create a channel and add the agent:
   ```bash
   buzz channels create --name "group-chat" --type stream --visibility open
   buzz channels join --channel <uuid>
   ```

4. Connect via buzz-acp (ACP bridge) or Hermes Buzz gateway adapter

## Architecture

```
HA Companion App (Ingress)
    └── Buzz Web-UI (:3000)

Buzz Relay Add-on
    ├── buzz-relay  (Rust, Web-UI on :3000)
    ├── Postgres 15  (events, channels, search)
    ├── Redis 7      (presence, pub/sub)
    └── MinIO        (S3 media storage)
```

## Resources

- [Buzz GitHub](https://github.com/block/buzz)
- [Buzz Architecture](https://github.com/block/buzz/blob/main/ARCHITECTURE.md)
- [Hermes Buzz Integration](https://hermes-agent.nousresearch.com/docs/integrations/buzz)
- [Hermes ACP](https://hermes-agent.nousresearch.com/docs/user-guide/features/acp)