-- Example silver model
-- Silver layer: cleaned, typed, deduplicated data

{{ config(
    materialized='incremental',
    schema='silver',
    unique_key='id'
) }}

SELECT 
    id,
    TRIM(name) as name,
    loaded_at,
    CURRENT_TIMESTAMP as transformed_at
FROM {{ ref('bronze_example') }}

{% if is_incremental() %}
WHERE loaded_at > (SELECT MAX(loaded_at) FROM {{ this }})
{% endif %}