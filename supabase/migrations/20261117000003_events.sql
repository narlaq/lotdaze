-- =============================================================================
-- 003_events.sql
-- Events (Lot Days, Ride Outs, Shows, Hang Outs ...), hosted by a rider OR an
-- org. Exact location lives in its own table so it can be hidden until a
-- reveal time. Invites, RSVPs, check-ins, and host updates hang off event.
-- =============================================================================

-- Admin-extensible lookup (not an enum on purpose): the scene invents event kinds.
CREATE TABLE event_type (
    event_type_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code             text NOT NULL UNIQUE,
    name             text NOT NULL,
    is_moving        boolean NOT NULL DEFAULT false,   -- ride outs: start point + route, not one spot
    sort_order       smallint NOT NULL DEFAULT 100
);
INSERT INTO event_type (code, name, is_moving, sort_order) VALUES
    ('LOT_DAY',   'Lot Day',         false, 10),
    ('RIDE_OUT',  'Ride Out',        true,  20),
    ('SHOW',      'Show',            false, 30),
    ('HANG_OUT',  'Hang Out',        false, 40),
    ('BIKE_NIGHT','Bike Night',      false, 50),
    ('TRACK_DAY', 'Track Day',       false, 60),
    ('WRENCH',    'Wrench Session',  false, 70),
    ('CHARITY',   'Charity Ride',    true,  80);

-- -----------------------------------------------------------------------------
-- Spots: saved places a rider or org reuses ("the usual lot"). Private to the
-- owner — sharing a spot happens only by attaching it to an event.
-- -----------------------------------------------------------------------------
CREATE TABLE spot (
    spot_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_rider_id   uuid REFERENCES rider ON DELETE CASCADE,
    owner_org_id     uuid REFERENCES org   ON DELETE CASCADE,
    name             text NOT NULL,
    spot_kind        text NOT NULL DEFAULT 'lot'
                     CHECK (spot_kind IN ('lot', 'shop', 'track', 'venue', 'meet_point', 'other')),
    address          text,
    latitude         numeric(9,6) CHECK (latitude  BETWEEN -90  AND 90),
    longitude        numeric(9,6) CHECK (longitude BETWEEN -180 AND 180),
    notes            text,                        -- 'owner OK'd Sundays, stay off the grass'
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(owner_rider_id, owner_org_id) = 1)
);
CREATE TRIGGER tr_spot_touch BEFORE UPDATE ON spot
    FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();

-- -----------------------------------------------------------------------------
-- Event
-- -----------------------------------------------------------------------------
CREATE TABLE event (
    event_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type_id    smallint NOT NULL REFERENCES event_type,
    host_rider_id    uuid REFERENCES rider,       -- exactly one of these two
    host_org_id      uuid REFERENCES org,
    title            text NOT NULL CHECK (length(title) BETWEEN 3 AND 120),
    description      text CHECK (length(description) <= 4000),
    house_rules      text,                        -- 'respect the lot, no street stunts on the way out'
    general_area     text NOT NULL,               -- always visible: 'Portage, MI'
    starts_at        timestamptz NOT NULL,
    ends_at          timestamptz,
    visibility       event_visibility NOT NULL DEFAULT 'friends',
    location_reveal_at timestamptz,               -- NULL = exact spot visible to anyone who can see the event
    location_requires_rsvp boolean NOT NULL DEFAULT false,  -- true = only riders who RSVP'd going/maybe get the spot
    status           event_status NOT NULL DEFAULT 'scheduled',
    capacity         smallint CHECK (capacity > 0),
    rsvp_closes_at   timestamptz,
    cover_url        text,
    created_by       uuid NOT NULL REFERENCES rider,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(host_rider_id, host_org_id) = 1),
    CHECK (ends_at IS NULL OR ends_at > starts_at),
    CHECK (location_reveal_at IS NULL OR location_reveal_at <= starts_at),
    -- 'org' visibility only makes sense when an org is hosting
    CHECK (visibility <> 'org' OR host_org_id IS NOT NULL)
);
CREATE INDEX ix_event_starts     ON event (starts_at);
CREATE INDEX ix_event_host_rider ON event (host_rider_id) WHERE host_rider_id IS NOT NULL;
CREATE INDEX ix_event_host_org   ON event (host_org_id)   WHERE host_org_id   IS NOT NULL;
CREATE TRIGGER tr_event_touch BEFORE UPDATE ON event
    FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER tr_event_audit AFTER INSERT OR UPDATE OR DELETE ON event
    FOR EACH ROW EXECUTE FUNCTION fn_audit_row('event_id');

