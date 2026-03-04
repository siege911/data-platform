-- Silver model: stg_staff (Golden Record)
--
-- The single source of truth for internal staff identity.
-- Entra ID (Microsoft Graph) is the authoritative spine.
--
-- Key logic:
--   - Filters OUT external/guest users (#EXT# in UPN)
--   - Deduplicates by Entra ID object ID (keeps latest extraction)
--   - Derives email from userPrincipalName (lowercased, trimmed)
--   - Extracts first business phone from JSONB array
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

    SELECT *
    FROM deduplicated
    WHERE _row_num = 1
      AND user_id IS NOT NULL
      AND user_principal_name NOT LIKE '%#EXT#%'

),

typed AS (

    SELECT
        -- Platform-owned surrogate key
        uuid_generate_v4()                                  AS staff_id,

        -- Entra ID object ID (natural key from Microsoft Graph)
        TRIM(user_id)                                       AS ms_graph_id,

        -- ERP employee ID: NULL until ERP integration is added
        NULL::VARCHAR(100)                                  AS erp_employee_id,

        -- Email: derived from UPN, lowercased and trimmed
        LOWER(TRIM(user_principal_name))                    AS email,

        -- Name fields
        NULLIF(TRIM(given_name), '')                        AS first_name,
        NULLIF(TRIM(surname), '')                           AS last_name,
        NULLIF(TRIM(display_name), '')                      AS display_name,

        -- Organizational: not yet available from this Entra ID connector.
        -- Populate when Graph API scopes are expanded to include
        -- jobTitle, department, manager.
        NULL::VARCHAR(255)                                  AS job_title,
        NULL::VARCHAR(255)                                  AS department,
        NULL::UUID                                          AS manager_staff_id,

        -- Phone: first element from the businessPhones JSONB array
        CASE
            WHEN business_phones IS NOT NULL
                 AND jsonb_array_length(business_phones) > 0
            THEN TRIM(business_phones->>0)
            ELSE NULL
        END                                                 AS phone,

        -- Status: defaulting to TRUE until accountEnabled field is synced
        TRUE                                                AS is_active,

        -- Metadata
        _airbyte_extracted_at                               AS _source_updated_at,
        NOW()                                               AS _loaded_at,
        NOW()                                               AS _updated_at

    FROM internal_users

)

SELECT * FROM typed
