// Coach visual pipeline: route -> design -> validate. Runs after the chat answer has streamed, so the
// text always lands first and the visual arrives beneath it. Three separate model calls:
//   1. route    picks whether the answer deserves a visual, which kind and which chart type
//               (Jev when TYPESAFE_API_KEY is set, else one cheap chat-model call).
//   2. design   the chat model fills one typed tool (chart, timeline, or cards) and gets schema,
//               correctness and layout issues back to fix.
//   3. validate an independent fact-check call against the answer and the user's logged data.
// A visual that cannot be validated is dropped: no visual beats a wrong one.

/* eslint-disable @typescript-eslint/no-explicit-any */

export const CHART_TYPES: Record<string, string> = {
  bar: 'One measure compared across a few categories, sessions, or lifts.',
  stacked_bar: 'Totals split into parts across categories or days, e.g. sets per muscle group per week, or macros per day.',
  line: 'One or a few numeric measures over time, e.g. HRV, e1RM, body weight, or resting heart rate across days or weeks.',
  area: 'A measure over time where the filled magnitude matters, e.g. weekly volume or sleep hours.',
  pie: 'One total split into at most six parts at a single point in time, e.g. calories from protein, carbs, and fat.',
  scatter: 'Relationship between two numeric measures across items, e.g. sleep hours against next-day HRV.',
  bubble: 'Items placed on two measures with a third as bubble size, e.g. lifts by frequency and average load sized by volume.',
  heatmap: 'A grid of values across two dimensions, e.g. sets by muscle group and weekday, or intensity by week and lift.',
  waterfall: 'A start value building up or down to an end value through additive steps, e.g. weekly volume change by lift.',
  range: 'Point estimates with a low and high, e.g. rep ranges, target zones, or min-to-max heart rate per day.',
  progress: 'Actual against a target for a few items, e.g. weekly sets against a goal, protein against a target, steps against a goal.',
};

export const TIMELINE_TYPES: Record<string, string> = {
  gantt: "Phases or blocks laid out over calendar time with start and end, e.g. a training program's mesocycles or a deload schedule.",
  milestones: 'Dated one-off events without durations, e.g. PRs, test days, or competitions.',
};

export const CARD_TYPES: Record<string, string> = {
  facts: 'A handful of headline figures to scan at a glance.',
  table: 'Several attributes for each of several items, e.g. lifts with weight, reps, and change.',
  comparison: 'Two to four options, sessions, or periods compared side by side.',
  list: 'An ordered list of items, steps, or priorities, each with an optional tag.',
  alerts: 'A few warnings or caveats that deserve emphasis.',
};

export const ALL_TYPES: Record<string, string> = { ...CHART_TYPES, ...TIMELINE_TYPES, ...CARD_TYPES };

export const VISUAL_KINDS: Record<string, string> = {
  none: 'Plain prose is enough: no concrete figures, comparisons, sequences, or lists that a visual would clarify.',
  trend_chart: 'A numeric measure over time or sessions, such as HRV, strength, weight, sleep, or volume trends (line or area chart).',
  category_comparison: 'Compare numeric measures across categories, lifts, muscle groups, or days, possibly split into series (bar or stacked bar).',
  share_of_whole: 'Composition of a total, such as macro split, volume by muscle group, or time in zones (pie or stacked bar).',
  distribution_or_correlation: 'Relationships between two measures, or a matrix of values (scatter, bubble, or heatmap).',
  bridge_waterfall: 'How a starting value builds up or down to an end value through steps (waterfall).',
  range_estimate: 'Values with a low and high, such as rep ranges or target zones (range).',
  goal_progress: 'Actual against a target or goal for a few items (progress bars).',
  program_timeline: 'Training blocks, phases, or dated milestones over calendar time (Gantt or milestones).',
  table: 'Several attributes for each of multiple items, such as lifts with weight, reps, and change (table).',
  kpi_facts: 'A handful of headline figures to scan at a glance (fact tiles).',
  comparison_cards: 'Two to four options, sessions, or periods compared side by side (comparison cards).',
  ranked_list: 'An ordered list of items or steps, each with a tag (list).',
  risk_alerts: 'A few warnings, red flags, or caveats that deserve emphasis (alerts).',
};

export const KIND_TYPES: Record<string, string[]> = {
  trend_chart: ['line', 'area'],
  category_comparison: ['bar', 'stacked_bar', 'progress'],
  share_of_whole: ['pie', 'stacked_bar'],
  distribution_or_correlation: ['scatter', 'bubble', 'heatmap'],
  bridge_waterfall: ['waterfall'],
  range_estimate: ['range'],
  goal_progress: ['progress', 'bar'],
  program_timeline: ['gantt', 'milestones'],
  table: ['table'],
  kpi_facts: ['facts'],
  comparison_cards: ['comparison'],
  ranked_list: ['list'],
  risk_alerts: ['alerts'],
};

export const ROW_SHAPES: Record<string, string> = {
  bar: 'label, value, series?',
  stacked_bar: 'label, series, value',
  line: 'label, value, series?',
  area: 'label, value, series?',
  pie: 'label, value',
  scatter: 'x, y, label?',
  bubble: 'x, y, size, label',
  heatmap: 'x, y, value (x and y are category names)',
  waterfall: 'label, value, total? (true on the start and end bars)',
  range: 'label, value, lower, upper',
  progress: 'label, value, target',
};

const MAX_POINTS = 40;
const MAX_LABEL = 40;
const MAX_TABLE_ROWS = 10;
const MAX_TABLE_COLUMNS = 5;
const MAX_TASKS = 20;
const TONES = new Set(['neutral', 'positive', 'warning', 'negative', 'info']);

const isObject = (value: unknown): value is Record<string, any> => value !== null && typeof value === 'object' && !Array.isArray(value);
const text = (value: unknown, max: number): string =>
  typeof value === 'string' ? value.trim().slice(0, max) : typeof value === 'number' && Number.isFinite(value) ? String(value) : '';

export function toNumber(value: unknown): number | null {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value !== 'string') return null;
  const cleaned = value.replace(/[,%$€£\s]|lbs?|kg|ms|bpm|hrs?|min|USD|EUR/gi, '');
  if (cleaned === '' || cleaned === '-') return null;
  const parsed = Number(cleaned);
  return Number.isFinite(parsed) ? parsed : null;
}

const QUARTER = /^(\d{4})-?Q([1-4])$/i;
const HALF = /^(?:H([12])\s*(\d{4})|(\d{4})\s*-?\s*H([12]))$/i;

export function toIsoDate(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const v = value.trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return Number.isNaN(Date.parse(v)) ? null : v;
  if (/^\d{4}-\d{2}$/.test(v)) return `${v}-01`;
  if (/^\d{4}$/.test(v)) return `${v}-01-01`;
  const q = v.match(QUARTER);
  if (q) return `${q[1]}-${String((Number(q[2]) - 1) * 3 + 1).padStart(2, '0')}-01`;
  const h = v.match(HALF);
  if (h) {
    const year = h[2] ?? h[3];
    const half = Number(h[1] ?? h[4]);
    return `${year}-${half === 1 ? '01' : '07'}-01`;
  }
  const parsed = Date.parse(v);
  return Number.isNaN(parsed) ? null : new Date(parsed).toISOString().slice(0, 10);
}

// ---------------------------------------------------------------------------
// Normalisation: a designer tool call becomes the canonical shape the app decodes.
// ---------------------------------------------------------------------------

