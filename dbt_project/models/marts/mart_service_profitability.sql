{{
    config(
        materialized='table'
    )
}}

/*
    Answers business question #1 from the README: which service types
    generate the most gross profit after parts and labour cost?

    Grain: service_type_code x month. Built on fct_work_orders so the cost
    and revenue definitions are computed exactly once and reused everywhere.
*/

with fct as (

    select * from {{ ref('fct_work_orders') }}

),

service_types as (

    select * from {{ ref('service_type_codes') }}

),

monthly as (

    select

        date_trunc('month', opened_at)                        as month,
        service_type_code,

        count(*)                                               as job_count,
        sum(revenue_ngn)                                       as revenue_ngn,
        sum(cost_ngn)                                          as cost_ngn,
        sum(gross_profit_ngn)                                  as gross_profit_ngn,
        avg(cycle_time_hours)                                  as avg_cycle_time_hours

    from fct
    group by 1, 2

)

select

    m.month,
    m.service_type_code,
    st.description                                             as service_type_description,
    st.category                                                as service_category,

    m.job_count,
    m.revenue_ngn,
    m.cost_ngn,
    m.gross_profit_ngn,

    case when m.revenue_ngn = 0 then null
         else m.gross_profit_ngn / m.revenue_ngn
    end                                                          as margin_pct,

    m.avg_cycle_time_hours

from monthly m
left join service_types st on st.service_type_code = m.service_type_code
order by m.month, m.gross_profit_ngn desc
