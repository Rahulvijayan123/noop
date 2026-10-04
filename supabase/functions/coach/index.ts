// In-app coach: authenticated model relay + conversation/memory store (installation credential).
import { createSupabaseRest, restConfigFromEnv } from '../_shared/rest.ts';
import { coachConfig, handleCoachRequest } from '../_shared/coach.ts';

const cfg = coachConfig();
const rest = createSupabaseRest({ cfg: restConfigFromEnv() });

Deno.serve((req: Request) => handleCoachRequest(req, { rest, cfg }));
