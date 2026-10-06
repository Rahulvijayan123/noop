import { IdentityError, resolveUploadIdentity, resolveJwtUser, bearerToken, looksLikeJwt } from './tokens.ts';
import { createNoopDeviceResolver, findNoopDevice } from './devices.ts';
import { isSafeExternalDeviceId, isUuid } from './keys.ts';
import { STRETCH_FEEDBACK_MAX_BODY_BYTES, validateStretchFeedback } from './stretchFeedback.ts';
import {
  EXPOSURE_MAX_BODY_BYTES,
  parseContextHistoryQuery,
  parseContextQuery,
  parseExposureReadQuery,
  submitExposureEvents,
} from './physiologyContext.ts';
import { GROUND_TRUTH_LABELS_MAX_BODY_BYTES, submitGroundTruthLabels } from './groundTruthLabels.ts';
import type { PushFunctionConfig } from './config.ts';
import type { SupabaseRest } from './rest.ts';

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

export function utcDay(at = new Date()): string {
  return at.toISOString().slice(0, 10);
}

function fail(code: string, status: number): Error {
  return Object.assign(new Error(code), { code, status });
}

export async function readOwnerDayScores({ rest, userId, day, deviceId }: {
  rest: Pick<SupabaseRest, 'rpc'>; userId: string; day: string; deviceId: string | null;
}) {
  const date = new Date(day);
  if (!DAY_RE.test(day) || !Number.isFinite(date.getTime()) || utcDay(date) !== day) {
    throw fail('invalid_day', 400);
  }
  if (!deviceId) {
    return { server_scoring: await rest.rpc('server_scoring_pending_contract',{p_user:userId,p_day:day}) };
  }
  const overlay = await rest.rpc('server_scoring_for_device_day', {
    p_user: userId, p_day: day, p_device: deviceId,
  });
  return { server_scoring: overlay };
}

/**
 * The hosted NOOP worker's own published day result (`scoring_snapshots_v2`), for an enrolled installation.
 *
 * The worker runs the app's `AnalyticsEngine.analyzeDay` unchanged, so this is the number the offline app
 * would show for the same inputs. The family contract above keeps withholding legacy beat-timing values
 * from account clients; only the installation route attaches this. Null when nothing is published yet.
 */
export async function readHostedSnapshot({ rest, userId, deviceId, day }: {
  rest: Pick<SupabaseRest, 'select'>; userId: string; deviceId: string; day: string;
}) {
  const algorithms = await rest.select('scoring_algorithms_v2',
    'active=eq.true&enabled=eq.true&select=algorithm_version&limit=1');
  const algorithm = algorithms[0]?.algorithm_version;
  if (typeof algorithm !== 'string' || !/^[A-Za-z0-9._-]{1,64}$/.test(algorithm)) return null;
  const scope = `user_id=eq.${userId}&device_id=eq.${deviceId}&day=eq.${day}&algorithm_version=eq.${algorithm}`;
  const rows = await rest.select('scoring_snapshots_v2',
    `${scope}&select=result_revision,input_revision,computed_at,payload&order=result_revision.desc&limit=1`);
  const row = rows[0];
  const payload = row?.payload;
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;
  const jobs = await rest.select('scoring_jobs_v2', `${scope}&select=input_revision&limit=1`);
  const requested = jobs[0]?.input_revision;
  return {
    algorithm_version: algorithm,
    result_revision: String(row.result_revision),
    input_revision: String(row.input_revision),
    computed_at: row.computed_at ?? null,
    pending: requested != null && Number(requested) > Number(row.input_revision),
    status: typeof payload.status === 'string' ? payload.status : null,
    status_reasons: Array.isArray(payload.statusReasons) ? payload.statusReasons : [],
    timezone: typeof payload.timezone === 'string' ? payload.timezone : null,
    data_through: payload.dataThrough ?? null,
    daily: payload.daily && typeof payload.daily === 'object' ? payload.daily : null,
    sleep: Array.isArray(payload.sleep) ? payload.sleep : [],
    coverage: payload.coverage && typeof payload.coverage === 'object' ? payload.coverage : null,
  };
}