type Parsed = { ok: true; viz: any } | { ok: false; issues: string[] };

function normalizeChart(raw: any): Parsed {
  const type = raw.type;
  if (!(type in CHART_TYPES)) return { ok: false, issues: [`type must be one of ${Object.keys(CHART_TYPES).join(', ')}`] };
  const rows = Array.isArray(raw.data) ? raw.data.filter(isObject) : [];
  if (rows.length === 0) return { ok: false, issues: ['data must be a non-empty array of row objects'] };
  const issues: string[] = [];
  const points: any[] = [];
  rows.slice(0, MAX_POINTS).forEach((row: any, index: number) => {
    const at = `row ${index + 1}`;
    const label = text(row.label ?? row.x, MAX_LABEL * 2);
    const series = text(row.series, MAX_LABEL * 2);
    const value = toNumber(row.value ?? row.y);
    switch (type) {
      case 'scatter':
      case 'bubble': {
        const x = toNumber(row.x);
        const y = toNumber(row.y ?? row.value);
        const size = toNumber(row.size);
        if (x === null || y === null) issues.push(`${at}: x and y must be numbers`);
        else if (type === 'bubble' && size === null) issues.push(`${at}: bubble rows need a numeric size`);
        else points.push({ xValue: x, y, ...(size !== null ? { size } : {}), ...(label ? { label } : {}), ...(series ? { series } : {}) });
        break;
      }
      case 'heatmap': {
        const column = text(row.x, MAX_LABEL);
        const rowName = text(row.y, MAX_LABEL);
        const v = toNumber(row.value);
        if (!column || !rowName || v === null) issues.push(`${at}: heatmap rows need x, y (category names) and a numeric value`);
        else points.push({ x: column, row: rowName, y: v });
        break;
      }
      case 'range': {
        const lower = toNumber(row.lower ?? row.low);
        const upper = toNumber(row.upper ?? row.high);
        if (!label || lower === null || upper === null) issues.push(`${at}: range rows need label, lower and upper`);
        else points.push({ x: label, y: value ?? (lower + upper) / 2, low: lower, high: upper, ...(value === null ? { midpoint: true } : {}) });
        break;
      }
      case 'progress': {
        const target = toNumber(row.target);
        if (!label || value === null || target === null) issues.push(`${at}: progress rows need label, value and target`);
        else points.push({ x: label, y: value, target });
        break;
      }
      default: {
        if (!label || value === null) issues.push(`${at}: needs a label and a numeric value`);
        else points.push({ x: label, y: value, ...(series ? { series } : {}), ...(row.total === true ? { total: true } : {}) });
      }
    }
  });
  if (issues.length) return { ok: false, issues: issues.slice(0, 5) };
  return {
    ok: true,
    viz: {
      type,
      title: text(raw.title, 120),
      ...(text(raw.subtitle, 160) ? { subtitle: text(raw.subtitle, 160) } : {}),
      ...(text(raw.yLabel, 60) ? { yLabel: text(raw.yLabel, 60) } : {}),
      ...(text(raw.xLabel, 60) ? { xLabel: text(raw.xLabel, 60) } : {}),
      ...(raw.horizontal === true ? { horizontal: true } : {}),
      ...(toNumber(raw.reference) !== null ? { reference: toNumber(raw.reference) } : {}),
      ...(text(raw.source, 120) ? { source: text(raw.source, 120) } : {}),
      points,
    },
  };
}

function normalizeTimeline(raw: any): Parsed {
  const type = raw.type;
  if (!(type in TIMELINE_TYPES)) return { ok: false, issues: ['type must be gantt or milestones'] };
  const tasks = Array.isArray(raw.tasks) ? raw.tasks.filter(isObject) : [];
  if (tasks.length === 0) return { ok: false, issues: ['tasks must be a non-empty array'] };
  const issues: string[] = [];
  const out: any[] = [];
  tasks.slice(0, MAX_TASKS).forEach((task: any, index: number) => {
    const name = text(task.name, MAX_LABEL + 20);
    const start = toIsoDate(text(task.start, 20));
    const end = task.end ? toIsoDate(text(task.end, 20)) : null;
    if (!name || !start) issues.push(`task ${index + 1}: needs a name and a valid start date`);
    else if (type === 'gantt' && !end) issues.push(`task "${name}": a gantt task needs an end date`);
    else out.push({ id: text(task.id, 40) || `t${index + 1}`, name, start, ...(end ? { end } : {}), ...(text(task.group, 40) ? { group: text(task.group, 40) } : {}) });
  });
  if (issues.length) return { ok: false, issues: issues.slice(0, 5) };
  return {
    ok: true,
    viz: {
      type,
      title: text(raw.title, 120),
      ...(text(raw.subtitle, 160) ? { subtitle: text(raw.subtitle, 160) } : {}),
      ...(text(raw.source, 120) ? { source: text(raw.source, 120) } : {}),
      tasks: out,
    },
  };
}

function normalizeCards(raw: any): Parsed {
  const type = raw.type;
  if (!(type in CARD_TYPES)) return { ok: false, issues: [`type must be one of ${Object.keys(CARD_TYPES).join(', ')}`] };
  const base = {
    type,
    title: text(raw.title, 120),
    ...(text(raw.subtitle, 160) ? { subtitle: text(raw.subtitle, 160) } : {}),
    ...(text(raw.source, 120) ? { source: text(raw.source, 120) } : {}),
  };
  const tone = (value: unknown) => (TONES.has(value as string) ? value : 'neutral');
  if (type === 'facts') {
    const facts = (Array.isArray(raw.facts) ? raw.facts : []).filter(isObject)
      .map((f: any) => ({ label: text(f.label, 40), value: text(f.value, 24), ...(text(f.detail, 60) ? { detail: text(f.detail, 60) } : {}), tone: tone(f.tone) }))
      .filter((f: any) => f.label && f.value).slice(0, 6);
    return facts.length >= 2 ? { ok: true, viz: { ...base, facts } } : { ok: false, issues: ['facts needs at least 2 items with label and value'] };
  }
  if (type === 'table') {
    const columns = (Array.isArray(raw.columns) ? raw.columns : []).map((c: any) => text(isObject(c) ? c.label : c, 24)).filter(Boolean).slice(0, MAX_TABLE_COLUMNS);
    const rows = (Array.isArray(raw.rows) ? raw.rows : [])
      .map((row: any) => (Array.isArray(row) ? row : isObject(row) ? Object.values(row) : [row]))
      .map((row: any[]) => columns.map((_: string, i: number) => text(row[i] ?? '', 32)))
      .filter((row: string[]) => row.some(Boolean)).slice(0, MAX_TABLE_ROWS);
    return columns.length >= 2 && rows.length >= 2
      ? { ok: true, viz: { ...base, columns, rows } }
      : { ok: false, issues: ['table needs at least 2 column names and 2 rows (rows are arrays of cells)'] };
  }
  if (type === 'comparison') {
    const options = (Array.isArray(raw.options) ? raw.options : []).filter(isObject).map((o: any) => ({
      name: text(o.name, 32),
      ...(text(o.badge, 24) ? { badge: text(o.badge, 24) } : {}),
      facts: (Array.isArray(o.facts) ? o.facts : []).filter(isObject).map((f: any) => ({ label: text(f.label, 32), value: text(f.value, 24) })).filter((f: any) => f.label && f.value).slice(0, 5),
    })).filter((o: any) => o.name && o.facts.length).slice(0, 4);
    return options.length >= 2 ? { ok: true, viz: { ...base, options } } : { ok: false, issues: ['comparison needs 2-4 options each with a name and facts'] };
  }
  if (type === 'list') {
    const items = (Array.isArray(raw.items) ? raw.items : []).filter(isObject)
      .map((i: any) => ({ title: text(i.title, 80), ...(text(i.detail, 120) ? { detail: text(i.detail, 120) } : {}), ...(text(i.tag, 20) ? { tag: text(i.tag, 20) } : {}) }))
      .filter((i: any) => i.title).slice(0, 8);
    return items.length >= 2 ? { ok: true, viz: { ...base, items } } : { ok: false, issues: ['list needs at least 2 items with a title'] };
  }
  const alerts = (Array.isArray(raw.alerts) ? raw.alerts : []).filter(isObject)
    .map((a: any) => ({ tone: tone(a.tone), title: text(a.title, 80), ...(text(a.detail, 160) ? { detail: text(a.detail, 160) } : {}) }))
    .filter((a: any) => a.title).slice(0, 4);
  return alerts.length >= 1 ? { ok: true, viz: { ...base, alerts } } : { ok: false, issues: ['alerts needs at least 1 alert with a title'] };
}

