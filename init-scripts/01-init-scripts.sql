-- ===========================================
-- Initialize Data Warehouse Schemas
-- ===========================================

-- Create schemas for Medallion architecture
CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;

-- Create schema for Airbyte raw data
CREATE SCHEMA IF NOT EXISTS airbyte_internal;

-- Create schema for dbt artifacts
CREATE SCHEMA IF NOT EXISTS dbt_artifacts;
0
-- Create separate database for Metabase metadata
CREATE DATABASE metabase;

-- Grant permissions
GRANT ALL PRIVILEGES ON SCHEMA bronze TO warehouse;
GRANT ALL PRIVILEGES ON SCHEMA silver TO warehouse;
GRANT ALL PRIVILEGES ON SCHEMA gold TO warehouse;
GRANT ALL PRIVILEGES ON SCHEMA airbyte_internal TO warehouse;
GRANT ALL PRIVILEGES ON SCHEMA dbt_artifacts TO warehouse;

-- Create read-only role for BI tools
CREATE ROLE bi_readonly;
GRANT USAGE ON SCHEMA silver TO bi_readonly;
GRANT USAGE ON SCHEMA gold TO bi_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA silver TO bi_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA gold TO bi_readonly;

-- Set default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA silver 
    GRANT SELECT ON TABLES TO bi_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA gold 
    GRANT SELECT ON TABLES TO bi_readonly;

-- Log completion
DO $$ 
BEGIN 
    RAISE NOTICE 'Database initialization complete!';
END $$;


-- Create database for Dagster
CREATE DATABASE dagster;