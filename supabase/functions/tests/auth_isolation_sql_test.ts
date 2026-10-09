// Supabase-Auth accounts against the full migration chain on the image Supabase runs, through real PostgREST
// with real role-switching JWTs. Nothing is stubbed except GoTrue's `/auth/v1/user` (the Auth server itself is
// exercised end to end by the Swift suite in StrandTests/NaraEndToEndTests.swift).
//
// Docker-gated like multiuser_sql_test.ts: supabase/tests/e2e/pipeline_db.sh builds the database and prints the
// variables that switch this on. Run it against a fresh database (`pipeline_db.sh reset`).
//
// Two tests:
//   1. The client-reachable surface of the schema, as a catalogue: which tables are row-level secured, what every
//      policy is written in terms of, and exactly which functions a signed-in or anonymous caller may execute.
//      A new table, policy or function that widens this fails here until somebody has reviewed it.
//   2. Two accounts, two installations, two devices, driven through the production Edge handlers and the
//      production database: ownership comes from the credential, never from a request, and nothing one account
//      sends reaches the other's rows, devices, sources, credentials or scores.
import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import { createSupabaseRest } from "../_shared/rest.ts";
import {
  CURRENT_INSTALLATION_TOKEN_HEADER,
  createInstallationProvisioning,
} from "../_shared/provisioning.ts";
import { createInstallationLifecycle } from "../_shared/installationLifecycle.ts";
import { createNoopDeviceResolver } from "../_shared/devices.ts";
import { resolveUploadIdentity } from "../_shared/tokens.ts";

const container = Deno.env.get("PIPELINE_TEST_DATABASE_CONTAINER");
const restUrl = Deno.env.get("PIPELINE_TEST_REST_URL");
const JWT_SECRET = "isolated-pipeline-jwt-secret-never-used-outside-tests";

function b64url(value: string) {
  return btoa(value).replaceAll("=", "").replaceAll("+", "-").replaceAll("/", "_");
}
function signJwt(role: string, sub?: string) {
  const header = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = b64url(
    JSON.stringify({ role, sub, aud: "authenticated", exp: Math.floor(Date.now() / 1000) + 3600 }),
  );
  const signature = createHmac("sha256", JWT_SECRET).update(`${header}.${body}`).digest("base64url");
  return `${header}.${body}.${signature}`;
}
function verifiedSub(jwt: string): string | null {
  const [header, body, signature] = jwt.split(".");
  if (!header || !body || !signature) return null;
  const expected = createHmac("sha256", JWT_SECRET).update(`${header}.${body}`).digest("base64url");
  if (expected !== signature) return null;
  try {
    return JSON.parse(atob(body.replaceAll("-", "+").replaceAll("_", "/"))).sub ?? null;
  } catch {
    return null;
  }
}

