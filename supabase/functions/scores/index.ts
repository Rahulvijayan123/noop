// Owner/device score reads, registration and sleep edits authenticate with the installation credential (or the
// signed-in account's Supabase session); the owner always comes from the credential, never from the request.
import { createSupabaseRest, restConfigFromEnv } from '../_shared/rest.ts';
import { pushConfig } from '../_shared/config.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';

const cfg = pushConfig();
const rest = createSupabaseRest({ cfg: restConfigFromEnv() });

Deno.serve((req: Request) => handleScoresRequest(req, { rest, cfg }));
