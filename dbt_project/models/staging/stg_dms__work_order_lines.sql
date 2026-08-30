{{
    config(
        materialized='view'
    )
}}

/*
    Bronze -> Silver: work order lines

    Cleaning applied here (see docs/DATA_CATALOG.md section 2.2):
      - Build a stable line_id, since the source has no unique line ID
      - Normalise line_type to a fixed vocabulary
      - Clean part_number (parts alias mapping is not applied — no
        seeds/part_number_aliases.csv exists yet; documented as a gap)
      - Cast quantity, unit_price and discount_pct, normalising the
        percent-vs-fraction ambiguity in discount_pct
      - Flag negative quantities rather than dropping them

    Deliberately NOT done here: the source's own vat_rate and line_total are
    read raw only. The catalog documents vat_rate as "not taken from source,
    joined by effective date instead" -- that join needs the parent work
    order's date, which is a cross-source lookup silver does not perform.
    The gold layer (fct_work_orders) recalculates the trusted line_total.
*/

with source as (

    select * from {{ source('dms', 'work_order_lines') }}

),

cleaned as (

    select

        upper(trim(wo_number)) || '-' || trim(line_no)      as line_id,
        upper(trim(wo_number))                               as wo_number,
        trim(line_no)                                        as line_no,

        case lower(trim(coalesce(line_type, '')))
            when 'labour' then 'labour'
            when 'part'   then 'part'
            when 'sublet' then 'sublet'
            when 'fee'    then 'fee'
            else 'unknown'
        end                                                   as line_type,

        nullif(
            upper(regexp_replace(trim(part_number), '\s+', '', 'g')),
            ''
        )                                                     as part_number,

        nullif(regexp_replace(trim(description), '\s+', ' ', 'g'), '')
                                                                as description,

        {{ clean_numeric('quantity') }}::decimal(10,2)        as quantity_raw,

        case
            when {{ clean_numeric('unit_price_ngn') }}::decimal(14,2) < 0
                then null
            else {{ clean_numeric('unit_price_ngn') }}::decimal(14,2)
        end                                                     as unit_price_ngn,

        {{ clean_numeric('unit_price_ngn') }}::decimal(14,2) < 0
                                                                as has_negative_price_anomaly,

        -- Source mixes '10' (percent) and '0.10' (fraction) for the same
        -- discount. Anything greater than 1 is a percent -- divide by 100.
        case
            when {{ clean_numeric('discount_pct') }}::decimal(6,3) > 1
                then {{ clean_numeric('discount_pct') }}::decimal(6,3) / 100
            else {{ clean_numeric('discount_pct') }}::decimal(6,3)
        end                                                     as discount_pct,

        -- Untouched — recalculated from clean inputs in the gold layer.
        {{ clean_numeric('vat_rate') }}::decimal(6,4)          as vat_rate_source_raw,
        {{ clean_numeric('line_total_ngn') }}::decimal(14,2)   as line_total_ngn_source_raw

    from source

)

select

    line_id,
    wo_number,
    line_type,
    part_number,
    description,

    case when quantity_raw < 0 and line_type != 'return'
        then null
        else quantity_raw
    end                                                         as quantity,

    quantity_raw < 0 and line_type != 'return'                  as has_negative_quantity_anomaly,

    unit_price_ngn,
    has_negative_price_anomaly,
    discount_pct,
    vat_rate_source_raw,
    line_total_ngn_source_raw

from cleaned
