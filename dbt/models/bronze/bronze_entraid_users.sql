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
    id                                  AS user_id,
    "givenName"                         AS given_name,
    surname,
    "displayName"                       AS display_name,
    mail,
    "userPrincipalName"                 AS user_principal_name,
    "mailNickname"                      AS mail_nickname,
    "jobTitle"                          AS job_title,
    department,
    "companyName"                       AS company_name,
    "employeeId"                        AS employee_id,
    "officeLocation"                    AS office_location,
    "mobilePhone"                       AS mobile_phone,
    "businessPhones"                    AS business_phones,
    "streetAddress"                     AS street_address,
    city,
    state,
    "postalCode"                        AS postal_code,
    country,
    "userType"                          AS user_type,
    "accountEnabled"                    AS account_enabled,
    manager,
    "createdDateTime"                   AS created_date_time,
    "lastPasswordChangeDateTime"        AS last_password_change,
    "preferredLanguage"                 AS preferred_language,
    identities
FROM {{ source('bronze_raw', 'entra_idusers') }}