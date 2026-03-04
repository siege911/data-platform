-- Silver model: staff_source_xref
--
-- Cross-reference mapping each staff_id to their native user ID
-- in every connected SaaS system. Currently seeds microsoft_365 entries.
--
-- When adding a new SaaS source, add a UNION ALL CTE below to
-- populate that source's mappings.

{{ config(
    materialized='incremental',
    schema='silver',
    unique_key='surrogate_key',
    incremental_strategy='merge'
) }}

WITH staff AS (

    SELECT staff_id, email, ms_graph_id
    FROM {{ ref('stg_staff') }}

),

microsoft_365_xref AS (

    SELECT
        MD5('microsoft_365' || '||' || staff.ms_graph_id)   AS surrogate_key,
        uuid_generate_v4()                                   AS id,
        staff.staff_id,
        'microsoft_365'::VARCHAR(100)                        AS source_system,
        staff.ms_graph_id::VARCHAR(500)                      AS source_user_id,
        NOW()                                                AS _loaded_at,
        NOW()                                                AS _updated_at
    FROM staff

)

-- Add new sources here:
-- , hubspot_xref AS ( ... )
-- , freshservice_xref AS ( ... )

SELECT * FROM microsoft_365_xref

{% if is_incremental() %}
WHERE surrogate_key NOT IN (SELECT surrogate_key FROM {{ this }})
{% endif %}
