{{
    config(
        materialized='view'
    )
}}

/*
    Bronze -> Silver: technicians

    Cleaning applied here (see docs/DATA_CATALOG.md section 2.7):
      - Normalise skill_level and specialisation vocabularies
      - Parse hire_date across the same multi-format pattern as work orders
      - Clean hourly_rate_ngn -- the rate used to cost labour lines in gold
      - Normalise is_active
*/

with source as (

    select * from {{ source('dms', 'technicians') }}

),

cleaned as (

    select

        upper(trim(technician_id))                          as technician_id,
        trim(technician_name)                                as technician_name,

        lower(trim(skill_level))                             as skill_level,

        -- Specialisation can be multi-value, semicolon-delimited in source.
        lower(trim(specialisation))                          as specialisation,

        {{ parse_multi_format_timestamp('hire_date') }}::date as hire_date,

        {{ clean_numeric('hourly_rate_ngn') }}::decimal(10,2) as hourly_rate_ngn,

        {{ normalise_boolean('is_active') }}                  as is_active

    from source

)

select * from cleaned
