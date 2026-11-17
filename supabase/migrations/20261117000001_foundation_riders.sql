-- =============================================================================
-- 001_foundation_riders.sql
-- Extensions, shared enums, audit plumbing, and the rider layer:
-- rider / bike / riding style / connections (friends)
-- Target: PostgreSQL 15+ on Supabase
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;      -- fuzzy handle / name search
CREATE EXTENSION IF NOT EXISTS citext;       -- case-insensitive handles

-- -----------------------------------------------------------------------------
-- Shared enums (system-controlled states only — human vocabulary such as
-- event kinds and riding styles lives in lookup tables)
-- -----------------------------------------------------------------------------
CREATE TYPE record_status     AS ENUM ('active', 'suspended', 'deleted');
CREATE TYPE connection_status AS ENUM ('pending', 'accepted', 'declined', 'blocked');
CREATE TYPE org_role          AS ENUM ('owner', 'admin', 'member');
CREATE TYPE member_status     AS ENUM ('requested', 'invited', 'active', 'left', 'removed', 'banned');
CREATE TYPE join_policy       AS ENUM ('open', 'request', 'invite_only');
CREATE TYPE event_visibility  AS ENUM ('public', 'friends', 'org', 'invite_only');
CREATE TYPE event_status      AS ENUM ('draft', 'scheduled', 'live', 'completed', 'canceled', 'postponed');
CREATE TYPE rsvp_response     AS ENUM ('going', 'maybe', 'not_going', 'waitlist');
CREATE TYPE invite_status     AS ENUM ('sent', 'accepted', 'declined', 'revoked');

-- -----------------------------------------------------------------------------
-- updated_at maintenance
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

-- -----------------------------------------------------------------------------
-- Generic audit log — attach fn_audit_row('<pk column>') to any table
-- -----------------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name      text        NOT NULL,
    row_pk          uuid,
    operation       text        NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    changed_by      uuid,                       -- auth.uid() of the caller, when known
    changed_at      timestamptz NOT NULL DEFAULT now(),
    old_row         jsonb,
    new_row         jsonb
);
CREATE INDEX ix_audit_log_row ON audit_log (table_name, row_pk, changed_at);

CREATE OR REPLACE FUNCTION fn_audit_row()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (table_name, row_pk, operation, changed_by, old_row, new_row)
    VALUES (
        TG_TABLE_NAME,
        COALESCE((to_jsonb(NEW) ->> (TG_ARGV[0]))::uuid, (to_jsonb(OLD) ->> (TG_ARGV[0]))::uuid),
        TG_OP,
        NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid,
        CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END
    );
    RETURN COALESCE(NEW, OLD);
END $$;

-- =============================================================================
-- RIDER LAYER
-- =============================================================================

-- rider is the atom. Everyone in the scene goes by a handle; legal names are
-- optional and never shown publicly (see vw_rider_public in 005).
-- auth_subject = the identity provider's user id (Supabase auth.users.id).
-- Kept as a plain uuid, as in Rec'd It, so the model isn't welded to Supabase.
CREATE TABLE rider (
    rider_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_subject     uuid NOT NULL UNIQUE,
    handle           citext NOT NULL UNIQUE
                     CHECK (handle ~ '^[A-Za-z0-9_.]{3,30}$'),
    display_name     text,
    bio              text CHECK (length(bio) <= 500),
    avatar_url       text,
    home_area        text,                       -- 'Kalamazoo, MI' — city-level only, never an address
    instagram        text,
    is_discoverable  boolean NOT NULL DEFAULT true,   -- show up in rider search
    status           record_status NOT NULL DEFAULT 'active',
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_rider_handle_trgm ON rider USING gin ((handle::text) gin_trgm_ops);

CREATE TRIGGER tr_rider_touch BEFORE UPDATE ON rider
    FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER tr_rider_audit AFTER INSERT OR UPDATE OR DELETE ON rider
    FOR EACH ROW EXECUTE FUNCTION fn_audit_row('rider_id');

-- Riding styles: lookup, not an enum — the scene invents categories.
CREATE TABLE riding_style (
    riding_style_id  smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code             text NOT NULL UNIQUE,
    name             text NOT NULL
);
INSERT INTO riding_style (code, name) VALUES
    ('STUNT',     'Stunt'),
    ('SPORT',     'Sport'),
    ('CRUISER',   'Cruiser'),
    ('TOURING',   'Touring'),
    ('DIRT',      'Dirt / Pit'),
    ('SUPERMOTO', 'Supermoto'),
    ('ATV',       'Quad / ATV'),
    ('TRACK',     'Track Day');

CREATE TABLE rider_riding_style (
    rider_id         uuid NOT NULL REFERENCES rider ON DELETE CASCADE,
    riding_style_id  smallint NOT NULL REFERENCES riding_style,
    PRIMARY KEY (rider_id, riding_style_id)
);

-- The garage. One rider, many bikes; one can be flagged as the main ride.
CREATE TABLE bike (
    bike_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    rider_id         uuid NOT NULL REFERENCES rider ON DELETE CASCADE,
    make             text NOT NULL,
    model            text NOT NULL,
    model_year       smallint CHECK (model_year BETWEEN 1900 AND 2100),
    nickname         text,
    photo_url        text,
    build_notes      text,                       -- 'subcage, 12-bar, rear brake'
    is_primary       boolean NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_bike_rider ON bike (rider_id);
CREATE UNIQUE INDEX ux_bike_one_primary ON bike (rider_id) WHERE is_primary;
CREATE TRIGGER tr_bike_touch BEFORE UPDATE ON bike
    FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();

-- -----------------------------------------------------------------------------
-- Connections (friends). One row per pair, stored low-id / high-id so a pair
-- can never be duplicated in either direction. requested_by says who asked;
-- for 'blocked', blocked_by says who pulled the plug.
-- -----------------------------------------------------------------------------
CREATE TABLE connection (
    rider_low_id     uuid NOT NULL REFERENCES rider ON DELETE CASCADE,
    rider_high_id    uuid NOT NULL REFERENCES rider ON DELETE CASCADE,
    status           connection_status NOT NULL DEFAULT 'pending',
    requested_by     uuid NOT NULL REFERENCES rider,
    blocked_by       uuid REFERENCES rider,
    requested_at     timestamptz NOT NULL DEFAULT now(),
    responded_at     timestamptz,
    PRIMARY KEY (rider_low_id, rider_high_id),
    CHECK (rider_low_id < rider_high_id),
    CHECK (requested_by IN (rider_low_id, rider_high_id)),
    CHECK ((status = 'blocked') = (blocked_by IS NOT NULL)),
    CHECK (blocked_by IS NULL OR blocked_by IN (rider_low_id, rider_high_id))
);
CREATE INDEX ix_connection_high ON connection (rider_high_id);
CREATE TRIGGER tr_connection_audit AFTER INSERT OR UPDATE OR DELETE ON connection
    FOR EACH ROW EXECUTE FUNCTION fn_audit_row('requested_by');