/** Series names `server_metric_series` accepts (its CHECK constraint, and `server_metric_series_read`). */
export const SERIES_METRICS = ['hrv_rmssd_ms', 'resting_hr_bpm', 'resp_rate_bpm', 'steps', 'calories_kcal'] as const;
const SERIES_MAX_RANGE_SECONDS = 3 * 86_400;

/**
 * `GET /series?from=<unix>&to=<unix>[&metrics=a,b]`: a half-open range of at most three days (the RPC's own
 * limit, and about 4,300 rows) over the user's dense intraday series. Anything malformed is rejected before the
 * database is asked.
 */
export function parseSeriesQuery(params: URLSearchParams) {
  const from = params.get('from');
  const to = params.get('to');
  if (from == null || to == null || !/^\d{1,10}$/.test(from) || !/^\d{1,10}$/.test(to)) throw fail('invalid_range', 400);
  const start = Number(from);
  const end = Number(to);
  if (end <= start || end - start > SERIES_MAX_RANGE_SECONDS) throw fail('invalid_range', 400);
  let metrics: string[] | null = null;
  const raw = params.get('metrics');
  if (raw != null) {
    metrics = raw.split(',');
    if (new Set(metrics).size !== metrics.length || metrics.some((m) => !(SERIES_METRICS as readonly string[]).includes(m))) {
      throw fail('invalid_metrics', 400);
    }
  }
  return { from: new Date(start * 1000).toISOString(), to: new Date(end * 1000).toISOString(), metrics };
}

/** The raw-IMU lane's lineage: the only one that writes `activity_encoder_windows` today. */
const ACTIVITY_WINDOWS_ALGORITHM = 'hart-activity-1';
const ACTIVITY_WINDOWS_MAX_DAYS = 3;

/**
 * `GET /activity-windows?days=<YYYY-MM-DD>[,…][&known=<YYYY-MM-DD>:<revision>,…]`: HART's per-window output
 * (`hart-windows-1`) for up to three UTC days. A local day spans two UTC days, so the phone asks for both. A
 * day listed in `known` at its current result revision comes back without its windows (`unchanged: true`), so
 * an unchanged day costs a few bytes rather than its whole document.
 */
function isCalendarDay(day: string): boolean {
  const at = new Date(`${day}T00:00:00Z`);
  return !Number.isNaN(at.getTime()) && at.toISOString().slice(0, 10) === day;
}

export function parseActivityWindowsQuery(params: URLSearchParams) {
  const raw = params.get('days');
  if (raw == null) throw fail('invalid_days', 400);
  const days = raw.split(',');
  if (days.length < 1 || days.length > ACTIVITY_WINDOWS_MAX_DAYS || new Set(days).size !== days.length
      || days.some((d) => !DAY_RE.test(d) || !isCalendarDay(d))) {
    throw fail('invalid_days', 400);
  }
  const known = new Map<string, string>();
  const rawKnown = params.get('known');
  if (rawKnown != null && rawKnown !== '') {
    for (const entry of rawKnown.split(',')) {
      const m = /^(\d{4}-\d{2}-\d{2}):(\d{1,18})$/.exec(entry);
      if (!m || !days.includes(m[1])) throw fail('invalid_known', 400);
      known.set(m[1], m[2]);
    }
  }
  return { days, known };
}

export async function readActivityWindows({ rest, userId, deviceId, days, known }: {
  rest: SupabaseRest; userId: string; deviceId: string; days: string[]; known: Map<string, string>;
}) {
  const owner = `user_id=eq.${userId}&device_id=eq.${deviceId}&algorithm_version=eq.${ACTIVITY_WINDOWS_ALGORITHM}`;
  const heads = await rest.select('activity_encoder_windows', `${owner}&day=in.(${days.join(',')})`
    + '&select=day,encoder_id,model_version,preprocessing_version,feature_schema,window_count,first_ts,last_ts,'
    + 'result_revision,computed_at') ?? [];
  const wanted = heads.filter((h: any) => known.get(h.day) !== String(h.result_revision)).map((h: any) => h.day);
  const bodies = wanted.length
    ? await rest.select('activity_encoder_windows',
      `${owner}&day=in.(${wanted.join(',')})&select=day,result_revision,windows`) ?? []
    : [];
  const bodyByDay = new Map(bodies.map((b: any) => [b.day, b]));
  return heads.map((h: any) => {
    const body: any = bodyByDay.get(h.day);
    // A republish between the two reads makes the body newer than its head; the body's revision is the one
    // that describes the windows sent.
    return body
      ? { ...h, result_revision: String(body.result_revision), windows: body.windows }
      : { ...h, result_revision: String(h.result_revision), unchanged: true };
  });
}

