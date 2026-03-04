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

        -- Manager: requires Graph API manager expansion which provides
        -- manager.id — not available in the current stream. NULL for now.
        -- When available, resolve via self-join on ms_graph_id.
        NULL::UUID                                          AS manager_staff_id,

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

)

SELECT * FROM typed