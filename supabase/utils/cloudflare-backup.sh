#!/usr/bin/env bash
# =============================================================================
# ☁️  cloudflare-backup.sh — off-site state backup to Cloudflare Workers KV
# =============================================================================
# Why KV (not R2): KV is card-free (no payment method required) and is usable
# with the wrangler/tunnel credentials this stack already has. KV caps each
# value at 25 MiB, so larger archives are split into CHUNK_BYTES-sized chunks.
#
# Namespace layout:
#   latest/<base>.<NN>         chunks of the CURRENT (freshest) archive
#   latest/manifest.json       {file, ts, parts, size, sha256}
#   archive/<ts>/<base>.<NN>   same bytes, timestamped (rolling history)
#   archive/<ts>/manifest.json
#
# Retention: the freshest set is always under 'latest/' (overwritten each
# push). Each push also stamps the same bytes under archive/<now>/ but then
# prunes to KEEP_ARCHIVES generations — so the OLDEST archive is deleted
# automatically and the store never grows forever. It always holds the latest
# backup and at most one previous generation.
#
# The runner keeps no growing local history either: snapshots overwrite a single
# on-disk archive and chunk temp dirs are removed after each push.
#
# Usage:
#   cloudflare-backup.sh push <file>            # upload + prune oldest
#   cloudflare-backup.sh restore <outfile>      # pull latest and reassemble
#   cloudflare-backup.sh manifest               # print latest backup's unix ts
#   cloudflare-backup.sh verify                 # confirm 'latest' is restorable (size+sha256)
#   cloudflare-backup.sh refresh                # renew access token from the .env refresh token
#   cloudflare-backup.sh list                   # show keys + retention state
#
# NOTE on OAuth tokens: Cloudflare 'cfor*' refresh tokens are SINGLE-USE and
# rotate on every mint. The workflow keeps the rotated token in supabase/.env so
# the chain survives on a persistent runner; a fresh runner needs either a
# permanent API token (preferred — set CLOUDFLARE_BACKUP_TOKEN to it) or a
# re-seeded refresh token.
#
# Config (read from supabase/.env, or from the environment):
#   CF_ACCOUNT_ID, CF_KV_NAMESPACE_ID, CF_API_TOKEN
#   (CF_API_TOKEN needs Workers KV Storage → Edit on the account)
# =============================================================================
set -uo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CF_ENV="$BASE_DIR/.env"

CHUNK_BYTES=$((24 * 1024 * 1024))   # 24 MiB (KV hard limit is 25 MiB)
KEEP_ARCHIVES=1                      # generations kept under archive/ (oldest pruned)
MIN_PUSH_BYTES=30000                     # floor: anything this small is an empty/aborted dump
# (A healthy Supabase DB dump is normally far above this; snapshot-state.sh keeps the last
# good dump around and guards its own tiny-dump clobbering, so a sub-30KB full archive is
# near-certainly empty. The 500KB guard we started with wrongly suppressed legitimately
# small-but-valid databases.)

CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
CF_KV_NAMESPACE_ID="${CF_KV_NAMESPACE_ID:-}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_REFRESH_TOKEN="${CF_REFRESH_TOKEN:-}"

# Wrangler OAuth app (public client, used by `wrangler login`) — lets us renew
# the short-lived access token from the long-lived refresh token. Cloudflare's
# token endpoint also accepts Basic auth w/ client_id:client_secret, but this
# OAuth client is public so body-only is enough (matches wrangler's own code).
CF_OAUTH_CLIENT_ID="54d11594-84e4-41aa-b438-e81b8fa78ee7"

# ---------------------------------------------------------------------------
load_cfg() {
  if [ -f "$CF_ENV" ]; then
    CF_ACCOUNT_ID="$(grep -E '^CF_ACCOUNT_ID=' "$CF_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    CF_KV_NAMESPACE_ID="$(grep -E '^CF_KV_NAMESPACE_ID=' "$CF_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    CF_API_TOKEN="$(grep -E '^CF_API_TOKEN=' "$CF_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
    CF_REFRESH_TOKEN="$(grep -E '^CF_REFRESH_TOKEN=' "$CF_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
  fi
}

