-- Settlr — let add_expense_by_token / update_expense_by_token carry a
-- receipt's Storage object path. expenses.receipt_path has existed
-- since 0001 for exactly this, but nothing ever set it.
--
-- Adding a parameter changes a function's signature, so CREATE OR
-- REPLACE alone would leave the old 9/10-arg versions in place as a
-- separate overload instead of actually replacing them — each
-- function is explicitly dropped first, then recreated with the new
-- parameter appended (as a DEFAULT so existing callers that omit it
-- keep working), then re-granted, since a dropped-and-recreated
-- function starts with no privileges of its own.
--
-- Actually writing the file to Storage happens client-side, gated by
-- the bucket's RLS policies in 0015 (authenticated only, own folder) —
-- this migration only teaches the two RPCs to record the resulting
-- path once the upload has already happened.

drop function if exists public.add_expense_by_token(text, text, text, numeric, text, numeric, uuid, text, jsonb);

create or replace function public.add_expense_by_token(
  p_token text,
  p_description text,
  p_category text,
  p_amount numeric,
  p_currency text,
  p_exchange_rate numeric,
  p_paid_by uuid,
  p_split_type text,
  p_splits jsonb,
  p_receipt_path text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
  v_expense_id uuid;
  v_splits jsonb;
  split jsonb;
begin
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  v_splits := public._recompute_expense_splits(p_amount, p_split_type, p_splits);

  insert into public.expenses (
    trip_id, description, category, amount, currency, exchange_rate, paid_by, split_type, receipt_path
  ) values (
    v_trip_id, p_description, p_category, p_amount, p_currency, p_exchange_rate, p_paid_by, p_split_type, p_receipt_path
  ) returning id into v_expense_id;

  for split in select * from jsonb_array_elements(v_splits) loop
    insert into public.expense_splits (expense_id, trip_member_id, share_value, owed_amount)
    values (
      v_expense_id,
      (split->>'trip_member_id')::uuid,
      (split->>'share_value')::numeric,
      (split->>'owed_amount')::numeric
    );
  end loop;

  return v_expense_id;
end;
$$;

drop function if exists public.update_expense_by_token(text, uuid, text, text, numeric, text, numeric, uuid, text, jsonb);

create or replace function public.update_expense_by_token(
  p_token text,
  p_expense_id uuid,
  p_description text,
  p_category text,
  p_amount numeric,
  p_currency text,
  p_exchange_rate numeric,
  p_paid_by uuid,
  p_split_type text,
  p_splits jsonb,
  p_receipt_path text default null,
  p_clear_receipt boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
  v_splits jsonb;
  split jsonb;
begin
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  v_splits := public._recompute_expense_splits(p_amount, p_split_type, p_splits);

  update public.expenses set
    description = p_description,
    category = p_category,
    amount = p_amount,
    currency = p_currency,
    exchange_rate = p_exchange_rate,
    paid_by = p_paid_by,
    split_type = p_split_type,
    -- Explicit clear wins; otherwise a newly-uploaded path replaces the
    -- old one, and omitting both (the common case — editing something
    -- that has nothing to do with the receipt) leaves it untouched.
    receipt_path = case
      when p_clear_receipt then null
      when p_receipt_path is not null then p_receipt_path
      else receipt_path
    end
  where id = p_expense_id and trip_id = v_trip_id;

  delete from public.expense_splits where expense_id = p_expense_id;

  for split in select * from jsonb_array_elements(v_splits) loop
    insert into public.expense_splits (expense_id, trip_member_id, share_value, owed_amount)
    values (
      p_expense_id,
      (split->>'trip_member_id')::uuid,
      (split->>'share_value')::numeric,
      (split->>'owed_amount')::numeric
    );
  end loop;
end;
$$;

revoke all on function public.add_expense_by_token(text, text, text, numeric, text, numeric, uuid, text, jsonb, text) from public;
revoke all on function public.update_expense_by_token(text, uuid, text, text, numeric, text, numeric, uuid, text, jsonb, text, boolean) from public;

grant execute on function public.add_expense_by_token(text, text, text, numeric, text, numeric, uuid, text, jsonb, text) to anon, authenticated;
grant execute on function public.update_expense_by_token(text, uuid, text, text, numeric, text, numeric, uuid, text, jsonb, text, boolean) to anon, authenticated;
