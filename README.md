# 🚀 Supabase Self-Hosted on GitHub Actions

[![Supabase Self-Hosted](https://github.com/apunabhibhilegendhai/Supabase-Actions/actions/workflows/supabase-host.yml/badge.svg)](https://github.com/apunabhibhilegendhai/Supabase-Actions/actions/workflows/supabase-host.yml)

**Run Supabase (no object storage) on free GitHub Actions runners with a permanent URL via Cloudflare Tunnel.**

```
┌──────────────────────┐     ┌──────────────────────┐     ┌──────────────────┐
│  Your App / Browser  │ ──▶ │  Cloudflare Tunnel   │ ──▶ │  GitHub Actions  │
│  (anywhere)          │     │  perm URL (static)   │     │  Runner          │
│                      │ ◀── │                      │ ◀── │  ├── Kong:8000   │
│                      │     │                      │     │  ├── Postgres    │
│                      │     │                      │     │  ├── Redis 7     │
│                      │     │                      │     │  ├── Auth        │
│                      │     │                      │     │  ├── Realtime    │
│                      │     │                      │     │  └── Studio      │
└──────────────────────┘     └──────────────────────┘     └──────────────────┘
         ↕                                                        ↕
  Permanent domain                                     State backup at shutdown
  (never changes)                                      persists between runs
```

## ✨ Features

| Feature | Included |
|---|---|
| **PostgreSQL database** | ✅ Full Supabase Postgres |
| **Redis 7 In-Memory Cache** | ✅ Cache + Kong rate-limiting backend + RDB persistence + [permanent remote link](#-permanent-redis-link-free--no-card) |
| **PostgREST API** | ✅ Auto-generated REST API |
| **Auth (GoTrue)** | ✅ Login, signup, JWT, OAuth |
| **Realtime subscriptions** | ✅ WebSocket-based live queries |
| **Supabase Studio** | ✅ Dashboard UI (port 8000) |
| **Edge Functions** | ✅ Deno-based edge functions |
| **Google / GitHub OAuth** | ✅ (opt-in — set client secrets) |
| **pgvector (AI/vector search)** | ✅ |
| **pg_cron (scheduled jobs)** | ✅ |
| **Custom access token hook** | ✅ (opt-in) |
| **Versioned migrations** | ✅ (`supabase/migrations/`) |
| **Remote migrations / DB admin** | ✅ (`./remote.sh` — push & run SQL over HTTPS) |
| **Permanent URL** | ✅ Cloudflare Tunnel (static domain) |
| **Data persistence** | ✅ Full state backed up at shutdown → restored next run |
| **Object Storage** | ❌ Not included |

## ⏱️ How It Works

1. **Workflow triggers** — manually or every 6 hours via cron
2. **Restores database and Redis** from GitHub Actions cache (your data survives)
3. **Starts all Supabase services** via Docker Compose (Postgres, Redis, Kong, Auth, PostgREST, Realtime, Studio, Edge Functions, Supavisor, Logflare, Vector)
4. **Connects Cloudflare Tunnel** — your permanent URL goes live
5. **Runs for ~5h30m** — access Studio, API, Auth, Realtime (maximizes the full 6-hour GitHub limit)
6. **Snapshot every 5 minutes (on disk)** — the full state (DB + edge functions + snippets + Vault key) is refreshed continuously and **persisted to the GitHub cache at shutdown** (GitHub no longer exposes cache credentials to `run:` steps, so mid-session cache uploads aren't possible). A clean handoff between scheduled runs loses nothing; a hard-cancelled run falls back to the previous run's backup
7. **Graceful shutdown** — final backup, then repeat
8. **Repeat** — next run picks up where you left off

> **Downtime:** ~1-2 minutes between runs via workflow-watchman (scheduled runs queue behind the active session; sessions run ~5h05m)

## 📡 Health Check / Monitoring

### Instant Status (Badge)

Click the badge at the top of this README to see the latest workflow run:
- 🟢 **Passing** = Supabase is running (or was running until recently)
- 🔴 **Failing** = Something went wrong
- 🟡 **No status** = First run not yet complete

### What to Check When Tunnel Goes Down

| Check | How |
|-------|-----|
| **Last workflow status** | README badge or Actions tab in your repo |
| **Tunnel status** | [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) → Networks → Tunnels |
| **Next scheduled run** | Waiting for cron `0 */6 * * *` (every 6 hours) |
| **Container health** | Workflow logs show docker compose ps output |

---

## 📋 Setup Guide

### Step 1: Fork / Clone This Repo

```bash
git clone <your-repo-url>
cd supabase-selfhosted
```

### Step 2: Get a Domain on Cloudflare

You need a domain managed by Cloudflare (free):
- Buy one (e.g., `yourdomain.com`) or use an existing one
- Add it to Cloudflare's free plan

### Step 3: Create a Cloudflare Tunnel

1. Go to **Cloudflare Dashboard → Zero Trust → Networks → Tunnels**
2. Click **"Create a tunnel"** → Choose **"Cloudflared"**
3. Name it (e.g., `supabase-tunnel`)
4. Copy the **tunnel token** (long string starting with `eyJh...`)
5. Under **"Public Hostname"**, add:
   - **Subdomain**: `supabase` (or whatever you want)
   - **Domain**: your domain (e.g., `yourdomain.com`)
   - **Type**: `HTTP`
   - **URL**: `localhost:8000`
6. Save the tunnel

Your permanent URL will be: **`https://supabase.yourdomain.com`**

#### Every public hostname this stack can use

Only the first is required. Each one is a **separate Public Hostname entry on the
same tunnel** — none of them come for free:

| Subdomain | Type | Origin URL | Serves | Required? |
|---|---|---|---|---|
| `supabase.<domain>` | HTTP | `localhost:8000` | Studio API, Auth, REST, Realtime — the whole public surface | ✅ |
| `redis.<domain>` | HTTP | `localhost:8081` | Redis Commander web console (see [🔗 Permanent Redis link](#-permanent-redis-link-free--no-card)) | ⬜ |
| `db.<domain>` | **TCP** (not HTTP) | `localhost:5432` | `./pg-tunnel.sh` — a real Postgres connection. Also needs a **Service Auth** Access policy | ⬜ |

Two things worth knowing before debugging a 404 or 502:

- **There is no wildcard record.** Cloudflare zones don't get a `*.domain` entry by default, so a subdomain you haven't added resolves to nothing at all (`NXDOMAIN`). Every hostname above must be created explicitly.
- **A DNS record is not a route.** A hostname that answers Cloudflare's **502** has a record *and* a proxy, but nothing on the runner is reachable at the configured origin — or the ingress rule points somewhere else. A **404** usually means no ingress rule matches the hostname.

### Step 4: Generate Secrets

Run these commands locally to generate secure values for your GitHub Secrets:

```bash
# PostgreSQL password (64 hex chars = 256 bits)
openssl rand -hex 32
# → Copy this for POSTGRES_PASSWORD

# JWT secret (32+ chars, base64)
openssl rand -base64 32
# → Copy this for JWT_SECRET

# Dashboard password
openssl rand -base64 16
# → Copy this for DASHBOARD_PASSWORD
```

> 🔐 Save these values somewhere safe — you'll need them in Step 5. If you lose them, just generate new ones (existing cached database backups will be unrecoverable with a new `POSTGRES_PASSWORD`).

### Step 5: Add GitHub Secrets

This workflow requires **4 secrets** (1 optional). You can set them via the GitHub UI or the `gh` CLI (recommended if you have it installed).

#### Option A: Using `gh` CLI (fastest)

```bash
# Navigate to your repo directory first
cd supabase-selfhosted

# 1. Cloudflare Tunnel token (REQUIRED) — from Step 3
gh secret set CF_TUNNEL_TOKEN
# Paste your tunnel token and press Ctrl+D

# 2. Your domain on Cloudflare (OPTIONAL — leave out if no domain yet)
gh secret set CF_TUNNEL_DOMAIN
# Example: supabase.yourdomain.com (no https://)

# 3. PostgreSQL password (REQUIRED) — generate a secure one
openssl rand -hex 32 | gh secret set POSTGRES_PASSWORD

# 4. JWT signing secret (REQUIRED) — 32+ characters
openssl rand -base64 32 | gh secret set JWT_SECRET

# 5. Supabase Studio password (REQUIRED) — your admin login
gh secret set DASHBOARD_PASSWORD
# Type a strong password and press Ctrl+D
```

> **One-liner for all 4 required secrets:**
> ```bash
> gh secret set CF_TUNNEL_TOKEN -b"$(echo -n 'paste-your-token-here')" && \
> openssl rand -hex 32 | gh secret set POSTGRES_PASSWORD && \
> openssl rand -base64 32 | gh secret set JWT_SECRET && \
> gh secret set DASHBOARD_PASSWORD -b"your-strong-password"
> ```

#### Option B: GitHub UI

Go to **Settings → Secrets and variables → Actions → New repository secret** and add each one:

| Secret | Required | Value |
|---|---|---|
| `CF_TUNNEL_TOKEN` | ✅ Required | The tunnel token from Step 3 (`eyJh...`) |
| `CF_TUNNEL_DOMAIN` | ⬜ Optional | Your URL: `supabase.yourdomain.com` (no `https://`) |
| `POSTGRES_PASSWORD` | ✅ Required | Output from `openssl rand -hex 32` |
| `JWT_SECRET` | ✅ Required | Output from `openssl rand -base64 32` |
| `DASHBOARD_PASSWORD` | ✅ Required | Your secure Supabase Studio password |
| `NGROK_AUTHTOKEN` | ⬜ Optional | ngrok **agent authtoken** (dashboard → Your Authtoken). Publishes a permanent link to the Redis web console. Not the API key. |
| `NGROK_DOMAIN` | ⬜ Optional | ngrok static dev domain to bind, e.g. `uncompiled-tinkly-laronda.ngrok-free.dev`. Omit to let ngrok use the account's assigned domain. |

#### Secrets Reference

| Secret | Where It's Used | What It Does |
|---|---|---|
| `CF_TUNNEL_TOKEN` | Cloudflare Tunnel step | Authenticates the tunnel to Cloudflare's edge. Created once in the Cloudflare dashboard. |
| `CF_TUNNEL_DOMAIN` | `.env` generation + Tunnel display | Sets the public URL so Supabase generates correct redirect URIs. Omit this to use `localhost:8000` (tunnel still connects, but no public routing). |
| `POSTGRES_PASSWORD` | `.env` → PostgreSQL container | Superuser password for the database. Used internally by all Supabase services. |
| `JWT_SECRET` | `.env` → JWT key generation | Signs all Auth tokens. The workflow auto-generates all API keys from this secret. |
| `DASHBOARD_PASSWORD` | `.env` → Supabase Studio | Login password for Studio at port 8000 (username: `supabase`). |
| `SMTP_HOST` | `.env` → GoTrue (auth email) | SMTP server hostname (e.g. `smtp.resend.com`). Optional — unset keeps dev-only inbucket. |
| `SMTP_PORT` | `.env` → GoTrue (auth email) | SMTP port (587 TLS typical). |
| `SMTP_USER` | `.env` → GoTrue (auth email) | SMTP username (Resend: `resend`). |
| `SMTP_PASS` | `.env` → GoTrue (auth email) | SMTP password / API key. |
| `SMTP_ADMIN_EMAIL` | `.env` → GoTrue (auth email) | Verified From address for auth emails. |
| `SMTP_SENDER_NAME` | `.env` → GoTrue (auth email) | Sender display name (e.g. `Supabase`). |

#### Auto-Generated Keys (no setup needed)

The workflow automatically generates all these keys from `JWT_SECRET` — no manual setup required:

| Key / Secret | Generated From | Purpose |
|---|---|---|
| `ANON_KEY` | `JWT_SECRET` (HS256 JWT) | Legacy public API key |
| `SERVICE_ROLE_KEY` | `JWT_SECRET` (HS256 JWT) | Legacy admin API key |
| `SUPABASE_PUBLISHABLE_KEY` | `JWT_SECRET` (opaque `sb_publishable_...`) | New opaque public API key |
| `SUPABASE_SECRET_KEY` | `JWT_SECRET` (opaque `sb_secret_...`) | New opaque admin API key |
| `JWT_KEYS` | `JWT_SECRET` (ES256 EC P-256 + HS256) | Private JWKs for Auth signing |
| `JWT_JWKS` | `JWT_SECRET` (ES256 EC P-256 + HS256) | Public JWKS for all services |
| `ANON_KEY_ASYMMETRIC` | `JWT_SECRET` (ES256 JWT) | Asymmetric anon JWT for Kong |
| `SERVICE_ROLE_KEY_ASYMMETRIC` | `JWT_SECRET` (ES256 JWT) | Asymmetric service JWT for Kong |
| `SECRET_KEY_BASE` | `JWT_SECRET` (HMAC-SHA512) | Cookie & session signing |
| `REALTIME_DB_ENC_KEY` | `JWT_SECRET` (HMAC-SHA512) | Realtime broadcast encryption |
| `VAULT_ENC_KEY` | `JWT_SECRET` (HMAC-SHA512) | Vault encryption |
| `PG_META_CRYPTO_KEY` | `JWT_SECRET` (HMAC-SHA512) | Studio metadata encryption |
| `LOGFLARE_PUBLIC_TOKEN` / `LOGFLARE_PRIVATE_TOKEN` | `JWT_SECRET` (HMAC-SHA512) | Logflare logging |

> **💡 All keys are deterministic** — the same `JWT_SECRET` always produces the same keys. To get the **current public keys**, open the latest workflow run and read the **🔑 Current public API keys** table in its summary (or the "Run summary" panel of the run page).
>
> Only `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_PUBLISHABLE_KEY` are published — the `service_role` / secret keys are root on the database and are never written to a summary or log. For those, use `remote.env` with `./remote.sh`.
>
> ⚠️ A key copied from an old `.env`, an old run, or a tutorial will **not** work: the keys are derived from `JWT_SECRET`, so changing that secret (or the run that generated your copy) silently invalidates every copy. Symptoms are a plain `401` from every endpoint — see the troubleshooting table.

#### 📧 Real auth emails (optional)

By default auth emails (signup confirmation, password reset, OTP) go to the dev-only **inbucket** fake SMTP and are silently dropped. To actually deliver them, set the SMTP secrets above to any transactional SMTP provider — e.g. [Resend](https://resend.com) (free tier: 100 emails/day):

```bash
gh secret set SMTP_HOST -b"smtp.resend.com"
gh secret set SMTP_PORT -b"587"
gh secret set SMTP_USER -b"resend"
gh secret set SMTP_PASS -b"<your-resend-api-key>"
gh secret set SMTP_ADMIN_EMAIL -b"noreply@your-domain.com"   # must be verified with Resend
gh secret set SMTP_SENDER_NAME -b"Supabase"
```

Since `ENABLE_EMAIL_AUTOCONFIRM=false`, new signups require email confirmation — with real SMTP the confirmation links and password resets start working end-to-end.

#### 🔐 Google / GitHub OAuth (optional)

Set the provider's client ID + secret as GitHub secrets and the workflow auto-enables it (`GOOGLE_ENABLED`/`GITHUB_ENABLED` flip to `true`, redirect URIs are derived from your tunnel domain):

```bash
# Create an OAuth app first:
#   Google: https://console.cloud.google.com/apis/credentials
#   GitHub: https://github.com/settings/developers
# Authorized redirect URI must be: https://<CF_TUNNEL_DOMAIN>/auth/v1/callback
gh secret set GOOGLE_CLIENT_ID -b"<id>"
gh secret set GOOGLE_SECRET -b"<secret>"
# or
gh secret set GITHUB_CLIENT_ID -b"<id>"
gh secret set GITHUB_SECRET -b"<secret>"
```

Anonymous users are enabled by default (`ENABLE_ANONYMOUS_USERS=true`) — guests can use the app and later upgrade to a real account.

## 🗂️ Versioned migrations

Schema changes that must survive sessions live in `supabase/migrations/*.sql` (committed). A workflow step applies them on top of the restored database every session, tracking applied files in `public._schema_migrations` so each runs exactly once:

```bash
echo "ALTER TABLE public.users ADD COLUMN IF NOT EXISTS avatar_url text;" > supabase/migrations/002-avatar-url.sql
git add supabase/migrations/002-avatar-url.sql && git commit && git push
```

Failed migrations are left unapplied and retry next session. See `supabase/migrations/README.md`. A ready-to-use **custom access token hook** (`001-custom-access-token-hook.sql`) is included — flip `ENABLE_CUSTOM_ACCESS_TOKEN_HOOK=true` to turn it on and edit the function to add claims.

### 🌍 Remote control — apply migrations & run SQL from anywhere

Committed migrations only apply at the *next* session. When a session is LIVE and the tunnel is up, you can push schema changes **instantly over HTTPS** with the bundled `remote.sh` — no SSH, no TCP exposure, no waiting for the 6-hour restart:

```bash
# 1. Configure once (either keep secrets out of git)
cat > remote.env <<EOF
REMOTE_URL=https://supabase.yourdomain.com
REMOTE_SERVICE_KEY=<your service_role key>
EOF

# 2. Use it — same commands work from any machine
./remote.sh status                     # list applied migrations + DB info
./remote.sh run "CREATE TABLE public.notes (id bigserial primary key, body text);"
./remote.sh run < schema.sql           # one-off SQL from a file/stdin
./remote.sh push                       # apply supabase/migrations/*.sql (idempotent)
./remote.sh push supabase/migrations/003-foo.sql
./remote.sh untrack 002-backfill-user-emails.sql   # make it re-apply on next push
```

It calls a built-in edge function (`/api/migrate` or `/functions/v1/migrate`, service-role key required) that executes SQL as the postgres superuser and records each applied migration in `public._schema_migrations` — **the same table** the session-start step uses, so:
- remote pushes and committed migrations share one idempotent source of truth (never double-apply),
- a migration you push remotely rides the 5-minute state snapshot into the next session's backup,
- the next session sees it already applied and skips it.

> ⚠️ Migration SQL must be **pure SQL** — psql meta-commands (`\c`, `\set`) don't exist over HTTPS. The service_role key is effectively root on this database: keep it secret (it's the same key Studio / the REST API use). Want read-only mode? Set `MIGRATE_READONLY=true` on the `functions` service in `supabase/docker-compose.yml`.
>
> On Windows run `bash remote.sh ...` from Git Bash or WSL. `remote.env` is gitignored. `remote.sh` needs `curl` and either `python3` or `node`.

## 🔑 Personal Access Tokens

Generate `sbp_` personal access tokens just like Supabase Cloud:

```bash
# Create a token
./run.sh gen-token "My CI Token" "For GitHub Actions deployments"

# List all tokens
./run.sh list-tokens

# Revoke a token
./run.sh revoke-token <token-uuid>
```

Tokens are HS256 JWTs with service_role privileges, tracked in the database for listing and revocation. Use with any Supabase API:

```bash
curl -H "Authorization: Bearer <token>" https://your-domain.com/rest/v1/your_table
```

## ⚡ Self-Hosted Redis 7

A lightweight Redis 7 instance (`redis:7-alpine`) runs alongside the Supabase stack.

### Key Capabilities
- **Kong Rate-Limiting Backend**: Kong route rate limiting is backed by Redis instead of in-memory local policy, keeping accurate rate-limit counts.
- **Application Cache**: Accessible on the Docker internal network by all services, Edge Functions, and backend containers.
- **AOF durability**: `--appendonly yes --appendfsync everysec` — every write is appended, so a hard runner kill or container restart loses at most ~1s of writes (RDB alone could lose up to a minute). `--aof-load-truncated yes` keeps a half-written tail from blocking startup.
- **Cross-Session Persistence**: both the AOF (`appendonlydir/`) and a compact RDB (`dump.rdb`) are archived into `supabase-state.tar.gz` and restored automatically across GitHub Actions sessions. The archive is refreshed every 5 minutes with a **non-blocking** `BGSAVE` + `BGREWRITEAOF` (the old blocking `SAVE` stalled every client for seconds each time).
- **Health endpoint**: [`/functions/v1/health`](#-redis--tunnel-health) reports Redis and tunnel reachability, including AOF/RDB status.
- **Interactive Shell**:
  ```bash
  ./run.sh redis-cli
  ```
- **Connection Details**:
  - Host: `redis` (internal docker network) or `localhost` (host port)
  - Port: `6379`
  - Password: `${REDIS_PASSWORD}` (configured in `.env`)
  - Connection URI: `redis://default:${REDIS_PASSWORD}@redis:6379`

### 🔗 Permanent Redis link (free — no card)

The internal `redis://redis:6379` address only resolves inside the Docker network. For an address you can hardcode in an app that runs anywhere, use your **existing Cloudflare Tunnel** — it's already permanent and free:

1. **One-time dashboard step** — Zero Trust → Networks → Tunnels → your tunnel → **Public Hostname** → Add:

   | Field | Value |
   |---|---|
   | Subdomain | `redis` |
   | Domain | your domain (e.g. `chuglii.in`) |
   | Type | **TCP** |
   | URL | `localhost:6379` |

   Recommended: add an Access application with a service token so the port isn't open to the world (Redis's password is the only other lock).

2. **Connect** — `cloudflared` is the client half of a TCP tunnel, so run the bundled helper once and leave it up:

   ```bash
   ./redis-tunnel.sh                 # → redis://127.0.0.1:6379, stays valid forever
   redis-cli -h 127.0.0.1 -p 6379 -a "$REDIS_PASSWORD"
   ```

   It reads `remote.env` (`REMOTE_URL`/`REDIS_TUNNEL_HOSTNAME`, plus `CF_ACCESS_CLIENT_ID`/`CF_ACCESS_CLIENT_SECRET` if you set an Access token) and prints the ready-to-paste URI.

**Already-permanent alternatives with zero setup:**

- **General-purpose Redis HTTPS bridge** — `POST https://<your-domain>/functions/v1/redis-http` with `{ "cmd": "get", "args": [...] }` (or `pipeline`). Auth: `apikey: <SUPABASE_SERVICE_ROLE_KEY>` (or `REDIS_LINK_TOKEN`). This is the permanent Redis endpoint used by the frontend API on Vercel, where `cloudflared` can't run. Works from any HTTP client, no software. See `supabase/volumes/functions/redis-http/index.ts`.
- **HTTP cache API** — `https://<your-domain>/functions/v1/cache` (see below); no client software, just `fetch`.
- **Web console** — if `NGROK_AUTHTOKEN` is set, the workflow publishes the redis-commander UI on your ngrok **free permanent dev domain** and prints the link in the run summary.

> ⚠️ **Why not ngrok for the raw link?** ngrok's free plan includes only a permanent *HTTPS* dev domain. A permanent `redis://host:port` needs a **reserved TCP address**, which ngrok restricts to paid plans — `ngrok tcp 6379` on free prints a **new random `N.tcp.ngrok.io:PORT` every session**, exactly the problem it's meant to solve (and TCP needs a card on file). The Cloudflare route above gets you the same permanence for free.
>
> The `bore.pub` relay in the workflow prints an **ephemeral** `bore.pub:<random port>` each session. It's kept as a convenience for quick `redis-cli` access, but never hardcode it.

### 🌐 Frontend HTTP Cache API (`/functions/v1/cache`)

External browser or mobile frontends can access Redis directly via HTTPS through the built-in edge function:

```javascript
// 1. Set a key (with optional TTL in seconds)
await fetch("https://supabase.yourdomain.com/functions/v1/cache", {
  method: "POST",
  headers: {
    "apikey": SUPABASE_ANON_KEY,
    "Content-Type": "application/json"
  },
  body: JSON.stringify({ key: "user:123", value: { name: "Alice" }, ttl: 3600 })
});

// 2. Get a key
const res = await fetch("https://supabase.yourdomain.com/functions/v1/cache?key=user:123", {
  headers: { "apikey": SUPABASE_ANON_KEY }
});
const data = await res.json(); // { key: "user:123", value: { name: "Alice" }, exists: true, ttl: 3599 }

// 3. Delete a key
await fetch("https://supabase.yourdomain.com/functions/v1/cache?key=user:123", {
  method: "DELETE",
  headers: { "apikey": SUPABASE_ANON_KEY }
});
```

#### ⏳ Surviving the session gap

Redis disappears for ~1-2 minutes whenever the runner is replaced. The bridge handles the reconnect itself (it retries forever with backoff), and while it's disconnected it answers **`503` with a `Retry-After` header** instead of hanging. Treat cache reads as optional and writes as best-effort:

```javascript
async function cacheFetch(url, init) {
  const res = await fetch(url, init);
  if (res.status === 503) {
    // Between sessions — back off for as long as the server asked, then retry.
    const wait = Number(res.headers.get("Retry-After") || 5) * 1000;
    throw Object.assign(new Error("redis unavailable"), { retryable: true, wait });
  }
  return res;
}

// Never let a cache miss break the request — fall back to Postgres.
async function getUser(id) {
  try {
    const res = await cacheFetch(`/functions/v1/cache?key=user:${id}`, {
      headers: { apikey: SUPABASE_ANON_KEY },
    });
    if (res.ok) return (await res.json()).value;
  } catch {
    /* gap or miss — fall through */
  }
  return fetchUserFromPostgres(id);
}
```

### 🩺 Redis + tunnel health (`/functions/v1/health`)

One public endpoint tells you whether Redis and the tunnel are actually reachable — useful because this stack is *expected* to have 1-2 minute gaps between sessions:

```bash
curl https://supabase.yourdomain.com/functions/v1/health
```

```jsonc
{
  "ok": true,
  "checked_at": "2026-09-21T10:04:11.482Z",
  "redis": {
    "ok": true, "status": "ready", "ping": "PONG", "latency_ms": 1, "keys": 42,
    "persistence": {
      "aof_enabled": "1",
      "aof_last_write_status": "ok",
      "rdb_last_bgsave_status": "ok",
      "rdb_last_save_iso": "2026-09-21T10:00:07Z"
    }
  },
  "tunnel": {
    "ok": true, "mode": "cloudflare",
    "public_url": "https://supabase.yourdomain.com",
    "status": 200, "latency_ms": 143, "end_to_end": true
  }
}
```

| Field | Meaning |
|---|---|
| `redis.ok` | A `PING` was answered right now (short timeout, no retries — it reports, it doesn't heal) |
| `redis.persistence.aof_enabled` | `1` when AOF durability is active. `0` means RDB-only |
| `tunnel.ok` | The public hostname answered through Cloudflare → Kong |
| `tunnel.end_to_end` | The whole path answered — tunnel **and** Kong **and** the edge function **and** Redis |
| `tunnel.mode` | `cloudflare`, or `local` when no `CF_TUNNEL_DOMAIN` is set (nothing to probe, not a failure) |

**Status codes:** `200` when both are up, `503` when either is down — and the `503` carries a `Retry-After` header, so a client that polls this endpoint during a session handover knows to back off and retry instead of treating the gap as a hard failure.

> Internal error strings (which can contain cluster addresses) are omitted by default; add `?verbose=true` to see them.

### 🐘 Connecting to Postgres from outside (`pg-tunnel.sh`)

A plain connection URL against your tunnel domain **cannot work**:

```bash
postgresql://postgres:PASSWORD@supabase.yourdomain.com:5432/postgres   # ✗ times out
```

`supabase.yourdomain.com` resolves to Cloudflare's HTTP proxy, which only forwards 80/443 — port 5432 is dropped **at Cloudflare's edge**, so the packets never reach the runner. `supabase-db` also publishes no host port, and the tunnel's only ingress is HTTP to `kong:8000`. Publishing a raw public TCP port needs Cloudflare Spectrum (paid), so the connection is dialled through the tunnel instead:

**1. One-time dashboard setup**

| Step | Where | Value |
|---|---|---|
| Add a public hostname | Zero Trust → Networks → Tunnels → your tunnel | Subdomain `db`, Type **TCP**, URL `localhost:5432` (Supavisor, session mode) |
| Protect it | Zero Trust → Access → Applications → Add → Self-hosted | Domain `db.yourdomain.com`, policy action **Service Auth** |
| Create the token | Access → Service Auth → Service Tokens | Put the id/secret in `remote.env` |

> 🔓 **The Access policy is not optional.** This repo is public and the Postgres password is in its git history, so the password alone protects nothing — the service token is the only thing between the internet and your database. `pg-tunnel.sh` refuses to start without one (override with `--i-know-what-im-doing` only on a trusted network).

**2. Connect**

```bash
cat >> remote.env <<'EOF'
PG_TUNNEL_HOSTNAME=db.yourdomain.com
CF_ACCESS_CLIENT_ID=<service-token-id>
CF_ACCESS_CLIENT_SECRET=<service-token-secret>
EOF

./pg-tunnel.sh          # leave running → opens 127.0.0.1:5432
# then, in another shell:
psql "postgresql://postgres.$POOLER_TENANT_ID:***@127.0.0.1:5432/postgres"
```

**3. Internal URLs (no tunnel needed)**

| From | URL |
|---|---|
| Any container on the Docker network | `postgresql://postgres:PASSWORD@db:5432/postgres` |
| Pooled, session mode (prepared statements OK) | `postgresql://postgres.<POOLER_TENANT_ID>:PASSWORD@supavisor:5432/postgres` |
| Pooled, transaction mode | `…@supavisor:6543/postgres` |

> ⚠️ Two gotchas: the pooler wants the username `postgres.<POOLER_TENANT_ID>` (bare `postgres` fails auth; the tenant is in `.env`), and **Supavisor crash-loops for ~60s** when a session starts — connection refusals right after a runner boots are expected, not a config error.

**Remember this is still an ephemeral database.** The URL is stable but the server is down 1-2 minutes per session handover, and everything is lost if the Actions cache is evicted. For an app that needs a database that is *always* up, use a managed Postgres and keep this stack for dev/auth/realtime.

### Step 6: Push & Run

```bash
git add .
git commit -m "Add Supabase self-hosted workflow"
git push
```

Then go to **Actions → Supabase Self-Hosted → Run workflow** (or wait for the scheduled trigger).

### Step 7: Access Your Supabase

| What | URL |
|---|---|
| **Supabase Studio** | `https://supabase.yourdomain.com` |
| **Login** | Username: `supabase` / Password: your `DASHBOARD_PASSWORD` |
| **REST API** | `https://supabase.yourdomain.com/rest/v1/` |
| **Auth** | `https://supabase.yourdomain.com/auth/v1/` |
| **Realtime** | `wss://supabase.yourdomain.com/realtime/v1/` |
| **ANON KEY** | Visible in Studio settings or from workflow logs |
| **Redis + tunnel health** | `https://supabase.yourdomain.com/functions/v1/health` |
| **System Logs** | `https://supabase.yourdomain.com/api/logs` (requires service role key) |
| **Remote DB / Migrations** | `./remote.sh` (see [🌍 Remote control](#-remote-control--apply-migrations--run-sql-from-anywhere)) |

---

## 📜 System Logs API (`/api/logs`)

A unified endpoint to see what the whole stack is doing and debug issues. It reads the
Vector → Logflare → Postgres log pipeline (auth, API/PostgREST, realtime, edge functions,
Kong/API gateway, database) plus live service health.

**Auth:** requires the Supabase **service role key** (admin-only, like Studio):

```bash
curl -H "apikey: $SERVICE_ROLE_KEY" https://supabase.yourdomain.com/api/logs
# or: ?apikey=$SERVICE_ROLE_KEY in the query string
```

| Endpoint | What it returns |
|---|---|
| `GET /api/logs` | Recent log events (filtered) |
| `GET /api/logs/sources` | Every log table + row count + last event time |
| `GET /api/logs/health` | Live health of every service (studio, kong, auth, rest, realtime, meta, functions, analytics, vector, db) |
| `GET /api/logs/system` | Services + log sources + database info in one report |

`/api/logs` query params: `level=info|warn|error`, `q=<search text>`, `limit=<1-500>`,
`after=<ISO timestamp>`, `before=<ISO timestamp>`.

Logs are kept only while a session runs (they live in the separate `_supabase` database and are not part of the state backup).

---

## 🛠️ Customization

### Change the schedule

Edit `.github/workflows/supabase-host.yml` and modify the cron:

```yaml
schedule:
  - cron: '0 */4 * * *'   # Every 4 hours
  - cron: '0 */6 * * *'   # Every 6 hours
```

### Run longer (maxing out the 6-hour limit)

Already configured for max utilization. The settings are:

```yaml
timeout-minutes: 355   # 5h55m — 5 min buffer under 360 min hard limit
# In the keep-alive step:
DURATION=18300  # 5h05m — leaves ~50 min buffer for the final backup + cache save
```

### Enable Analytics in Dashboard

The logs/analytics tab in Studio is disabled by default (`ENABLED_FEATURES_LOGS_ALL: "false"`). Logflare and Vector still collect data, but the dashboard won't show it. To enable:

1. Open `supabase/docker-compose.yml`
2. Change `ENABLED_FEATURES_LOGS_ALL: "false"` to `ENABLED_FEATURES_LOGS_ALL: "true"`

### Add OAuth providers

Set `GOOGLE_CLIENT_ID`/`GOOGLE_SECRET` or `GITHUB_CLIENT_ID`/`GITHUB_SECRET` as repo secrets — the workflow enables the provider automatically (see 🔐 Google / GitHub OAuth above).

---

## 🧠 Architecture Notes

Object storage is intentionally excluded but can be re-added (see Troubleshooting).

### Why not use VPS?

This setup is **free** (GitHub Actions + Cloudflare free tier). The trade-off:
- ✅ **Zero cost** to run
- ✅ **Auto-scaling** runners
- ✅ **Full 6-hour window utilized** (5h05m uptime + ~2m gap via watchman)
- ❌ **~15 minutes downtime** between 6-hour runs
- ❌ **Ephemeral** — cache could be evicted if not used for 7+ days

### How data persists

```
Run 1: Start fresh DB → Use Supabase → pg_dump → Save to cache
  ↓
Run 2: Restore from cache → Use Supabase → pg_dump → Save to cache
  ↓
Run 3: Restore from cache → Use Supabase → pg_dump → Save to cache
  ...
```

### Cache limitations

- GitHub Actions cache has **10GB limit** per repo
- The state is snapshotted every 5 minutes **on disk** and saved to the cache **at session end** — persistence relies on the end-of-run `actions/cache` save (GitHub doesn't expose cache-service env vars to `run:` steps, so per-snapshot uploads aren't possible)
- Old state-cache entries are pruned automatically (the newest 3 are kept) to stay under the cache limit
- Docker images are **not cached** — they're pulled fresh each run (~2 min, in parallel with setup), so the cache budget is used only for the (tiny) database state archives
- The DB dump uses **maximum compression** (`pg_dump -Z 9`), so state archives stay tiny within the 10GB budget
- Analytics/log data lives in the separate `_supabase` database and is intentionally **not backed up** (it's disposable and would bloat every snapshot)
- Cache is **evicted** after 7 days of inactivity
- If cache is lost, you start fresh (schema is auto-created by Supabase SQL init scripts)

---

## 🆘 Troubleshooting

| Problem | Fix |
|---|---|
| Tunnel not connecting | Verify `CF_TUNNEL_TOKEN` is correct in GitHub Secrets |
| Can't access URL | Check Cloudflare Tunnel dashboard → tunnel status |
| Database not persisting | Check the "💿 Save final state to GitHub Actions cache" step in the run log — state is saved at session shutdown |
| Workflow not running on schedule | GitHub may delay schedule events during high load |
| "No space left on device" | GitHub runner has ~14GB free — clean up old Docker images |
| Port already in use | Runner resets between runs, should be fresh |
| Rate limited (429) | Open auth routes limited to 30 req/min; SSO ACS to 10 req/min |
| `supabase-pooler` restarting | Fixed automatically: the workflow restarts supavisor once the DB restore completes. If it still crash-loops, check the start step output for SMTP/.env config errors. |
| **Can't connect to Postgres — `…:5432` times out** | Expected, not a bug: Cloudflare's proxy drops port 5432 at the edge. Use `./remote.sh` for SQL, or `./pg-tunnel.sh` for a real connection (see [🐘 Connecting to Postgres](#-connecting-to-postgres-from-outside-pg-tunnelsh)) |
| `password authentication failed` on the pooler | Username must be `postgres.<POOLER_TENANT_ID>` (from `.env`), not bare `postgres` |
| DB refuses connections right after a session starts | Supavisor crash-loops for ~60s at boot; the workflow restarts it. Retry after a minute. |
| `cannot find an appropriate entrypoint` from an edge function | The function directory doesn't exist on the runner — commit it (the restore step runs `git checkout -- volumes/functions/`) and make sure it's whitelisted in `.gitignore` |
| Kong returning errors | Check workflow logs; `KONG_PROXY_ERROR_LOG` is output to stdout |
| Want object storage? | Add `storage` and `imgproxy` services back to `docker-compose.yml` and mount `storage` SQL init |

---

## 📚 Resources

- [Supabase Self-Hosting Docs](https://supabase.com/docs/guides/self-hosting/docker)
- [Cloudflare Tunnel Docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [GitHub Actions Cache](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/caching-dependencies-to-speed-up-workflows)
- [Supabase GitHub](https://github.com/supabase/supabase)
