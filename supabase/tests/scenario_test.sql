-- =============================================================================
-- Scenario test: 4 riders, run against a fresh database after all migrations.
-- Simulates each login by setting the JWT subject the way Supabase does.
-- Every check is an assertion: any wrong result stops the run with an error.
--
-- Local / CI:  psql -v ON_ERROR_STOP=1 -f supabase/tests/ci_bootstrap.sql
--              (apply supabase/migrations/*.sql in order)
--              psql -v ON_ERROR_STOP=1 -f supabase/tests/scenario_test.sql
-- =============================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
\set A '''aaaaaaaa-0000-0000-0000-000000000001'''
\set B '''bbbbbbbb-0000-0000-0000-000000000002'''
\set C '''cccccccc-0000-0000-0000-000000000003'''
\set D '''dddddddd-0000-0000-0000-000000000004'''

CREATE FUNCTION pg_temp.expect(label text, actual anyelement, expected anyelement)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'FAIL: % (got %, expected %)', label, actual, expected;
    END IF;
    RAISE NOTICE 'pass: %', label;
END $$;
CREATE FUNCTION pg_temp.as_rider(p_sub text) RETURNS void LANGUAGE sql AS
$$ SELECT set_config('request.jwt.claim.sub', p_sub, false) $$;

SET client_min_messages = notice;
SET ROLE authenticated;

SELECT pg_temp.as_rider(:A); SELECT FROM fn_create_profile('ace_wheelies',  'Ace',  'Kalamazoo, MI');
SELECT pg_temp.as_rider(:B); SELECT FROM fn_create_profile('bree636',       'Bree', 'Portage, MI');
SELECT pg_temp.as_rider(:C); SELECT FROM fn_create_profile('cole.12oclock', 'Cole', 'Battle Creek, MI');
SELECT pg_temp.as_rider(:D); SELECT FROM fn_create_profile('dre_stoppies',  'Dre',  'Kalamazoo, MI');
CREATE TEMP TABLE ids AS SELECT handle::text, rider_id FROM rider;

-- 1. Friend request + accept --------------------------------------------------
SELECT pg_temp.as_rider(:A);
SELECT pg_temp.expect('request starts pending',
    (fn_request_connection((SELECT rider_id FROM ids WHERE handle = 'bree636'))).status, 'pending'::connection_status);
SELECT pg_temp.as_rider(:B);
SELECT pg_temp.expect('Bree sees incoming request',
    (SELECT relation FROM vw_my_connections WHERE handle = 'ace_wheelies'), 'incoming');
SELECT pg_temp.expect('Bree accepts',
    (fn_respond_connection((SELECT rider_id FROM ids WHERE handle = 'ace_wheelies'), true)).status, 'accepted'::connection_status);

-- 2. Friends-only lot day, spot revealed the day before ----------------------
SELECT pg_temp.as_rider(:A);
INSERT INTO bike (rider_id, make, model, model_year, is_primary) VALUES (fn_me(), 'Kawasaki', 'ZX-6R', 2009, true);
SELECT FROM fn_create_event('LOT_DAY', 'Sunday Lot Day', now() + interval '5 days', 'Portage, MI',
    p_visibility => 'friends', p_location_reveal_at => now() + interval '4 days',
    p_place_name => 'Old Kmart lot', p_meet_notes => 'back by the docks');
SELECT pg_temp.expect('host always sees the spot',
    (SELECT place_name FROM vw_upcoming_events WHERE title = 'Sunday Lot Day'), 'Old Kmart lot');
SELECT pg_temp.expect('host auto-RSVPd going',
    (SELECT going_count FROM vw_upcoming_events WHERE title = 'Sunday Lot Day'), 1::bigint);

-- 3. Friend sees event but not spot; stranger sees nothing -------------------
SELECT pg_temp.as_rider(:B);
SELECT pg_temp.expect('friend sees the event',
    (SELECT count(*) FROM vw_upcoming_events WHERE title = 'Sunday Lot Day'), 1::bigint);
SELECT pg_temp.expect('friend cannot see spot before reveal',
    (SELECT location_visible FROM vw_upcoming_events WHERE title = 'Sunday Lot Day'), false);
SELECT pg_temp.as_rider(:C);
SELECT pg_temp.expect('stranger sees no friends-only event',
    (SELECT count(*) FROM vw_upcoming_events), 0::bigint);

-- 4. Crew with join-by-request ----------------------------------------------
SELECT pg_temp.as_rider(:A);
SELECT FROM fn_create_org('Kzoo Stunt Crew', 'kzoo-stunt', 'crew', 'request');
SELECT pg_temp.as_rider(:C);
SELECT pg_temp.expect('join request is pending',
    (fn_join_org((SELECT org_id FROM org WHERE slug = 'kzoo-stunt'))).status, 'requested'::member_status);
SELECT pg_temp.as_rider(:A);
SELECT pg_temp.expect('admin approves',
    (fn_review_join_request((SELECT org_id FROM org WHERE slug = 'kzoo-stunt'),
                            (SELECT rider_id FROM ids WHERE handle = 'cole.12oclock'), true)).status,
    'active'::member_status);

-- 5. Crew-only ride out, cap 2, spot only after RSVP --------------------------
SELECT FROM fn_create_event('RIDE_OUT', 'Crew Ride Out', now() + interval '3 days', 'Kalamazoo, MI',
    p_visibility => 'org', p_host_org_id => (SELECT org_id FROM org WHERE slug = 'kzoo-stunt'),
    p_capacity => 2::smallint, p_location_requires_rsvp => true, p_place_name => 'Shop on Westnedge');
SELECT pg_temp.as_rider(:C);
SELECT pg_temp.expect('member sees crew event, spot hidden until RSVP',
    (SELECT location_visible FROM vw_upcoming_events WHERE title = 'Crew Ride Out'), false);
SELECT FROM fn_submit_rsvp((SELECT event_id FROM event WHERE title = 'Crew Ride Out'), 'going');
SELECT pg_temp.expect('spot shows after RSVP',
    (SELECT place_name FROM vw_upcoming_events WHERE title = 'Crew Ride Out'), 'Shop on Westnedge');
SELECT pg_temp.as_rider(:D);
SELECT pg_temp.expect('non-member cannot see crew event',
    (SELECT count(*) FROM vw_upcoming_events WHERE title = 'Crew Ride Out'), 0::bigint);

-- 6. Capacity + waitlist + auto-promotion ------------------------------------
SELECT pg_temp.as_rider(:A);
SELECT FROM fn_invite_to_event((SELECT event_id FROM event WHERE title = 'Crew Ride Out'),
                               (SELECT rider_id FROM ids WHERE handle = 'bree636'));
SELECT pg_temp.as_rider(:B);
SELECT pg_temp.expect('invitee over capacity goes to waitlist',
    (fn_submit_rsvp((SELECT event_id FROM event WHERE title = 'Crew Ride Out'), 'going')).response,
    'waitlist'::rsvp_response);
SELECT pg_temp.as_rider(:C);
SELECT FROM fn_submit_rsvp((SELECT event_id FROM event WHERE title = 'Crew Ride Out'), 'not_going');
SELECT pg_temp.as_rider(:A);
SELECT pg_temp.expect('waitlisted rider promoted when a spot opens',
    (SELECT response FROM vw_event_attendees
      WHERE handle = 'bree636' AND event_id = (SELECT event_id FROM event WHERE title = 'Crew Ride Out')),
    'going'::rsvp_response);

-- 7. Blocking hides everything both ways -------------------------------------
SELECT FROM fn_create_event('SHOW', 'Fall Bike Show', now() + interval '10 days', 'Kalamazoo, MI',
    p_visibility => 'public');
SELECT pg_temp.as_rider(:D);
SELECT pg_temp.expect('public event visible',
    (SELECT count(*) FROM vw_upcoming_events WHERE title = 'Fall Bike Show'), 1::bigint);
SELECT fn_block_rider((SELECT rider_id FROM ids WHERE handle = 'ace_wheelies'));
SELECT pg_temp.expect('blocker no longer sees host''s public event',
    (SELECT count(*) FROM vw_upcoming_events WHERE title = 'Fall Bike Show'), 0::bigint);
SELECT pg_temp.expect('blocker cannot see blocked profile',
    (SELECT count(*) FROM vw_rider_profile WHERE handle = 'ace_wheelies'), 0::bigint);
SELECT pg_temp.as_rider(:A);
SELECT pg_temp.expect('blocked rider cannot see blocker profile',
    (SELECT count(*) FROM vw_rider_profile WHERE handle = 'dre_stoppies'), 0::bigint);
DO $$ BEGIN
    PERFORM fn_request_connection((SELECT rider_id FROM ids WHERE handle = 'dre_stoppies'));
    RAISE EXCEPTION 'FAIL: blocked rider could send a friend request';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'pass: blocked rider cannot send a friend request';
END $$;

-- 8. Things that must be refused ---------------------------------------------
SELECT pg_temp.as_rider(:C);
DO $$ BEGIN
    BEGIN
        INSERT INTO event_rsvp (event_id, rider_id, response)
        SELECT event_id, fn_me(), 'going' FROM event LIMIT 1;
        RAISE EXCEPTION 'FAIL: direct RSVP insert allowed';
    EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'pass: direct RSVP insert blocked'; END;
    BEGIN
        UPDATE rider SET status = 'suspended' WHERE rider_id = fn_me();
        RAISE EXCEPTION 'FAIL: rider changed own status';
    EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'pass: rider cannot change own status'; END;
    BEGIN
        PERFORM fn_post_event_update((SELECT event_id FROM event WHERE title = 'Crew Ride Out'), 'hijack');
        RAISE EXCEPTION 'FAIL: non-host posted an update';
    EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'pass: non-host cannot post updates'; END;
END $$;
SELECT pg_temp.expect('audit log hidden from clients', (SELECT count(*) FROM audit_log), 0::bigint);
SELECT fn_leave_org((SELECT org_id FROM org WHERE slug = 'kzoo-stunt'));
SELECT pg_temp.as_rider(:A);
DO $$ BEGIN
    PERFORM fn_leave_org((SELECT org_id FROM org WHERE slug = 'kzoo-stunt'));
    RAISE EXCEPTION 'FAIL: owner left without handing off';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'pass: owner must hand off before leaving';
END $$;

-- 9. Cancel via host update --------------------------------------------------
SELECT FROM fn_post_event_update((SELECT event_id FROM event WHERE title = 'Sunday Lot Day'),
                                 'Rain all day, calling it', 'canceled');
SELECT pg_temp.expect('canceled update cancels the event',
    (SELECT status FROM event WHERE title = 'Sunday Lot Day'), 'canceled'::event_status);

-- 10. Turnout view ------------------------------------------------------------
SELECT pg_temp.expect('turnout counts going riders as no-shows before check-in',
    (SELECT no_shows FROM vw_event_turnout WHERE title = 'Crew Ride Out'), 2::bigint);

RESET ROLE;
\echo 'ALL SCENARIO CHECKS PASSED'
