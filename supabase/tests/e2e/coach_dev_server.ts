// A local `coach` function for running the iOS app's Sana chat (threads, memory, context) in the Simulator
// without a hosted project (docs/COACH_MEMORY.md §7.1 "DEBUG seam").
//
//   deno run -A --no-lock supabase/tests/e2e/coach_dev_server.ts [--seed]
//
// It starts the disposable native PostgreSQL + PostgREST of supabase/functions/tests/local_postgres.ts with the
// coach migrations, provisions one Supabase-Auth installation and a fresh `noop_dev_chatmem_<hex>` bearer for a
// fixed owner, and serves the unmodified coach handler on 127.0.0.1:54460 at /functions/v1/coach. Model calls
// go to Fireworks when FIREWORKS_AI_API_KEY is set (only that key and the COACH_* settings are read), otherwise
// to the scripted stand-in the end-to-end test uses. `--seed` adds two invented chats through the same routes.
// It prints the SIMCTL_CHILD_* variables for `xcrun simctl launch`, and runs until interrupted; everything it
// created is thrown away on exit (the database files stay under EDGE_TEST_ARTIFACTS for inspection).
//
// Developer machines only: it binds to loopback, and the database is synthetic.
import { startLocalPostgres } from '../../functions/tests/local_postgres.ts';
import { coachConfig } from '../../functions/_shared/coach.ts';
import { coachClient, seedInstallation, serveCoach, startScriptedUpstream } from '../../functions/tests/coach_e2e_support.ts';

const OWNER = '00000000-0000-4000-8000-00000000c0ac';
const PORT = Number(Deno.env.get('NARA_COACH_DEV_PORT') ?? '54460');
const seed = Deno.args.includes('--seed');

// A short artifact directory keeps the PostgreSQL socket path under macOS's 103-byte limit.
if (!Deno.env.get('EDGE_TEST_ARTIFACTS')) Deno.env.set('EDGE_TEST_ARTIFACTS', await Deno.makeTempDir({ dir: '/tmp', prefix: 'ccd' }));

const key = (Deno.env.get('FIREWORKS_AI_API_KEY') ?? '').trim();
const scripted = key ? null : startScriptedUpstream();
const env: Record<string, string> = scripted
  ? { FIREWORKS_AI_API_KEY: 'scripted-dev-key', COACH_UPSTREAM_URL: scripted.url }
  : { FIREWORKS_AI_API_KEY: key };
for (const name of ['COACH_MODEL_CHAT', 'COACH_MODEL_VISION', 'COACH_MODEL_UTILITY', 'COACH_UTILITY_REASONING', 'COACH_UTILITY_API_KEY',
  'COACH_DAILY_CALL_LIMIT', 'COACH_DAILY_UTILITY_LIMIT']) {
  const v = Deno.env.get(name);
  if (v !== undefined) env[name] = v;
}
const cfg = coachConfig(env);

const db = await startLocalPostgres({ authProvisioning: true, coachMemory: true });
let server: ReturnType<typeof serveCoach> | null = null;
let closing = false;
async function shutdown(code = 0) {
  if (closing) return;
  closing = true;
  try {
    await server?.close();
    await scripted?.close();
    await db.close();
  } finally {
    Deno.exit(code);
  }
}
Deno.addSignalListener('SIGINT', () => void shutdown());
Deno.addSignalListener('SIGTERM', () => void shutdown());

try {
  const hex = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, '0')).join('');
  const token = `noop_dev_chatmem_${hex}`;
  await db.sql(`insert into auth.users(id) values ('${OWNER}') on conflict do nothing;`);
  await seedInstallation(db.sql, OWNER, token);
  server = serveCoach(db.rest, cfg, { port: PORT, onError: (err) => console.error('coach handler error:', err) });

  if (seed) {
    const api = coachClient(server.url, token);
    const day = 86_400_000;
    const chats = [
      { at: Date.now() - 3 * day, title: "I'm training for the Valencia marathon", turns: [
        ["I'm training for the Valencia marathon on 2026-12-06 and I have a recurring left Achilles tendon injury. How should I build my long runs?",
          'Keep long runs flat for now and build by about 10% a week to 30 km, with an easy day after each one. Stop the run if the Achilles pain passes 3/10.'],
        ["I'll report back after Sunday's 24 km run.", 'Good. Note how the Achilles feels the next morning; that tells us more than the run itself.'],
      ] },
      { at: Date.now() - day, title: "I'm vegetarian and don't eat", turns: [
        ["I'm vegetarian and don't eat eggs. What should I eat after long runs?",
          'Aim for 20 to 30 g of protein with carbs within an hour: tofu or tempeh with rice, lentil pasta, or a soy milk smoothie with oats and banana.'],
      ] },
    ];
    for (const chat of chats) {
      const threadId = crypto.randomUUID();
      let at = chat.at;
      for (const [i, [q, a]] of chat.turns.entries()) {
        const rows = [
          { clientId: crypto.randomUUID(), threadId, role: 'user', content: q, meta: {}, createdAt: new Date(at).toISOString(), ...(i === 0 ? { threadTitle: chat.title } : {}) },
          { clientId: crypto.randomUUID(), threadId, role: 'assistant', content: a, meta: {}, createdAt: new Date(at + 60_000).toISOString() },
        ];
        const saved = await api.post('messages', { messages: rows });
        if (saved.status !== 200) throw new Error(`seeding failed: ${saved.status}`);
        if (i === 0) await api.post('followups', { threadId, question: q, answer: a, asked: [q], wantTitle: true });
        at += 10 * 60_000;
      }
      const maintained = await api.post(`threads/${threadId}/maintain`, {});
      console.log(`seeded chat ${threadId}: maintain ${JSON.stringify(maintained.body)}`);
    }
  }

  console.log(`\nSana coach dev server on ${server.url} (${scripted ? 'scripted model' : `Fireworks, chat ${cfg.models.chat}, utility ${cfg.models.utility}`})`);
  console.log('Launch the Debug app in the Simulator with:\n');
  console.log(`  export SIMCTL_CHILD_NARA_COACH_URL=${server.url}`);
  console.log(`  export SIMCTL_CHILD_NARA_COACH_TOKEN=${token}`);
  console.log(`  export SIMCTL_CHILD_NARA_COACH_OWNER=${OWNER}`);
  console.log('  xcrun simctl launch booted <bundle id>\n');
  console.log('Ctrl-C stops the server and the database.');
} catch (err) {
  console.error('coach dev server failed to start:', err instanceof Error ? err.message : err);
  await shutdown(1);
}
