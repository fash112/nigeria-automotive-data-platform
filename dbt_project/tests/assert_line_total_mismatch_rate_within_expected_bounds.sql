/*
    The generator deliberately corrupts ~3% of source line totals (see
    data_generator/generate_all.py, gen_work_order_lines). fct_work_orders
    flags every work order where a part line's recalculated total disagrees
    with the source's own line_total_ngn by more than NGN 1.

    Scoped to has_part_line_total_mismatch, not the labour or overall flag:
    labour totals have a separate, expected precision limitation (rounded
    display quantities) that isn't corruption -- mixing it in here would
    make this test meaningless as a corruption-rate check. Part lines have
    no such limitation, so their mismatch rate is a clean signal.

    A mismatch rate anywhere near 3% is expected and healthy -- it proves the
    recalculation is catching real source errors. A mismatch rate above 10%
    would mean the recalculation logic itself is wrong, not the source data,
    so this test fails on that case rather than on individual mismatches.
*/

select
    count(*) filter (where has_part_line_total_mismatch)                          as mismatched,
    count(*)                                                                      as total,
    count(*) filter (where has_part_line_total_mismatch)::decimal / nullif(count(*), 0)
                                                                                   as mismatch_rate
from {{ ref('fct_work_orders') }}
having count(*) filter (where has_part_line_total_mismatch)::decimal / nullif(count(*), 0) > 0.10
