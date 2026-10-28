# Who Is the Impostor?

A real-time, guest-only social deduction game for 4–8 players. The React client talks only to the `game` Supabase Edge Function for game actions. PostgreSQL owns room membership, private roles, clues, votes, deadlines, phase transitions, and score settlement. Room row changes are published through Supabase Realtime; clients also poll the authenticated state endpoint so reconnects recover current state.

## Architecture

```mermaid
flowchart LR
  A[React + TypeScript / Vite] -->|anonymous Supabase JWT| B[game Edge Function]
  A <-->|safe room row change events| C[Supabase Realtime]
  B -->|service role, after JWT validation| D[(PostgreSQL RPC)]
  C --> D
  D --> E[Public room and roster]
  D --> F[Private roles, clues, votes]
  G[pg_cron deadline worker] --> D
  H[Vercel HTTPS hosting] --> A
```

The browser receives only its own current-round role/word. Public room rows have no role or word fields. Direct table access is revoked from browser roles; RLS permits an authenticated room member to receive safe room row events only. Votes and role assignments are kept in separate RLS-protected tables. The Edge Function validates the Supabase guest JWT before invoking a `service_role`-only RPC. Round settlement is protected by a unique `(room_id, round)` result key and runs inside the same locked database transaction as score updates.

## Local setup

1. Create a Supabase project. Anonymous Sign-Ins are enabled in `supabase/config.toml`.
2. Install dependencies with `npm install`.
3. Copy `.env.example` to `.env.local` and set the project URL and anon key. These are public client values; never put a service-role key in a `VITE_*` variable.
4. Install the Supabase CLI and link the project: `supabase login`, then `supabase link --project-ref YOUR_REF`.
5. Apply project Auth settings, schema, and the function: `supabase config push`, `supabase db push`, then `supabase functions deploy game`.
6. Start the frontend with `npm run dev`.

The Supabase database migration enables `pg_cron` and schedules server phase processing every second. One-second schedules require Postgres 15.1.1.61 or later on Supabase. A state request also processes any deadline that has elapsed, so an active room catches up immediately on reconnect. On a project that does not support sub-minute cron intervals, enable `pg_cron` in Database > Extensions and change the schedule statement to `* * * * *` as a reduced-precision fallback.

## Implementation plan

1. Create isolated room, member, private-role, clue, vote, and round-result tables with RLS and service-only action RPC.
2. Implement locked server actions for room membership, phase progression, result settlement, and scheduled deadline processing.
3. Build the responsive guest lobby and round screens, with Realtime updates plus persisted guest-session recovery.
4. Verify scoring and phase rules with Vitest, then exercise the responsive landing and lobby with Playwright before deployment.

## Commands

- `npm run dev` — local Vite server
- `npm run build` — TypeScript check and production bundle
- `npm test` — Vitest rule tests
- `npm run test:e2e` — Playwright browser checks (install a browser with `npx playwright install chromium` first)

## Deploy to Vercel

Import this repository into Vercel, select the Vite preset, and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in the project environment. Deploy the frontend with `vercel --prod`. Then deploy the Auth config, migration, and Edge Function to the linked Supabase project as above. Confirm that the Vercel URL loads over HTTPS and test room creation/joining from separate guest browser contexts.

## Verification and rollout status

- `npm test`: 7 unit tests passed.
- `npm run build`: TypeScript check and Vite production build passed.
- `npm run test:e2e`: 2 Playwright checks passed for the responsive landing page and lobby preview.
- A production database integration check exercised eight-player capacity, private role views, duplicate clue/vote rejection, self-vote rejection, deadline advancement, scoring idempotency, and a complete three-round match. The temporary test room and rate-limit rows were removed by the check.
- Supabase project `zbejlzoavvuskyrlykte` has both migrations applied, the `game` Edge Function active with JWT verification, and the one-second deadline worker scheduled. The security advisor no longer reports an exposed `SECURITY DEFINER` helper; the remaining RLS notices are intentional because direct access to private game tables is revoked.
- The hosted project still has Anonymous Sign-Ins disabled. `supabase/config.toml` enables it; apply that setting with `supabase config push` after linking and logging into the project. The Vercel project has its public Supabase environment variables configured, but no Vercel deployment URL is available until guest sign-in is enabled and the frontend is deployed.

## Rules and phase durations

Each match has three rounds. The host starts each round, and the server runs each phase through its deadline (clues and votes can finish early after everyone submits). The default role reveal, clue, discussion, voting, and results durations are 15, 60, 60, 30, and 15 seconds. Every round selects one impostor and a related word pair; detectives share the other word. Each player submits one clue and one private vote, with no self-votes. A tie produces no accusation and counts as impostor survival. Correct detective votes earn 2 points; an impostor who survives gains 2, and a correct impostor word guess gains 1. Guest sessions persist in the browser for reconnecting. Host transfer occurs on a subsequent member request after the host has been inactive for 30 seconds.