-- Exact location, 1:1 with event. Separate table = separate access rule
-- (see fn_can_see_location in 004). For ride outs this is the meet-up point.
CREATE TABLE event_location (
    event_id         uuid PRIMARY KEY REFERENCES event ON DELETE CASCADE,
    spot_id          uuid REFERENCES spot ON DELETE SET NULL,
    place_name       text NOT NULL,
    address          text,
    latitude         numeric(9,6) CHECK (latitude  BETWEEN -90  AND 90),
    longitude        numeric(9,6) CHECK (longitude BETWEEN -180 AND 180),
    meet_notes       text,                        -- 'back corner by the loading docks'
    route_url        text,                        -- ride outs: link to a route
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER tr_event_location_touch BEFORE UPDATE ON event_location
    FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER tr_event_location_audit AFTER INSERT OR UPDATE OR DELETE ON event_location
    FOR EACH ROW EXECUTE FUNCTION fn_audit_row('event_id');

-- Invites: to a single rider, or to a whole org (= every active member).
CREATE TABLE event_invite (
    event_invite_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id         uuid NOT NULL REFERENCES event ON DELETE CASCADE,
    invited_rider_id uuid REFERENCES rider ON DELETE CASCADE,
    invited_org_id   uuid REFERENCES org   ON DELETE CASCADE,
    invited_by       uuid NOT NULL REFERENCES rider,
    status           invite_status NOT NULL DEFAULT 'sent',
    created_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(invited_rider_id, invited_org_id) = 1)
);
CREATE UNIQUE INDEX ux_event_invite_rider ON event_invite (event_id, invited_rider_id) WHERE invited_rider_id IS NOT NULL;
CREATE UNIQUE INDEX ux_event_invite_org   ON event_invite (event_id, invited_org_id)   WHERE invited_org_id   IS NOT NULL;
CREATE INDEX ix_event_invite_rider ON event_invite (invited_rider_id) WHERE invited_rider_id IS NOT NULL;

-- RSVP: one current answer per rider per event; history via the audit trigger.
CREATE TABLE event_rsvp (
    event_rsvp_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id         uuid NOT NULL REFERENCES event ON DELETE CASCADE,
    rider_id         uuid NOT NULL REFERENCES rider ON DELETE CASCADE,
    response         rsvp_response NOT NULL,
    bike_id          uuid REFERENCES bike ON DELETE SET NULL,  -- 'bringing the 636'
    plus_ones        smallint NOT NULL DEFAULT 0 CHECK (plus_ones BETWEEN 0 AND 10),
    note             text CHECK (length(note) <= 280),
    responded_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, rider_id)
);
CREATE INDEX ix_event_rsvp_rider ON event_rsvp (rider_id);
CREATE TRIGGER tr_event_rsvp_audit AFTER INSERT OR UPDATE OR DELETE ON event_rsvp
    FOR EACH ROW EXECUTE FUNCTION fn_audit_row('event_rsvp_id');

-- Who actually showed up.
CREATE TABLE event_checkin (
    event_id         uuid NOT NULL REFERENCES event ON DELETE CASCADE,
    rider_id         uuid NOT NULL REFERENCES rider ON DELETE CASCADE,
    checked_in_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, rider_id)
);

-- Host posts: 'lot changed', 'running 30 late', 'rain — moving to Sunday'.
-- Subscribe to this table with Supabase Realtime for live updates.
CREATE TABLE event_update (
    event_update_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id         uuid NOT NULL REFERENCES event ON DELETE CASCADE,
    posted_by        uuid NOT NULL REFERENCES rider,
    update_kind      text NOT NULL DEFAULT 'info'
                     CHECK (update_kind IN ('info', 'time_change', 'location_change', 'canceled', 'heads_up')),
    body             text NOT NULL CHECK (length(body) BETWEEN 1 AND 1000),
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_event_update_event ON event_update (event_id, created_at DESC);