async function boundedBody(req: Request, maxBytes = 8192): Promise<any> {
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.length > maxBytes) throw fail('payload_too_large', 413);
  try { return JSON.parse(new TextDecoder().decode(bytes)); }
  catch { throw fail('invalid_body', 400); }
}

/**
 * `POST /stretch-feedback`: validate every item, resolve each item's optional device to one the caller
 * owns (an id that does not resolve is stored as no device, never an error), and hand only the valid items
 * to `upsert_activity_stretch_feedback` with the owner taken from the credential. Rejected items are
 * reported back individually; the last-writer-wins decision (saved vs ignored/stale) is the RPC's.
 */
export async function submitStretchFeedback({ rest, userId, sourceId, body }: {
  rest: Pick<SupabaseRest, 'select' | 'rpc'>; userId: string; sourceId: string; body: unknown;
}) {
  const { valid, rejected } = validateStretchFeedback(body);
  const resolved = new Map<string, string | null>();
  const items = [];
  for (const item of valid) {
    const external = item.external_device_id;
    if (external != null && !resolved.has(external)) {
      resolved.set(external, await findNoopDevice({ rest, userId, sourceId, externalDeviceId: external }));
    }
    items.push({ ...item, device_id: external != null ? (resolved.get(external) ?? null) : null });
  }
  let saved: unknown[] = [];
  let ignored: unknown[] = [];
  if (items.length > 0) {
    const result = await rest.rpc('upsert_activity_stretch_feedback', { p_owner: userId, p_items: items });
    saved = Array.isArray(result?.saved) ? result.saved : [];
    ignored = Array.isArray(result?.ignored) ? result.ignored : [];
  }
  return { saved, ignored, rejected };
}

function sleepArguments(value: any, canonicalDevice: string) {
  const keys = ['p_id', 'p_device', 'p_original_start', 'p_original_end', 'p_start', 'p_end',
    'p_tombstone', 'p_expected_revision'];
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).some((key) => !keys.includes(key) && key !== 'p_legacy_revision')
      || keys.some((key) => !(key in value))
      || !isUuid(value.p_id) || value.p_device !== canonicalDevice
      || typeof value.p_tombstone !== 'boolean'
      || !Number.isSafeInteger(value.p_expected_revision) || value.p_expected_revision < 0
      || (value.p_legacy_revision != null && !/^[0-9a-f]{64}$/.test(value.p_legacy_revision))) {
    throw fail('invalid_override', 400);
  }
  for (const key of ['p_original_start', 'p_original_end', 'p_start', 'p_end']) {
    if (typeof value[key] !== 'string' || !Number.isFinite(Date.parse(value[key]))) {
      throw fail('invalid_override', 400);
    }
  }
  return { ...value, p_legacy_revision: value.p_legacy_revision ?? null };
}

