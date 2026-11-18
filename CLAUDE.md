# LotDaze — working notes for Claude

Meet-up coordination app for stunt riders and bike life (lot days, ride outs, shows, hang outs).
"LotDaze" is a placeholder name. Owner: Lucas (narlaq). Sister project: narlaq/Rec-d-It — same
architecture and conventions; borrow from it freely (e.g. its messaging design for event chat).

## Ground rules
- **SQL-first.** Postgres on Supabase. Business rules live in the database (RLS + `fn_*` functions);
  the front end is a thin client. Lucas works mainly in SQL — explain front-end pieces plainly.
- **Schema changes = new migration file** in `supabase/migrations/` (timestamp-prefixed, never edit
  one that has been deployed). Never change the schema directly in the Supabase dashboard.
- **Deploys go through GitHub Actions** (`.github/workflows/database.yml`): tests on every push/PR,
  `supabase db push --remote` from main after tests pass.
- **Every new rule gets an assertion** in `supabase/tests/scenario_test.sql` (`pg_temp.expect`).
- Keep all project context in this repo (this file + README) so any Claude session can pick it up.

## Conventions (match Rec'd It)
- UUID PKs; `fn_touch_updated_at` + `fn_audit_row('<pk>')` triggers on consequential tables.
- Enums for system states; lookup tables (`event_type`, `riding_style`) for vocabulary users extend.
- Workflow functions: `SECURITY DEFINER SET search_path = public`, caller resolved with
  `fn_require_me()` from `auth.uid()` — never accept "act as rider X" from the client.
- RLS on every table, policies `TO authenticated` only. Policy helpers are SECURITY DEFINER to avoid
  policy recursion (org ↔ org_member recursed once — use `fn_member_status` / `fn_org_is_listed`).
- Views use `security_invoker = true` so the caller's RLS applies.

## Privacy is a core feature, not a nice-to-have
Street stunting is illegal in most places; broadcasting meet locations draws attention.
Defaults: events `friends` visibility; exact spot in `event_location` with its own rule
(reveal time, optional RSVP-required); blocks hide everything both ways; profiles store handles and
city-level area only — no legal names, emails, phones, addresses. Keep it that way.

## Running tests locally
```bash
psql -v ON_ERROR_STOP=1 -f supabase/tests/ci_bootstrap.sql     # fresh, empty database
for f in supabase/migrations/*.sql; do psql -v ON_ERROR_STOP=1 -f "$f"; done
psql -v ON_ERROR_STOP=1 -f supabase/tests/scenario_test.sql    # ends with ALL SCENARIO CHECKS PASSED
```

## Status (2026-11-17)
- Done: schema 001–005 (riders, bikes, connections, orgs, events, locations, invites, RSVP/waitlist,
  check-ins, host updates, RLS, workflow functions, views); scenario test (27 checks); CI + deploy.
- Next: Supabase project + scoped token (see README "Turning on deploys") + repo secrets → first deploy; notifications; event chat; report/moderation
  queue before any public beta; PWA front end (same plan as Rec'd It).
- Name candidates: PullUp (favorite), Kickstand, RollCall, Twelve O'Clock, Clutch, Rev'd Up,
  Wheelie Down?, LotDaze. Availability (App Store, domains, trademark) not yet checked.
