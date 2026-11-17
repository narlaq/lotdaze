-- =============================================================================
-- 005_views_functions.sql
-- Workflow functions (the API surface for writes with rules attached) and
-- read views for the main screens.
--
-- Every function works out WHO is calling from the login token (fn_me()) —
-- the client never passes "act as rider X", so it can't lie about it.
-- All are SECURITY DEFINER with a pinned search_path.
-- =============================================================================

-- Small guard used by every workflow function.
CREATE OR REPLACE FUNCTION fn_require_me()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v uuid := fn_me();
BEGIN
    IF v IS NULL THEN
        RAISE EXCEPTION 'No active rider profile for this login' USING ERRCODE = '42501';
    END IF;
    RETURN v;
END $$;

-- =============================================================================
-- PROFILE
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_create_profile(
    p_handle       text,
    p_display_name text DEFAULT NULL,
    p_home_area    text DEFAULT NULL
) RETURNS rider
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r rider;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Not signed in' USING ERRCODE = '42501';
    END IF;
    INSERT INTO rider (auth_subject, handle, display_name, home_area)
    VALUES (auth.uid(), p_handle, p_display_name, p_home_area)
    RETURNING * INTO r;
    RETURN r;
END $$;

-- =============================================================================
-- CONNECTIONS
-- =============================================================================

-- Send a request. If they already asked you, this accepts it.
CREATE OR REPLACE FUNCTION fn_request_connection(p_other uuid)
RETURNS connection
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me  uuid := fn_require_me();
    lo  uuid := LEAST(me, p_other);
    hi  uuid := GREATEST(me, p_other);
    c   connection;
BEGIN
    IF p_other = me THEN RAISE EXCEPTION 'Cannot connect with yourself'; END IF;
    IF NOT EXISTS (SELECT 1 FROM rider WHERE rider_id = p_other AND status = 'active') THEN
        RAISE EXCEPTION 'Rider not found';
    END IF;

    SELECT * INTO c FROM connection WHERE rider_low_id = lo AND rider_high_id = hi FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO connection (rider_low_id, rider_high_id, requested_by)
        VALUES (lo, hi, me) RETURNING * INTO c;
    ELSIF c.status = 'blocked' THEN
        RAISE EXCEPTION 'Rider not found';          -- don't reveal the block
    ELSIF c.status = 'pending' AND c.requested_by <> me THEN
        UPDATE connection SET status = 'accepted', responded_at = now()
        WHERE rider_low_id = lo AND rider_high_id = hi RETURNING * INTO c;
    ELSIF c.status = 'declined' THEN
        UPDATE connection SET status = 'pending', requested_by = me, requested_at = now(), responded_at = NULL
        WHERE rider_low_id = lo AND rider_high_id = hi RETURNING * INTO c;
    END IF;                                          -- pending-by-me / accepted: no-op
    RETURN c;
END $$;

CREATE OR REPLACE FUNCTION fn_respond_connection(p_other uuid, p_accept boolean)
RETURNS connection
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me uuid := fn_require_me();
    c  connection;
BEGIN
    UPDATE connection
    SET status = CASE WHEN p_accept THEN 'accepted'::connection_status ELSE 'declined' END,
        responded_at = now()
    WHERE rider_low_id = LEAST(me, p_other) AND rider_high_id = GREATEST(me, p_other)
      AND status = 'pending' AND requested_by = p_other
    RETURNING * INTO c;
    IF NOT FOUND THEN RAISE EXCEPTION 'No pending request from that rider'; END IF;
    RETURN c;
END $$;

