-- Silver model: stg_staff (Golden Record)
--
-- The single source of truth for internal staff identity.
-- Entra ID (Microsoft Graph) is the authoritative spine.
--
-- Key logic:
--   - Filters OUT external/guest users (#EXT# in UPN or userType = 'Guest')
--   - Deduplicates by Entra ID object ID (keeps latest extraction)
--   - Derives email from mail field (falls back to UPN)
--   - Extracts phone from mobilePhone or first businessPhones entry
--   - Maps accountEnabled to is_active
--   - Resolves manager_staff_id via self-join on manager JSON's id field
--   - Generates a platform-owned staff_id UUID
--
-- WARNING: Do not run --full-refresh on this model. It will regenerate
-- all staff_id UUIDs and break every downstream FK that references them.

{{ config(
    materialized='incremental',
    schema='silver',
    unique_key='ms_graph_id',
    incremental_strategy='merge'
) }}

WITH source AS (

    SELECT * FROM {{ ref('bronze_entraid_users') }}

),

filtered AS (

    SELECT *
    FROM source
    {% if is_incremental() %}
    WHERE _airbyte_extracted_at > (
        SELECT COALESCE(MAX(_source_updated_at), '1970-01-01'::TIMESTAMPTZ)
        FROM {{ this }}
    )
    {% endif %}

),

deduplicated AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY _airbyte_extracted_at DESC
        ) AS _row_num
    FROM filtered

),

internal_users AS (

    -- Filter out external/guest users
    SELECT *
    FROM deduplicated
    WHERE _row_num = 1
      AND user_id IS NOT NULL
      AND user_principal_name NOT LIKE '%#EXT#%'
      AND (user_type IS NULL OR user_type <> 'Guest')

),

typed AS (

    SELECT
        -- Platform-owned surrogate key
        uuid_generate_v4()                                  AS staff_id,

        -- Entra ID object ID (natural key from Microsoft Graph)
        TRIM(user_id)                                       AS ms_graph_id,

        -- ERP employee ID: from Entra ID's employeeId field if populated,
        -- otherwise NULL until a separate ERP integration enriches it
        NULLIF(TRIM(employee_id), '')                       AS erp_employee_id,

        -- Email: prefer the mail field; fall back to UPN
        LOWER(TRIM(
            COALESCE(NULLIF(TRIM(mail), ''), user_principal_name)
        ))                                                  AS email,

        -- Name fields
        NULLIF(TRIM(given_name), '')                        AS first_name,
        NULLIF(TRIM(surname), '')                           AS last_name,
        NULLIF(TRIM(display_name), '')                      AS display_name,

        -- Organizational
        NULLIF(TRIM(job_title), '')                         AS job_title,
        NULLIF(TRIM(department), '')                        AS department,

        -- Manager: extract the Entra ID object ID from the manager JSON.
        -- This is resolved to a staff_id UUID in the next CTE via self-join.
        NULLIF(TRIM(manager->>'id'), '')                    AS _manager_ms_graph_id,

        -- Phone: prefer mobilePhone, fall back to first businessPhones entry
        COALESCE(
            NULLIF(TRIM(mobile_phone), ''),
            CASE
                WHEN business_phones IS NOT NULL
                     AND jsonb_array_length(business_phones) > 0
                THEN TRIM(business_phones->>0)
                ELSE NULL
            END
        )                                                   AS phone,

        -- Status: derived from Entra ID accountEnabled flag
        CASE
            WHEN account_enabled = 'true' THEN TRUE
            WHEN account_enabled = 'false' THEN FALSE
            ELSE TRUE  -- default if null
        END                                                 AS is_active,

        -- Metadata
        _airbyte_extracted_at                               AS _source_updated_at,
        NOW()                                               AS _loaded_at,
        NOW()                                               AS _updated_at

    FROM internal_users

),

-- Resolve manager_staff_id by self-joining to the existing silver table.
-- On the first run (full load), we join typed to itself so managers who
-- are also in the current batch get resolved. On incremental runs, we
-- also check the existing silver table for managers loaded in prior runs.
with_manager AS (

    SELECT
        t.staff_id,
        t.ms_graph_id,
        t.erp_employee_id,
        t.email,
        t.first_name,
        t.last_name,
        t.display_name,
        t.job_title,
        t.department,

        -- Try to resolve manager from the current batch first,
        -- then fall back to the existing silver table
        COALESCE(
            mgr_current.staff_id,
            {% if is_incremental() %}
            mgr_existing.staff_id,
            {% endif %}
            NULL
        )                                                   AS manager_staff_id,

        t.phone,
        t.is_active,
        t._source_updated_at,
        t._loaded_at,
        t._updated_at

    FROM typed t

    -- Join to current batch: manager might be in this same run
    LEFT JOIN typed mgr_current
        ON mgr_current.ms_graph_id = t._manager_ms_graph_id

    -- Join to existing silver table: manager was loaded in a prior run
    {% if is_incremental() %}
    LEFT JOIN {{ this }} mgr_existing
        ON mgr_existing.ms_graph_id = t._manager_ms_graph_id
    {% endif %}

)

SELECT * FROM with_manager