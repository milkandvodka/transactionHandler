-- Run this once in the Supabase SQL editor before starting the app.
-- It creates the tables and RPC functions used by the backend.

create table if not exists public.user_stats (
  user_id text primary key,
  total_amount numeric(14, 2) not null default 0,
  transaction_count integer not null default 0,
  points integer not null default 0,
  last_transaction_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_stats_user_id_format check (user_id ~ '^[A-Za-z0-9_-]{3,40}$')
);

create table if not exists public.transactions (
  id bigserial primary key,
  request_id text not null unique,
  user_id text not null references public.user_stats(user_id),
  amount numeric(12, 2) not null,
  transaction_type text not null,
  amount_delta numeric(12, 2) not null,
  points_delta integer not null,
  created_at timestamptz not null default now(),
  constraint transactions_request_id_format check (request_id ~ '^[A-Za-z0-9:_-]{8,80}$'),
  constraint transactions_amount_range check (amount > 0 and amount <= 100000),
  constraint transactions_type_check check (transaction_type in ('purchase', 'refund'))
);

create index if not exists idx_transactions_user_created_at
  on public.transactions(user_id, created_at desc);

alter table public.user_stats enable row level security;
alter table public.transactions enable row level security;

revoke all on table public.user_stats from anon, authenticated;
revoke all on table public.transactions from anon, authenticated;
revoke all on sequence public.transactions_id_seq from anon, authenticated;

