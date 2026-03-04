{% macro generate_schema_name(custom_schema_name, node) -%}

    {#
        If a model specifies +schema (e.g., bronze, silver, gold),
        use that name exactly. Otherwise fall back to the profile
        default (dbt_artifacts).

        Without this macro, dbt concatenates:
            dbt_artifacts_bronze, dbt_artifacts_silver, etc.
        With this macro:
            bronze, silver, gold (as intended)
    #}

    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}