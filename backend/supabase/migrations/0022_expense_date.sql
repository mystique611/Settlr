-- Settlr — a user-settable date per trip expense (the date the expense
-- actually happened, not when it was logged — those can differ, e.g.
-- entering a few days of receipts after getting back to wifi).
--
-- expenses.created_at (from 0001) still exists and still drives default
-- ordering everywhere that doesn't care about this — it's "when the row
-- was written," a bookkeeping timestamp. expense_date is the new,
-- separate, user-facing concept: "what day was this actually spent."
-- The trip dashboard's new date-grouped view groups and sorts by this
-- column, not created_at.

set search_path = public, extensions;

alter table public.expenses
  add column expense_date date not null default current_date;

comment on column public.expenses.expense_date is 'The date the expense actually happened (user-editable, defaults to today at entry) — distinct from created_at, which is when the row was written.';

create index idx_expenses_trip_date on public.expenses(trip_id, expense_date desc);

-- ── add_expense_by_token: p_expense_date ──
drop function if exists public.add_expense_by_token(text, text, text, numeric, text, numeric, uuid, text, jsonb, text, text);

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
  p_receipt_path text default null,
  p_note text default null,
  p_expense_date date default current_date
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
    trip_id, description, category, amount, currency, exchange_rate, paid_by, split_type, receipt_path, note, expense_date
  ) values (
    v_trip_id, p_description, p_category, p_amount, p_currency, p_exchange_rate, p_paid_by, p_split_type, p_receipt_path, p_note, coalesce(p_expense_date, current_date)
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

-- ── update_expense_by_token: p_expense_date ──
drop function if exists public.update_expense_by_token(text, uuid, text, text, numeric, text, numeric, uuid, text, jsonb, text, boolean, text);

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
  p_clear_receipt boolean default false,
  p_note text default null,
  p_expense_date date default current_date
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
    receipt_path = case
      when p_clear_receipt then null
      when p_receipt_path is not null then p_receipt_path
      else receipt_path
    end,
    note = p_note,
    expense_date = coalesce(p_expense_date, expense_date)
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

grant execute on function public.add_expense_by_token(text, text, text, numeric, text, numeric, uuid, text, jsonb, text, text, date) to anon, authenticated;
grant execute on function public.update_expense_by_token(text, uuid, text, text, numeric, text, numeric, uuid, text, jsonb, text, boolean, text, date) to anon, authenticated;