-- Unfriend / cancel a request. Does nothing to blocks.
CREATE OR REPLACE FUNCTION fn_remove_connection(p_other uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE me uuid := fn_require_me();
BEGIN
    DELETE FROM connection
    WHERE rider_low_id = LEAST(me, p_other) AND rider_high_id = GREATEST(me, p_other)
      AND status <> 'blocked';
END $$;

CREATE OR REPLACE FUNCTION fn_block_rider(p_other uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE me uuid := fn_require_me();
BEGIN
    IF p_other = me THEN RAISE EXCEPTION 'Cannot block yourself'; END IF;
    INSERT INTO connection (rider_low_id, rider_high_id, status, requested_by, blocked_by, responded_at)
    VALUES (LEAST(me, p_other), GREATEST(me, p_other), 'blocked', me, me, now())
    ON CONFLICT (rider_low_id, rider_high_id) DO UPDATE
        SET status = 'blocked', blocked_by = me, responded_at = now()
        WHERE connection.status <> 'blocked';        -- first blocker keeps ownership
END $$;

CREATE OR REPLACE FUNCTION fn_unblock_rider(p_other uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE me uuid := fn_require_me();
BEGIN
    DELETE FROM connection
    WHERE rider_low_id = LEAST(me, p_other) AND rider_high_id = GREATEST(me, p_other)
      AND status = 'blocked' AND blocked_by = me;
END $$;

-- =============================================================================
-- ORGS
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_create_org(
    p_name          text,
    p_slug          text,
    p_org_type      text DEFAULT 'crew',
    p_join_policy   join_policy DEFAULT 'request',
    p_parent_org_id uuid DEFAULT NULL,
    p_home_area     text DEFAULT NULL
) RETURNS org
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me uuid := fn_require_me();
    o  org;
BEGIN
    -- Only the parent's owners/admins can hang a crew under it.
    IF p_parent_org_id IS NOT NULL AND NOT fn_is_org_admin(p_parent_org_id, me) THEN
        RAISE EXCEPTION 'Only admins of the parent org can add a crew under it' USING ERRCODE = '42501';
    END IF;
    INSERT INTO org (name, slug, org_type, join_policy, parent_org_id, home_area, created_by)
    VALUES (p_name, p_slug, p_org_type, p_join_policy, p_parent_org_id, p_home_area, me)
    RETURNING * INTO o;
    INSERT INTO org_member (org_id, rider_id, role, status, joined_at)
    VALUES (o.org_id, me, 'owner', 'active', now());
    RETURN o;
END $$;

-- Join (open), ask to join (request), or accept a pending invite.
CREATE OR REPLACE FUNCTION fn_join_org(p_org uuid)
RETURNS org_member
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me  uuid := fn_require_me();
    o   org;
    m   org_member;
BEGIN
    SELECT * INTO o FROM org WHERE org_id = p_org AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'Org not found'; END IF;

    SELECT * INTO m FROM org_member WHERE org_id = p_org AND rider_id = me FOR UPDATE;
    IF FOUND THEN
        IF m.status = 'banned' THEN RAISE EXCEPTION 'Org not found'; END IF;
        IF m.status IN ('active', 'requested') THEN RETURN m; END IF;
        IF m.status = 'invited' THEN
            UPDATE org_member SET status = 'active', joined_at = now()
            WHERE org_member_id = m.org_member_id RETURNING * INTO m;
            RETURN m;
        END IF;
        -- left / removed: fall through and re-apply under current policy
    END IF;

    IF o.join_policy = 'invite_only' THEN
        RAISE EXCEPTION 'This org is invite only';
    END IF;

    INSERT INTO org_member (org_id, rider_id, role, status, joined_at)
    VALUES (p_org, me, 'member',
            CASE WHEN o.join_policy = 'open' THEN 'active'::member_status ELSE 'requested' END,
            CASE WHEN o.join_policy = 'open' THEN now() END)
    ON CONFLICT (org_id, rider_id) DO UPDATE
        SET status = EXCLUDED.status, role = 'member', joined_at = EXCLUDED.joined_at
    RETURNING * INTO m;
    RETURN m;
END $$;

-- Admin invites a rider. If the rider had already asked to join, this approves them.
CREATE OR REPLACE FUNCTION fn_invite_to_org(p_org uuid, p_rider uuid)
RETURNS org_member
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me uuid := fn_require_me();
    m  org_member;
BEGIN
    IF NOT fn_is_org_admin(p_org, me) THEN
        RAISE EXCEPTION 'Only org admins can invite' USING ERRCODE = '42501';
    END IF;
    IF fn_is_blocked(me, p_rider) THEN RAISE EXCEPTION 'Rider not found'; END IF;

    INSERT INTO org_member (org_id, rider_id, status, invited_by)
    VALUES (p_org, p_rider, 'invited', me)
    ON CONFLICT (org_id, rider_id) DO UPDATE
        SET status = CASE WHEN org_member.status = 'requested' THEN 'active'::member_status
                          WHEN org_member.status IN ('left', 'removed') THEN 'invited'
                          ELSE org_member.status END,      -- active/banned/invited unchanged
            joined_at = CASE WHEN org_member.status = 'requested' THEN now() ELSE org_member.joined_at END,
            invited_by = me
    RETURNING * INTO m;
    RETURN m;
END $$;

-- Admin approves or denies a join request.
CREATE OR REPLACE FUNCTION fn_review_join_request(p_org uuid, p_rider uuid, p_approve boolean)
RETURNS org_member
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me uuid := fn_require_me();
    m  org_member;
BEGIN
    IF NOT fn_is_org_admin(p_org, me) THEN
        RAISE EXCEPTION 'Only org admins can review requests' USING ERRCODE = '42501';
    END IF;
    IF p_approve THEN
        UPDATE org_member SET status = 'active', joined_at = now()
        WHERE org_id = p_org AND rider_id = p_rider AND status = 'requested'
        RETURNING * INTO m;
    ELSE
        DELETE FROM org_member
        WHERE org_id = p_org AND rider_id = p_rider AND status = 'requested'
        RETURNING * INTO m;
    END IF;
    IF m.org_member_id IS NULL THEN RAISE EXCEPTION 'No pending request from that rider'; END IF;
    RETURN m;
END $$;

-- Owner sets roles. Setting someone to 'owner' hands ownership over.
CREATE OR REPLACE FUNCTION fn_set_member_role(p_org uuid, p_rider uuid, p_role org_role)
RETURNS org_member
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me uuid := fn_require_me();
    m  org_member;
BEGIN
    IF fn_org_role(p_org, me) IS DISTINCT FROM 'owner' THEN
        RAISE EXCEPTION 'Only the owner can change roles' USING ERRCODE = '42501';
    END IF;
    IF p_rider = me THEN RAISE EXCEPTION 'Hand ownership to someone else instead'; END IF;
    IF p_role = 'owner' THEN
        UPDATE org_member SET role = 'admin' WHERE org_id = p_org AND rider_id = me;
    END IF;
    UPDATE org_member SET role = p_role
    WHERE org_id = p_org AND rider_id = p_rider AND status = 'active'
    RETURNING * INTO m;
    IF NOT FOUND THEN RAISE EXCEPTION 'That rider is not an active member'; END IF;
    RETURN m;
END $$;

CREATE OR REPLACE FUNCTION fn_leave_org(p_org uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE me uuid := fn_require_me();
BEGIN
    IF fn_org_role(p_org, me) = 'owner' THEN
        RAISE EXCEPTION 'Hand ownership to another member before leaving';
    END IF;
    UPDATE org_member SET status = 'left', role = 'member'
    WHERE org_id = p_org AND rider_id = me AND status IN ('active', 'invited', 'requested');
END $$;

-- Admin removes (or bans) a member. Admins can't remove the owner or other admins;
-- the owner can remove anyone.
CREATE OR REPLACE FUNCTION fn_remove_member(p_org uuid, p_rider uuid, p_ban boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me      uuid := fn_require_me();
    my_role org_role := fn_org_role(p_org, me);
    target  org_role := fn_org_role(p_org, p_rider);
BEGIN
    IF my_role IS NULL OR my_role = 'member' THEN
        RAISE EXCEPTION 'Only org admins can remove members' USING ERRCODE = '42501';
    END IF;
    IF target = 'owner' OR (target = 'admin' AND my_role <> 'owner') THEN
        RAISE EXCEPTION 'Not allowed to remove that member' USING ERRCODE = '42501';
    END IF;
    UPDATE org_member
    SET status = CASE WHEN p_ban THEN 'banned'::member_status ELSE 'removed' END,
        role = 'member'
    WHERE org_id = p_org AND rider_id = p_rider;
END $$;

-- =============================================================================
-- EVENTS
-- =============================================================================

-- Create an event and (optionally) its exact location in one call.
-- Org-hosted events require owner/admin of that org. The host is auto-RSVP'd 'going'.
CREATE OR REPLACE FUNCTION fn_create_event(
    p_event_type_code   text,
    p_title             text,
    p_starts_at         timestamptz,
    p_general_area      text,
    p_visibility        event_visibility DEFAULT 'friends',
    p_host_org_id       uuid DEFAULT NULL,
    p_ends_at           timestamptz DEFAULT NULL,
    p_description       text DEFAULT NULL,
    p_house_rules       text DEFAULT NULL,
    p_location_reveal_at timestamptz DEFAULT NULL,
    p_location_requires_rsvp boolean DEFAULT false,
    p_capacity          smallint DEFAULT NULL,
    p_rsvp_closes_at    timestamptz DEFAULT NULL,
    p_place_name        text DEFAULT NULL,
    p_address           text DEFAULT NULL,
    p_latitude          numeric DEFAULT NULL,
    p_longitude         numeric DEFAULT NULL,
    p_meet_notes        text DEFAULT NULL,
    p_route_url         text DEFAULT NULL,
    p_spot_id           uuid DEFAULT NULL,
    p_publish           boolean DEFAULT true      -- false = save as draft
) RETURNS event
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me    uuid := fn_require_me();
    v_type smallint;
    s     spot;
    e     event;
BEGIN
    SELECT event_type_id INTO v_type FROM event_type WHERE code = p_event_type_code;
    IF v_type IS NULL THEN RAISE EXCEPTION 'Unknown event type %', p_event_type_code; END IF;

    IF p_host_org_id IS NOT NULL AND NOT fn_is_org_admin(p_host_org_id, me) THEN
        RAISE EXCEPTION 'Only org admins can host events for the org' USING ERRCODE = '42501';
    END IF;
    IF p_starts_at < now() - interval '1 hour' THEN
        RAISE EXCEPTION 'Start time is in the past';
    END IF;

    -- Using a saved spot? It has to be one you control.
    IF p_spot_id IS NOT NULL THEN
        SELECT * INTO s FROM spot WHERE spot_id = p_spot_id;
        IF NOT FOUND OR NOT (s.owner_rider_id = me
                             OR (s.owner_org_id IS NOT NULL AND fn_is_org_admin(s.owner_org_id, me))) THEN
            RAISE EXCEPTION 'Spot not found';
        END IF;
    END IF;

    INSERT INTO event (event_type_id, host_rider_id, host_org_id, title, description, house_rules,
                       general_area, starts_at, ends_at, visibility, location_reveal_at,
                       location_requires_rsvp, status, capacity, rsvp_closes_at, created_by)
    VALUES (v_type,
            CASE WHEN p_host_org_id IS NULL THEN me END, p_host_org_id,
            p_title, p_description, p_house_rules, p_general_area, p_starts_at, p_ends_at,
            p_visibility, p_location_reveal_at, p_location_requires_rsvp,
            CASE WHEN p_publish THEN 'scheduled'::event_status ELSE 'draft' END,
            p_capacity, p_rsvp_closes_at, me)
    RETURNING * INTO e;

    IF p_spot_id IS NOT NULL OR p_place_name IS NOT NULL THEN
        INSERT INTO event_location (event_id, spot_id, place_name, address, latitude, longitude,
                                    meet_notes, route_url)
        VALUES (e.event_id, p_spot_id,
                COALESCE(p_place_name, s.name),
                COALESCE(p_address, s.address),
                COALESCE(p_latitude, s.latitude),
                COALESCE(p_longitude, s.longitude),
                COALESCE(p_meet_notes, s.notes),
                p_route_url);
    END IF;

    INSERT INTO event_rsvp (event_id, rider_id, response) VALUES (e.event_id, me, 'going');
    RETURN e;
END $$;

-- Invite a rider or a whole org. Hosts can always invite; on non-invite-only
-- events, anyone who's going can bring people in too.
CREATE OR REPLACE FUNCTION fn_invite_to_event(p_event uuid, p_rider uuid DEFAULT NULL, p_org uuid DEFAULT NULL)
RETURNS event_invite
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me uuid := fn_require_me();
    e  event;
    i  event_invite;
BEGIN
    IF num_nonnulls(p_rider, p_org) <> 1 THEN
        RAISE EXCEPTION 'Invite exactly one rider or one org';
    END IF;
    SELECT * INTO e FROM event WHERE event_id = p_event;
    IF NOT FOUND OR NOT fn_can_see_event(p_event, me) THEN RAISE EXCEPTION 'Event not found'; END IF;

    IF NOT fn_can_manage_event(p_event, me) AND NOT (
           e.visibility <> 'invite_only'
       AND EXISTS (SELECT 1 FROM event_rsvp WHERE event_id = p_event AND rider_id = me AND response = 'going')) THEN
        RAISE EXCEPTION 'Not allowed to invite to this event' USING ERRCODE = '42501';
    END IF;
    IF p_rider IS NOT NULL AND fn_is_blocked(me, p_rider) THEN RAISE EXCEPTION 'Rider not found'; END IF;
    -- Only an org's own admins can invite the whole org.
    IF p_org IS NOT NULL AND NOT fn_is_org_admin(p_org, me) THEN
        RAISE EXCEPTION 'Only that org''s admins can invite the whole org' USING ERRCODE = '42501';
    END IF;

    IF p_rider IS NOT NULL THEN
        INSERT INTO event_invite (event_id, invited_rider_id, invited_by)
        VALUES (p_event, p_rider, me)
        ON CONFLICT (event_id, invited_rider_id) WHERE invited_rider_id IS NOT NULL
        DO UPDATE SET status = 'sent', invited_by = me
            WHERE event_invite.status = 'revoked'
        RETURNING * INTO i;
    ELSE
        INSERT INTO event_invite (event_id, invited_org_id, invited_by)
        VALUES (p_event, p_org, me)
        ON CONFLICT (event_id, invited_org_id) WHERE invited_org_id IS NOT NULL
        DO UPDATE SET status = 'sent', invited_by = me
            WHERE event_invite.status = 'revoked'
        RETURNING * INTO i;
    END IF;
    RETURN i;
END $$;

-- RSVP with capacity + waitlist. When a 'going' frees up, the oldest waitlisted
-- rider is promoted automatically.
CREATE OR REPLACE FUNCTION fn_submit_rsvp(
    p_event     uuid,
    p_response  rsvp_response,
    p_bike_id   uuid DEFAULT NULL,
    p_plus_ones smallint DEFAULT 0,
    p_note      text DEFAULT NULL
) RETURNS event_rsvp
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me      uuid := fn_require_me();
    e       event;
    v_taken integer;
    r       event_rsvp;
BEGIN
    IF p_response = 'waitlist' THEN
        RAISE EXCEPTION 'Waitlist is assigned automatically — RSVP going instead';
    END IF;
    SELECT * INTO e FROM event WHERE event_id = p_event FOR UPDATE;   -- serialize capacity math
    IF NOT FOUND OR NOT fn_can_see_event(p_event, me) THEN RAISE EXCEPTION 'Event not found'; END IF;
    IF e.status NOT IN ('scheduled', 'live') THEN
        RAISE EXCEPTION 'RSVPs are closed: event is %', e.status;
    END IF;
    IF e.rsvp_closes_at IS NOT NULL AND now() > e.rsvp_closes_at THEN
        RAISE EXCEPTION 'RSVPs are closed';
    END IF;
    IF p_bike_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM bike WHERE bike_id = p_bike_id AND rider_id = me) THEN
        RAISE EXCEPTION 'That bike is not in your garage';
    END IF;

    IF p_response = 'going' AND e.capacity IS NOT NULL THEN
        SELECT COALESCE(sum(1 + plus_ones), 0) INTO v_taken
        FROM event_rsvp WHERE event_id = p_event AND response = 'going' AND rider_id <> me;
        IF v_taken + 1 + COALESCE(p_plus_ones, 0) > e.capacity THEN
            p_response := 'waitlist';
        END IF;
    END IF;

    INSERT INTO event_rsvp (event_id, rider_id, response, bike_id, plus_ones, note)
    VALUES (p_event, me, p_response, p_bike_id, COALESCE(p_plus_ones, 0), p_note)
    ON CONFLICT (event_id, rider_id) DO UPDATE
        SET response = EXCLUDED.response, bike_id = EXCLUDED.bike_id,
            plus_ones = EXCLUDED.plus_ones, note = EXCLUDED.note, responded_at = now()
    RETURNING * INTO r;

    -- Close out a personal invite, if there was one.
    UPDATE event_invite
    SET status = CASE WHEN p_response = 'not_going' THEN 'declined'::invite_status ELSE 'accepted' END
    WHERE event_id = p_event AND invited_rider_id = me AND status = 'sent';

    -- Spot opened up? Promote waitlisted riders, oldest first, while they fit.
    IF p_response <> 'going' AND e.capacity IS NOT NULL THEN
        PERFORM fn_promote_waitlist(p_event);
    END IF;
    RETURN r;
END $$;

-- Internal: move waitlisted riders to 'going' while capacity allows.
CREATE OR REPLACE FUNCTION fn_promote_waitlist(p_event uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_cap   smallint;
    v_taken integer;
    w       event_rsvp;
BEGIN
    SELECT capacity INTO v_cap FROM event WHERE event_id = p_event;
    IF v_cap IS NULL THEN RETURN; END IF;
    FOR w IN SELECT * FROM event_rsvp
             WHERE event_id = p_event AND response = 'waitlist'
             ORDER BY responded_at LOOP
        SELECT COALESCE(sum(1 + plus_ones), 0) INTO v_taken
        FROM event_rsvp WHERE event_id = p_event AND response = 'going';
        EXIT WHEN v_taken + 1 + w.plus_ones > v_cap;
        UPDATE event_rsvp SET response = 'going' WHERE event_rsvp_id = w.event_rsvp_id;
    END LOOP;
END $$;
REVOKE EXECUTE ON FUNCTION fn_promote_waitlist(uuid) FROM PUBLIC;

-- Check in at the event. Opens 2 hours before start, closes 12 hours after.
CREATE OR REPLACE FUNCTION fn_check_in(p_event uuid)
RETURNS event_checkin
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me uuid := fn_require_me();
    e  event;
    c  event_checkin;
BEGIN
    SELECT * INTO e FROM event WHERE event_id = p_event;
    IF NOT FOUND OR NOT fn_can_see_event(p_event, me) THEN RAISE EXCEPTION 'Event not found'; END IF;
    IF e.status NOT IN ('scheduled', 'live') THEN RAISE EXCEPTION 'Event is %', e.status; END IF;
    IF now() < e.starts_at - interval '2 hours'
       OR now() > COALESCE(e.ends_at, e.starts_at) + interval '12 hours' THEN
        RAISE EXCEPTION 'Check-in is not open right now';
    END IF;
    INSERT INTO event_checkin (event_id, rider_id) VALUES (p_event, me)
    ON CONFLICT DO NOTHING;
    SELECT * INTO c FROM event_checkin WHERE event_id = p_event AND rider_id = me;
    RETURN c;
END $$;

-- Host posts an update. A 'canceled' update also cancels the event.
CREATE OR REPLACE FUNCTION fn_post_event_update(p_event uuid, p_body text, p_kind text DEFAULT 'info')
RETURNS event_update
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    me uuid := fn_require_me();
    u  event_update;
BEGIN
    IF NOT fn_can_manage_event(p_event, me) THEN
        RAISE EXCEPTION 'Only hosts can post updates' USING ERRCODE = '42501';
    END IF;
    INSERT INTO event_update (event_id, posted_by, update_kind, body)
    VALUES (p_event, me, p_kind, p_body) RETURNING * INTO u;
    IF p_kind = 'canceled' THEN
        UPDATE event SET status = 'canceled' WHERE event_id = p_event;
    END IF;
    RETURN u;
END $$;

-- =============================================================================
-- VIEWS — security_invoker so the caller's RLS applies (hidden locations stay
-- hidden, blocked riders stay out of counts).
-- =============================================================================

-- My people: accepted friends, plus requests waiting on me and ones I sent.
CREATE VIEW vw_my_connections WITH (security_invoker = true) AS
SELECT
    other.rider_id,
    other.handle,
    other.display_name,
    other.avatar_url,
    other.home_area,
    c.status,
    CASE
        WHEN c.status = 'pending' AND c.requested_by = fn_me() THEN 'outgoing'
        WHEN c.status = 'pending'                               THEN 'incoming'
        ELSE c.status::text
    END AS relation,
    c.requested_at,
    c.responded_at
FROM connection c
JOIN rider other
  ON other.rider_id = CASE WHEN c.rider_low_id = fn_me() THEN c.rider_high_id ELSE c.rider_low_id END
WHERE c.status IN ('pending', 'accepted')
   OR (c.status = 'blocked' AND c.blocked_by = fn_me());   -- you see who YOU blocked, not who blocked you

CREATE VIEW vw_my_orgs WITH (security_invoker = true) AS
SELECT
    o.org_id, o.name, o.slug, o.org_type, o.avatar_url, o.home_area, o.parent_org_id,
    p.name AS parent_org_name,
    m.role, m.status AS membership_status, m.title, m.joined_at,
    (SELECT count(*) FROM org_member am WHERE am.org_id = o.org_id AND am.status = 'active') AS member_count
FROM org_member m
JOIN org o      ON o.org_id = m.org_id
LEFT JOIN org p ON p.org_id = o.parent_org_id
WHERE m.rider_id = fn_me() AND m.status IN ('active', 'invited', 'requested');

-- One row per event with headcounts. Location columns come back NULL when the
-- caller isn't allowed to see the spot yet.
CREATE VIEW vw_event_card WITH (security_invoker = true) AS
SELECT
    e.event_id,
    et.code               AS event_type_code,
    et.name               AS event_type,
    e.title,
    e.description,
    e.house_rules,
    e.general_area,
    e.starts_at,
    e.ends_at,
    e.status,
    e.visibility,
    e.capacity,
    e.cover_url,
    e.host_rider_id,
    hr.handle             AS host_handle,
    e.host_org_id,
    ho.name               AS host_org_name,
    e.location_reveal_at,
    (loc.event_id IS NOT NULL) AS location_visible,
    loc.place_name,
    loc.address,
    loc.latitude,
    loc.longitude,
    loc.meet_notes,
    loc.route_url,
    COALESCE(cnt.going, 0)    AS going_count,
    COALESCE(cnt.maybe, 0)    AS maybe_count,
    COALESCE(cnt.waitlist, 0) AS waitlist_count,
    mine.response             AS my_response,
    fn_can_manage_event(e.event_id, fn_me()) AS i_can_manage
FROM event e
JOIN event_type et     ON et.event_type_id = e.event_type_id
LEFT JOIN rider hr     ON hr.rider_id = e.host_rider_id
LEFT JOIN org ho       ON ho.org_id = e.host_org_id
LEFT JOIN event_location loc ON loc.event_id = e.event_id
LEFT JOIN LATERAL (
    SELECT sum(1 + plus_ones) FILTER (WHERE response = 'going') AS going,
           count(*)           FILTER (WHERE response = 'maybe') AS maybe,
           count(*)           FILTER (WHERE response = 'waitlist') AS waitlist
    FROM event_rsvp r WHERE r.event_id = e.event_id
) cnt ON true
LEFT JOIN event_rsvp mine ON mine.event_id = e.event_id AND mine.rider_id = fn_me();

-- The home feed: everything upcoming I'm allowed to see, soonest first.
CREATE VIEW vw_upcoming_events WITH (security_invoker = true) AS
SELECT * FROM vw_event_card
WHERE status IN ('scheduled', 'live', 'postponed')
  AND COALESCE(ends_at, starts_at + interval '12 hours') > now()
ORDER BY starts_at;

-- Who's coming, with their bike.
CREATE VIEW vw_event_attendees WITH (security_invoker = true) AS
SELECT
    r.event_id,
    r.rider_id,
    rd.handle,
    rd.display_name,
    rd.avatar_url,
    r.response,
    r.plus_ones,
    r.note,
    b.make || ' ' || b.model AS bike,
    (ci.rider_id IS NOT NULL) AS checked_in,
    r.responded_at
FROM event_rsvp r
JOIN rider rd          ON rd.rider_id = r.rider_id
LEFT JOIN bike b       ON b.bike_id = r.bike_id
LEFT JOIN event_checkin ci ON ci.event_id = r.event_id AND ci.rider_id = r.rider_id;

-- Host dashboard: RSVP'd vs actually showed, per event (for the past events tab).
CREATE VIEW vw_event_turnout WITH (security_invoker = true) AS
SELECT
    e.event_id,
    e.title,
    e.starts_at,
    (SELECT count(*) FROM event_rsvp r
      WHERE r.event_id = e.event_id AND r.response = 'going')                        AS said_going,
    (SELECT count(*) FROM event_checkin ci WHERE ci.event_id = e.event_id)           AS checked_in,
    (SELECT count(*) FROM event_checkin ci
      WHERE ci.event_id = e.event_id
        AND NOT EXISTS (SELECT 1 FROM event_rsvp r WHERE r.event_id = ci.event_id
                          AND r.rider_id = ci.rider_id AND r.response = 'going'))    AS walk_ins,
    (SELECT count(*) FROM event_rsvp r
      WHERE r.event_id = e.event_id AND r.response = 'going'
        AND NOT EXISTS (SELECT 1 FROM event_checkin ci WHERE ci.event_id = r.event_id
                          AND ci.rider_id = r.rider_id))                             AS no_shows
FROM event e
WHERE fn_can_manage_event(e.event_id, fn_me());

-- Public-safe rider profile with garage + styles rolled up.
CREATE VIEW vw_rider_profile WITH (security_invoker = true) AS
SELECT
    rd.rider_id, rd.handle, rd.display_name, rd.bio, rd.avatar_url, rd.home_area, rd.instagram,
    (SELECT array_agg(s.name ORDER BY s.name)
       FROM rider_riding_style rs JOIN riding_style s USING (riding_style_id)
      WHERE rs.rider_id = rd.rider_id) AS riding_styles,
    (SELECT jsonb_agg(jsonb_build_object('bike_id', b.bike_id, 'make', b.make, 'model', b.model,
                                         'year', b.model_year, 'nickname', b.nickname,
                                         'photo_url', b.photo_url, 'is_primary', b.is_primary)
                      ORDER BY b.is_primary DESC, b.created_at)
       FROM bike b WHERE b.rider_id = rd.rider_id) AS garage,
    fn_are_friends(rd.rider_id, fn_me()) AS is_friend
FROM rider rd
WHERE rd.status = 'active';
