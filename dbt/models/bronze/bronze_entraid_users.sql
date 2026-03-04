-- Bronze model: Entra ID Users
-- Provides a stable, snake_case interface over the raw Airbyte table.
-- No type casting or transformation — that happens in silver.
--
-- NOTE: This Airbyte connection uses the newer flat-column format
-- (columns extracted directly), NOT the older JSONB _airbyte_data pattern.

{{ config(
    materialized='view',
    schema='bronze'
) }}

SELECT
    _airbyte_raw_id,
    _airbyte_extracted_at,
    _airbyte_meta,
    id                      AS user_id,
    "givenName"             AS given_name,
    surname,
    "displayName"           AS display_name,
    "userPrincipalName"     AS user_principal_name,
    "businessPhones"        AS business_phones,
    "preferredLanguage"     AS preferred_language
FROM {{ source('bronze_raw', 'entraId_users') }}
