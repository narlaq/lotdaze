-- =============================================================================
-- 002_crews_orgs.sql
-- Groups at every size: a 5-rider crew, a club, a regional org that crews
-- roll up under. One table, self-referencing, so the hierarchy can be as deep
-- as the scene actually is.
-- =============================================================================

CREATE TABLE org (
    org_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_org_id    uuid REFERENCES org,         -- crew under a bigger org; NULL = top level
    name             text NOT NULL,
    slug             citext NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9-]{3,40}$'),
    org_type         text NOT NULL DEFAULT 'crew'
                     CHECK (org_type IN ('crew', 'club', 'org', 'shop', 'promoter')),
    bio              text CHECK (length(bio) <= 1000),
    avatar_url       text,
    home_area        text,
    instagram        text,
    join_policy      join_policy NOT NULL DEFAULT 'request',
    is_listed        boolean NOT NULL DEFAULT true,   -- false = can't be found in search
    status           record_status NOT NULL DEFAULT 'active',
    created_by       uuid NOT NULL REFERENCES rider,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (parent_org_id IS NULL OR parent_org_id <> org_id)
);
CREATE INDEX ix_org_parent    ON org (parent_org_id) WHERE parent_org_id IS NOT NULL;
CREATE INDEX ix_org_name_trgm ON org USING gin (name gin_trgm_ops);
CREATE TRIGGER tr_org_touch BEFORE UPDATE ON org
    FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER tr_org_audit AFTER INSERT OR UPDATE OR DELETE ON org
    FOR EACH ROW EXECUTE FUNCTION fn_audit_row('org_id');

-- Prevent hierarchy loops (A under B under A).
CREATE OR REPLACE FUNCTION fn_org_no_cycle()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.parent_org_id IS NOT NULL AND EXISTS (
        WITH RECURSIVE up AS (
            SELECT org_id, parent_org_id FROM org WHERE org_id = NEW.parent_org_id
            UNION ALL
            SELECT o.org_id, o.parent_org_id FROM org o JOIN up ON o.org_id = up.parent_org_id
        )
        SELECT 1 FROM up WHERE org_id = NEW.org_id
    ) THEN
        RAISE EXCEPTION 'Org hierarchy cycle: % cannot sit under %', NEW.org_id, NEW.parent_org_id;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER tr_org_no_cycle BEFORE INSERT OR UPDATE OF parent_org_id ON org
    FOR EACH ROW EXECUTE FUNCTION fn_org_no_cycle();

-- Membership. One row per rider per org; status carries the whole lifecycle
-- (requested → active, invited → active, active → left/removed/banned).
CREATE TABLE org_member (
    org_member_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id           uuid NOT NULL REFERENCES org ON DELETE CASCADE,
    rider_id         uuid NOT NULL REFERENCES rider ON DELETE CASCADE,
    role             org_role NOT NULL DEFAULT 'member',
    status           member_status NOT NULL,
    title            text,                        -- 'Road Captain', 'Founder' — flavor, not permissions
    invited_by       uuid REFERENCES rider,
    joined_at        timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (org_id, rider_id)
);
CREATE INDEX ix_org_member_rider ON org_member (rider_id) WHERE status = 'active';
-- Every org keeps exactly one owner.
CREATE UNIQUE INDEX ux_org_one_owner ON org_member (org_id) WHERE role = 'owner' AND status = 'active';
CREATE TRIGGER tr_org_member_touch BEFORE UPDATE ON org_member
    FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER tr_org_member_audit AFTER INSERT OR UPDATE OR DELETE ON org_member
    FOR EACH ROW EXECUTE FUNCTION fn_audit_row('org_member_id');
