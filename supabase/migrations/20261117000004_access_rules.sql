-- =============================================================================
-- 004_access_rules.sql
-- Row-Level Security. The database is the security boundary, not the app:
-- every rule below holds even if a client is buggy or hostile.
--
-- Pattern (same as Rec'd It's security.md):
--   * Helper functions are SECURITY DEFINER + STABLE so policies can call them
--     without recursing into each other's RLS.
--   * Tables whose writes carry business rules (connections, membership,
--     invites, RSVPs, check-ins, host updates) get SELECT policies only;
--     writes go through the fn_* workflow functions in 005.
--   * Only the 'authenticated' role gets policies. 'anon' sees nothing.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- The calling rider (NULL if signed in but no profile yet).
CREATE OR REPLACE FUNCTION fn_me()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT rider_id FROM rider WHERE auth_subject = auth.uid() AND status = 'active'
$$;

-- Either rider has blocked the other.
CREATE OR REPLACE FUNCTION fn_is_blocked(p_a uuid, p_b uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (
        SELECT 1 FROM connection
        WHERE rider_low_id  = LEAST(p_a, p_b)
          AND rider_high_id = GREATEST(p_a, p_b)
          AND status = 'blocked'
    )
$$;

CREATE OR REPLACE FUNCTION fn_are_friends(p_a uuid, p_b uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (
        SELECT 1 FROM connection
        WHERE rider_low_id  = LEAST(p_a, p_b)
          AND rider_high_id = GREATEST(p_a, p_b)
          AND status = 'accepted'
    )
$$;

-- Active role in an org, or NULL.
CREATE OR REPLACE FUNCTION fn_org_role(p_org uuid, p_rider uuid)
RETURNS org_role LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT role FROM org_member
    WHERE org_id = p_org AND rider_id = p_rider AND status = 'active'
$$;

CREATE OR REPLACE FUNCTION fn_is_org_admin(p_org uuid, p_rider uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT COALESCE(fn_org_role(p_org, p_rider) IN ('owner', 'admin'), false)
$$;

-- Membership status of any kind (active / invited / requested / banned ...), or NULL.
CREATE OR REPLACE FUNCTION fn_member_status(p_org uuid, p_rider uuid)
RETURNS member_status LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT status FROM org_member WHERE org_id = p_org AND rider_id = p_rider
$$;

CREATE OR REPLACE FUNCTION fn_org_is_listed(p_org uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT COALESCE((SELECT is_listed FROM org WHERE org_id = p_org), false)
$$;

-- Host rider, creator, or an owner/admin of the hosting org.
CREATE OR REPLACE FUNCTION fn_can_manage_event(p_event uuid, p_rider uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (
        SELECT 1 FROM event e
        WHERE e.event_id = p_event
          AND (e.host_rider_id = p_rider
               OR e.created_by = p_rider
               OR (e.host_org_id IS NOT NULL AND fn_is_org_admin(e.host_org_id, p_rider)))
    )
$$;

-- The core visibility rule. Order matters: blocks and bans beat everything
-- except being the host.
CREATE OR REPLACE FUNCTION fn_can_see_event(p_event uuid, p_rider uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    e event%ROWTYPE;
BEGIN
    IF p_rider IS NULL THEN RETURN false; END IF;
    SELECT * INTO e FROM event WHERE event_id = p_event;
    IF NOT FOUND THEN RETURN false; END IF;

    IF fn_can_manage_event(p_event, p_rider) THEN RETURN true; END IF;
    IF e.status = 'draft' THEN RETURN false; END IF;

    -- Blocked by (or blocking) the host or the creator: invisible.
    IF fn_is_blocked(p_rider, e.created_by)
       OR (e.host_rider_id IS NOT NULL AND fn_is_blocked(p_rider, e.host_rider_id)) THEN
        RETURN false;
    END IF;
    -- Banned from the hosting org: invisible.
    IF e.host_org_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM org_member
        WHERE org_id = e.host_org_id AND rider_id = p_rider AND status = 'banned') THEN
        RETURN false;
    END IF;

    -- Personally invited, or a member of an invited org.
    IF EXISTS (
        SELECT 1 FROM event_invite i
        WHERE i.event_id = p_event AND i.status <> 'revoked'
          AND (i.invited_rider_id = p_rider
               OR (i.invited_org_id IS NOT NULL AND fn_org_role(i.invited_org_id, p_rider) IS NOT NULL))
    ) THEN RETURN true; END IF;

    -- Members of the hosting org always see its events.
    IF e.host_org_id IS NOT NULL AND fn_org_role(e.host_org_id, p_rider) IS NOT NULL THEN
        RETURN true;
    END IF;

    RETURN CASE e.visibility
        WHEN 'public'      THEN true
        WHEN 'friends'     THEN fn_are_friends(p_rider, COALESCE(e.host_rider_id, e.created_by))
        WHEN 'org'         THEN false          -- members already handled above
        WHEN 'invite_only' THEN false          -- invitees already handled above
    END;
END $$;

-- Exact location: must be able to see the event, the reveal time must have
-- passed, and (optionally) the rider must have RSVP'd. Hosts always see it.
CREATE OR REPLACE FUNCTION fn_can_see_location(p_event uuid, p_rider uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    e event%ROWTYPE;
BEGIN
    IF NOT fn_can_see_event(p_event, p_rider) THEN RETURN false; END IF;
    IF fn_can_manage_event(p_event, p_rider) THEN RETURN true; END IF;

    SELECT * INTO e FROM event WHERE event_id = p_event;
    IF e.status IN ('canceled', 'postponed') THEN RETURN false; END IF;
    IF e.location_reveal_at IS NOT NULL AND now() < e.location_reveal_at THEN RETURN false; END IF;
    IF e.location_requires_rsvp AND NOT EXISTS (
        SELECT 1 FROM event_rsvp r
        WHERE r.event_id = p_event AND r.rider_id = p_rider AND r.response IN ('going', 'maybe')
    ) THEN RETURN false; END IF;
    RETURN true;
END $$;

-- -----------------------------------------------------------------------------
-- Enable RLS everywhere
-- -----------------------------------------------------------------------------
ALTER TABLE audit_log          ENABLE ROW LEVEL SECURITY;
ALTER TABLE rider              ENABLE ROW LEVEL SECURITY;
ALTER TABLE riding_style       ENABLE ROW LEVEL SECURITY;
ALTER TABLE rider_riding_style ENABLE ROW LEVEL SECURITY;
ALTER TABLE bike               ENABLE ROW LEVEL SECURITY;
ALTER TABLE connection         ENABLE ROW LEVEL SECURITY;
ALTER TABLE org                ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_member         ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_type         ENABLE ROW LEVEL SECURITY;
ALTER TABLE spot               ENABLE ROW LEVEL SECURITY;
ALTER TABLE event              ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_location     ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_invite       ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_rsvp         ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_checkin      ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_update       ENABLE ROW LEVEL SECURITY;
-- audit_log: no policies at all = no client access. Read it from the dashboard.

-- Lookups: readable by any signed-in user.
CREATE POLICY p_riding_style_read ON riding_style FOR SELECT TO authenticated USING (true);
CREATE POLICY p_event_type_read   ON event_type   FOR SELECT TO authenticated USING (true);

-- -----------------------------------------------------------------------------
-- rider: anyone signed in can see active riders they haven't blocked / been
-- blocked by. Profiles hold handles and city-level area only — no legal
-- names, emails, or phone numbers are stored.
-- -----------------------------------------------------------------------------
CREATE POLICY p_rider_read ON rider FOR SELECT TO authenticated
    USING (auth_subject = auth.uid()
           OR (status = 'active' AND NOT fn_is_blocked(rider_id, fn_me())));
CREATE POLICY p_rider_update_own ON rider FOR UPDATE TO authenticated
    USING (auth_subject = auth.uid()) WITH CHECK (auth_subject = auth.uid());
-- Riders may edit only their profile fields — not auth_subject or status.
REVOKE UPDATE ON rider FROM authenticated;
GRANT  UPDATE (handle, display_name, bio, avatar_url, home_area, instagram, is_discoverable)
    ON rider TO authenticated;

CREATE POLICY p_rider_style_read ON rider_riding_style FOR SELECT TO authenticated
    USING (NOT fn_is_blocked(rider_id, fn_me()));
CREATE POLICY p_rider_style_write ON rider_riding_style FOR ALL TO authenticated
    USING (rider_id = fn_me()) WITH CHECK (rider_id = fn_me());

CREATE POLICY p_bike_read ON bike FOR SELECT TO authenticated
    USING (rider_id = fn_me() OR NOT fn_is_blocked(rider_id, fn_me()));
CREATE POLICY p_bike_write ON bike FOR ALL TO authenticated
    USING (rider_id = fn_me()) WITH CHECK (rider_id = fn_me());

-- -----------------------------------------------------------------------------
-- connection: you see rows you're part of. Writes via fn_* only.
-- (A rider who has been blocked still sees the row exists — the app shows it
-- as "unavailable". blocked_by is hidden from them by vw_my_connections.)
-- -----------------------------------------------------------------------------
CREATE POLICY p_connection_read ON connection FOR SELECT TO authenticated
    USING (fn_me() IN (rider_low_id, rider_high_id));

-- -----------------------------------------------------------------------------
-- org / org_member
-- -----------------------------------------------------------------------------
CREATE POLICY p_org_read ON org FOR SELECT TO authenticated
    USING (status = 'active' AND (
               is_listed
            OR fn_member_status(org_id, fn_me()) IN ('active', 'invited', 'requested')));
CREATE POLICY p_org_update ON org FOR UPDATE TO authenticated
    USING (fn_is_org_admin(org_id, fn_me())) WITH CHECK (fn_is_org_admin(org_id, fn_me()));
REVOKE UPDATE ON org FROM authenticated;
GRANT  UPDATE (name, bio, avatar_url, home_area, instagram, join_policy, is_listed)
    ON org TO authenticated;

-- Your own membership rows always; an org's active roster if you're in it or
-- it's listed; pending requests/invites only for that org's admins.
CREATE POLICY p_org_member_read ON org_member FOR SELECT TO authenticated
    USING (rider_id = fn_me()
        OR fn_is_org_admin(org_id, fn_me())
        OR (status = 'active' AND (
                fn_org_role(org_id, fn_me()) IS NOT NULL
             OR fn_org_is_listed(org_id))));

-- -----------------------------------------------------------------------------
-- spot: private to its owner (rider, or the org's owners/admins).
-- -----------------------------------------------------------------------------
CREATE POLICY p_spot_owner ON spot FOR ALL TO authenticated
    USING      (owner_rider_id = fn_me() OR (owner_org_id IS NOT NULL AND fn_is_org_admin(owner_org_id, fn_me())))
    WITH CHECK (owner_rider_id = fn_me() OR (owner_org_id IS NOT NULL AND fn_is_org_admin(owner_org_id, fn_me())));

-- -----------------------------------------------------------------------------
-- event + children
-- -----------------------------------------------------------------------------
CREATE POLICY p_event_read ON event FOR SELECT TO authenticated
    USING (fn_can_see_event(event_id, fn_me()));
CREATE POLICY p_event_update ON event FOR UPDATE TO authenticated
    USING (fn_can_manage_event(event_id, fn_me()))
    WITH CHECK (fn_can_manage_event(event_id, fn_me()));
-- Hosts can edit details but not who hosts it or who created it.
REVOKE UPDATE ON event FROM authenticated;
GRANT  UPDATE (event_type_id, title, description, house_rules, general_area, starts_at, ends_at,
               visibility, location_reveal_at, location_requires_rsvp, status, capacity,
               rsvp_closes_at, cover_url)
    ON event TO authenticated;
-- No DELETE policy: events are canceled, not erased (attendees need to see that).

CREATE POLICY p_event_location_read ON event_location FOR SELECT TO authenticated
    USING (fn_can_see_location(event_id, fn_me()));
CREATE POLICY p_event_location_insert ON event_location FOR INSERT TO authenticated
    WITH CHECK (fn_can_manage_event(event_id, fn_me()));
CREATE POLICY p_event_location_update ON event_location FOR UPDATE TO authenticated
    USING (fn_can_manage_event(event_id, fn_me()))
    WITH CHECK (fn_can_manage_event(event_id, fn_me()));

CREATE POLICY p_event_invite_read ON event_invite FOR SELECT TO authenticated
    USING (invited_rider_id = fn_me()
        OR fn_can_manage_event(event_id, fn_me())
        OR (invited_org_id IS NOT NULL AND fn_org_role(invited_org_id, fn_me()) IS NOT NULL));

-- If you can see the event, you can see who's coming (minus anyone blocked).
CREATE POLICY p_event_rsvp_read ON event_rsvp FOR SELECT TO authenticated
    USING (fn_can_see_event(event_id, fn_me()) AND NOT fn_is_blocked(rider_id, fn_me()));

CREATE POLICY p_event_checkin_read ON event_checkin FOR SELECT TO authenticated
    USING (fn_can_see_event(event_id, fn_me()) AND NOT fn_is_blocked(rider_id, fn_me()));

CREATE POLICY p_event_update_read ON event_update FOR SELECT TO authenticated
    USING (fn_can_see_event(event_id, fn_me()));
