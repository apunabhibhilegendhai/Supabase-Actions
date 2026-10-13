/**
 * workflow-watchman — Cloudflare Worker
 * ---------------------------------------
 * Monitors the Supabase-Actions and OpenDrive repos and restarts either
 * workflow when it has been inactive/dead longer than its grace period.
 *
 * Repo-specific behaviour:
 *   - Supabase-Actions (supabase-host.yml): 1 min grace — 24/7 session chaining
 *   - OpenDrive        (opendrive.yml):     90 s grace — 24/7 session chaining
 *     (both are fast-polled EVERY minute so the handoff gap stays ~1-2 min)
 *
 * OpenDrive's workflow is not dedicated to hosting: the same `opendrive.yml` also runs CI on every
 * push and the web publish, so its run history is a mix. Only the runs that actually start the API
 * host count for liveness/throttle, and those are the ones whose `run-name` starts with
 * "API host" (the workflow names them that way on purpose). `runNamePrefix` selects them.
 */

const OWNER = "apunabhibhilegendhai";

// ===== Per-repo configuration ================================================
// ONLY these two repositories are watched — everything else is intentionally
// absent. Both hold a single long-running (≈5h) session and need to be chained
// around the clock; the end-of-run self-chain handles the normal handoff and
// this worker covers what the self-chain cannot (a cancelled run, or a runner
// hard-killed at the 6h limit).
const REPO_CONFIGS = [
  // Supabase self-hosted. Sessions run ~5h05m then stop; restart the moment one
  // completes so the stack is up around the clock. Short grace = fast handoff.
  // restartOnFailure: true — a mid-session death surfaces as a health-check
  // `failure` and MUST be restarted.
  { repo: "Supabase-Actions", workflow: "supabase-host.yml", branch: "master", graceMs: 60 * 1000, throttleMax: 12, fastPoll: true, restartOnFailure: true },

  // OpenDrive API host. Sessions run ~5h then stop, same 24/7 chaining. This is a single workflow
  // that also carries CI and the web publish, so `runNamePrefix` restricts every liveness and
  // throttle decision to the runs that actually host the API — otherwise a busy push day would
  // look like a string of short "sessions" and both throttle the restarts and (because a failed CI
  // run is short) trip the pre-flight guard below.
  // restartOnFailure: false — this workflow fails *fast* only in its up-front
  // pre-flight (unreachable DATABASE_URL / tunnel), and restarting that would be
  // a ~5-minute crash loop. A *late* failure (preempted runner, hard kill) is
  // still restarted: the guard ignores the failure only when the run was short.
  { repo: "OpenDrive", workflow: "opendrive.yml", branch: "main", runNamePrefix: "API host", graceMs: 90 * 1000, throttleMax: 10, fastPoll: true, restartOnFailure: false },
];

const THROTTLE_WINDOW = 24 * 60 * 60 * 1000; // 24 hours
const HEALTH_CHECK_RETRIES = 6;
const HEALTH_CHECK_INTERVAL = 30 * 1000; // 30 seconds

// A FAILED run shorter than this is treated as an up-front pre-flight failure
// (see the crash-loop guard in evaluateRepo); anything longer died mid-session
// and is restarted. OpenDrive's pre-flight takes ~5 min, a real session ~5 h.
const MID_SESSION_MIN_MS = 30 * 60 * 1000;

// ===== Per-repo dispatch/notify guards =======================================
// lastDispatchAt: prevents double-dispatch races when the schedule-queued run
// and our dispatch land in the same cron window. lastErrorAt: caps Discord
// error spam to once per 30 min per repo (a broken config was alerting every 5 min).
//
// NOTE: these live in module state, which is per-isolate in Workers. With the
// 1-min cron, a slow health check (up to 3 min) can overlap the next scheduled
// invocation in a different isolate, where the cooldown isn't visible. This is
// acceptable: the active-run check (queued/pending counts as active) catches a
// just-dispatched run within seconds, a duplicate with cancel-in-progress: false
// only QUEUES (never cancels a live session), and throttleMax bounds the blast
// radius. A KV/cache-backed lock would close the window entirely if ever needed.
const DISPATCH_COOLDOWN_MS = 90 * 1000;
const ERROR_NOTIFY_INTERVAL_MS = 30 * 60 * 1000;
const lastDispatchAt = {};
const lastErrorAt = {};

// ===== Helpers ===============================================================

function ghHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    "User-Agent": "workflow-watchman/2.0",
    Accept: "application/vnd.github.v3+json",
  };
}