export async function handleScoresRequest(req: Request, { rest, cfg: _cfg, fetchImpl: _fetchImpl = fetch }: {
  rest: SupabaseRest;
  cfg: Pick<PushFunctionConfig, 'supabaseUrl' | 'supabaseAnonKey'> & Partial<Pick<PushFunctionConfig, 'allowLegacyEnrollment'>>;
  fetchImpl?: typeof fetch;
}): Promise<Response> {
  const url = new URL(req.url);
  const route = url.pathname.replace(/^\/functions\/v1/, '').replace(/^\/scores/, '') || '/';
  const isRead = req.method === 'GET' && route === '/';
  const isDays = req.method === 'GET' && route === '/days';
  const isSeries = req.method === 'GET' && route === '/series';
  const isActivityWindows = req.method === 'GET' && route === '/activity-windows';
  const isDiagnostics = req.method === 'GET' && route === '/diagnostics';
  const isRegister = req.method === 'POST' && route === '/devices';
  const isOverride = req.method === 'POST' && route === '/sleep-overrides';
  const isComputeSubmit = req.method === 'POST' && route === '/compute-requests';
  const isComputeRead = req.method === 'GET' && route === '/compute-requests';
  const isPlacementPost = req.method === 'POST' && route === '/placement';
  const isPlacementGet = req.method === 'GET' && route === '/placement';
  const isStretchFeedback = req.method === 'POST' && route === '/stretch-feedback';
  // Physiology context (contracts.md §8). Device-scoped reads take deviceId from the query like /series;
  // exposure events are account-level and take no device.
  const isContext = req.method === 'GET' && route === '/context';
  const isContextHistory = req.method === 'GET' && route === '/context/history';
  const isExposurePost = req.method === 'POST' && route === '/exposures';
  const isExposureGet = req.method === 'GET' && route === '/exposures';
  const isGroundTruthLabels = req.method === 'POST' && route === '/ground-truth-labels';
  if (!isRead && !isDays && !isSeries && !isActivityWindows && !isDiagnostics && !isRegister && !isOverride
      && !isComputeSubmit && !isComputeRead && !isPlacementPost && !isPlacementGet && !isStretchFeedback
      && !isContext && !isContextHistory && !isExposurePost && !isExposureGet && !isGroundTruthLabels) {
    return Response.json({ error: 'method_not_allowed' }, { status: 405 });
  }
  if (!rest.configured) return Response.json({ error: 'service_role_unconfigured' }, { status: 503 });
  try {
    const jwt = looksLikeJwt(bearerToken(req.headers));
    let user: {id: string; sourceId: string};
    if (jwt) {
      const account = await resolveJwtUser({headers:req.headers,supabaseUrl:_cfg.supabaseUrl,
        anonKey:_cfg.supabaseAnonKey,fetchImpl:_fetchImpl});
      const sourceId = req.headers.get('x-noop-source-id');
      if (!isUuid(sourceId)) throw new IdentityError('registered source required');
      if (isRegister) {
        await rest.rpc('register_account_compute_source',{p_user:account.id,p_source:sourceId});
      } else {
        const registered = await rest.select('compute_account_sources',
          `source_id=eq.${sourceId}&select=user_id,source_id,revoked_at`);
        const installation = await rest.select('noop_app_installations',
          `source_id=eq.${sourceId}&select=user_id,revoked_at`);
        if ((registered?.[0] && registered[0].user_id!==account.id) ||
          (installation?.[0] && installation[0].user_id!==account.id)) {
          throw new IdentityError('source owner mismatch', 403, 'forbidden');
        }
        if (registered?.[0]?.revoked_at!=null || installation?.[0]?.revoked_at!=null) {
          throw new IdentityError('source revoked', 401, 'source_revoked');
        }
        if (!registered?.[0] && !installation?.[0]) throw new IdentityError('registered source required');
      }
      user={id:account.id,sourceId:sourceId!};
    } else {
      const installation=await resolveUploadIdentity({headers:req.headers,rest,allowLegacyFleetUploads:false,
        allowLegacyEnrollment:_cfg.allowLegacyEnrollment===true});
      if (installation.authMode!=='installation' || !installation.sourceId) throw new IdentityError('installation required');
      user={id:installation.id,sourceId:installation.sourceId};
    }
    const requestBody = isRead || isDays || isSeries || isActivityWindows || isDiagnostics || isComputeRead
        || isPlacementGet || isContext || isContextHistory || isExposureGet
      ? null : await boundedBody(req, isStretchFeedback ? STRETCH_FEEDBACK_MAX_BODY_BYTES
        : isExposurePost ? EXPOSURE_MAX_BODY_BYTES
        : isGroundTruthLabels ? GROUND_TRUTH_LABELS_MAX_BODY_BYTES : undefined);
    const externalDeviceId = isRead || isDays || isSeries || isActivityWindows || isDiagnostics || isComputeRead
        || isContext || isContextHistory
      ? url.searchParams.get('deviceId')
      : (isPlacementGet || isStretchFeedback || isExposurePost || isExposureGet || isGroundTruthLabels) ? null
      : isPlacementPost ? (requestBody?.device_id ?? null)
      : requestBody?.deviceId;
    // Placement is owner-scoped: GET takes no device, and a POST without device_id is a
    // user-level declaration (the RPC's NULL device scope). Stretch feedback and ground-truth labels
    // carry a device per item, which is resolved leniently inside their handlers, so they have no
    // request-level device.
    if (!isPlacementGet && !isStretchFeedback && !isExposurePost && !isExposureGet && !isGroundTruthLabels
        && !(isPlacementPost && externalDeviceId == null)
        && !isSafeExternalDeviceId(externalDeviceId)) throw fail('invalid_device_id', 400);
    const lookup = { userId: user.id, sourceId: user.sourceId, externalDeviceId };
    // Placement resolves its own device scope inside the handlers (POST with device_id,
    // user-level when absent; GET is owner-scoped and never device-scoped).
    const deviceId = isRegister
      ? await createNoopDeviceResolver({ rest })(lookup)
      : (isPlacementPost || isPlacementGet || isStretchFeedback || isExposurePost || isExposureGet
        || isGroundTruthLabels) ? null
      : await findNoopDevice({ rest, ...lookup });
    const project = _cfg.supabaseUrl.replace(/\/+$/,'');
    const identity = { userId: user.id, sourceId: user.sourceId, deviceId, externalDeviceId, project };
    if (isRegister) return Response.json({ identity });
    if (isDays) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const cursor = url.searchParams.get('cursor') ?? '0';
      const limit = url.searchParams.get('limit') ?? '8';
      const scope = url.searchParams.get('scopeRevision');
      if (!/^\d{1,16}$/.test(cursor) || !Number.isSafeInteger(Number(cursor)) ||
          !/^\d{1,2}$/.test(limit) || Number(limit) < 1 || Number(limit) > 32 ||
          (scope != null && !/^[a-f0-9]{32}$/.test(scope))) throw fail('invalid_cursor', 400);
      const page = await rest.rpc('server_result_days_page', { p_user: user.id, p_device: deviceId,
        p_source: user.sourceId, p_after: Number(cursor), p_limit: Number(limit), p_scope_revision: scope });
      return Response.json({ ...page, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isSeries) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const query = parseSeriesQuery(url.searchParams);
      const series = await rest.rpc('server_metric_series_read', {
        p_user: user.id, p_from: query.from, p_to: query.to, ...(query.metrics ? { p_metrics: query.metrics } : {}),
      });
      return Response.json({ series, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isActivityWindows) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const query = parseActivityWindowsQuery(url.searchParams);
      const days = await readActivityWindows({ rest, userId: user.id, deviceId, ...query });
      return Response.json({ days, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isComputeSubmit || isComputeRead) {
      if (!deviceId) throw fail('device_registration_pending',409);
      let result: any;
      if (isComputeSubmit) {
        const request=requestBody?.request;
        const keys=['id','family','session_id','event_start','event_end','timezone_id','input_revision',
          'algorithm_version','configuration_version','consent','expires_at'];
        if (!request || Object.keys(request).some(k=>!keys.includes(k)) || keys.some(k=>!(k in request)) ||
          !isUuid(request.id) || !isUuid(request.session_id) || typeof request.family!=='string' ||
          typeof request.timezone_id!=='string' || !Number.isSafeInteger(request.input_revision) || request.input_revision<0 ||
          request.algorithm_version!=='vps-only-1' || request.configuration_version!=='vps-only-1' ||
          typeof request.consent!=='boolean' || !Number.isFinite(Date.parse(request.event_start)) ||
          (request.event_end!==null && !Number.isFinite(Date.parse(request.event_end))) ||
          (request.expires_at!==null && !Number.isFinite(Date.parse(request.expires_at)))) throw fail('invalid_compute_request',400);
        result=await rest.rpc('submit_compute_session_request',{p_user:user.id,p_device:deviceId,p_source:user.sourceId,p_request:request});
      } else {
        const requestId=url.searchParams.get('requestId');
        if (!isUuid(requestId)) throw fail('invalid_request_id',400);
        result=await rest.rpc('read_compute_session_result',{p_user:user.id,p_device:deviceId,p_source:user.sourceId,p_request:requestId});
      }
      if (result?.result) result.result={...result.result,project};
      return Response.json({...result,identity},{headers:{'cache-control':'no-store'}});
    }
    if (isPlacementPost) {
      // G4 manual placement declaration (spec §6). The edge resolves the OWNER from the
      // installation identity and passes it to set_placement_interval — a client-supplied
      // owner is never accepted. Same auth as every other score read; no new auth path.
      const body = requestBody ?? {};
      const placement = body?.placement;
      const effectiveStart = body?.effective_start;
      const suppliedDevice = body?.device_id ?? null;
      if (typeof placement !== 'string' || !['wrist', 'bicep', 'other', 'unknown'].includes(placement)) {
        throw fail('invalid_placement', 400);
      }
      if (typeof effectiveStart !== 'string' || !Number.isFinite(Date.parse(effectiveStart))) {
        throw fail('invalid_effective_start', 400);
      }
      if (suppliedDevice != null && !isSafeExternalDeviceId(suppliedDevice)) throw fail('invalid_device_id', 400);
      let scopeDevice: string | null = null;
      if (suppliedDevice != null) {
        scopeDevice = await findNoopDevice({ rest, userId: user.id, sourceId: user.sourceId,
          externalDeviceId: suppliedDevice });
        if (!scopeDevice) throw fail('device_registration_pending', 409);
      }
      const interval = await rest.rpc('set_placement_interval', {
        p_owner: user.id, p_placement: placement, p_effective_start: effectiveStart, p_device: scopeDevice,
      });
      return Response.json({ interval }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isStretchFeedback) {
      // Model-tuning labels. The owner comes from the credential, never from the body; same auth as
      // every other score route, no new auth path.
      const outcome = await submitStretchFeedback({ rest, userId: user.id, sourceId: user.sourceId, body: requestBody });
      return Response.json(outcome, { headers: { 'cache-control': 'no-store' } });
    }
    if (isContext || isContextHistory) {
      // One device-day's context document, or the device's episodes/bouts/daily values over a range. The
      // owner is the credential's and the device the caller's own (findNoopDevice); the RPCs check both again.
      if (!deviceId) throw fail('device_registration_pending', 409);
      if (isContext) {
        const query = parseContextQuery(url.searchParams);
        const context = await rest.rpc('physiology_context_read_v1', {
          p_user: user.id, p_device: deviceId, p_day: query.day, p_mode: query.mode, p_metric: query.metric,
        });
        return Response.json({ context, identity }, { headers: { 'cache-control': 'no-store' } });
      }
      const query = parseContextHistoryQuery(url.searchParams);
      const history = await rest.rpc('physiology_context_history_read_v1', {
        p_user: user.id, p_device: deviceId, p_from: query.from, p_to: query.to, p_mode: query.mode,
      });
      return Response.json({ history, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isExposurePost) {
      // Account-level exposure revisions; owner and uploading source from the credential, never the body.
      const outcome = await submitExposureEvents({ rest, userId: user.id, sourceId: user.sourceId, body: requestBody });
      return Response.json({ ...outcome, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isExposureGet) {
      const query = parseExposureReadQuery(url.searchParams);
      const read = await rest.rpc('exposure_events_read_v1', {
        p_owner: user.id, p_from: query.from, p_to: query.to, p_include_history: query.history,
      });
      return Response.json({
        events: Array.isArray(read?.events) ? read.events : [],
        ...(query.history ? { revisions: Array.isArray(read?.revisions) ? read.revisions : [] } : {}),
        truncated: read?.truncated === true,
        identity,
      }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isGroundTruthLabels) {
      // Ground-truth activity labels. The owner comes from the credential, never from the body; same
      // auth as every other score route, no new auth path.
      const outcome = await submitGroundTruthLabels({ rest, userId: user.id, sourceId: user.sourceId, body: requestBody });
      return Response.json(outcome, { headers: { 'cache-control': 'no-store' } });
    }
    if (isPlacementGet) {
      // Owner-scoped read for reconciliation. device_id is returned as the EXTERNAL device id
      // (the id the phone registered and sends on ingest), so the phone's per-device grouping
      // in PlacementCloudSync.reconcile matches its local store.
      const rows = (await rest.select('placement_intervals',
        `owner=eq.${user.id}&select=id,device_id,placement,effective_start,effective_end,source,revision&order=effective_start.asc`)) ?? [];
      const internalIds = [...new Set(rows.map((r: any) => r.device_id).filter(Boolean))];
      let externalById: Record<string, string | null> = {};
      if (internalIds.length > 0) {
        const devices = (await rest.select('devices',
          `user_id=eq.${user.id}&id=in.(${internalIds.join(',')})&select=id,external_device_id`)) ?? [];
        for (const d of devices) externalById[d.id] = d.external_device_id ?? null;
      }
      const intervals = rows.map((r: any) => ({
        id: r.id,
        device_id: r.device_id != null ? (externalById[r.device_id] ?? r.device_id) : null,
        placement: r.placement,
        effective_start: r.effective_start,
        effective_end: r.effective_end ?? null,
        source: r.source,
        revision: r.revision,
      }));
      return Response.json({ intervals }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isOverride) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const args = sleepArguments(requestBody?.arguments, deviceId);
      const revision = await rest.rpc('enrolled_physiology_sleep_override', { ...args, p_user: user.id });
      return Response.json(revision);
    }
    if (isDiagnostics) {
      const day = url.searchParams.get('day') || utcDay();
      const parsed = new Date(day);
      if (!DAY_RE.test(day) || !Number.isFinite(parsed.getTime()) || utcDay(parsed) !== day) throw fail('invalid_day', 400);
      if (!deviceId) throw fail('device_registration_pending', 409);
      // G7 single owner-scoped diagnostic surface. The RPC (schema_version 2) reports
      // day bounds/zone, stream status + coverage + largest gap, scoring_jobs_v2 queue
      // age, projection revision, durable-vs-verified archive, and explicit blockers,
      // all for THIS owner/source/device/day only. Same auth as every other score read;
      // no new auth paths, and NO owner/device identity in the payload (the route is
      // owner-scoped by auth, exactly as before).
      const diagnostics = await rest.rpc('server_pipeline_diagnostics', {
        p_user: user.id, p_source: user.sourceId, p_device: deviceId, p_day: day,
      });
      return Response.json(diagnostics, { headers: { 'cache-control': 'no-store' } });
    }
    const day = url.searchParams.get('day') || utcDay();
    const body = await readOwnerDayScores({ rest, userId: user.id, day, deviceId });
    const overlay = body.server_scoring as any;
    if (overlay?.compute) {
      overlay.compute={...overlay.compute,project,source_id:user.sourceId};
      for (const result of Object.values(overlay.compute.families ?? {}) as any[]) {
        result.project=project; result.source_id=user.sourceId;
      }
    }
    if (!jwt && deviceId && overlay && typeof overlay === 'object') {
      try {
        const hosted = await readHostedSnapshot({ rest, userId: user.id, deviceId, day });
        if (hosted) overlay.hosted_snapshot = hosted;
      } catch {
        console.error('[scores] hosted snapshot read failed');
      }
    }
    return Response.json({ ...body, identity }, { headers: { 'cache-control': 'no-store' } });
  } catch (err: any) {
    if (err instanceof IdentityError) return Response.json({ error: err.code }, { status: err.status || 401 });
    if ([400, 403, 404, 409, 413].includes(err?.status)) {
      return Response.json({ error: err.code || 'request_rejected' }, { status: err.status });
    }
    console.error('[scores] request failed');
    return Response.json({ error: 'scores_unavailable' }, { status: 500 });
  }
}
