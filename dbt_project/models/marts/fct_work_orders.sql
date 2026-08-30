{{
    config(
        materialized='table'
    )
}}

/*
    Silver -> Gold: one row per work order, enriched with cost and profit.

    This is where the cross-source joins the silver layer deliberately avoids
    finally happen:
      - vat_rates seed, joined by the work order's opened_at date, replaces
        the source's own (untrustworthy) vat_rate field
      - line_total is recalculated from quantity * price * (1 - discount) *
        (1 + vat), not trusted from source -- ~3% of source totals disagree
        with this recalculation, which has_line_total_mismatch surfaces
      - part lines are costed from stg_erp__parts.unit_cost_ngn; labour lines
        are costed from the work order's assigned technician's hourly_rate_ngn
      - sublet and fee lines have no cost basis in this dataset -- their cost
        is left at 0 and this is a documented gap, not a silent assumption

    Revenue and cost are both VAT-exclusive: VAT is collected on the
    customer's behalf, not company revenue, so it is tracked separately
    and excluded from gross_profit_ngn.
*/

with work_orders as (

    select * from {{ ref('stg_dms__work_orders') }}

),

lines as (

    select * from {{ ref('stg_dms__work_order_lines') }}

),

parts as (

    select * from {{ ref('stg_erp__parts') }}

),

technicians as (

    select * from {{ ref('stg_dms__technicians') }}

),

vat_rates as (

    select * from {{ ref('vat_rates') }}

),

work_orders_with_vat as (

    select
        wo.*,
        v.vat_rate as effective_vat_rate
    from work_orders wo
    left join vat_rates v
        on wo.opened_at::date >= v.valid_from
       and wo.opened_at::date <= v.valid_to

),

priced_lines as (

    select

        l.wo_number,
        l.line_id,
        l.line_type,

        -- discount_pct is only honoured on part lines. Verified against the
        -- source: labour line totals reconcile exactly to quantity x price
        -- x (1 + vat) with no discount applied, even when discount_pct is
        -- populated -- the source captures a discount field for labour that
        -- the billing system never actually applies. Recalculating with the
        -- discount for labour would flag ~85% of labour lines as
        -- mismatched, when the source is actually internally consistent.
        round(
            coalesce(l.quantity, 0) * coalesce(l.unit_price_ngn, 0)
                * case when l.line_type = 'part'
                       then 1 - coalesce(l.discount_pct, 0)
                       else 1
                  end,
            2
        )                                                       as line_subtotal_ngn,

        wo.effective_vat_rate,

        case l.line_type
            when 'part'   then coalesce(l.quantity, 0) * coalesce(p.unit_cost_ngn, 0)
            when 'labour' then coalesce(l.quantity, 0) * coalesce(t.hourly_rate_ngn, 0)
            else 0
        end                                                     as line_cost_ngn,

        l.line_total_ngn_source_raw

    from lines l
    inner join work_orders_with_vat wo on wo.wo_number = l.wo_number
    left join parts p on p.part_number = l.part_number and l.line_type = 'part'
    left join technicians t on t.technician_id = wo.technician_id and l.line_type = 'labour'

),

priced_lines_with_totals as (

    select

        *,
        round(line_subtotal_ngn * coalesce(effective_vat_rate, 0), 2) as line_vat_ngn,
        round(
            line_subtotal_ngn * (1 + coalesce(effective_vat_rate, 0)),
            2
        )                                                             as line_total_recalculated_ngn

    from priced_lines

),

work_order_agg as (

    select

        wo_number,

        sum(case when line_type = 'part'   then line_subtotal_ngn else 0 end) as parts_revenue_ngn,
        sum(case when line_type = 'labour' then line_subtotal_ngn else 0 end) as labour_revenue_ngn,
        sum(case when line_type in ('sublet', 'fee') then line_subtotal_ngn else 0 end)
                                                                                as other_revenue_ngn,
        sum(line_subtotal_ngn)                                                as revenue_ngn,
        sum(line_vat_ngn)                                                     as vat_ngn,

        sum(case when line_type = 'part'   then line_cost_ngn else 0 end)     as parts_cost_ngn,
        sum(case when line_type = 'labour' then line_cost_ngn else 0 end)     as labour_cost_ngn,
        sum(line_cost_ngn)                                                    as cost_ngn,

        count(*)                                                              as line_count,

        bool_or(
            line_total_ngn_source_raw is not null
            and abs(line_total_ngn_source_raw - line_total_recalculated_ngn) > 1
        )                                                                     as has_line_total_mismatch,

        -- Part lines reconcile exactly except for the ~3% of source totals
        -- the generator deliberately corrupts -- a clean signal.
        bool_or(
            line_type = 'part'
            and line_total_ngn_source_raw is not null
            and abs(line_total_ngn_source_raw - line_total_recalculated_ngn) > 1
        )                                                                     as has_part_line_total_mismatch,

        -- Labour lines don't reconcile as cleanly: the source's displayed
        -- quantity (hours) is sometimes rounded for display while the total
        -- was computed from the unrounded value, so recalculating from the
        -- displayed quantity can't always reproduce the total exactly. This
        -- is a genuine source precision limit, not a data error -- it is
        -- surfaced here rather than folded into the corruption-rate test.
        bool_or(
            line_type = 'labour'
            and line_total_ngn_source_raw is not null
            and abs(line_total_ngn_source_raw - line_total_recalculated_ngn) > 1
        )                                                                     as has_labour_line_total_mismatch

    from priced_lines_with_totals
    group by 1

)

select

    wo.wo_number,
    wo.customer_id,
    wo.vehicle_vin,
    wo.service_type_code,
    wo.technician_id,
    wo.bay_id,
    wo.status,
    wo.is_warranty,
    wo.opened_at,
    wo.closed_at,

    date_diff('hour', wo.opened_at, wo.closed_at)                as cycle_time_hours,

    coalesce(a.parts_revenue_ngn, 0)                             as parts_revenue_ngn,
    coalesce(a.labour_revenue_ngn, 0)                            as labour_revenue_ngn,
    coalesce(a.other_revenue_ngn, 0)                             as other_revenue_ngn,
    coalesce(a.revenue_ngn, 0)                                   as revenue_ngn,
    coalesce(a.vat_ngn, 0)                                       as vat_ngn,

    coalesce(a.parts_cost_ngn, 0)                                as parts_cost_ngn,
    coalesce(a.labour_cost_ngn, 0)                                as labour_cost_ngn,
    coalesce(a.cost_ngn, 0)                                      as cost_ngn,

    coalesce(a.revenue_ngn, 0) - coalesce(a.cost_ngn, 0)         as gross_profit_ngn,

    case when coalesce(a.revenue_ngn, 0) = 0 then null
         else (coalesce(a.revenue_ngn, 0) - coalesce(a.cost_ngn, 0)) / a.revenue_ngn
    end                                                           as margin_pct,

    coalesce(a.line_count, 0)                                    as line_count,
    coalesce(a.has_line_total_mismatch, false)                   as has_line_total_mismatch,
    coalesce(a.has_part_line_total_mismatch, false)              as has_part_line_total_mismatch,
    coalesce(a.has_labour_line_total_mismatch, false)            as has_labour_line_total_mismatch

from work_orders_with_vat wo
left join work_order_agg a on a.wo_number = wo.wo_number
