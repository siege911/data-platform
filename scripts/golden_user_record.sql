-- ============================================================
-- GOLDEN RECORD: Staff Identity Tables
-- Silver layer: stg_staff, staff_source_xref
-- Gold layer:   dim_staff
-- ============================================================

-- ------------------------------------------------------------
-- EXTENSION: uuid generation (if not already enabled)
-- ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- SILVER LAYER
-- ============================================================

-- ------------------------------------------------------------
-- silver.stg_staff
-- The core golden record for internal staff.
-- M365 (Microsoft Graph) is the authoritative spine.
-- ERP enriches specific fields via COALESCE in dbt.
-- ------------------------------------------------------------
CREATE TABLE silver.stg_staff (
    staff_id            UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
    ms_graph_id         VARCHAR(255)    NOT NULL,
    erp_employee_id     VARCHAR(100),

    -- Identity
    email               VARCHAR(320)    NOT NULL,
    first_name          VARCHAR(150),
    last_name           VARCHAR(150),
    display_name        VARCHAR(300),

    -- Organizational
    job_title           VARCHAR(255),
    department          VARCHAR(255),
    manager_staff_id    UUID            REFERENCES silver.stg_staff(staff_id),

    -- Contact
    phone               VARCHAR(50),

    -- Status
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,

    -- Metadata
    _source_updated_at  TIMESTAMP WITH TIME ZONE,
    _loaded_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    _updated_at         TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),

    -- Constraints
    CONSTRAINT uq_stg_staff_email       UNIQUE (email),
    CONSTRAINT uq_stg_staff_ms_graph_id UNIQUE (ms_graph_id)
);

COMMENT ON TABLE  silver.stg_staff IS 'Golden record for internal staff. M365 is the authoritative source; ERP enriches select fields.';
COMMENT ON COLUMN silver.stg_staff.staff_id IS 'Platform-generated surrogate key. Use this as the FK from all other tables.';
COMMENT ON COLUMN silver.stg_staff.ms_graph_id IS 'Microsoft Entra ID object ID from Graph API.';
COMMENT ON COLUMN silver.stg_staff.erp_employee_id IS 'Employee ID from legacy ERP. Nullable — not all staff may exist in ERP.';
COMMENT ON COLUMN silver.stg_staff.email IS 'Primary email from M365. Lowercased and trimmed. Universal match key across SaaS systems.';
COMMENT ON COLUMN silver.stg_staff.manager_staff_id IS 'Self-referencing FK to the staff members manager.';
COMMENT ON COLUMN silver.stg_staff._source_updated_at IS 'Most recent update timestamp from the upstream source system.';
COMMENT ON COLUMN silver.stg_staff._loaded_at IS 'Timestamp when the record was first inserted by dbt.';
COMMENT ON COLUMN silver.stg_staff._updated_at IS 'Timestamp when the record was last updated by dbt.';

CREATE INDEX idx_stg_staff_email      ON silver.stg_staff (lower(email));
CREATE INDEX idx_stg_staff_manager    ON silver.stg_staff (manager_staff_id);
CREATE INDEX idx_stg_staff_is_active  ON silver.stg_staff (is_active);
CREATE INDEX idx_stg_staff_department ON silver.stg_staff (department);

-- ------------------------------------------------------------
-- silver.staff_source_xref
-- Maps each staff member to their native user ID in every
-- connected SaaS system. One row per staff × source system.
-- ------------------------------------------------------------
CREATE TABLE silver.staff_source_xref (
    id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
    staff_id            UUID            NOT NULL REFERENCES silver.stg_staff(staff_id),
    source_system       VARCHAR(100)    NOT NULL,
    source_user_id      VARCHAR(500)    NOT NULL,

    -- Metadata
    _loaded_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    _updated_at         TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),

    -- Constraints
    CONSTRAINT uq_staff_xref_system_user UNIQUE (source_system, source_user_id),
    CONSTRAINT uq_staff_xref_staff_system UNIQUE (staff_id, source_system)
);

COMMENT ON TABLE  silver.staff_source_xref IS 'Cross-reference mapping staff_id to native user IDs in each connected source system.';
COMMENT ON COLUMN silver.staff_source_xref.source_system IS 'Canonical name of the source system (e.g., microsoft_365, hubspot, jira, salesforce, erp_legacy).';
COMMENT ON COLUMN silver.staff_source_xref.source_user_id IS 'The users native ID in the source system.';

CREATE INDEX idx_staff_xref_staff_id ON silver.staff_source_xref (staff_id);
CREATE INDEX idx_staff_xref_system   ON silver.staff_source_xref (source_system);

-- ============================================================
-- GOLD LAYER
-- ============================================================

-- ------------------------------------------------------------
-- gold.dim_staff
-- BI-ready staff dimension. Denormalized with resolved
-- manager name. Queryable without joins for common use cases.
-- ------------------------------------------------------------
CREATE TABLE gold.dim_staff (
    staff_id            UUID            PRIMARY KEY,
    ms_graph_id         VARCHAR(255)    NOT NULL,
    erp_employee_id     VARCHAR(100),

    -- Identity
    email               VARCHAR(320)    NOT NULL,
    first_name          VARCHAR(150),
    last_name           VARCHAR(150),
    display_name        VARCHAR(300),
    full_name           VARCHAR(300),

    -- Organizational
    job_title           VARCHAR(255),
    department          VARCHAR(255),
    manager_staff_id    UUID,
    manager_display_name VARCHAR(300),
    manager_email       VARCHAR(320),

    -- Contact
    phone               VARCHAR(50),

    -- Status
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,

    -- Metadata
    _loaded_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    _updated_at         TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  gold.dim_staff IS 'Denormalized staff dimension for BI consumption. Refreshed by dbt from silver.stg_staff.';
COMMENT ON COLUMN gold.dim_staff.full_name IS 'Derived field: first_name || last_name. Convenience for BI tools.';
COMMENT ON COLUMN gold.dim_staff.manager_display_name IS 'Resolved from manager_staff_id join to stg_staff. Avoids BI-layer self-joins.';
COMMENT ON COLUMN gold.dim_staff.manager_email IS 'Resolved manager email. Useful for filtering and drill-through.';

CREATE INDEX idx_dim_staff_email      ON gold.dim_staff (lower(email));
CREATE INDEX idx_dim_staff_department ON gold.dim_staff (department);
CREATE INDEX idx_dim_staff_is_active  ON gold.dim_staff (is_active);
CREATE INDEX idx_dim_staff_manager    ON gold.dim_staff (manager_staff_id);

-- ------------------------------------------------------------
-- PERMISSIONS: grant bi_readonly access
-- ------------------------------------------------------------
GRANT SELECT ON silver.stg_staff          TO bi_readonly;
GRANT SELECT ON silver.staff_source_xref  TO bi_readonly;
GRANT SELECT ON gold.dim_staff            TO bi_readonly;