// GitHub secondary rate limits return HTTP 429 with a Retry-After header.
// Wrap every API call so short 429s back off and retry instead of failing
// the whole repo scan/restart. Primary rate limits (403 + ratelimit headers)
// are not retried — those would need to wait up to an hour.
const GH_MAX_ATTEMPTS = 3;
// If GitHub asks us to wait longer than this, don't hammer the endpoint —
// return the 429 and let the next cron cycle (5 min) pick the repo up.
const GH_BACKOFF_BUDGET_SEC = 90;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Retry-After is seconds ("60") or an HTTP-date; fall back to 5s.
function retryAfterSeconds(resp) {
  const ra = resp.headers.get("Retry-After");
  if (!ra) return 5;
  const secs = Number(ra);
  if (Number.isFinite(secs)) return Math.max(secs, 1);
  const dateMs = Date.parse(ra);
  if (Number.isFinite(dateMs)) {
    return Math.max(Math.ceil((dateMs - Date.now()) / 1000), 1);
  }
  return 5;
}

async function ghFetch(url, headers, init = {}) {
  for (let attempt = 1; attempt <= GH_MAX_ATTEMPTS; attempt++) {
    const resp = await fetch(url, { ...init, headers: { ...headers, ...(init.headers || {}) } });
    if (resp.status !== 429 || attempt === GH_MAX_ATTEMPTS) return resp;
    const wait = retryAfterSeconds(resp);
    if (wait > GH_BACKOFF_BUDGET_SEC) {
      console.log(
        `[gh] 429 on ${url} — Retry-After ${wait}s exceeds budget ${GH_BACKOFF_BUDGET_SEC}s, deferring to next cycle`
      );
      return resp;
    }
    console.log(`[gh] 429 on ${url} — backing off ${wait}s (attempt ${attempt}/${GH_MAX_ATTEMPTS})`);
    await sleep(wait * 1000);
  }
}

function fmtDuration(ms) {
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

// A repo config may restrict which runs count (see `runNamePrefix`). OpenDrive's single workflow
// carries CI, web publishes and API sessions in one run history; only the API sessions may drive
// liveness or the throttle, and those are exactly the runs named "API host…".
function selectRuns(runs, config) {
  const prefix = config.runNamePrefix;
  if (!prefix) return runs;
  return runs.filter((r) => typeof r.name === "string" && r.name.startsWith(prefix));
}

// ===== Discord notifications =================================================

async function sendDiscordAlert(env, repo, summary) {
  const url = env.DISCORD_WEBHOOK_URL;
  if (!url) return;
  const fields = [];
  if (summary.deadDuration) fields.push({ name: "Dead for", value: summary.deadDuration, inline: true });
  if (summary.lastConclusion) fields.push({ name: "Last conclusion", value: summary.lastConclusion, inline: true });
  fields.push({ name: "Restarts today", value: String(summary.restartsToday || 0), inline: true });
  const resp = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      embeds: [{
        title: `🔄 ${repo} restarted`,
        color: 15105570,
        description: summary.reason || "",
        fields,
        footer: { text: "workflow-watchman" },
        timestamp: new Date().toISOString(),
      }],
    }),
  });
  if (!resp.ok) console.error(`[notify] Discord webhook returned ${resp.status}`);
}

async function sendDiscordError(env, repo, message) {
  const url = env.DISCORD_WEBHOOK_URL;
  if (!url) return;
  await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      embeds: [{
        title: `⚠️ ${repo} error`,
        color: 15158332,
        description: message,
        footer: { text: "workflow-watchman" },
        timestamp: new Date().toISOString(),
      }],
    }),
  });
}

// ===== Dashboard / Metrics ===================================================

// Result cache for the public dashboard (60s TTL): each page view calls the
// GitHub API for EVERY repo, so a public worker URL without caching would let
// anyone exhaust the token's 5000/hr rate limit (DoS on restarts).
const DASHBOARD_CACHE_TTL = 60 * 1000;
let dashboardCache = null;
let dashboardCacheAt = 0;

async function fetchAllStatusCached(env) {
  const now = Date.now();
  if (dashboardCache && now - dashboardCacheAt < DASHBOARD_CACHE_TTL) {
    return dashboardCache;
  }
  dashboardCache = await fetchAllStatus(env);
  dashboardCacheAt = now;
  return dashboardCache;
}