create or replace function public.get_summary(p_user_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_summary jsonb;
begin
  if p_user_id is null or p_user_id !~ '^[A-Za-z0-9_-]{3,40}$' then
    raise exception 'validation_failed: invalid user_id' using errcode = '22023';
  end if;

  select jsonb_build_object(
    'user_id', us.user_id,
    'total_amount', us.total_amount,
    'transaction_count', us.transaction_count,
    'points', us.points,
    'last_transaction_at', us.last_transaction_at
  )
  into v_summary
  from public.user_stats us
  where us.user_id = p_user_id;

  return coalesce(
    v_summary,
    jsonb_build_object(
      'user_id', p_user_id,
      'total_amount', 0,
      'transaction_count', 0,
      'points', 0,
      'last_transaction_at', null
    )
  );
end;
$$;

create or replace function public.record_transaction(
  p_request_id text,
  p_user_id text,
  p_amount numeric,
  p_transaction_type text default 'purchase'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.transactions%rowtype;
  v_inserted public.transactions%rowtype;
  v_amount numeric(12, 2);
  v_amount_delta numeric(12, 2);
  v_points_delta integer;
  v_recent_count integer;
begin
  p_transaction_type := lower(trim(p_transaction_type));
  v_amount := round(p_amount, 2);

  if p_request_id is null or p_request_id !~ '^[A-Za-z0-9:_-]{8,80}$' then
    raise exception 'validation_failed: invalid request_id' using errcode = '22023';
  end if;

  if p_user_id is null or p_user_id !~ '^[A-Za-z0-9_-]{3,40}$' then
    raise exception 'validation_failed: invalid user_id' using errcode = '22023';
  end if;

  if p_amount is null or p_amount <= 0 or p_amount > 100000 or v_amount <> p_amount then
    raise exception 'validation_failed: amount must be greater than 0, at most 100000, and use up to 2 decimals'
      using errcode = '22023';
  end if;

  if p_transaction_type not in ('purchase', 'refund') then
    raise exception 'validation_failed: transaction_type must be purchase or refund' using errcode = '22023';
  end if;

  select *
  into v_existing
  from public.transactions
  where request_id = p_request_id;

  if found then
    if v_existing.user_id = p_user_id
      and v_existing.amount = v_amount
      and v_existing.transaction_type = p_transaction_type
    then
      return jsonb_build_object(
        'status', 'duplicate',
        'duplicate', true,
        'transaction', jsonb_build_object(
          'id', v_existing.id,
          'request_id', v_existing.request_id,
          'user_id', v_existing.user_id,
          'amount', v_existing.amount,
          'transaction_type', v_existing.transaction_type,
          'amount_delta', v_existing.amount_delta,
          'points_delta', v_existing.points_delta,
          'created_at', v_existing.created_at
        ),
        'summary', public.get_summary(p_user_id)
      );
    end if;

    raise exception 'duplicate_request_conflict: request_id was already used for a different transaction'
      using errcode = '23505';
  end if;

  insert into public.user_stats(user_id)
  values (p_user_id)
  on conflict (user_id) do nothing;

  perform 1
  from public.user_stats
  where user_id = p_user_id
  for update;

  select count(*)
  into v_recent_count
  from public.transactions
  where user_id = p_user_id
    and created_at >= now() - interval '10 seconds';

  if v_recent_count >= 5 then
    raise exception 'rate_limited: maximum 5 accepted transactions per user per 10 seconds'
      using errcode = 'P0001';
  end if;

  if p_transaction_type = 'purchase' then
    v_amount_delta := v_amount;
    v_points_delta := least(floor(v_amount)::integer, 500);
  else
    v_amount_delta := -v_amount;
    v_points_delta := -least(floor(v_amount)::integer, 500);
  end if;

  insert into public.transactions(
    request_id,
    user_id,
    amount,
    transaction_type,
    amount_delta,
    points_delta
  )
  values (
    p_request_id,
    p_user_id,
    v_amount,
    p_transaction_type,
    v_amount_delta,
    v_points_delta
  )
  on conflict (request_id) do nothing
  returning *
  into v_inserted;

  if v_inserted.id is null then
    select *
    into v_existing
    from public.transactions
    where request_id = p_request_id;

    if v_existing.user_id = p_user_id
      and v_existing.amount = v_amount
      and v_existing.transaction_type = p_transaction_type
    then
      return jsonb_build_object(
        'status', 'duplicate',
        'duplicate', true,
        'transaction', jsonb_build_object(
          'id', v_existing.id,
          'request_id', v_existing.request_id,
          'user_id', v_existing.user_id,
          'amount', v_existing.amount,
          'transaction_type', v_existing.transaction_type,
          'amount_delta', v_existing.amount_delta,
          'points_delta', v_existing.points_delta,
          'created_at', v_existing.created_at
        ),
        'summary', public.get_summary(p_user_id)
      );
    end if;

    raise exception 'duplicate_request_conflict: request_id was already used for a different transaction'
      using errcode = '23505';
  end if;

  update public.user_stats
  set total_amount = total_amount + v_amount_delta,
      transaction_count = transaction_count + 1,
      points = points + v_points_delta,
      last_transaction_at = v_inserted.created_at,
      updated_at = now()
  where user_id = p_user_id;

  return jsonb_build_object(
    'status', 'created',
    'duplicate', false,
    'transaction', jsonb_build_object(
      'id', v_inserted.id,
      'request_id', v_inserted.request_id,
      'user_id', v_inserted.user_id,
      'amount', v_inserted.amount,
      'transaction_type', v_inserted.transaction_type,
      'amount_delta', v_inserted.amount_delta,
      'points_delta', v_inserted.points_delta,
      'created_at', v_inserted.created_at
    ),
    'summary', public.get_summary(p_user_id)
  );
end;
$$;

create or replace function public.get_ranking(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit integer;
  v_result jsonb;
begin
  v_limit := coalesce(p_limit, 20);

  if v_limit < 1 or v_limit > 100 then
    raise exception 'validation_failed: limit must be between 1 and 100' using errcode = '22023';
  end if;

  with scored as (
    select
      us.user_id,
      us.total_amount,
      us.transaction_count,
      us.points,
      us.last_transaction_at,
      least(us.transaction_count, 30) * 5 as activity_bonus,
      case
        when us.last_transaction_at >= now() - interval '7 days' then 30
        when us.last_transaction_at >= now() - interval '30 days' then 10
        else 0
      end as recency_bonus,
      greatest(
        0,
        (
          select count(*)::integer
          from public.transactions t
          where t.user_id = us.user_id
            and t.created_at >= now() - interval '1 minute'
        ) - 20
      ) * 25 as abuse_penalty
    from public.user_stats us
  ),
  ranked as (
    select
      row_number() over (
        order by
          greatest(0, points + activity_bonus + recency_bonus - abuse_penalty) desc,
          points desc,
          transaction_count desc,
          last_transaction_at desc,
          user_id asc
      ) as rank,
      user_id,
      total_amount,
      transaction_count,
      points,
      activity_bonus,
      recency_bonus,
      abuse_penalty,
      greatest(0, points + activity_bonus + recency_bonus - abuse_penalty) as score
    from scored
    order by
      greatest(0, points + activity_bonus + recency_bonus - abuse_penalty) desc,
      points desc,
      transaction_count desc,
      last_transaction_at desc,
      user_id asc
    limit v_limit
  )
  select jsonb_build_object(
    'formula',
    'score = capped points + min(transaction_count, 30) * 5 + recency bonus - burst penalty; each transaction gives or removes at most 500 points',
    'items',
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'rank', rank,
          'user_id', user_id,
          'score', score,
          'points', points,
          'transaction_count', transaction_count,
          'total_amount', total_amount,
          'activity_bonus', activity_bonus,
          'recency_bonus', recency_bonus,
          'abuse_penalty', abuse_penalty
        )
        order by rank
      ),
      '[]'::jsonb
    )
  )
  into v_result
  from ranked;

  return v_result;
end;
$$;

grant execute on function public.record_transaction(text, text, numeric, text) to anon, authenticated;
grant execute on function public.get_summary(text) to anon, authenticated;
grant execute on function public.get_ranking(integer) to anon, authenticated;