export function parseVisualization(toolName: string | undefined, raw: unknown): Parsed {
  if (!isObject(raw)) return { ok: false, issues: ['the tool arguments must be an object'] };
  if (!text(raw.title, 120)) return { ok: false, issues: ['title is required and must name what is shown'] };
  return toolName === 'visualize_timeline' ? normalizeTimeline(raw)
    : toolName === 'present_cards' ? normalizeCards(raw)
    : normalizeChart(raw);
}

// ---------------------------------------------------------------------------
// Figures: what the source states
// ---------------------------------------------------------------------------

export function numbersIn(source: unknown): number[] {
  return [...String(source).replace(/(\d),(?=\d{3})/g, '$1').matchAll(/\d+(?:\.\d+)?/g)].map((m) => Number(m[0]));
}

interface Stated { value: number; pct: boolean; mass: boolean }

/** Stated figures with the unit context around each number: only explicitly-marked conversions are ever accepted. */
export function statedFigures(source: unknown): Stated[] {
  const body = String(source).replace(/(\d),(?=\d{3})/g, '$1');
  return [...body.matchAll(/\d+(?:\.\d+)?/g)].map((m) => {
    const value = Number(m[0]);
    const index = m.index ?? 0;
    const after = body.slice(index + m[0].length, index + m[0].length + 8);
    const before = body.slice(Math.max(0, index - 10), index);
    const pct = /%|percent/i.test(after) || /percent of|percentage of/i.test(before + after);
    const mass = /\b(?:k?g|grams?|lbs?|pounds?|oz|ounces?)\b/i.test(after.replace(/^[.,;)]*/, '')) || /\b(?:k?g|grams?|lbs?|pounds?|oz|ounces?)\b\s*$/i.test(before);
    return { value, pct, mass };
  });
}

function isStated(value: number, stated: Stated[]): boolean {
  const v = Math.abs(value);
  if (v === 0 || v === 1 || v === 100) return true;
  const near = (a: number, b: number) => Math.abs(a - b) <= Math.max(1e-9, Math.abs(b) * 0.005);
  return stated.some(({ value: a, pct, mass }) => {
    if (near(v, a) || Math.abs(Math.round(a) - v) < 1e-9 || Math.abs(Math.round(a * 10) / 10 - v) < 1e-9) return true;
    if (pct && (near(v, a / 100) || near(v, a * 100))) return true;
    if (mass && (near(v, a * 1000) || near(v, a / 1000))) return true;
    return false;
  });
}

export function unstatedFigures(values: unknown[], source: unknown, ignoreSmall = false): number[] {
  const stated = statedFigures(source);
  const withoutCodes = (s: string) => s.replace(/\b[A-Za-z]+[-‑]?\d[\w-]*|\b\d+[A-Za-z]+\d[\w-]*/g, ' ');
  const figures = values.flatMap((v) => (typeof v === 'number' ? [v] : numbersIn(withoutCodes(String(v)))));
  return [...new Set(figures.filter((v) => !(ignoreSmall && Number.isInteger(v) && Math.abs(v) < 10) && !isStated(v, stated)))];
}