async function docker(args: string[], input?: string) {
  const child = new Deno.Command("docker", { args, stdin: "piped", stdout: "piped", stderr: "piped" }).spawn();
  const writer = child.stdin.getWriter();
  if (input) await writer.write(new TextEncoder().encode(input));
  await writer.close();
  const result = await child.output();
  assert.equal(result.code, 0, new TextDecoder().decode(result.stderr));
  return new TextDecoder().decode(result.stdout).trim();
}
const sql = (text: string) =>
  docker(["exec", "-i", container!, "psql", "-U", "postgres", "-d", "postgres", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"], text);
const sqlJson = async (text: string) => JSON.parse(await sql(text));

const serviceRest = createSupabaseRest({
  cfg: { supabaseUrl: restUrl ?? "http://127.0.0.1:0", supabaseServiceRoleKey: signJwt("service_role") },
  fetchImpl: (input, init) =>
    fetch(String(input).replace("/rest/v1/", "/"), { ...init, signal: AbortSignal.timeout(15000) }),
});

interface Reply { status: number; body: any }
async function call(token: string | null, method: string, path: string, body?: unknown): Promise<Reply> {
  const response = await fetch(`${restUrl}/${path}`, {
    method,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "application/json",
      prefer: "return=representation",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
  });
  const text = await response.text();
  let parsed: any = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = text;
  }
  return { status: response.status, body: parsed };
}
const refused = (reply: Reply) => [401, 403].includes(reply.status);
const affected = (reply: Reply) => (reply.status >= 200 && reply.status < 300 && Array.isArray(reply.body) ? reply.body.length : 0);

// ---------------------------------------------------------------------------------------------------------
// 1. The catalogue
// ---------------------------------------------------------------------------------------------------------

/** Public tables that deliberately have no row-level security: configuration read by the signed-in role only. */
const TABLES_WITHOUT_RLS = ["compute_family_policy"];

/** Policies that are not written in terms of the caller: read-only reference data shared by every account. */
const SHARED_REFERENCE_POLICIES = [
  "energy_model_versions.energy_model_versions_select",
  "physiology_algorithm_versions.read_versions",
  "physiology_feature_defaults.read_versions",
  "physiology_feature_manifests.physiology_feature_manifest_read",
  "physiology_feature_qualifications.read_versions",
];

/**
 * Every function a signed-in or anonymous caller can execute in `public`. Adding to this list is a review
 * decision: a SECURITY DEFINER function here must check `auth.uid()` / `auth.role()` itself, and an invoker
 * function runs under the caller's row-level security.
 */
const CLIENT_CALLABLE_FUNCTIONS = [
  // Already shipped, missing from this list (INTEGRATION_HANDOFF.md): an invoker lookup under the caller's RLS
  // (20261004150000_activity_context_canonical_class.sql) and the owner's own day values, keyed by auth.uid()
  // (20261008000000_metric_insights.sql).
  "activity_context_at",
  "continue_legacy_physiology_sleep_override",
  "daily_metrics_steps_recompute",
  "day_bounds",
  "get_day_snapshot",
  "get_days",
  "get_energy_day",
  "get_energy_range",
  "get_energy_workout",
  "get_frwhoop_day",
  "get_frwhoop_range",
  "get_range",
  "get_scoring_history_input_head_v3",
  "get_scoring_history_input_v3",
  "get_server_score_snapshot_v2",
  "get_sync_revision",
  "hr_series_occupied_buckets",
  "local_calendar_date",
  "metric_insight_day_values_v1",
  // The caller's own sync health (20261009110000_account_sync_health.sql): keyed by auth.uid(), takes no owner.
  "my_sync_health_v1",
  "noop_keep_device_owner",
  "physiology_feature_is_canonical",
  "physiology_owned_sleep_overrides",
  "physiology_processing_metadata",
  "physiology_required_revision",
  "physiology_shadow_model_for_day",
  "profile_timezone",
  "put_scoring_history_input_v3",
  "scoring_legacy_minimum_readable_revision",
  "scoring_timestamp_v3",
  "select_physiology_source",
  "server_legacy_read_eligibility",
  "server_scoring_for_day",
  "server_scoring_read_contract",
  "server_scoring_read_contract_before_signals",
  "server_scoring_read_contract_v1",
  "set_physiology_sleep_override",
  "set_placement_interval",
  "sleep_day_availability",
  "step_validation_events_are_valid",
  "sync_daily_metric_aliases",
];

/** SECURITY DEFINER functions in that list that take no caller-specific input, so there is nothing to check. */
const DEFINER_WITHOUT_CALLER_CHECK = ["physiology_feature_is_canonical"];

/** Functions the services run on a client's behalf with a verified identity; no client may execute them. */
const SERVICE_ONLY_FUNCTIONS = [
  "provision_noop_installation",
  "register_noop_device",
  "confirm_noop_wearable",
  "handoff_noop_collection",
  "retire_noop_installation",
  "admit_noop_request",
  "noop_project_append_batch",
  "noop_push_consume_ingest_quota",
  "http_post_worker",
  "scoring_claim_one",
  "recover_noop_account_from_enrollment",
  "upsert_activity_stretch_feedback",
  // Physiology context (20261006050000_physiology_context.sql): the worker's queue and the scores route's reads.
  "enqueue_physiology_context_days_v1",
  "invalidate_physiology_context_span_v1",
  "claim_physiology_context_v1",
  "renew_physiology_context_v1",
  "fail_physiology_context_v1",
  "publish_physiology_context_v1",
  "physiology_context_read_v1",
  "physiology_context_history_read_v1",
  "record_exposure_event_v1",
  "exposure_events_read_v1",
  // Metric insights (20261008000000_metric_insights.sql): the scores route's request and the insight worker's queue.
  "metric_insight_request_v1",
  "metric_insight_claim_v1",
  "metric_insight_renew_v1",
  "metric_insight_fail_v1",
  "metric_insight_publish_v1",
  // Coach threads and memory (20261007160000_coach_threads_memory.sql): the coach function's RPCs.
  "coach_take_utility_quota",
  "coach_add_utility_tokens",
  "coach_messages_save_v1",
  "coach_thread_delete_v1",
  "coach_search_v1",
  "coach_memories_ranked_v1",
  "coach_context_manifest_v1",
  "coach_thread_claim_v1",
  "coach_thread_publish_v1",
  "coach_memory_apply_v1",
  "coach_consolidation_claim_v1",
  // Account sync health (20261009110000_account_sync_health.sql): any account's upload recency, for the coach
  // status route and operators.
  "account_sync_health_v1",
  // Measurement context per minute (20261009130100_measurement_context_minutes.sql): the scores route's read, the
  // builder, its pg_cron tick and the operator backfill (internal schema, never exposed through PostgREST).
  "measurement_context_minutes_read_v1",
  "build_measurement_context_minutes",
  "build_measurement_context_minutes_v1",
  "backfill_measurement_context_minutes",
  "measurement_context_tick_v1",
  "measurement_context_discover_v1",
  "measurement_context_process_v1",
  "measurement_context_quality_v1",
  "exercise_session_spans_v1",
];

Deno.test({
  name: "client-reachable surface: tables, policies, functions and views are reviewed",
  ignore: !container || !restUrl,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async (t) => {
    assert.match(container!, /^nara-db-server-pipeline\.[a-z0-9]+$/);

    await t.step("every public table is row-level secured", async () => {
      const tables: Array<{ table: string; rls: boolean; owned: boolean }> = await sqlJson(`
        select coalesce(jsonb_agg(jsonb_build_object('table', c.relname, 'rls', c.relrowsecurity,
          'owned', exists(select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='user_id' and not a.attisdropped))
          order by c.relname), '[]')
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind in ('r','p')`);
      assert.ok(tables.filter((row) => row.owned).length >= 100, "the schema's user-owned tables were not found");
      const unsecured = tables.filter((row) => !row.rls).map((row) => row.table).sort();
      assert.deepEqual(unsecured, TABLES_WITHOUT_RLS, "a table without row-level security was added or removed");
      const ownedUnsecured = tables.filter((row) => row.owned && !row.rls);
      assert.deepEqual(ownedUnsecured, [], "a table that stores user_id has no row-level security");
    });

    await t.step("every policy a client can hit is written in terms of the caller", async () => {
      const policies: Array<{ table: string; policy: string; cmd: string; roles: string[]; using: string | null; check: string | null }> =
        await sqlJson(`
          select coalesce(jsonb_agg(jsonb_build_object('table', tablename, 'policy', policyname, 'cmd', cmd,
            'roles', roles, 'using', qual, 'check', with_check) order by tablename, policyname), '[]')
          from pg_policies
          where schemaname = 'public' and roles && array['public','anon','authenticated']::name[]`);
      assert.ok(policies.length >= 100);
      const unscoped = policies.filter((policy) =>
        !/auth\.(uid|role)\(\)/.test(`${policy.using ?? ""} ${policy.check ?? ""}`)
      );
      assert.deepEqual(
        unscoped.map((policy) => `${policy.table}.${policy.policy}`).sort(),
        [...SHARED_REFERENCE_POLICIES].sort(),
        "a policy that is not tied to auth.uid() / auth.role() was added or changed",
      );
      for (const policy of unscoped) {
        assert.equal(policy.cmd, "SELECT", `${policy.table}.${policy.policy} may only ever read`);
        assert.equal(policy.using, "true");
        assert.ok(!policy.roles.includes("anon") && !policy.roles.includes("public"), `${policy.table}: shared data is for signed-in callers`);
      }
      // A caller-scoped write policy must also constrain the row it produces, so a row can never be created
      // for, or moved to, another account.
      const writers = policies.filter((policy) =>
        ["INSERT", "UPDATE", "ALL"].includes(policy.cmd) && /auth\.uid\(\)/.test(`${policy.using ?? ""} ${policy.check ?? ""}`)
      );
      for (const policy of writers) {
        const predicate = policy.cmd === "INSERT" ? policy.check : (policy.check ?? policy.using);
        assert.match(predicate ?? "", /auth\.uid\(\)/, `${policy.table}.${policy.policy} does not constrain the written row`);
      }
    });

    await t.step("exactly the reviewed functions are executable by clients", async () => {
      const callable: Array<{ name: string; definer: boolean; body: string; anon: boolean }> = await sqlJson(`
        select coalesce(jsonb_agg(jsonb_build_object('name', p.proname, 'definer', p.prosecdef, 'body', p.prosrc,
          'anon', has_function_privilege('anon', p.oid, 'EXECUTE')) order by p.proname), '[]')
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.prokind in ('f','p')
          and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
          and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')`);
      const names = [...new Set(callable.map((row) => row.name))].sort();
      assert.deepEqual(names, [...CLIENT_CALLABLE_FUNCTIONS].sort(), "the set of client-executable functions changed");

      for (const row of callable.filter((candidate) => candidate.definer)) {
        if (DEFINER_WITHOUT_CALLER_CHECK.includes(row.name)) continue;
        assert.match(row.body, /auth\.(uid|role)\(\)|service_role|current_user|session_user|request\.jwt/,
          `${row.name} runs with its owner's rights and never asks who is calling`);
      }
      // The functions that act for a verified identity must not be reachable by any client at all.
      for (const name of SERVICE_ONLY_FUNCTIONS) {
        const reachable: boolean[] = await sqlJson(`
          select coalesce(jsonb_agg(has_function_privilege('anon', p.oid, 'EXECUTE')
            or has_function_privilege('authenticated', p.oid, 'EXECUTE')), '[]')
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname in ('public', 'internal') and p.proname = '${name}'`);
        assert.ok(reachable.length > 0, `${name} no longer exists; update the reviewed list`);
        assert.ok(reachable.every((value) => value === false), `${name} is executable by a client`);
      }
    });

    await t.step("no view hands a client rows its owner's rights could see", async () => {
      const views: Array<{ name: string; invoker: boolean; reachable: boolean }> = await sqlJson(`
        select coalesce(jsonb_agg(jsonb_build_object('name', c.relname,
          'invoker', coalesce('security_invoker=true' = any(c.reloptions), false),
          'reachable', has_table_privilege('anon', c.oid, 'select') or has_table_privilege('authenticated', c.oid, 'select'))
          order by c.relname), '[]')
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind in ('v','m')`);
      assert.ok(views.length > 0);
      for (const view of views) {
        assert.ok(!view.reachable || view.invoker, `${view.name} is readable by clients but not security_invoker`);
      }
    });
  },
});

// ---------------------------------------------------------------------------------------------------------
// 2. Two accounts, two installations, two devices
// ---------------------------------------------------------------------------------------------------------

const sha256 = (value: string) => createHash("sha256").update(value).digest("hex");
const uuid = () => crypto.randomUUID();
const RECEIPT = "e".repeat(64);

Deno.test({
  name: "Supabase-Auth accounts: two users, two installations, two devices stay apart on the production image",
  ignore: !container || !restUrl,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async (t) => {
    assert.match(container!, /^nara-db-server-pipeline\.[a-z0-9]+$/);
    assert.equal(
      await docker(["inspect", container!, "--format", '{{index .Config.Labels "nara.test"}}']),
      "server-pipeline",
    );
    for (let attempt = 0; ; attempt++) {
      try {
        await serviceRest.select("devices", "select=id&limit=1");
        break;
      } catch (error) {
        if (attempt === 59) throw error;
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
    }

    const A = uuid(), B = uuid();
    const SA = uuid(), SB = uuid();
    const jwtA = signJwt("authenticated", A), jwtB = signJwt("authenticated", B);
    await sql(`
      insert into auth.users(id, email) values
        ('${A}', 'a-${A}@example.test'), ('${B}', 'b-${B}@example.test');
      insert into profiles(id, timezone) values ('${A}', 'UTC'), ('${B}', 'UTC')
        on conflict (id) do update set timezone = 'UTC';`);

    // GoTrue stand-in: the token's signature is checked and its subject is the user, which is all the
    // provisioning handler asks of the Auth server.
    const goTrue: typeof fetch = (input, init) => {
      assert.ok(String(input).endsWith("/auth/v1/user"));
      const token = String(new Headers(init?.headers).get("authorization") ?? "").replace(/^Bearer /, "");
      const sub = verifiedSub(token);
      return Promise.resolve(
        sub
          ? Response.json({ id: sub, email: `${sub}@example.test`, email_confirmed_at: "2026-10-03T00:00:00Z", is_anonymous: false })
          : Response.json({ error_code: "bad_jwt" }, { status: 403 }),
      );
    };
    const provision = createInstallationProvisioning({
      rest: serviceRest, supabaseUrl: "https://project.test", anonKey: "sb_publishable_test", fetchImpl: goTrue,
    });
    const provisionAs = async (jwt: string | null, body: unknown, current?: string) => {
      const response = await provision(new Request("https://x.test/functions/v1/push/installations/provision", {
        method: "POST",
        headers: {
          ...(jwt ? { authorization: `Bearer ${jwt}` } : {}),
          "content-type": "application/json",
          ...(current ? { [CURRENT_INSTALLATION_TOKEN_HEADER]: current } : {}),
        },
        body: JSON.stringify(body),
      }));
      return { status: response.status, body: await response.json() };
    };
    const lifecycle = createInstallationLifecycle(serviceRest);
    const lifecycleAs = async (token: string, action: "confirm" | "handoff" | "retire", body?: unknown) => {
      const response = await lifecycle(new Request("https://x.test/functions/v1/push/wearables", {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
      }), action);
      return { status: response.status, body: await response.json().catch(() => null) };
    };
    const resolveDevice = createNoopDeviceResolver({ rest: serviceRest });
    const identityOf = (token: string, extra: Record<string, string> = {}) =>
      resolveUploadIdentity({ rest: serviceRest, headers: new Headers({ authorization: `Bearer ${token}`, ...extra }) });
    const confirmBody = (provisional: string, serial: string) => ({
      provisionalExternalDeviceId: provisional,
      evidence: { method: "device_information_serial_v1", serial, receiptSha256: RECEIPT },
    });
    const project = (user: string, device: string, source: string, stream: string, rows: any[]) => {
      const batch = uuid();
      return serviceRest.rpc("noop_project_append_batch", {
        p_user: user, p_device: device, p_source: source, p_batch: batch, p_stream: stream,
        p_rows: rows.map((row) => ({ ...row, user_id: user, device_id: device, source_id: source, batch_id: batch })),
      });
    };

    const state: Record<string, any> = {};
    const now = Math.floor(Date.now() / 1000) - 600;
    const day = new Date().toISOString().slice(0, 10);

    await t.step("each credential is bound to exactly its own account and source", async () => {
      const a = await provisionAs(jwtA, { sourceId: SA, platform: "ios", appVersion: "1.0 (1)", userId: B, user_id: B });
      const b = await provisionAs(jwtB, { sourceId: SB, platform: "ios", appVersion: "1.0 (1)" });
      assert.equal(a.status, 201);
      assert.equal(b.status, 201);
      assert.equal(a.body.userId, A, "a user id in the request body is ignored");
      assert.equal(b.body.userId, B);
      state.tokenA = a.body.installationToken;
      state.tokenB = b.body.installationToken;
      assert.notEqual(state.tokenA, state.tokenB);
      assert.equal(
        await sql(`select string_agg(user_id||'|'||source_id||'|'||provisioning_method||'|'||coalesce(enrollment_code_id::text,'none'), ',' order by user_id)
          from noop_app_installations where source_id in ('${SA}','${SB}')`),
        [`${A}|${SA}|supabase_auth|none`, `${B}|${SB}|supabase_auth|none`].sort().join(","),
      );
      assert.equal(await sql(`select count(*) from noop_ingest_tokens where token_hash in ('${sha256(state.tokenA)}','${sha256(state.tokenB)}')`), "2");
      assert.equal(await sql(`select count(*) from noop_ingest_tokens where token_hash like 'noop_%'`), "0", "plaintext credentials are never stored");

      const identityA = await identityOf(state.tokenA);
      const identityB = await identityOf(state.tokenB, { "x-noop-fleet-token": "noop_stale_fleet_header" });
      assert.deepEqual([identityA.id, identityA.sourceId, identityA.authMode], [A, SA, "installation"]);
      assert.deepEqual([identityB.id, identityB.sourceId, identityB.authMode], [B, SB, "installation"]);
      await assert.rejects(() => identityOf(signJwt("authenticated", A)), "a Supabase session is not an upload credential");
      await assert.rejects(() => identityOf(`${state.tokenA}x`));
    });

    await t.step("the same strap in two accounts is two devices, and confirming it cannot touch the other", async () => {
      const serial = "PIPE-SHARED-0001";
      state.provisionalA = await resolveDevice({ userId: A, sourceId: SA, externalDeviceId: "strap" });
      state.provisionalB = await resolveDevice({ userId: B, sourceId: SB, externalDeviceId: "strap" });
      assert.notEqual(state.provisionalA, state.provisionalB);
      for (const [user, device, source, bpm] of [[A, state.provisionalA, SA, 60], [B, state.provisionalB, SB, 80]] as const) {
        assert.equal(await project(user, device, source, "hrSample", [{ ts: now, bpm }, { ts: now + 1, bpm }]), 2);
        assert.equal(
          await project(user, device, source, "rrInterval", [{ ts: now, rrMs: 1000, seq: 0 }, { ts: now, rrMs: 1040, seq: 1 }]),
          2,
        );
      }
      const confirmedA = await lifecycleAs(state.tokenA, "confirm", confirmBody("strap", serial));
      const confirmedB = await lifecycleAs(state.tokenB, "confirm", confirmBody("strap", serial));
      assert.equal(confirmedA.status, 200, JSON.stringify(confirmedA.body));
      assert.equal(confirmedB.status, 200, JSON.stringify(confirmedB.body));
      assert.equal(confirmedA.body.userId, A);
      assert.equal(confirmedB.body.userId, B);
      assert.notEqual(confirmedA.body.deviceId, confirmedB.body.deviceId, "one serial, two accounts, two devices");
      state.canonicalA = confirmedA.body.deviceId;
      state.canonicalB = confirmedB.body.deviceId;
      assert.equal(await sql(`select user_id from devices where id='${state.canonicalA}'`), A);
      assert.equal(await sql(`select user_id from devices where id='${state.canonicalB}'`), B);
      assert.equal(await sql(`select count(*) from noop_hr_samples where user_id='${A}' and bpm=60`), "2");
      assert.equal(await sql(`select count(*) from noop_hr_samples where user_id='${B}' and bpm=80`), "2");

      // After confirmation each strap's later seconds go to its own canonical device.
      for (const [user, device, source, bpm] of [[A, state.canonicalA, SA, 61], [B, state.canonicalB, SB, 81]] as const) {
        assert.equal(await project(user, device, source, "hrSample", [{ ts: now + 2, bpm }]), 1);
      }

      // What the worker would have published, for both accounts, so the score reads below have something to leak.
      await sql(`
        insert into server_metric_series(user_id, metric, bucket_start, value, device_id, algorithm_version) values
          ('${A}', 'hrv_rmssd_ms', now() - interval '1 hour', 40, '${state.canonicalA}', 'frwhoop-server-1'),
          ('${B}', 'hrv_rmssd_ms', now() - interval '1 hour', 80, '${state.canonicalB}', 'frwhoop-server-1');
        insert into server_daily_scores(user_id, day, algorithm_version, source_device_id, hrv_rmssd_ms) values
          ('${A}', '${day}', 'frwhoop-server-1', '${state.canonicalA}', 40),
          ('${B}', '${day}', 'frwhoop-server-1', '${state.canonicalB}', 80);`);
    });

    const ownedTables = async (): Promise<string[]> => await sqlJson(`
      select coalesce(jsonb_agg(c.relname order by c.relname), '[]')
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r','p')
        and exists(select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'user_id' and not a.attisdropped)`);
    const holdings = async (tables: string[], users: string[]) => {
      const list = users.map((user) => `'${user}'`).join(",");
      const rows = await sql(tables.map((table) =>
        `select '${table}' || '|' || user_id::text || '|' || count(*) from public."${table}" where user_id::text in (${list}) group by user_id`
      ).join(" union all ") + " order by 1;");
      return rows;
    };

    await t.step("every user-owned table shows a signed-in user only their own rows", async () => {
      const tables = await ownedTables();
      let populatedForBoth = 0;
      for (const table of tables) {
        const counts = await sqlJson(`select jsonb_build_object('a', (select count(*) from public."${table}" where user_id::text = '${A}'),
          'b', (select count(*) from public."${table}" where user_id::text = '${B}'))`);
        const asA = await call(jwtA, "GET", `${table}?select=user_id&limit=1000`);
        const asB = await call(jwtB, "GET", `${table}?select=user_id&limit=1000`);
        const asAnon = await call(null, "GET", `${table}?select=user_id&limit=1000`);
        const visible = (reply: Reply, user: string) => {
          if (refused(reply)) return 0;
          assert.equal(reply.status, 200, `${table}: ${JSON.stringify(reply.body)}`);
          assert.ok(
            reply.body.every((row: any) => String(row.user_id).toLowerCase() === user),
            `${table}: a read as ${user} returned another account's rows`,
          );
          return reply.body.length as number;
        };
        const seenByA = visible(asA, A);
        const seenByB = visible(asB, B);
        assert.equal(refused(asAnon) || asAnon.status !== 200 ? 0 : asAnon.body.length, 0, `${table}: an anonymous read returned rows`);
        assert.ok(seenByA <= Math.min(counts.a, 1000), `${table}: A sees more rows than it owns`);
        assert.ok(seenByB <= Math.min(counts.b, 1000), `${table}: B sees more rows than it owns`);
        if (seenByA > 0 && seenByB > 0) populatedForBoth++;
        const crossA = await call(jwtA, "GET", `${table}?user_id=eq.${B}&select=user_id`);
        const crossB = await call(jwtB, "GET", `${table}?user_id=eq.${A}&select=user_id`);
        assert.equal(refused(crossA) ? 0 : crossA.body.length, 0, `${table}: A asked for B's rows`);
        assert.equal(refused(crossB) ? 0 : crossB.body.length, 0, `${table}: B asked for A's rows`);
      }
      assert.ok(populatedForBoth >= 6, `only ${populatedForBoth} tables showed rows to both accounts; the sweep proved too little`);
    });

    await t.step("nothing a signed-in user sends can create, change, move or remove another account's rows", async () => {
      const tables = await ownedTables();
      const before = await holdings(tables, [A, B]);
      for (const table of tables) {
        const forged = await call(jwtA, "POST", table, { user_id: B });
        assert.ok(forged.status >= 400, `${table}: A created a row for B (${forged.status})`);
        const rewrite = await call(jwtA, "PATCH", `${table}?user_id=eq.${B}`, { user_id: A });
        assert.equal(affected(rewrite), 0, `${table}: A rewrote B's rows`);
        // Moving A's own row to B is refused by the policy, or neutralised by a trigger that pins the owner;
        // either way the row that comes back (if any) is still A's, and the holdings check below agrees.
        const steal = await call(jwtA, "PATCH", `${table}?user_id=eq.${A}`, { user_id: B });
        if (affected(steal) > 0) {
          assert.ok(
            steal.body.every((row: any) => String(row.user_id).toLowerCase() === A),
            `${table}: A handed its own rows to B`,
          );
        }
        const erase = await call(jwtA, "DELETE", `${table}?user_id=eq.${B}`);
        assert.equal(affected(erase), 0, `${table}: A deleted B's rows`);
        const anonymousWrite = await call(null, "POST", table, { user_id: B });
        assert.ok(anonymousWrite.status >= 400, `${table}: an anonymous caller created a row (${anonymousWrite.status})`);
        const anonymousErase = await call(null, "DELETE", `${table}?user_id=eq.${B}`);
        assert.equal(affected(anonymousErase), 0, `${table}: an anonymous caller deleted rows`);
      }
      assert.equal(await holdings(tables, [A, B]), before, "the attempts above changed what an account holds");
    });

    await t.step("client-callable functions refuse another account's identifiers", async () => {
      const rpc = (token: string | null, name: string, body: unknown) => call(token, "POST", `rpc/${name}`, body);
      const asA = {
        snapshot: await rpc(jwtA, "get_server_score_snapshot_v2", {
          p_day: day, p_source: SB, p_external_device_id: "strap",
        }),
        contract: await rpc(jwtA, "server_scoring_read_contract", { p_user: B, p_day: day, p_device: state.canonicalB }),
        head: await rpc(jwtA, "get_scoring_history_input_head_v3", {
          p_device: state.canonicalB, p_kind: "profile", p_entity: "primary",
        }),
        write: await rpc(jwtA, "put_scoring_history_input_v3", {
          p_device: state.canonicalB, p_kind: "profile", p_entity: "primary", p_effective_day: day,
          p_payload: { heightCm: 180 }, p_expected_revision: 0, p_deleted: false,
          p_client_id: uuid(), p_client_mutation_id: uuid(), p_client_revision: 1,
        }),
      };
      for (const [name, reply] of Object.entries(asA)) {
        assert.ok(refused(reply), `${name}: A used B's identifiers (${reply.status} ${JSON.stringify(reply.body).slice(0, 200)})`);
      }
      assert.equal(await sql(`select count(*) from scoring_history_inputs_v3 where user_id='${B}'`), "0");
      for (const name of SERVICE_ONLY_FUNCTIONS.filter((candidate) => candidate !== "scoring_claim_one")) {
        for (const token of [jwtA, null]) {
          const reply = await rpc(token, name, {});
          assert.ok(refused(reply) || reply.status === 404, `${name} answered a client (${reply.status})`);
        }
      }
      for (const name of ["noop_push_consume_ingest_quota", "http_post_worker"]) {
        const reply = await rpc(jwtA, name, { p_user_id: B, p_bytes: 1, p_max_batches: 1, p_max_bytes: 1, p_window_seconds: 60, fn_path: "/reconcile" });
        assert.ok(refused(reply) || reply.status === 404, `${name} answered a client (${reply.status})`);
      }
    });

    await t.step("one account's credential cannot register, claim, confirm or hand off for the other", async () => {
      const takeover = await provisionAs(jwtA, { sourceId: SB, platform: "ios", appVersion: "1.0 (1)" });
      assert.deepEqual([takeover.status, takeover.body.code], [409, "installation_unavailable"]);
      const unknown = await provisionAs(jwtA, { sourceId: uuid(), platform: "ios", appVersion: "1.0 (1)" });
      assert.equal(unknown.status, 201, "an unused source id is simply registered");
      const withTheirs = await provisionAs(jwtA, { sourceId: SB, platform: "ios", appVersion: "1.0 (1)" }, state.tokenB);
      assert.equal(withTheirs.status, 409, "B's own credential does not let A claim B's source");
      assert.equal(withTheirs.body.installationToken, undefined);
      assert.equal(
        await sql(`select count(*) from noop_ingest_tokens where user_id='${B}' and revoked_at is null`), "1",
        "B's credential was neither rotated nor revoked",
      );

      const handoff = await lifecycleAs(state.tokenA, "handoff", { externalDeviceId: "whoop-PIPE-B-ONLY-0001" });
      assert.equal(handoff.status, 404, "B's strap does not exist in A's account");
      const aliasesBefore = await sql(`select count(*) from noop_wearable_aliases where user_id='${B}'`);
      const devicesBefore = await sql(`select string_agg(id::text, ',' order by id) from devices where user_id='${B}'`);
      const claim = await lifecycleAs(state.tokenA, "confirm", confirmBody("strap", "PIPE-B-ONLY-0001"));
      assert.ok([200, 409, 422].includes(claim.status), JSON.stringify(claim));
      if (claim.status === 200) {
        assert.equal(claim.body.userId, A, "a confirmation is recorded for the caller");
        assert.equal(await sql(`select user_id from devices where id='${claim.body.deviceId}'`), A);
        assert.ok(![state.canonicalB, state.provisionalB].includes(claim.body.deviceId));
      }
      assert.equal(await sql(`select count(*) from noop_wearable_aliases where user_id='${B}'`), aliasesBefore);
      assert.equal(await sql(`select string_agg(id::text, ',' order by id) from devices where user_id='${B}'`), devicesBefore);
    });

    await t.step("a source or a device cannot be re-pointed at another owner, even by the service role", async () => {
      await assert.rejects(() => serviceRest.patch("noop_app_installations", { user_id: B }, `source_id=eq.${SA}`));
      await assert.rejects(() => serviceRest.patch("devices", { user_id: B }, `id=eq.${state.canonicalA}`));
      await assert.rejects(() => serviceRest.patch("noop_ingest_tokens", { user_id: B }, `user_id=eq.${A}`));
      await assert.rejects(() =>
        serviceRest.rpc("register_noop_device", {
          p_device: state.canonicalA, p_user: B, p_external_device_id: "hijack", p_last_seen_at: new Date().toISOString(),
        })
      );
      await assert.rejects(() =>
        serviceRest.upsert("noop_app_installations", {
          source_id: SA, user_id: B, platform: "ios", app_version: "1.0 (1)", provisioning_method: "supabase_auth",
        }, { onConflict: "source_id" })
      );
      assert.equal(await sql(`select user_id from noop_app_installations where source_id='${SA}'`), A);
      assert.equal(await sql(`select user_id from devices where id='${state.canonicalA}'`), A);

      // Rows that nothing references yet are protected only by the immutability triggers, not by foreign keys.
      const lonelyDevice = crypto.randomUUID();
      const lonelySource = crypto.randomUUID();
      await sql(`
        insert into devices(id, user_id, source_kind, external_device_id) values ('${lonelyDevice}', '${A}', 'whoop', 'lonely-${lonelyDevice}');
        insert into noop_app_installations(source_id, user_id, platform, app_version, provisioning_method)
          values ('${lonelySource}', '${A}', 'ios', '1.0 (1)', 'supabase_auth');`);
      await assert.rejects(() => serviceRest.patch("devices", { user_id: B }, `id=eq.${lonelyDevice}`));
      await assert.rejects(() => serviceRest.patch("noop_app_installations", { user_id: B }, `source_id=eq.${lonelySource}`));
      assert.equal(await sql(`select user_id from devices where id='${lonelyDevice}'`), A);
      assert.equal(await sql(`select user_id from noop_app_installations where source_id='${lonelySource}'`), A);
      await sql(`delete from devices where id='${lonelyDevice}'; delete from noop_app_installations where source_id='${lonelySource}';`);

      await assert.rejects(
        () => project(B, state.canonicalA, SB, "hrSample", [{ ts: now + 30, bpm: 99 }]),
        "B's installation cannot write into A's device",
      );
      await assert.rejects(
        () => project(A, state.canonicalA, SB, "hrSample", [{ ts: now + 30, bpm: 99 }]),
        "A's device cannot be written through B's installation",
      );
      assert.equal(await sql(`select count(*) from noop_hr_samples where bpm=99`), "0");
    });

    await t.step("revoked and deleted accounts fail closed and leave the other account untouched", async () => {
      const aBefore = await sql(`select count(*) from noop_hr_samples where user_id='${A}'`);
      const bBefore = await sql(`select count(*) from noop_hr_samples where user_id='${B}'`);
      const aDevices = await sql(`select string_agg(id::text, ',' order by id) from devices where user_id='${A}'`);

      await serviceRest.patch("noop_app_installations", { revoked_at: new Date().toISOString() }, `source_id=eq.${SA}`);
      await assert.rejects(() => identityOf(state.tokenA), "a revoked installation's credential is refused");
      assert.equal((await identityOf(state.tokenB)).id, B, "revoking A's installation left B working");
      const reprovision = await provisionAs(jwtA, { sourceId: SA, platform: "ios", appVersion: "1.0 (1)" });
      assert.equal(reprovision.status, 403);
      assert.equal(reprovision.body.code, "installation_revoked", "a revoked source is not silently revived");
      await assert.rejects(() => project(A, state.canonicalA, SA, "hrSample", [{ ts: now + 40, bpm: 62 }]));
      assert.equal(await sql(`select count(*) from noop_hr_samples where user_id='${A}'`), aBefore);

      await sql(`delete from auth.users where id='${B}'`);
      await assert.rejects(() => identityOf(state.tokenB), "a deleted account's credential is refused");
      const afterDeletion = await provisionAs(jwtB, { sourceId: SB, platform: "ios", appVersion: "1.0 (1)" });
      assert.ok(afterDeletion.status >= 400 && afterDeletion.body.installationToken === undefined, JSON.stringify(afterDeletion));
      assert.equal(bBefore, "3");
      for (const table of ["noop_hr_samples", "noop_rr_intervals", "devices", "noop_app_installations", "noop_ingest_tokens", "server_metric_series", "server_daily_scores"]) {
        assert.equal(await sql(`select count(*) from public."${table}" where user_id='${B}'`), "0", `${table}: the deleted account's rows remain`);
      }
      assert.equal(await sql(`select count(*) from noop_hr_samples where user_id='${A}'`), aBefore, "deleting B did not touch A");
      assert.equal(await sql(`select string_agg(id::text, ',' order by id) from devices where user_id='${A}'`), aDevices);
    });
  },
});
