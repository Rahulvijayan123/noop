import type { SupabaseRest } from './rest.ts';
import { isUuid } from './keys.ts';

const fail = () => Object.assign(new Error('invalid_detection_request'), { status: 400, code: 'invalid_detection_request' });
const keys = (body: Record<string, unknown>, allowed: string[]) => Object.keys(body).every(k => allowed.includes(k));
const instant = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 32503680000;
export function validateDetectionCommand(body: any): boolean {
  if (!body || typeof body !== 'object' || Array.isArray(body) || !isUuid(body.requestId) || !isUuid(body.typeId)) return false;
  const common = ['action', 'requestId', 'typeId'];
  if (body.action === 'setting') return keys(body, [...common, 'enabled']) && typeof body.enabled === 'boolean';
  if (body.action === 'withdraw') return keys(body, [...common, 'reviewId']) && isUuid(body.reviewId);
  if (!instant(body.start) || !instant(body.end) || body.end <= body.start || body.end - body.start > 86400) return false;
  if (body.action === 'negative') return keys(body, [...common, 'start', 'end', 'deviceId']) && isUuid(body.deviceId);
  return body.action === 'review' && keys(body, [...common, 'detectionId', 'outcome', 'start', 'end'])
    && isUuid(body.detectionId) && ['confirmed', 'rejected', 'unsure', 'archived'].includes(body.outcome);
}
export async function personalEvents(rest: SupabaseRest, user: {id: string; sourceId: string},
  route: string, params: URLSearchParams, body?: unknown) {
  if (body !== undefined) {
    if (!validateDetectionCommand(body)) throw fail();
    return await rest.rpc('event_detection_command', { p_user: user.id, p_source: user.sourceId, p_body: body });
  }
  if (route === '/event-detection/physiology') {
    if ([...params.keys()].some(k => !['deviceId', 'from', 'to'].includes(k))) throw fail();
    const from = Number(params.get('from')), to = Number(params.get('to'));
    if (!isUuid(params.get('deviceId')) || !params.has('from') || !params.has('to')
      || !instant(from) || !instant(to) || to <= from || to - from > 172800) throw fail();
    return await rest.rpc('event_physiology', { p_user: user.id, p_device: params.get('deviceId'), p_start: from, p_end: to });
  }
  if ([...params.keys()].some(k => k !== 'before')) throw fail();
  const before = params.get('before');
  if (before && !isUuid(before.split(':')[1])) throw fail();
  const [time, id] = before?.split(':') ?? [];
  if (before && (!instant(Number(time)) || before.split(':').length !== 2)) throw fail();
  const cursor = before ? `&or=(start_at.lt.${Number(time)},and(start_at.eq.${Number(time)},id.lt.${id}))` : '';
  const [settings, rows, reviews] = await Promise.all([
    rest.select('event_detector_settings', `user_id=eq.${user.id}&select=type_id,enabled,revision,state,active_model_id,last_training_at,last_input_at,detail&order=type_id.asc&limit=1000`),
    rest.select('event_detections', `user_id=eq.${user.id}${cursor}&select=id,type_id,device_id,start_at,end_at,model_id,status,manual_event_id,historical&order=start_at.desc,id.desc&limit=201`),
    rest.select('event_detection_reviews', `user_id=eq.${user.id}&body->>action=in.(negative,withdraw)&select=id,body&order=created_at.desc&limit=1000`),
  ]);
  const detections = rows.slice(0, 200), last = detections.at(-1);
  const withdrawn = new Set(reviews.filter(r => r.body.action === 'withdraw').map(r => r.body.reviewId.toLowerCase()));
  const negativeReviews = reviews.filter(r => r.body.action === 'negative' && !withdrawn.has(r.id.toLowerCase()))
    .map(r => ({ id: r.id, typeId: r.body.typeId, start: r.body.start, end: r.body.end }));
  return { settings, detections, negativeReviews, next: rows.length > 200 ? `${last.start_at}:${last.id}` : null };
}
