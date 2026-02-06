-- Example bronze model
-- Bronze layer: raw data views, no transformations

{{ config(
    materialized='view',
    schema='bronze'
) }}

-- This is a placeholder
-- Replace with actual source tables from Airbyte
SELECT 
    1 as id,
    'example' as name,
    CURRENT_TIMESTAMP as loaded_at