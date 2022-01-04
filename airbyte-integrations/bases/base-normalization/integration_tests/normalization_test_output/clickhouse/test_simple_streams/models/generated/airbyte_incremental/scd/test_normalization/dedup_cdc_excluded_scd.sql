{{ config(
    unique_key = "_airbyte_unique_key_scd",
    schema = "test_normalization",
    post_hook = ['drop view _airbyte_test_normalization.dedup_cdc_excluded_stg'],
    tags = [ "top-level" ]
) }}
-- depends_on: ref('dedup_cdc_excluded_stg')
with
{% if is_incremental() %}
new_data as (
    -- retrieve incremental "new" data
    select
        *
    from {{ ref('dedup_cdc_excluded_stg')  }}
    -- dedup_cdc_excluded from {{ source('test_normalization', '_airbyte_raw_dedup_cdc_excluded') }}
    where 1 = 1
    {{ incremental_clause('_airbyte_emitted_at') }}
),
new_data_ids as (
    -- build a subset of _airbyte_unique_key from rows that are new
    select distinct
        {{ dbt_utils.surrogate_key([
            'id',
        ]) }} as _airbyte_unique_key
    from new_data
),
empty_new_data as (
    -- build an empty table to only keep the table's column types
    select * from new_data where 1 = 0
),
previous_active_scd_data as (
    -- retrieve "incomplete old" data that needs to be updated with an end date because of new changes
    select
        {{ star_intersect(ref('dedup_cdc_excluded_stg'), this, from_alias='inc_data', intersect_alias='this_data') }}
    from {{ this }} as this_data
    -- make a join with new_data using primary key to filter active data that need to be updated only
    join new_data_ids on this_data._airbyte_unique_key = new_data_ids._airbyte_unique_key
    -- force left join to NULL values (we just need to transfer column types only for the star_intersect macro on schema changes)
    --left join empty_new_data as inc_data on this_data._airbyte_ab_id = inc_data._airbyte_ab_id
    where _airbyte_active_row = 1
),
input_data as (
    select {{ dbt_utils.star(ref('dedup_cdc_excluded_stg')) }} from new_data
    union all
    select {{ dbt_utils.star(ref('dedup_cdc_excluded_stg')) }} from previous_active_scd_data
),
{% else %}
input_data as (
    select *
    from {{ ref('dedup_cdc_excluded_stg')  }}
    -- dedup_cdc_excluded from {{ source('test_normalization', '_airbyte_raw_dedup_cdc_excluded') }}
),
{% endif %}
input_data_with_active_row_num as (
    select *,
      row_number() over (
        partition by id
        order by
            _airbyte_emitted_at is null asc,
            _airbyte_emitted_at desc,
            _airbyte_emitted_at desc, _ab_cdc_updated_at desc
      ) as _airbyte_active_row_num
    from input_data
),
scd_data as (
    -- SQL model to build a Type 2 Slowly Changing Dimension (SCD) table for each record identified by their primary key
    select
      {{ dbt_utils.surrogate_key([
            'id',
      ]) }} as _airbyte_unique_key,
        id,
        name,
        _ab_cdc_lsn,
        _ab_cdc_updated_at,
        _ab_cdc_deleted_at,
      _airbyte_emitted_at as _airbyte_start_at,
      case when _airbyte_active_row_num = 1 and _ab_cdc_deleted_at is null then 1 else 0 end as _airbyte_active_row,
      anyOrNull(_airbyte_emitted_at) over (
        partition by id
        order by
            _airbyte_emitted_at is null asc,
            _airbyte_emitted_at desc,
            _airbyte_emitted_at desc, _ab_cdc_updated_at desc
            ROWS BETWEEN 1 PRECEDING AND 1 PRECEDING
      ) as _airbyte_end_at,
      _airbyte_ab_id,
      _airbyte_emitted_at,
      _airbyte_dedup_cdc_excluded_hashid
    from input_data_with_active_row_num
),
dedup_data as (
    select
        -- we need to ensure de-duplicated rows for merge/update queries
        -- additionally, we generate a unique key for the scd table
        row_number() over (
            partition by _airbyte_unique_key, _airbyte_start_at, _airbyte_emitted_at, accurateCastOrNull(_ab_cdc_deleted_at, '{{ dbt_utils.type_string() }}'), accurateCastOrNull(_ab_cdc_updated_at, '{{ dbt_utils.type_string() }}')
            order by _airbyte_active_row desc, _airbyte_ab_id
        ) as _airbyte_row_num,
        {{ dbt_utils.surrogate_key([
          '_airbyte_unique_key',
          '_airbyte_start_at',
          '_airbyte_emitted_at', '_ab_cdc_deleted_at', '_ab_cdc_updated_at'
        ]) }} as _airbyte_unique_key_scd,
        scd_data.*
    from scd_data
)
select
    _airbyte_unique_key,
    _airbyte_unique_key_scd,
        id,
        name,
        _ab_cdc_lsn,
        _ab_cdc_updated_at,
        _ab_cdc_deleted_at,
    _airbyte_start_at,
    _airbyte_end_at,
    _airbyte_active_row,
    _airbyte_ab_id,
    _airbyte_emitted_at,
    {{ current_timestamp() }} as _airbyte_normalized_at,
    _airbyte_dedup_cdc_excluded_hashid
from dedup_data where _airbyte_row_num = 1

