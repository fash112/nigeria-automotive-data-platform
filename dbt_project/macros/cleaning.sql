{#
    Reusable cleaning macros.
    Written once, used across every staging model.
#}

{% macro clean_numeric(column_name) %}
    /* Strips currency symbols, units, thousands separators, and converts
       comma decimal separators to points.

       DuckDB's regex engine (RE2) has no lookahead, so the thousands-comma
       can't be matched-and-dropped while leaving the following digits alone
       the way a lookahead would. Instead the comma is matched together with
       the three digits after it, and the replacement puts just the digits
       back via a capture group -- same result, no lookahead required. */
    nullif(
        replace(
            regexp_replace(
                upper(trim(coalesce({{ column_name }}::varchar, ''))),
                '(NGN|₦|KM|KMS|HRS|HOURS)|,(\d{3})\b', '\2', 'g'
            ),
            ',', '.'
        ),
        ''
    )
{% endmacro %}


{% macro normalise_boolean(column_name) %}
    /* Source systems represent booleans as Y/N, 1/0, TRUE/FALSE, yes/no. */
    case upper(trim(coalesce({{ column_name }}::varchar, '')))
        when 'Y'     then true
        when 'YES'   then true
        when '1'     then true
        when 'TRUE'  then true
        when 'T'     then true
        when 'N'     then false
        when 'NO'    then false
        when '0'     then false
        when 'FALSE' then false
        when 'F'     then false
        else null
    end
{% endmacro %}


{% macro parse_multi_format_timestamp(column_name) %}
    /* Handles DD/MM/YYYY, YYYY-MM-DD, and epoch milliseconds in one column.

       DuckDB has no to_timestamp(text, format) overload (that's Postgres) --
       formatted date strings are parsed with strptime instead. Pattern
       matching uses regexp_matches(), not the `~` operator -- on this
       DuckDB version `~` does not reliably behave as POSIX regex match
       (verified: it silently disagreed with regexp_matches on the very
       'YYYY-MM-DD' pattern this macro depends on). */
    case
        when regexp_matches({{ column_name }}, '^\d{13}$')
            then to_timestamp({{ column_name }}::bigint / 1000)::timestamp
        when regexp_matches({{ column_name }}, '^\d{2}/\d{2}/\d{4}')
            then strptime({{ column_name }}, '%d/%m/%Y')::timestamp
        when regexp_matches({{ column_name }}, '^\d{4}-\d{2}-\d{2}')
            then {{ column_name }}::timestamp
        else null
    end
{% endmacro %}


{% macro normalise_phone_ng(column_name) %}
    /* Normalises Nigerian phone numbers to E.164 (+234...). */
    case
        when regexp_matches(regexp_replace({{ column_name }}, '[^0-9]', '', 'g'), '^0[789]\d{9}$')
            then '+234' || substring(regexp_replace({{ column_name }}, '[^0-9]', '', 'g') from 2)
        when regexp_matches(regexp_replace({{ column_name }}, '[^0-9]', '', 'g'), '^234[789]\d{9}$')
            then '+' || regexp_replace({{ column_name }}, '[^0-9]', '', 'g')
        else null
    end
{% endmacro %}