# Renew the OAuth access token from CF_REFRESH_TOKEN; rotates the refresh token
# too (Cloudflare refresh tokens are single-use) and persists both to .env so
# later snapshots and sibling processes stay in sync. The rotated token is also
# written to .cf-creds, which is archived with the state — without that, a
# rotation mid-session left the NEXT session holding an already-consumed token
# and the off-site backup chain died after one session.
cf_refresh_token() {
  [ -n "$CF_REFRESH_TOKEN" ] || return 1
  local resp at rt
  resp="$(curl -sS --max-time 20 -X POST "https://dash.cloudflare.com/oauth2/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "grant_type=refresh_token&refresh_token=$CF_REFRESH_TOKEN&client_id=$CF_OAUTH_CLIENT_ID")"
  at="$(printf '%s' "$resp" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
  [ -n "$at" ] || return 1
  rt="$(printf '%s' "$resp" | sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p')"
  CF_API_TOKEN="$at"
  if [ -f "$CF_ENV" ]; then
    sed -i -E '/^CF_API_TOKEN=/d; /^CF_REFRESH_TOKEN=/d' "$CF_ENV" 2>/dev/null || true
    {
      echo "CF_API_TOKEN=$at"
      [ -n "$rt" ] && echo "CF_REFRESH_TOKEN=$rt"
    } >> "$CF_ENV"
  fi
  # Archive-visible copy of the (single-use) refresh token — only overwrite
  # when Cloudflare actually handed back a rotation.
  if [ -n "$rt" ]; then
    printf 'CF_REFRESH_TOKEN=%s\n' "$rt" > "$BASE_DIR/.cf-creds" 2>/dev/null || true
    chmod 600 "$BASE_DIR/.cf-creds" 2>/dev/null || true
  fi
  echo "  ☁️  Cloudflare OAuth access token refreshed (~1h)"
  return 0
}

# put with a single 401 → refresh-retry (access tokens only live ~1h).
put_with_retry() {
  if put_value "$1" "$2"; then
    return 0
  fi
  cf_refresh_token && put_value "$1" "$2"
}

cfg_ok() {
  [ -n "$CF_ACCOUNT_ID" ] && [ -n "$CF_KV_NAMESPACE_ID" ] && [ -n "$CF_API_TOKEN" ]
}

