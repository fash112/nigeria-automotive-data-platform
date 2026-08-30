{{
    config(
        materialized='view'
    )
}}

/*
    Bronze -> Silver: parts

    Cleaning applied here (see docs/DATA_CATALOG.md section 2.5):
      - Normalise part_number the same way work order lines do, so the two
        join cleanly in gold without a separate alias table
      - Clean unit_cost_ngn -- the cost basis used for parts margin in gold
      - Currency is not FX-converted here (source is deliberately all NGN in
        this dataset); the catalog's USD/EUR FX-conversion rule is not yet
        exercised by the generator and is left as a documented gap
*/

with source as (

    select * from {{ source('erp', 'parts') }}

),

cleaned as (

    select

        upper(regexp_replace(trim(part_number), '\s+', '', 'g')) as part_number,
        trim(part_description)                                    as part_description,
        trim(category)                                             as category,
        trim(subcategory)                                          as subcategory,

        {{ clean_numeric('unit_cost_ngn') }}::decimal(14,2)        as unit_cost_ngn,
        {{ clean_numeric('unit_price_ngn') }}::decimal(14,2)       as unit_price_ngn,

        upper(trim(supplier_id))                                   as supplier_id,
        {{ clean_numeric('qty_on_hand') }}::integer                as qty_on_hand,

        case
            when trim(coalesce(reorder_point, '')) in ('', 'N/A')
                then null
            else {{ clean_numeric('reorder_point') }}::integer
        end                                                         as reorder_point,

        upper(trim(currency))                                      as currency

    from source

)

select * from cleaned