function textFigures(viz: any): string[] {
  const parts: string[] = [];
  if (viz.facts) viz.facts.forEach((f: any) => parts.push(f.value, f.detail ?? ''));
  if (viz.rows) viz.rows.forEach((r: string[]) => parts.push(...r));
  if (viz.options) viz.options.forEach((o: any) => o.facts.forEach((f: any) => parts.push(f.value)));
  if (viz.items) viz.items.forEach((i: any) => parts.push(i.detail ?? ''));
  if (viz.alerts) viz.alerts.forEach((a: any) => parts.push(a.detail ?? ''));
  return parts.filter(Boolean);
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/** Problems that make a visual state something false. Such a spec is never shown. */
export function correctnessIssues(viz: any, source?: string): string[] {
  const issues: string[] = [];
  if (viz.points) {
    if (viz.type === 'pie') {
      const percentages = /%|percent|share/i.test(`${viz.yLabel ?? ''} ${viz.title} ${viz.subtitle ?? ''}`);
      const total = viz.points.reduce((s: number, p: any) => s + p.y, 0);
      if (percentages && viz.points.every((p: any) => p.y >= 0 && p.y <= 100) && total > 102) {
        issues.push(`the slices add up to ${Math.round(total)}%, so they are not parts of one whole; use a bar chart`);
      }
      const seen = new Set<string>();
      const repeated = viz.points.filter((p: any) => (seen.has(p.x) ? true : (seen.add(p.x), false))).map((p: any) => `"${p.x}"`);
      if (repeated.length) issues.push(`${[...new Set(repeated)].slice(0, 3).join(', ')} appear more than once in one pie`);
    }
    if (viz.type === 'range') {
      const bad = viz.points.filter((p: any) => p.low > p.y || p.high < p.y || p.low > p.high).map((p: any) => p.x);
      if (bad.length) issues.push(`ranges must satisfy lower <= value <= upper for: ${bad.slice(0, 3).join(', ')}`);
    }
    if (viz.type === 'line' || viz.type === 'area') {
      const counts = new Map<string, number>();
      for (const p of viz.points) counts.set(p.series ?? '', (counts.get(p.series ?? '') ?? 0) + 1);
      const lonely = [...counts].filter(([, n]) => n < 2).map(([s]) => `"${s || 'value'}"`);
      if (lonely.length) issues.push(`series ${lonely.slice(0, 3).join(', ')} have a single point; a line needs at least 2 points per series, with time or sessions as the label`);
    }
    if (source) {
      const values: number[] = [];
      for (const p of viz.points) {
        for (const key of ['y', 'xValue', 'size', 'low', 'high', 'target']) {
          if (typeof p[key] === 'number' && !(key === 'y' && p.midpoint)) values.push(p[key]);
        }
      }
      if (typeof viz.reference === 'number') values.push(viz.reference);
      const unstated = unstatedFigures(values, source);
      if (unstated.length) issues.push(`these values are not stated in the answer or the data; plot only stated figures: ${unstated.slice(0, 5).join(', ')}`);
      const frame = `${viz.yLabel ?? ''} ${viz.title} ${viz.subtitle ?? ''}`;
      const percentChart = /%|percent/i.test(frame) || (viz.type === 'pie' && /share/i.test(frame));
      if (percentChart && values.length && !statedFigures(source).some((s) => s.pct)) {
        issues.push('the source never states a percentage; plot the stated measure and its unit instead of repainting plain figures as percentages');
      }
    }
  }
  if (viz.tasks && source) {
    for (const task of viz.tasks) {
      if (task.end && task.end < task.start) issues.push(`task "${task.name}" ends before it starts`);
    }
  }
  if (source) {
    const cardFigures = textFigures(viz);
    if (cardFigures.length) {
      const unstated = unstatedFigures(cardFigures, source, true);
      if (unstated.length) issues.push(`these figures are not stated in the answer or the data; use only stated figures: ${unstated.slice(0, 5).join(', ')}`);
    }
  }
  return issues;
}

/** Design review: cramped or unclear, but not false. Sent back to the designer once. */
export function lintVisualization(viz: any, source?: string): string[] {
  const issues: string[] = [];
  if (viz.points) {
    const labels = [...new Set<string>(viz.points.map((p: any) => p.x).filter((v: unknown) => typeof v === 'string'))];
    if (labels.some((l) => l.length > MAX_LABEL)) issues.push(`shorten category labels to under ${MAX_LABEL} characters and move detail into the subtitle`);
    if (viz.type === 'pie' && labels.length > 6) issues.push('pie charts read poorly past 6 slices; use a bar chart');
    if (viz.type === 'heatmap' && viz.points.length < 4) issues.push('a heatmap needs at least 4 cells');
    if ((viz.type === 'bar' || viz.type === 'progress') && labels.length > 12) issues.push('too many bars; keep the 12 that matter most');
  }
  return [...issues, ...correctnessIssues(viz, source)];
}

// ---------------------------------------------------------------------------
// Axes: titled, ordered, legible and free of collisions. Geometry is kept in step with CoachVizViews.swift.
// ---------------------------------------------------------------------------

const UNIT = /\(.+\)|%|\b(?:lbs?|kg|ms|bpm|hrs?|hours?|mins?|minutes?|secs?|seconds?|sets?|reps?|kcal|cal(?:ories)?|grams?|g|steps?|days?|weeks?|sessions?|workouts?|score|points?|miles?|mi|km|mph|watts?|rpe|rir|volume|load|count|hz|rate|per)\b/i;
const PLACEHOLDER = /^(?:x|y|value|values|data|number|amount|axis|label|labels|category|categories|series)$/i;
const TIME_LIKE = /\b(?:date|dates|day|days|week|weeks|month|months|time|session|sessions|workout|workouts|year|period|set|sets|block|cycle|phase|rep|reps|round|rounds|age|distance)\b/i;
const BAR_LIKE = new Set(['bar', 'stacked_bar', 'waterfall', 'range', 'progress']);
const TIME_TYPES = new Set(['line', 'area']);
const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const PLOT_WIDTH = 250;
const PLOT_HEIGHT = 140;
const CHAR_WIDTH = 5.4;
const LABEL_HEIGHT = 12;
const MARK_CLEARANCE = 1.5;
const MAX_LABELLED_POINTS = 8;

export function labelOrderKey(label: unknown): number | null {
  const v = String(label).trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return Date.parse(v);
  const md = v.match(/^([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2})(?:,?\s+(\d{4}))?$/);
  if (md) {
    const month = MONTHS.indexOf(md[1].toLowerCase());
    if (month < 0) return null;
    return (md[3] ? Number(md[3]) : 2000) * 10000 + month * 100 + Number(md[2]);
  }
  const week = v.match(/^(?:week|wk|w)\s*(\d+)$/i);
  if (week) return Number(week[1]);
  const numeric = v.match(/^(?:session|workout|day|#)?\s*(\d+)$/i);
  if (numeric) return Number(numeric[1]);
  return null;
}

function unorderedLabels(labels: string[]): boolean {
  const keys = labels.map(labelOrderKey);
  if (keys.some((k) => k === null) || keys.length < 3) return false;
  const nums = keys as number[];
  const decreases = nums.filter((k, i) => i > 0 && k < nums[i - 1]).length;
  if (decreases === 0) return false;
  // Month/day labels with no year can legitimately wrap once across New Year.
  const undated = labels.every((l) => !/\d{4}/.test(l)) && labels.every((l) => /^[A-Za-z]{3}/.test(l));
  return !(undated && decreases === 1 && nums[nums.length - 1] < nums[0]);
}

function axisTitleIssue(name: string, value: string | undefined, needsUnit: boolean): string | null {
  const v = (value ?? '').trim();
  if (!v || PLACEHOLDER.test(v)) {
    return `${name} is required: ${needsUnit ? "name the measure and its unit, like 'HRV (ms)' or 'Body weight (lb)'" : "name what the horizontal axis shows, like 'Date', 'Week' or 'Lift'"}`;
  }
  if (needsUnit && !UNIT.test(v)) return `${name} "${v}" has no unit; write it as 'Measure (unit)'`;
  return null;
}

export function labelCollisions(viz: any): string[][] {
  const pts = viz.points.filter((p: any) => typeof p.xValue === 'number' && p.label);
  if (pts.length < 2) return [];
  const fraction = viz.type === 'bubble' ? 0.32 : 0.2;
  const pad = (values: number[]) => {
    const lo = Math.min(...values);
    const hi = Math.max(...values);
    const span = Math.max(hi - lo, Math.abs(hi) * 0.02, 1e-6);
    return [lo - span * fraction, hi + span * fraction];
  };
  const [xlo, xhi] = pad(viz.points.map((p: any) => p.xValue));
  const [ylo, yhi] = pad(viz.points.map((p: any) => p.y));
  const sizes = viz.points.map((p: any) => p.size ?? 0);
  const smin = Math.min(...sizes);
  const smax = Math.max(...sizes);
  const radius = (p: any) => {
    if (viz.type !== 'bubble') return 4;
    const t = smax > smin ? (p.size - smin) / (smax - smin) : 0;
    return Math.sqrt(90 + t * 810) / 2;
  };
  const boxes = pts.map((p: any) => {
    const px = ((p.xValue - xlo) / (xhi - xlo)) * PLOT_WIDTH;
    const py = PLOT_HEIGHT - ((p.y - ylo) / (yhi - ylo)) * PLOT_HEIGHT;
    const r = radius(p);
    const w = p.label.length * CHAR_WIDTH;
    return {
      label: p.label,
      text: { x: px - w / 2, y: py - r - 2 - LABEL_HEIGHT, w, h: LABEL_HEIGHT },
      mark: { x: px - r - MARK_CLEARANCE, y: py - r - MARK_CLEARANCE, w: (r + MARK_CLEARANCE) * 2, h: (r + MARK_CLEARANCE) * 2 },
    };
  });
  const hit = (a: any, b: any) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
  const clashes: string[][] = [];
  for (let i = 0; i < boxes.length; i += 1) {
    for (let j = 0; j < boxes.length; j += 1) {
      if (i === j) continue;
      if ((j > i && hit(boxes[i].text, boxes[j].text)) || hit(boxes[i].text, boxes[j].mark)) clashes.push([boxes[i].label, boxes[j].label]);
    }
  }
  return clashes;
}

/** Blocking axis review. Returns designer-facing instructions; empty means the axes are sound. */
export function axisIssues(viz: any): string[] {
  if (!viz.points) return [];
  const issues: string[] = [];
  const { type, points } = viz;
  const labels: string[] = points.map((p: any) => p.x).filter((v: unknown) => typeof v === 'string');
  const unique = [...new Set(labels)];

  if (type === 'pie') return issues;
  if (type === 'heatmap') {
    const cell = axisTitleIssue('yLabel', viz.yLabel, true);
    if (cell) issues.push(`${cell} (for a heatmap it names what each cell's colour measures)`);
    if (unique.length > 8) issues.push(`a heatmap with ${unique.length} columns is too wide for a phone; keep at most 8 columns`);
    if (unique.length > 5 && unique.some((l) => l.length > 6)) issues.push("heatmap column labels must be 6 characters or fewer (like 'Mon' or 'W12') when there are more than 5 columns");
    return issues;
  }

  const y = axisTitleIssue('yLabel', viz.yLabel, true);
  if (y) issues.push(y);
  if (type === 'progress') return issues;

  const scatterLike = type === 'scatter' || type === 'bubble';
  const x = axisTitleIssue('xLabel', viz.xLabel, scatterLike);
  if (x) issues.push(x);
  if (viz.xLabel && viz.yLabel && viz.xLabel.trim().toLowerCase() === viz.yLabel.trim().toLowerCase()) issues.push('xLabel and yLabel must name different things');

  if (scatterLike) {
    if (type === 'bubble' && points.some((p: any) => !p.label)) issues.push('every bubble needs a label naming it');
    if (type === 'bubble' && points.some((p: any) => typeof p.size === 'number' && p.size <= 0)) issues.push('every bubble needs a positive size; a zero or negative size cannot be drawn');
    if (type === 'bubble' && points.length > MAX_LABELLED_POINTS) issues.push(`a bubble chart draws every label; keep at most ${MAX_LABELLED_POINTS} bubbles`);
    if (points.length <= MAX_LABELLED_POINTS) {
      const clashes = labelCollisions(viz);
      if (clashes.length) {
        const names = [...new Set(clashes.flat())].slice(0, 4).map((n) => `"${n}"`).join(', ');
        issues.push(`the labels of ${names} would overlap each other or another point; drop the least important points, shorten the labels, or use a different chart type`);
      }
    }
    return issues;
  }

  const bySeries = new Map<string, any[]>();
  for (const p of points) {
    const key = p.series ?? '';
    if (!bySeries.has(key)) bySeries.set(key, []);
    bySeries.get(key)!.push(p);
  }

  const repeated: string[] = [];
  for (const rows of bySeries.values()) {
    const seen = new Set<string>();
    for (const p of rows) {
      if (seen.has(p.x)) repeated.push(p.x);
      seen.add(p.x);
    }
  }
  if (repeated.length && type !== 'waterfall') issues.push(`the label ${[...new Set(repeated)].slice(0, 3).map((r) => `"${r}"`).join(', ')} appears twice on the same axis; every position needs a distinct label`);

  if (TIME_TYPES.has(type)) {
    for (const [name, rows] of bySeries) {
      if (unorderedLabels(rows.map((r) => r.x))) {
        issues.push(`${name ? `series "${name}" ` : ''}labels must run oldest to newest, left to right`);
        break;
      }
    }
    const long = unique.filter((l) => l.length > 12);
    if (long.length) issues.push(`time-axis labels must be 12 characters or fewer, like 'Mar 3' or 'Wk 12' (${long.slice(0, 2).map((l) => `"${l}"`).join(', ')})`);
    if (viz.xLabel && !TIME_LIKE.test(viz.xLabel.trim())) {
      issues.push(`a ${type} chart plots change over time, so xLabel should name the time axis (like 'Date', 'Week' or 'Session'), not "${viz.xLabel}"`);
    }
  }

  if (BAR_LIKE.has(type)) {
    const n = unique.length;
    if (!viz.horizontal && n > 8) issues.push(`${n} vertical bars will not fit on a phone; set horizontal true and keep at most 12, or keep 8 or fewer`);
    if (viz.horizontal && n > 12) issues.push('keep at most 12 horizontal bars');
    if (!viz.horizontal && n >= 2 && n <= 8) {
      const perLabel = PLOT_WIDTH / n;
      const allowed = Math.max(4, Math.floor((perLabel / CHAR_WIDTH) * 2) - 1);
      const tooLong = unique.filter((l) => l.length > allowed);
      if (tooLong.length) issues.push(`with ${n} columns, category labels must be ${allowed} characters or fewer (${tooLong.slice(0, 2).map((l) => `"${l}"`).join(', ')}); shorten them or set horizontal true`);
    }
    if (viz.horizontal) {
      const tooLong = unique.filter((l) => l.length > 24);
      if (tooLong.length) issues.push(`horizontal bar labels must be 24 characters or fewer (${tooLong.slice(0, 2).map((l) => `"${l}"`).join(', ')})`);
    }
  }

  if (bySeries.size > 1 && type !== 'stacked_bar' && type !== 'waterfall') {
    const peaks = [...bySeries.values()].map((rows) => Math.max(...rows.map((r) => Math.abs(r.y))));
    const positive = peaks.filter((v) => v > 0);
    if (positive.length > 1 && Math.max(...positive) / Math.min(...positive) > 12) {
      issues.push('the series differ by more than 12x in size, so the smaller one would look flat on one shared axis; plot one measure per chart or normalise both to the same unit');
    }
  }

  const seriesNames = [...new Set(points.map((p: any) => p.series).filter(Boolean))];
  if (seriesNames.length > 7) issues.push(`the app draws at most 7 series (one colour each); ${seriesNames.length} is too many; keep the 7 that matter`);
  if (['bar', 'stacked_bar', 'area', 'waterfall', 'progress'].includes(type) && points.some((p: any) => p.y < 0)) {
    issues.push('a zero-based chart cannot draw negative values; use a line chart or plot the absolute change with a note in the subtitle');
  }
  if (bySeries.size > 0 && [...bySeries.values()].some((rows) => rows.length > 1 && rows.every((r) => r.y === 0))) {
    issues.push('a series where every value is zero carries no data; drop it or plot a measure that varies');
  }
  return issues;
}

export function isSubstantive(viz: any): boolean {
  if (viz.points) return viz.points.length >= 2;
  if (viz.tasks) return viz.tasks.length >= 1;
  return true;
}

// ---------------------------------------------------------------------------
// 1. Route
// ---------------------------------------------------------------------------

export const JEV_URL = 'https://api.typesafe.ai/v1/systemone';
const MAX_QUESTION = 4000;
const MAX_ANSWER = 8000;
const MAX_EVIDENCE = 16000;
const MIN_ANSWER = 24;
const MAX_NONE_PROBABILITY = 0.35;
const MIN_TYPE_PROBABILITY = 0.12;
const EXACT_TYPE_PROBABILITY = 0.5;
const MAX_DESIGN_STEPS = 2;
const MAX_REDESIGNS = 1;
const MAX_VISUAL_WALL_MS = 60_000;
const MAX_DISTILLED_EVIDENCE = 4_000;
const JEV_TIMEOUT_MS = 5000;
const DESIGN_TIMEOUT_MS = 30_000;
const AUDIT_TIMEOUT_MS = 20_000;
const FALLBACK_TIMEOUT_MS = 8_000;
const ROUTABLE_TYPES: Record<string, string> = { ...CHART_TYPES, ...TIMELINE_TYPES };

/** Model access the pipeline needs: one non-streaming chat call with a timeout, plus an optional Jev key. */
export interface VisualDeps {
  callModel: (body: Record<string, unknown>, timeoutMs: number) => Promise<any>;
  jevKey?: string;
  fetchImpl?: typeof fetch;
}

export interface VisualRoute { kind: string; types: string[]; routedBy?: string }

export function pickVisualKind(answer: any): string | null {
  const choice = answer?.choice;
  if (!choice || choice === 'none' || !(choice in VISUAL_KINDS)) return null;
  if (typeof answer.probabilities?.none !== 'number') return null;
  return answer.probabilities.none < MAX_NONE_PROBABILITY ? choice : null;
}

export function confidentNone(answer: any): boolean {
  return typeof answer?.probabilities?.none === 'number' && answer.probabilities.none >= MAX_NONE_PROBABILITY;
}

export function rankChartTypes(answer: any): string[] {
  const ranked = Object.entries<number>(answer?.probabilities ?? {})
    .filter(([type, p]) => type in ROUTABLE_TYPES && p >= MIN_TYPE_PROBABILITY)
    .sort((a, b) => b[1] - a[1])
    .map(([type]) => type);
  const pick = answer?.choice && answer.choice in ROUTABLE_TYPES ? [answer.choice] : [];
  return [...new Set([...pick, ...ranked])].slice(0, 3);
}

export function planTypes(kind: string, chartAnswer: any): string[] {
  const family = KIND_TYPES[kind] ?? [];
  if (family.every((type) => type in CARD_TYPES)) return family.slice(0, 1);
  const ranked = rankChartTypes(chartAnswer);
  const confident = (chartAnswer?.probabilities?.[ranked[0]] ?? 0) >= EXACT_TYPE_PROBABILITY;
  const inFamily = ranked.filter((type) => family.includes(type));
  const plan = confident ? ranked : inFamily;
  return plan.length ? plan : family.slice(0, 3);
}

function parseJsonReply(content: unknown): any {
  if (typeof content !== 'string') return null;
  try {
    return JSON.parse(content.trim().replace(/^```(?:json)?\s*/i, '').replace(/```$/, '').trim());
  } catch {
    return null;
  }
}

async function routeVisualFallback(deps: VisualDeps, question: string, answer: string): Promise<any> {
  if (!answer.trim()) return null;
  try {
    const data = await deps.callModel({
      messages: [
        { role: 'system', content: `You pick whether a coach answer deserves a visual. Reply with JSON only: {"kind": "<one of ${Object.keys(VISUAL_KINDS).join('|')}>"} . Choose none by default: for questions about the assistant itself, definitions, general advice, how-to guidance, or answers where figures are incidental or merely restated from memory. Choose a visual only when the user's own measured figures, a comparison, a sequence, or a list ARE the substance of the answer, or the user asked for a chart, graph, or table.` },
        { role: 'user', content: `Question: ${question.slice(0, 1500)}\n\nAnswer: ${answer.slice(0, 4500)}` },
      ],
      response_format: { type: 'json_object' },
      temperature: 0, max_tokens: 60, reasoning_effort: 'none',
    }, FALLBACK_TIMEOUT_MS);
    const parsed = parseJsonReply(data?.choices?.[0]?.message?.content);
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch {
    return null;
  }
}

/**
 * Route via Jev when a key is configured; otherwise (or when Jev is unavailable or unconfident) one
 * chat-model call. A confident "none" means no visual, with no further calls.
 */
export async function routeVisual(deps: VisualDeps, question: string, answer: string): Promise<VisualRoute | null> {
  if (!answer.trim()) return null;
  const fetchImpl = deps.fetchImpl ?? fetch;
  const questions = {
    visual: {
      type: 'choice',
      instructions: 'Which visual, if any, would make this answer to a fitness and health question clearer or more useful? Choose none unless the answer states concrete figures, comparisons, sequences, or lists worth visualizing, or the user asked for a chart, graph, or table.',
      criteria: VISUAL_KINDS,
    },
    chart: {
      type: 'choice',
      instructions: 'If this answer is drawn as a chart, which chart type presents it most clearly? If the user named a chart type, choose it. Otherwise choose the most specific type the figures, dates, or relationships support; choose bar or line only when no more specific type fits.',
      criteria: ROUTABLE_TYPES,
    },
  };
  if (deps.jevKey) {
    try {
      const res = await fetchImpl(JEV_URL, {
        method: 'POST',
        headers: { Authorization: `Bearer ${deps.jevKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: 'jev-latest', state: { question, answer: answer.slice(0, 6000) }, questions }),
        signal: AbortSignal.timeout(JEV_TIMEOUT_MS),
      });
      if (res.ok) {
        const data = await res.json();
        const kind = pickVisualKind(data?.answers?.visual);
        if (kind) return { kind, types: planTypes(kind, data?.answers?.chart), routedBy: 'jev' };
        if (confidentNone(data?.answers?.visual)) return null;
      }
    } catch {
      // Jev unavailable; fall back below.
    }
  }
  const fallback = await routeVisualFallback(deps, question, answer);
  const kind = typeof fallback?.kind === 'string' && fallback.kind in VISUAL_KINDS && fallback.kind !== 'none' ? fallback.kind : null;
  if (!kind) return null;
  const family = KIND_TYPES[kind] ?? [];
  return { kind, types: family.slice(0, 3), routedBy: 'chat_model' };
}

// ---------------------------------------------------------------------------
// 2. Design (chat model, typed tools)
// ---------------------------------------------------------------------------

const cardShapes = `- facts: facts=[{label, value, detail?, tone?}] (2-6 items)
- table: columns=["Metric", ...] (2-5), rows=[[cell, ...]] (up to 10 rows, each an array of cells)
- comparison: options=[{name, badge?, facts:[{label, value}]}] (2-4 options)
- list: items=[{title, detail?, tag?}] (2-8 items, in order)
- alerts: alerts=[{tone: "warning"|"negative"|"info"|"positive", title, detail?}] (1-4)`;

const DESIGNER_INSTRUCTIONS = `You turn a finished fitness-coach answer into one compact, accurate visual by calling exactly one tool: visualize_data, visualize_timeline, or present_cards.

Rules:
- Use only figures, labels, and dates stated in the answer or in the DATA block (the user's own logged numbers). Never invent, estimate, smooth, or extrapolate. Never add derived values (differences, averages, totals) unless the answer or DATA states them.
- One axis is one measure in one unit.
- Axes are mandatory and checked: every chart except pie needs yLabel = the measure plus its unit in the form "Measure (unit)" (e.g. "HRV (ms)", "Body weight (lb)", "Weekly volume (sets)"), and xLabel = what the other axis shows ("Date", "Week", "Session", "Lift", "Muscle group"). Heatmaps need yLabel naming what the colour measures. Scatter and bubble charts need both labels with units.
- Order and legibility: time always runs oldest to newest, left to right. Category labels must be short enough to sit under their bars (about 8 characters for 6 columns); use horizontal:true for more than 8 categories or longer names. Never let points or labels crowd each other: label at most 8 scatter or bubble points and keep them clearly apart, dropping the least important rather than overlapping. Never put unrelated magnitudes (e.g. pounds and reps) on one axis.
- Draw the type you are given; only if the data cannot fill it, use the next listed type.
- Build the richest version the data supports: every stated point that belongs, not a two-point summary. At most 30 points for time series, 12 bars, 6 pie slices, 10 table rows.
- Time series: labels are short and chronological (e.g. "Mar 3"); one row per point; use "series" only for a real second dimension (e.g. two lifts), never to hold the label.
- Numbers must be numbers, not strings. Keep labels under 40 characters; put notes in the subtitle.
- Title names what is shown. End with source, e.g. "Your logged workouts" or "Apple Health".
- Row fields per chart type:
${Object.entries(ROW_SHAPES).map(([type, shape]) => `  - ${type}: {${shape}}`).join('\n')}
- present_cards types:
${cardShapes}
- If a tool returns issues, call it again with the full corrected spec.`;

const cellSchema = { type: 'object', additionalProperties: true };
const commonProps = {
  title: { type: 'string', description: 'Names what is shown.' },
  subtitle: { type: 'string' },
  source: { type: 'string', description: 'Where the figures come from, e.g. "Your logged workouts".' },
};
const describeTypes = (types: Record<string, string>) => Object.entries(types).map(([t, d]) => `${t} (${d})`).join(' | ');

export const DESIGNER_TOOLS = [
  {
    type: 'function',
    function: {
      name: 'visualize_data',
      description: `Chart figures. Types: ${describeTypes(CHART_TYPES)}`,
      parameters: {
        type: 'object',
        properties: {
          type: { type: 'string', enum: Object.keys(CHART_TYPES) },
          ...commonProps,
          data: { type: 'array', items: cellSchema, description: 'Rows of stated figures.' },
          yLabel: { type: 'string', description: 'Required except for pie. The measure and its unit as "Measure (unit)", e.g. "HRV (ms)".' },
          xLabel: { type: 'string', description: 'Required except for pie. What the other axis shows, e.g. "Date", "Week", "Lift".' },
          horizontal: { type: 'boolean', description: 'Horizontal bars.' },
          reference: { type: 'number', description: 'Optional reference line value stated in the answer.' },
        },
        required: ['type', 'title', 'data'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'visualize_timeline',
      description: `Timelines. Types: ${describeTypes(TIMELINE_TYPES)}`,
      parameters: {
        type: 'object',
        properties: {
          type: { type: 'string', enum: Object.keys(TIMELINE_TYPES) },
          ...commonProps,
          tasks: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                id: { type: 'string' },
                name: { type: 'string' },
                start: { type: 'string', description: 'ISO date, "2026-06", or "2026-Q3".' },
                end: { type: 'string', description: 'Omit for a milestone.' },
                group: { type: 'string' },
              },
              required: ['name', 'start'],
            },
          },
        },
        required: ['type', 'title', 'tasks'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'present_cards',
      description: `Card layouts. Types: ${describeTypes(CARD_TYPES)}`,
      parameters: {
        type: 'object',
        properties: {
          type: { type: 'string', enum: Object.keys(CARD_TYPES) },
          ...commonProps,
          facts: { type: 'array', items: cellSchema },
          columns: { type: 'array', items: { type: 'string' } },
          rows: { type: 'array', items: { type: 'array', items: {} } },
          options: { type: 'array', items: cellSchema },
          items: { type: 'array', items: cellSchema },
          alerts: { type: 'array', items: cellSchema },
        },
        required: ['type', 'title'],
      },
    },
  },
];

function toolFor(type: string): string {
  if (type in CHART_TYPES) return 'visualize_data';
  if (type in TIMELINE_TYPES) return 'visualize_timeline';
  return 'present_cards';
}

function briefing(a: { question: string; answer: string; evidence: string; kind: string; previous?: any; rejection?: string }): string {
  return [
    `Visual kind: ${a.kind} (${VISUAL_KINDS[a.kind] ?? ''})`,
    `User question:\n${a.question}`,
    `Answer:\n${a.answer}`,
    a.evidence ? `DATA (the user's own logged numbers; you may plot these):\n${a.evidence}` : '',
    a.previous ? `Your previous visual was rejected by the reviewers: ${a.rejection}\nPrevious visual:\n${JSON.stringify(a.previous).slice(0, 6000)}\nReturn a corrected visual that removes every unsupported value or claim.` : '',
  ].filter(Boolean).join('\n\n');
}

interface DesignArgs {
  question: string; answer: string; evidence: string; kind: string; types: string[]; previous?: any; rejection?: string;
}

/**
 * The designer fills one typed tool. Schema, correctness and axis issues always go back to the model;
 * cosmetic issues go back once, after which the best valid spec is kept.
 */
export async function designVisual(deps: VisualDeps, args: DesignArgs): Promise<any | null> {
  const { question, answer, evidence, kind, types, previous, rejection } = args;
  const source = [question, answer, evidence].join('\n');
  const [wanted, ...fallbacks] = types;
  const shape = ROW_SHAPES[wanted] ? ` each data row is {${ROW_SHAPES[wanted]}}` : '';
  const directive = `Draw a ${wanted} (${ALL_TYPES[wanted]}) using the ${toolFor(wanted)} tool;${shape}.`
    + (fallbacks.length ? ` Only if the data cannot fill it, draw ${fallbacks.join(', then ')}.` : '');
  const messages: any[] = [
    { role: 'system', content: DESIGNER_INSTRUCTIONS },
    { role: 'user', content: `${directive}\n\n${briefing({ question, answer, evidence, kind, previous, rejection })}` },
  ];
  let accepted: any = null;
  let reviewed: any = null;
  for (let step = 0; step < MAX_DESIGN_STEPS && !accepted; step += 1) {
    const data = await deps.callModel({
      messages, tools: DESIGNER_TOOLS, tool_choice: 'required',
      temperature: 0.2, max_tokens: 3500, reasoning_effort: 'none',
    }, DESIGN_TIMEOUT_MS);
    const message = data?.choices?.[0]?.message;
    const calls: any[] = Array.isArray(message?.tool_calls) ? message.tool_calls : [];
    if (calls.length === 0) {
      messages.push({ role: 'assistant', content: message?.content ?? '' }, { role: 'user', content: 'Call exactly one tool with the visual.' });
      continue;
    }
    const [call, ...extra] = calls;
    let issues: string[] = [];
    try {
      const parsed = parseVisualization(call.function?.name, JSON.parse(call.function?.arguments ?? '{}'));
      if (!parsed.ok) issues = parsed.issues;
      else {
        const offType = types.includes(parsed.viz.type) ? [] : [`draw a ${wanted}${fallbacks.length ? ` (or ${fallbacks.join(' or ')} if the data cannot fill it)` : ''}, not ${parsed.viz.type}`];
        const wrong = correctnessIssues(parsed.viz, source);
        const axes = axisIssues(parsed.viz);
        const cosmetic = reviewed ? [] : lintVisualization(parsed.viz, source).filter((issue) => !wrong.includes(issue));
        const empty = isSubstantive(parsed.viz) ? [] : ['the visual has too little data; include every stated point or use present_cards with facts'];
        issues = [...offType, ...wrong, ...axes, ...cosmetic, ...empty];
        if (issues.length === 0) accepted = parsed.viz;
        else if (wrong.length === 0 && axes.length === 0 && empty.length === 0 && offType.length === 0) reviewed ??= parsed.viz;
      }
    } catch {
      issues = ['the tool arguments were not valid JSON; return a smaller, complete JSON object'];
    }
    if (accepted) break;
    messages.push(
      { role: 'assistant', content: message.content ?? '', tool_calls: calls },
      { role: 'tool', tool_call_id: call.id, content: JSON.stringify({ ok: false, issues, next: 'Fix these problems and call the tool again with the full corrected spec.' }) },
      ...extra.map((other) => ({ role: 'tool', tool_call_id: other.id, content: JSON.stringify({ ok: false, issues: ['only one tool call is allowed'] }) })),
    );
  }
  return accepted ?? reviewed;
}

// ---------------------------------------------------------------------------
// 3. Validate (independent fact-check call, fail-closed)
// ---------------------------------------------------------------------------

/** Deterministic evidence distillation: keep only the lines that carry figures. */
export function distillEvidence(evidence: unknown): string {
  if (typeof evidence !== 'string' || !evidence.trim()) return '';
  const joined = evidence.split('\n').filter((line) => /\d/.test(line)).map((line) => line.trim()).filter(Boolean).join('\n');
  return joined.length > MAX_DISTILLED_EVIDENCE ? joined.slice(0, MAX_DISTILLED_EVIDENCE) : joined;
}

/** Data visuals and figure-bearing cards need the fact-check call; pure text cards do not. */
export function auditRequired(viz: any): boolean {
  if (viz.points || viz.tasks) return true;
  if (viz.facts?.some((f: any) => /\d/.test(`${f.value ?? ''} ${f.detail ?? ''}`))) return true;
  if (viz.rows?.some((row: string[]) => row.some((cell) => /\d/.test(String(cell))))) return true;
  if (viz.options?.some((o: any) => o.facts?.some((f: any) => /\d/.test(`${f.label ?? ''} ${f.value ?? ''}`)))) return true;
  return false;
}

const AUDITOR_INSTRUCTIONS = `You are a strict fact-checker for charts and cards in a fitness coaching app. You receive SOURCE (the user's question, the coach's answer, and the user's logged data) and VISUAL (the JSON that will be drawn).

Check every plotted value, label, date, unit, and claim in VISUAL against SOURCE:
- Every number must be stated in SOURCE (rounding to the shown precision is fine).
- Labels and units must match what SOURCE says they measure; no swapped series, wrong units, or reversed direction.
- Nothing in the title, subtitle, or text may claim more than SOURCE supports (no invented trends, causes, or comparisons).
- Time order must match SOURCE.

Reply with JSON only: {"ok": true|false, "issues": ["short description of each unsupported item"]}. Set ok=false if any value or claim is unsupported.`;

export function parseAuditReply(content: unknown): { ok: boolean; issues: string[] } | null {
  const parsed = parseJsonReply(content);
  if (typeof parsed?.ok !== 'boolean') return null;
  return { ok: parsed.ok, issues: Array.isArray(parsed.issues) ? parsed.issues.map(String).slice(0, 5) : [] };
}

type Review = { status: 'deterministic_pass' | 'passed' | 'rejected'; issues: string[] };

/**
 * Data visuals and figure-bearing cards get the one fact-check call. A transport failure or an
 * unreadable verdict rejects: no visual beats a wrong one, so nothing ships unvalidated.
 */
export async function reviewVisual(deps: VisualDeps, a: { question: string; answer: string; evidence: string; viz: any }): Promise<Review> {
  if (!auditRequired(a.viz)) return { status: 'deterministic_pass', issues: [] };
  try {
    const data = await deps.callModel({
      messages: [
        { role: 'system', content: AUDITOR_INSTRUCTIONS },
        { role: 'user', content: `SOURCE\nQuestion: ${a.question}\n\nAnswer: ${a.answer}\n\n${a.evidence ? `Logged data:\n${a.evidence}\n\n` : ''}VISUAL\n${JSON.stringify(a.viz).slice(0, 8000)}` },
      ],
      response_format: { type: 'json_object' },
      temperature: 0, max_tokens: 500, reasoning_effort: 'none',
    }, AUDIT_TIMEOUT_MS);
    const verdict = parseAuditReply(data?.choices?.[0]?.message?.content);
    if (verdict) return { status: verdict.ok ? 'passed' : 'rejected', issues: verdict.issues };
  } catch {
    // fall through to fail-closed
  }
  return { status: 'rejected', issues: ['the fact-check could not run; no visual beats a wrong one'] };
}

export interface VisualResult {
  viz: any | null;
  audit: string;
  stats: { design_calls: number; redesigns: number; audit_status: string; distilled_evidence_chars: number };
}

/** Design, then one fact-check, then at most one corrective redesign within the wall-clock budget. */
export async function produceVisual(deps: VisualDeps, a: { question: string; answer: string; evidence: string; route: VisualRoute }): Promise<VisualResult> {
  const startedAt = Date.now();
  const distilled = distillEvidence(a.evidence);
  const budgetLeft = () => Date.now() - startedAt < MAX_VISUAL_WALL_MS;
  const base = { question: a.question, answer: a.answer, evidence: distilled, kind: a.route.kind, types: a.route.types };
  let designCalls = 1;
  let viz = await designVisual(deps, base);
  const stats = (status: string, redesigns: number) => ({ design_calls: designCalls, redesigns, audit_status: status, distilled_evidence_chars: distilled.length });
  if (!viz) return { viz: null, audit: 'no_design', stats: stats('no_design', 0) };
  let review = await reviewVisual(deps, { question: a.question, answer: a.answer, evidence: distilled, viz });
  let redesigns = 0;
  while (review.status === 'rejected' && redesigns < MAX_REDESIGNS && budgetLeft()) {
    const rejection = review.issues.join('; ') || 'unsupported values or unclear axes';
    viz = await designVisual(deps, { ...base, previous: viz, rejection });
    designCalls += 1;
    redesigns += 1;
    if (!viz) break;
    review = await reviewVisual(deps, { question: a.question, answer: a.answer, evidence: distilled, viz });
  }
  if (!viz || review.status === 'rejected') return { viz: null, audit: 'rejected', stats: stats(review.status, redesigns) };
  return { viz, audit: review.status, stats: stats(review.status, redesigns) };
}

// ---------------------------------------------------------------------------
// Request parsing
// ---------------------------------------------------------------------------

const clip = (value: unknown, max: number) => (typeof value === 'string' ? value.trim().slice(0, max) : '');

/** A route the app got from an earlier route-only call; only known kinds and types are trusted. */
export function sanitizeRoute(route: any): VisualRoute | null {
  if (!isObject(route) || typeof route.kind !== 'string' || !(route.kind in VISUAL_KINDS)) return null;
  const types = Array.isArray(route.types)
    ? [...new Set<string>(route.types.filter((t: unknown): t is string => typeof t === 'string' && t in ALL_TYPES))].slice(0, 4)
    : [];
  return types.length ? { kind: route.kind, types } : null;
}

export function parseVisualRequest(payload: any) {
  if (!isObject(payload)) return null;
  const answer = clip(payload.answer, MAX_ANSWER);
  if (answer.length < MIN_ANSWER) return null;
  return {
    question: clip(payload.question, MAX_QUESTION),
    answer,
    evidence: clip(payload.evidence, MAX_EVIDENCE),
    routeOnly: payload.route_only === true,
    route: sanitizeRoute(payload.route),
  };
}