# URL-encode only what our generated keys contain (keeps path-safe chars intact)
urlenc() {
  local s="$1" c
  local i len=${#s}
  for ((i = 0; i < len; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
list_keys() {  # list_keys <urlencoded-prefix> -> one key per line, may paginate
  local prefix="$1" cursor="" body keys k
  while :; do
    local q="?limit=1000&prefix=$prefix"
    [ -n "$cursor" ] && q="$q&cursor=$cursor"
    body="$(curl -s "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/keys$q" \
      -H "Authorization: Bearer $CF_API_TOKEN")"
    keys="$(printf '%s' "$body" | grep -o '"name":"[^"]*"' | sed 's/"name":"//; s/"$//')"
    [ -n "$keys" ] && printf '%s\n' "$keys"
    cursor="$(printf '%s' "$body" | grep -o '"cursor":"[^"]*"' | head -1 | sed 's/"cursor":"//; s/"$//')"
    [ -z "$cursor" ] && break
  done
}

prune_archives() {
  local all keep="" oldest="" tss="" ts
  all="$(list_keys 'archive%2F')"      # encoded "archive/"
  [ -z "$all" ] && return 0
  tss="$(printf '%s\n' "$all" | sed -n 's|^archive/\([0-9]*\)/.*|\1|p' | sort -un)"
  [ -z "$tss" ] && return 0
  # newest KEEP_ARCHIVES generations survive; everything older gets deleted
  keep="$(printf '%s\n' "$tss" | tail -n "$KEEP_ARCHIVES")"
  local doomed="" k
  while IFS= read -r ts; do
    if ! printf '%s\n' "$keep" | grep -qx "$ts"; then
      while IFS= read -r k; do
        doomed="$doomed${doomed:+,}\"$k\""
      done <<EOF
$(printf '%s\n' "$all" | grep "^archive/$ts/")
EOF
    fi
  done <<EOF
$tss
EOF
  if [ -n "$doomed" ]; then
    local k code
    for k in $(printf '%s' "$doomed" | tr ',' '\n'); do
      k="${k#\"}"; k="${k%\"}"
      local enc enc_key
      enc_key=""
      # encode the key for the URL path
      local i len=${#k} c
      for ((i = 0; i < len; i++)); do
        c="${k:i:1}"
        case "$c" in
          [a-zA-Z0-9._-]) enc_key="$enc_key$c" ;;
          *) enc_key="$enc_key$(printf '%%%02X' "'$c")" ;;
        esac
      done
      code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
        "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/values/$enc_key" \
        -H "Authorization: Bearer $CF_API_TOKEN")"
      [ "$code" = "200" ] || echo "  ⚠️  delete of $k returned HTTP $code"
    done
    echo "  🧹 pruned $(printf '%s' "$doomed" | tr ',' '\n' | wc -l | tr -d ' ') old archive key(s) (kept newest $KEEP_ARCHIVES generation(s))"
  fi
}

put_value() {  # put_value <key> <file>
  local key="$1" file="$2" code
  code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/values/$(urlenc "$key")" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/octet-stream" --data-binary "@$file")"
  [ "$code" = "200" ]
}

get_value() {  # get_value <key> <outfile>  (curl exit code 0 = found)
  local key="$1" dest="$2"
  curl -s -o "$dest" -f \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$CF_KV_NAMESPACE_ID/values/$(urlenc "$key")" \
    -H "Authorization: Bearer $CF_API_TOKEN"
}

# ---------------------------------------------------------------------------
cmd_push() {
  # argv here is the ARGUMENTS ONLY: the dispatcher shifts the subcommand off, and
  # snapshot-state.sh invokes the CLI. Reading "$2" instead meant the positional was
  # always empty when cmd_verify called a sibling function directly.
  local file="${1:-}"
  load_cfg
  if ! cfg_ok; then
    echo "  ::warning::Cloudflare backup SKIPPED — CF_API_TOKEN/CF_KV_NAMESPACE_ID not configured"
    return 0
  fi
  [ -n "$file" ] || { echo "  ⚠️  usage: cloudflare-backup.sh push <file>"; return 1; }
  [ -s "$file" ] || { echo "  ☁️  nothing to push ($file missing/empty)"; return 0; }

  local size base ts tmp sha manifest parts nn code
  size="$(stat -c%s "$file")"
  if [ "$size" -lt "$MIN_PUSH_BYTES" ]; then
    echo "  ☁️  archive too small (${size}B) — not pushing to Cloudflare"
    return 0
  fi
  base="$(basename "$file")"
  ts="$(date +%s)"
  tmp="$(mktemp -d)"
  sha="$(sha256sum "$file" | cut -d' ' -f1)"

  split -b "$CHUNK_BYTES" -d -a 2 "$file" "$tmp/chunk."
  parts=0
  for f in "$tmp"/chunk.*; do
    nn="${f##*.}"
    if put_with_retry "latest/$base.$nn" "$f" && put_with_retry "archive/$ts/$base.$nn" "$f"; then
      parts=$((parts + 1))
    else
      echo "  ::warning::Cloudflare backup: chunk $nn upload failed — previous latest left intact"
      rm -rf "$tmp"
      return 1
    fi
  done

  manifest="{\"file\":\"$base\",\"ts\":$ts,\"parts\":$parts,\"size\":$size,\"sha256\":\"$sha\"}"
  printf '%s' "$manifest" > "$tmp/manifest.json"
  if put_with_retry "latest/manifest.json" "$tmp/manifest.json" && put_with_retry "archive/$ts/manifest.json" "$tmp/manifest.json"; then
    echo "  ☁️  backup pushed: $base (${parts}+1 keys, $(du -h "$file" | cut -f1)) → latest/ + archive/$ts/"
    prune_archives
  else
    echo "  ⚠️  manifest upload failed"
  fi
  rm -rf "$tmp"
}

cmd_restore() {
  # argv is ARGUMENTS ONLY (dispatcher shifts the subcommand). cmd_verify calls this
  # with a single path, so "$2" was empty and restore always printed its usage line.
  local outfile="${1:-}"
  load_cfg
  if ! cfg_ok; then
    echo "  ☁️  Cloudflare restore SKIPPED — CF_API_TOKEN/CF_KV_NAMESPACE_ID not configured"
    return 0
  fi
  [ -n "$outfile" ] || { echo "  ⚠️  usage: cloudflare-backup.sh restore <outfile>"; return 1; }

  local tmp manifest mf base parts size sha ok part
  tmp="$(mktemp -d)"
  ok=1
  get_value "latest/manifest.json" "$tmp/manifest.json" || ok=0
  if [ "$ok" != 1 ] || [ ! -s "$tmp/manifest.json" ]; then
    echo "  ☁️  no backup found in Cloudflare (latest/manifest.json missing)"
    rm -rf "$tmp"
    return 0
  fi
  mf="$(cat "$tmp/manifest.json")"
  base="$(printf '%s' "$mf" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')"
  parts="$(printf '%s' "$mf" | sed -n 's/.*"parts":\([0-9]*\).*/\1/p')"
  size="$(printf '%s' "$mf" | sed -n 's/.*"size":\([0-9]*\).*/\1/p')"
  sha="$(printf '%s' "$mf" | sed -n 's/.*"sha256":"\([0-9a-f]*\)".*/\1/p')"
  [ -n "$parts" ] && [ "$parts" -ge 1 ] || { echo "  ⚠️  manifest unreadable"; rm -rf "$tmp"; return 1; }

  for ((i = 0; i < parts; i++)); do
    nn="$(printf '%02d' "$i")"
    if ! get_value "latest/$base.$nn" "$tmp/part.$nn"; then
      echo "  ⚠️  chunk latest/$base.$nn missing — aborting (archive may be mid-upload)"
      rm -rf "$tmp"
      return 1
    fi
  done
  : > "$outfile"
  for ((i = 0; i < parts; i++)); do
    nn="$(printf '%02d' "$i")"
    cat "$tmp/part.$nn" >> "$outfile"
  done

  local got
  got="$(stat -c%s "$outfile")"
  if [ "$got" != "$size" ]; then
    echo "  ⚠️  size mismatch (got ${got}B, expected ${size}B) — discarding"
    rm -f "$outfile"
    rm -rf "$tmp"
    return 1
  fi
  local gotsha
  gotsha="$(sha256sum "$outfile" | cut -d' ' -f1)"
  if [ "$gotsha" != "$sha" ]; then
    echo "  ⚠️  sha256 mismatch — discarding"
    rm -f "$outfile"
    rm -rf "$tmp"
    return 1
  fi
  echo "  ☁️  restored from Cloudflare: $outfile (${parts} chunks, $(du -h "$outfile" | cut -f1), sha256 ok)"
  rm -rf "$tmp"
}

# Print the unix ts of the freshest off-site backup (stdout only, nothing on
# failure). The restore step compares this against the cached archive's
# embedded state-ts and adopts whichever is NEWER — a cancelled session never
# reaches the end-of-run cache save, so the KV mirror can be the only recent
# copy of the state.
cmd_manifest() {
  local ts=""
  load_cfg
  cfg_ok || return 0
  local tmp
  tmp="$(mktemp)"
  if get_value "latest/manifest.json" "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    ts="$(sed -n 's/.*"ts":\([0-9][0-9]*\).*/\1/p' "$tmp" | head -1)"
  fi
  rm -f "$tmp"
  printf '%s' "$ts"
  return 0
}

cmd_refresh() {
  load_cfg
  if [ -z "$CF_REFRESH_TOKEN" ]; then
    echo "  ⚠️  no refresh token in .env — nothing to refresh"
    return 1
  fi
  if cf_refresh_token; then
    echo "  ☁️  access token renewed from the .env refresh token"
    return 0
  fi
  echo "  ⚠️  refresh from .env failed (token expired/revoked)"
  return 1
}

cmd_verify() {
  local tmp rc=0
  load_cfg
  if ! cfg_ok; then
    echo "  ⚠️  Cloudflare verify SKIPPED — CF_API_TOKEN/CF_KV_NAMESPACE_ID not configured"
    return 0
  fi
  tmp="$(mktemp -d)"
  cmd_restore "$tmp/candidate.tar.gz" || rc=1
  if [ "$rc" = 0 ] && [ -s "$tmp/candidate.tar.gz" ]; then
    echo "  ☁️  verify OK — latest backup is restorable ($(du -h "$tmp/candidate.tar.gz" | cut -f1))"
  else
    echo "  ::warning::Cloudflare verify FAILED — latest backup is NOT restorable"
    rc=1
  fi
  rm -rf "$tmp"
  return $rc
}

cmd_list() {
  load_cfg
  if ! cfg_ok; then
    echo "  ☁️  Cloudflare KV not configured"; return 0
  fi
  local all n
  all="$(list_keys '')"
  n="$(printf '%s\n' "$all" | grep -c '^latest\|^archive' || true)"
  if [ -z "$all" ]; then
    echo "  ☁️  namespace empty"
  else
    echo "  ☁️  $n keys:"
    printf '%s\n' "$all" | sed 's/^/      /'
  fi
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  push)    shift; cmd_push "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  manifest) cmd_manifest "$@" ;;
  verify)  cmd_verify "$@" ;;
  refresh) cmd_refresh "$@" ;;
  list)    cmd_list ;;
  *) echo "usage: cloudflare-backup.sh {push <file> | restore <outfile> | manifest | verify | refresh | list}"; exit 1 ;;
esac