function isDashboardAuthed(request, env) {
  const secret = env.DASHBOARD_TOKEN;
  if (!secret) return true; // no token configured -> open (cache still protects rate limit)
  const provided = request.headers.get("x-watchman-token") || 
    new URL(request.url).searchParams.get("token") || "";
  return provided === secret;
}

const STATUS_ICON = {
  in_progress: "🟢",
  queued: "🟡",
  pending: "🟡",
  completed: "⚪",
};

function renderDashboard(repos) {
  const rows = repos
    .map((r) => {
      const icon = STATUS_ICON[r.status] || "⚪";
      let age = "—";
      if (r.lastRun) {
        const ms = Date.now() - new Date(r.lastRun).getTime();
        if (ms < 60000) age = "<1m";
        else if (ms < 3600000) age = `${Math.floor(ms / 60000)}m`;
        else age = `${Math.floor(ms / 3600000)}h ${Math.floor((ms % 3600000) / 60000)}m`;
      }
      return `<tr>
        <td><strong>${r.name}</strong></td>
        <td>${icon} ${r.status || "no runs"}</td>
        <td>${r.lastRun ? new Date(r.lastRun).toISOString().replace("T", " ").slice(0, 16) + " UTC" : "—"}</td>
        <td>${age}</td>
        <td>${r.restarts ?? 0}</td>
      </tr>`;
    })
    .join("\n");
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>workflow-watchman</title>
<style>
* { margin:0; padding:0; box-sizing:border-box; }
body { font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif; background:#0b0d11; color:#cdd0d4; padding:40px 20px; }
h1 { font-size:24px; font-weight:600; margin-bottom:4px; color:#e5ebf0; }
.subtitle { color:#6b7280; font-size:14px; margin-bottom:24px; }
table { width:100%; border-collapse:collapse; background:#13161b; border-radius:8px; overflow:hidden; }
th { text-align:left; padding:12px 16px; font-size:12px; text-transform:uppercase; letter-spacing:0.05em; color:#9ca3af; border-bottom:1px solid #1f2937; }
td { padding:12px 16px; border-bottom:1px solid #1a1f26; font-size:14px; }
tr:last-child td { border-bottom:none; }
tr:hover td { background:#1a1f26; }
.badge { display:inline-block; padding:2px 8px; border-radius:4px; font-size:11px; font-weight:600; }
.badge-ok { background:#065f46; color:#6ee7b7; }
.badge-warn { background:#78350f; color:#fcd34d; }
.badge-err { background:#7f1d1d; color:#fca5a5; }
.meta { margin-top:16px; font-size:12px; color:#6b7280; }
.meta span { margin-right:16px; }
a { color:#3b82f6; }
</style>
</head>
<body>
<h1>🛡️ workflow-watchman</h1>
<p class="subtitle">Monitoring ${repos.length} repos • cron */1 * * * * (fast-poll)</p>
<table>
<thead><tr><th>Repo</th><th>Status</th><th>Last Run</th><th>Age</th><th>Restarts</th></tr></thead>
<tbody>${rows}</tbody>
</table>
<p class="meta">
<span>Last check: ${new Date().toISOString().replace("T", " ").slice(0, 19)} UTC</span>
<span><a href="/__metrics">JSON metrics</a></span>
</p>
</body>
</html>`;
}

function renderMetrics(repos) {
  return {
    checkedAt: new Date().toISOString(),
    totalRepos: repos.length,
    running: repos.filter((r) => r.status === "in_progress").length,
    idle: repos.filter((r) => !r.status || r.status === "completed").length,
    repos: Object.fromEntries(
      repos.map((r) => [
        r.name,
        {
          status: r.status || "no_runs",
          lastRun: r.lastRun,
          lastConclusion: r.lastConclusion,
          restarts: r.restarts ?? 0,
        },
      ])
    ),
  };
}

// ===== Core logic ============================================================

async function evaluateRepo(config, headers) {
  const { repo, workflow, graceMs, throttleMax } = config;
  // Fetch a wide window, then drop runs that are not sessions of the long-running host. A single
  // workflow that also carries CI can otherwise bury the in-progress session under a busy day of
  // push runs and look "idle".
  const resp = await ghFetch(
    `https://api.github.com/repos/${OWNER}/${repo}/actions/workflows/${workflow}/runs?per_page=100`,
    headers
  );
  if (!resp.ok) throw new Error(`runs API: ${resp.status}`);

  const { workflow_runs: allRuns } = await resp.json();
  const runs = selectRuns(allRuns || [], config);
  const state = {
    name: repo,
    needsRestart: false,
    status: null,
    lastRun: null,
    lastConclusion: null,
    deadDuration: null,
    restarts: 0,
  };

  // No runs ever → needs restart
  if (!runs || runs.length === 0) {
    state.needsRestart = true;
    state.reason = "No runs ever";
    return state;
  }

  // Active run → no restart needed
  const activeRun = runs.find(
    (r) => r.status === "in_progress" || r.status === "queued" || r.status === "pending"
  );
  if (activeRun) {
    state.status = activeRun.status;
    state.lastRun = activeRun.run_started_at || activeRun.created_at;
    state.lastConclusion = null;
    return state;
  }

  // Latest completed run. Age is measured from updated_at (approximately completion
  // time), not run_started_at - for a 5h30m session those differ by hours, and the
  // grace window is meant to say "how long since the session ENDED".
  const latest = runs[0];
  state.status = latest.status;
  state.lastRun = latest.run_started_at || latest.created_at;
  state.lastConclusion = latest.conclusion;
  const endedAt = new Date(latest.updated_at || latest.created_at).getTime();
  const age = Number.isFinite(endedAt) ? Date.now() - endedAt : Infinity; // null -> treat as very old

  // Grace period check
  if (age < graceMs) return state;

  // Per-repo crash-loop guard. Some workflows (OpenDrive's api-host) only ever
  // fail *fast*, in an up-front pre-flight against an unreachable database, so a
  // blanket "restart on failure" would loop every few minutes. But a failure
  // that came *late* means the session died mid-flight (preempted runner, hard
  // kill) and MUST be recovered — the hourly schedule is not a reliable backstop
  // for this account. So a `failure` is ignored only when the run was short.
  // restartOnFailure defaults to true: repos without the flag always restart.
  if (config.restartOnFailure === false && latest.conclusion === "failure") {
    const startedAt = new Date(latest.run_started_at || latest.created_at).getTime();
    const ranMs = Number.isFinite(startedAt) ? endedAt - startedAt : 0;
    if (ranMs < MID_SESSION_MIN_MS) {
      state.reason = `Last run failed after ${fmtDuration(ranMs)} — pre-flight, not restarting`;
      return state;
    }
  }

  // Throttle check — count completions within the 24h window from fetched runs
  const recentCompletions = runs.filter((r) => {
    if (r.status !== "completed") return false;
    // GitHub marks cancelled runs as status 'completed' with conclusion 'cancelled'.
    // Those would silently eat the restart budget (the schedule+watchman handoff
    // cancels a duplicate queued run almost every cycle) - exclude them.
    if (r.conclusion === "cancelled") return false;
    return new Date(r.created_at).getTime() > Date.now() - THROTTLE_WINDOW;
  });
  state.restarts = recentCompletions.length;
  if (recentCompletions.length >= throttleMax) {
    state.reason = `Throttled (${recentCompletions.length} runs in 24h)`;
    state.throttled = true;
    return state;
  }

  // Needs restart
  state.needsRestart = true;
  state.deadDuration = fmtDuration(age);
  state.reason = latest.conclusion
    ? `Last run ${latest.conclusion} at ${latest.run_started_at}`
    : "No recent activity";
  return state;
}

async function executeRestart(config, state, headers, env) {
  const { repo, workflow, branch } = config;
  const now = Date.now();
  if (now - (lastDispatchAt[repo] || 0) < DISPATCH_COOLDOWN_MS) {
    console.log(`[${repo}] skipping dispatch (cooldown)`);
    return;
  }
  lastDispatchAt[repo] = now;
  console.log(`[${repo}] restarting — ${state.reason}`);

  const body = JSON.stringify({ ref: branch, inputs: { triggered_by: "workflow-watchman" } });

  const dispatchResp = await ghFetch(
    `https://api.github.com/repos/${OWNER}/${repo}/actions/workflows/${workflow}/dispatches`,
    headers,
    { method: "POST", headers: { "Content-Type": "application/json" }, body }
  );
  if (!dispatchResp.ok) throw new Error(`dispatch API: ${dispatchResp.status}`);

  console.log(`[${repo}] dispatched`);
  await sendDiscordAlert(env, repo, {
    reason: state.reason,
    deadDuration: state.deadDuration,
    lastConclusion: state.lastConclusion,
    restartsToday: state.restarts + 1,
  });

  // Health check — poll GitHub until the new run appears
  const healthOk = await healthCheck(config, headers);
  if (!healthOk) {
    await sendDiscordError(env, repo, "Health check failed — new run did not start within 3 min");
  } else {
    console.log(`[${repo}] health check passed`);
  }
}

async function healthCheck(config, headers) {
  const { repo, workflow } = config;
  for (let i = 0; i < HEALTH_CHECK_RETRIES; i++) {
    await new Promise((r) => setTimeout(r, HEALTH_CHECK_INTERVAL));
    const resp = await ghFetch(
      `https://api.github.com/repos/${OWNER}/${repo}/actions/workflows/${workflow}/runs?per_page=10`,
      headers
    );
    if (!resp.ok) continue;
    const { workflow_runs: runs } = await resp.json();
    // The dispatched session is the newest run *of its kind*: a push CI run may have landed after
    // it, so look only at the API-session runs.
    const latest = selectRuns(runs || [], config)[0];
    if (!latest) continue;
    const runAge = Date.now() - new Date(latest.created_at).getTime();
    if (runAge < HEALTH_CHECK_INTERVAL * (i + 1) + 10000) {
      // A run created since we dispatched proves the dispatch took effect.
      // Accept any status - a run that starts then fails fast is a workflow bug,
      // not a failed dispatch (and the next cycle will see it and re-evaluate).
      if (latest.status === "in_progress" || latest.status === "queued" || latest.status === "pending" || latest.conclusion) {
        console.log(`[${repo}] health check OK — run ${latest.id} ${latest.status}${latest.conclusion ? " (" + latest.conclusion + ")" : ""}`);
        return true;
      }
    }
  }
  return false;
}

async function fetchAllStatus(env) {
  const token = env.GITHUB_TOKEN;
  if (!token) return [];
  const headers = ghHeaders(token);
  const results = new Array(REPO_CONFIGS.length);
  await runWithConcurrency(REPO_CONFIGS, 4, async (config, i) => {
    try {
      results[i] = await evaluateRepo(config, headers);
    } catch {
      results[i] = { name: config.repo, status: "error" };
    }
  });
  return results;
}

// ===== Concurrency =====================================================
// Run configs with at most `limit` in flight. GitHub secondary rate limits
// can 429 a full 15-way burst, so restart work is capped at 4 at a time.
async function runWithConcurrency(configs, limit, fn) {
  let index = 0;
  const workers = Array.from(
    { length: Math.min(limit, configs.length) },
    async () => {
      while (index < configs.length) {
        const i = index++;
        await fn(configs[i], i);
      }
    }
  );
  await Promise.allSettled(workers);
}

// ===== Worker handlers =======================================================

export default {
  async scheduled(event, env, ctx) {
    const token = env.GITHUB_TOKEN;
    if (!token) {
      console.error("GITHUB_TOKEN not set");
      return;
    }
    const headers = ghHeaders(token);
    // Fast-poll gate: the cron fires every minute, and every configured repo is
    // flagged `fastPoll`, so all of them are checked on EVERY tick (~1-minute
    // detection of a dead session). The 5th-minute gate is retained for any
    // future repo that wants a cheaper cadence.
    const isNodeTick = Math.floor(Date.now() / 60000) % 5 === 0;
    await runWithConcurrency(REPO_CONFIGS, 4, async (config) => {
      if (!config.fastPoll && !isNodeTick) return;
      try {
        const state = await evaluateRepo(config, headers);
        if (state.needsRestart) {
          await executeRestart(config, state, headers, env);
        }
      } catch (err) {
        console.error(`[${config.repo}] error: ${err.message}`);
        const now = Date.now();
        if (now - (lastErrorAt[config.repo] || 0) >= ERROR_NOTIFY_INTERVAL_MS) {
          lastErrorAt[config.repo] = now;
          await sendDiscordError(env, config.repo, err.message);
        }
      }
    });
  },

  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/__health") return new Response("OK", { status: 200 });
    if (url.pathname === "/__metrics" || url.pathname === "/" || url.pathname === "") {
      if (!isDashboardAuthed(request, env)) {
        return new Response("Unauthorized", { status: 401 });
      }
    }
    if (url.pathname === "/__metrics") {
      const data = await fetchAllStatusCached(env);
      return new Response(JSON.stringify(renderMetrics(data), null, 2), {
        headers: { "Content-Type": "application/json" },
      });
    }
    if (url.pathname === "/" || url.pathname === "") {
      const data = await fetchAllStatusCached(env);
      return new Response(renderDashboard(data), {
        headers: { "Content-Type": "text/html" },
      });
    }
    return new Response("Not found", { status: 404 });
  },
};
