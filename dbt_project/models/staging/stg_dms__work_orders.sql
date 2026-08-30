{{
    config(
        materialized='view'
    )
}}

/*
    Bronze -> Silver: work orders

    Cleaning applied here (see docs/DATA_CATALOG.md section 2.1):
      - Deduplicate CDC events, keeping latest state per work order
      - Normalise inconsistent WO number prefixes
      - Parse three different date formats into UTC timestamps
      - Map numeric AND text status codes into one vocabulary
      - Strip units and separators from odometer and labour hours
      - Convert placeholder dates (1900-01-01) to NULL
      - Normalise boolean representations
      - Route invalid VINs to quarantine rather than dropping them

    Deliberately NOT done here: joins, aggregation, business logic.
*/

with source as (

    select * from {{ source('dms', 'work_orders') }}

),

deduplicated as (

    -- CDC emits one row per change. Keep only the latest state per work order.
    select
        *,
        row_number() over (
            partition by wo_number
            order by cdc_timestamp desc
        ) as _row_num
    from source

),

cleaned as (

    select

        -- ---------- identifiers ----------
        -- Source uses 'WO-123', 'WO123', 'W/O 123', 'wo-123' interchangeably
        'WO-' || regexp_replace(upper(trim(wo_number)), '^(WO|W/O)[-/ ]?', '')
            as wo_number,

        upper(trim(customer_id))                     as customer_id_raw,
        upper(regexp_replace(trim(vehicle_vin), '[^A-Z0-9]', '', 'g'))
                                                     as vehicle_vin,

        -- ---------- dates ----------
        -- Source sends DD/MM/YYYY, YYYY-MM-DD, and epoch milliseconds
        {{ parse_multi_format_timestamp('date_opened') }}   as opened_at,

        -- 1900-01-01 is the source placeholder for "still open"
        case
            when {{ parse_multi_format_timestamp('date_closed') }}
                 <= timestamp '1901-01-01'
                then null
            else {{ parse_multi_format_timestamp('date_closed') }}
        end                                                 as closed_at,

        -- ---------- status ----------
        -- Source mixes numeric codes and free text
        case upper(trim(coalesce(status, '')))
            when '1'             then 'open'
            when 'OPEN'          then 'open'
            when '2'             then 'in_progress'
            when 'IN PROGRESS'   then 'in_progress'
            when 'INPROGRESS'    then 'in_progress'
            when '3'             then 'awaiting_parts'
            when 'AWAITING PARTS' then 'awaiting_parts'
            when 'WAITING PARTS' then 'awaiting_parts'
            when '4'             then 'completed'
            when 'COMPLETED'     then 'completed'
            when 'CLOSED'        then 'completed'
            when '5'             then 'cancelled'
            when 'CANCELLED'     then 'cancelled'
            when 'CANCELED'      then 'cancelled'
            else 'unknown'
        end                                                 as status,

        upper(trim(service_type_code))                      as service_type_code,

        -- ---------- technician ----------
        -- Several sentinel values all mean "nobody assigned"
        nullif(
            nullif(
                nullif(upper(trim(coalesce(technician_id, ''))), ''),
                'UNASSIGNED'
            ),
            'N/A'
        )                                                   as technician_id,

        upper(trim(bay_id))                                 as bay_id,

        -- ---------- numeric fields ----------
        -- Odometer arrives as '145,300 km' / '145300KM' / '145300'
        {{ clean_numeric('odometer_reading') }}::integer     as odometer_km_raw,

        -- Labour hours use comma as decimal separator in some records
        {{ clean_numeric('labour_hours') }}::decimal(6,2)    as labour_hours,

        -- ---------- text ----------
        nullif(regexp_replace(trim(customer_complaint), '\s+', ' ', 'g'), '')
                                                            as customer_complaint,

        -- ---------- booleans ----------
        {{ normalise_boolean('is_warranty') }}              as is_warranty,

        -- ---------- CDC metadata ----------
        coalesce(cdc_operation = 'D', false)                as is_deleted,
        cdc_timestamp                                       as source_updated_at,
        _ingested_at                                        as ingested_at

    from deduplicated
    where _row_num = 1

),

validated as (

    select
        *,

        -- VIN must be exactly 17 alphanumeric characters
        length(vehicle_vin) = 17                            as is_vin_valid,

        -- Odometer sanity bounds; out-of-range becomes NULL but is flagged
        case
            when odometer_km_raw between 0 and 2000000
                then odometer_km_raw
            else null
        end                                                 as odometer_km,

        odometer_km_raw is not null
            and odometer_km_raw not between 0 and 2000000   as has_odometer_anomaly,

        labour_hours > 24                                   as has_labour_hours_anomaly

    from cleaned

)

select
    wo_number,
    customer_id_raw as customer_id,
    case when is_vin_valid then vehicle_vin end as vehicle_vin,
    opened_at,
    closed_at,
    status,
    service_type_code,
    technician_id,
    bay_id,
    odometer_km,
    labour_hours,
    customer_complaint,
    is_warranty,
    is_deleted,
    is_vin_valid,
    has_odometer_anomaly,
    has_labour_hours_anomaly,
    source_updated_at,
    ingested_at
from validated
