# LotDaze *(working name)*

*Meet-up coordination for stunt riders and bike life — lot days, ride outs, shows, hang outs.*

Built the same way as Rec'd It: Postgres-first on Supabase, the data model built up from the rider,
business rules living in the database, and the app as a thin client on top.

## Data model

```
rider ─┬─ bike (the garage)
       ├─ rider_riding_style ── riding_style (lookup)
       ├─ connection (friends: pending / accepted / declined / blocked — one row per pair)
       ├─ org_member ── org (crew / club / org / shop / promoter; parent_org_id = crews under orgs)
       ├─ event_rsvp ─────┐
       ├─ event_checkin ──┼── event ── event_type (Lot Day │ Ride Out │ Show │ Hang Out │ …)
       ├─ event_invite ───┤     ├── host: a rider OR an org (exactly one)
       └─ spot (saved)    │     ├── event_location (exact spot — separate access rule)
                          └─────└── event_update (host posts; Realtime feed)
```

1. **`rider` is the atom.** Handles, not legal names. No emails, phones, or addresses stored on the
   profile — `home_area` is city-level. Login lives in Supabase Auth and links via `auth_subject`.
2. **Friends without a group.** `connection` stores each pair once (lower id first), so A→B and B→A
   can't both exist. Blocking is a status on the same row and overrides everything else.
3. **Orgs at every size.** One self-referencing `org` table handles a 5-person crew, a club, or a
   regional org with crews under it. A trigger blocks hierarchy loops. Join policy is `open`,
   `request`, or `invite_only`. Exactly one owner per org (enforced by a unique index).
4. **Events have one host** — a rider or an org — and a visibility: `public`, `friends`, `org`,
   or `invite_only`. Invites go to a rider or a whole org.
5. **The spot is protected separately.** `event_location` has its own access rule: the event can be
   visible while the exact spot stays hidden until `location_reveal_at`, and optionally only to riders
   who RSVP'd (`location_requires_rsvp`). Canceled/postponed events hide the spot.
6. **RSVP with capacity + waitlist.** Plus-ones count against capacity. When someone drops, the oldest
   waitlisted rider is promoted automatically.
7. **Monitoring** is views: `vw_upcoming_events` (home feed), `vw_event_card`, `vw_event_attendees`,
   `vw_event_turnout` (said going vs. showed up), `vw_my_connections`, `vw_my_orgs`, `vw_rider_profile`.

## Security stance

The database is the security boundary. Every table has RLS on; `anon` sees nothing.
Writes that carry rules (friend requests, joins, invites, RSVPs, check-ins, host updates) go only
through `fn_*` functions, and those functions work out the caller from the login token — the app never
says "act as rider X." Blocks hide events, profiles, garages, and attendee rows in both directions.

## Files

| File | Contents |
|---|---|
| `supabase/migrations/…01_foundation_riders.sql` | Enums, audit log, rider, bike, riding styles, connections |
| `supabase/migrations/…02_crews_orgs.sql` | Orgs (with hierarchy) and membership |
| `supabase/migrations/…03_events.sql` | Event types, saved spots, events, locations, invites, RSVPs, check-ins, updates |
| `supabase/migrations/…04_access_rules.sql` | Visibility helpers + RLS policies on every table |
| `supabase/migrations/…05_views_functions.sql` | Workflow functions (the write API) + read views |
| `supabase/tests/scenario_test.sql` | 4-rider walkthrough, 27 assertions: friends, crew, private events, block, waitlist, must-fail checks |
| `supabase/tests/ci_bootstrap.sql` | Stand-ins for Supabase roles + `auth.uid()` so tests run on plain Postgres |
| `supabase/config.toml` | Supabase CLI project config (from `supabase init`) |
| `.github/workflows/database.yml` | Test every change; deploy from `main` after tests pass |
| `CLAUDE.md` | Working notes so any Claude session can pick the project up |

## Workflow functions (the write API)

| Area | Functions |
|---|---|
| Profile | `fn_create_profile` (then edit your own row directly; `bike`, `rider_riding_style`, `spot` are direct-edit too) |
| Friends | `fn_request_connection`, `fn_respond_connection`, `fn_remove_connection`, `fn_block_rider`, `fn_unblock_rider` |
| Orgs | `fn_create_org`, `fn_join_org`, `fn_invite_to_org`, `fn_review_join_request`, `fn_set_member_role`, `fn_leave_org`, `fn_remove_member` |
| Events | `fn_create_event`, `fn_invite_to_event`, `fn_submit_rsvp`, `fn_check_in`, `fn_post_event_update` |

Call from the client with `supabase.rpc('fn_submit_rsvp', { p_event, p_response: 'going' })`.

## Turning on deploys

The test job runs on every push and PR right away. The deploy job is skipped until you configure it:

1. Create a Supabase project (free tier is fine to start). Note its **project ref** (in the URL / Project Settings) and the **database password**.
2. **Create a scoped personal access token** (this is what lets GitHub Actions log in to Supabase as you):
   1. Go to <https://supabase.com/dashboard/account/tokens> (avatar → Account → **Access Tokens**) → **Generate new token**.
   2. **Name:** `lotdaze-github-deploy` — so you know what it's for when you see it later.
   3. **Expires in:** pick the longest you're comfortable with (max is 1 year). Put a reminder on your
      calendar a week before; when it expires, deploys fail until you swap in a new one.
   4. **Resources:** *selected projects* → only the LotDaze project. Not the whole org.
   5. **Permissions:** start from the **No access** preset (the *Read-only* preset includes secrets),
      then set these to **Read**: **Project Settings**, **API Keys**, **API Key Secrets**.
      That's what `supabase link` needs. The migrations themselves run over the database
      connection using `SUPABASE_DB_PASSWORD`, not through this token.
   6. Check the review screen, generate, and **copy the token right away** (starts with `sbp_`) —
      it's shown once. If you lose it, delete it and make another.
   7. Don't create a *legacy* (full-account) token for this, and never paste the token in a file in the repo.
   - If the deploy job later fails on a permissions error, edit nothing else — generate a new token
     that also has **Database: Read-write** and replace the secret.
3. In this repo: **Settings → Secrets and variables → Actions**
   - *Secrets*: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`
   - *Variables*: `SUPABASE_PROJECT_ID` = the project ref
4. Re-run the **Database** workflow (Actions tab → Run workflow) or push any change under `supabase/`.

## Next up

- Notifications table + triggers (invite received, location revealed, event changed)
- Event chat (reuse Rec'd It's thread/message design)
- Reporting / moderation queue before any public beta
- Front end: PWA first, same plan as Rec'd It
