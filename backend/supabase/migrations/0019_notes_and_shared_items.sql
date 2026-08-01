-- Settlr — optional notes (Bill Split items + trip expenses), and a
-- way to group several bill_items rows as "one logical item shared by
-- several people" so the frontend can show them as a single row
-- instead of one row per person.
--
-- Why bill_items still gets one row per person at all, rather than a
-- proper item/share join table: that's the existing design from 0005
-- onward (an "item" IS a person's owed slice), and every total/
-- breakdown/settle calculation already reads bill_items that way.
-- Reworking that into a real items+shares model would touch every
-- piece of Bill Split math for a purely cosmetic grouping need.
-- split_group_id is the minimal fix instead: rows created together
-- from one "Split Equally" entry share a group id, so the frontend can
-- fold them back into a single row for display/edit/delete, while
-- every existing total/settle calculation keeps reading the same flat
-- per-person rows it always has. "Duplicate Amount" rows (each person
-- really does have their own separate item) get split_group_id = null
-- and are never grouped.

set search_path = public, extensions;

alter table public.bill_items
  add column note text,
  add column split_group_id uuid;

comment on column public.bill_items.note is 'Optional free-text note, shown as small text under the description. Identical across every row in the same split_group_id, since they represent one logical item.';
comment on column public.bill_items.split_group_id is 'Set only for "Split Equally" across more than one person — every row from that one entry shares this id, so the frontend can render them as one "Shared by X, Y, Z" row instead of N separate rows. Null for single-person items and for "Duplicate Amount" items, which are never grouped.';

create index idx_bill_items_split_group_id on public.bill_items(split_group_id) where split_group_id is not null;

alter table public.expenses
  add column note text;

comment on column public.expenses.note is 'Optional free-text note, shown as small text under the "Paid by X · split label" line in the expense list.';

-- ── add_bill_item_by_token: p_note, p_split_group_id ──
drop function if exists public.add_bill_item_by_token(text, text, numeric, uuid, numeric);

create or replace function public.add_bill_item_by_token(
  p_token text,
  p_description text,
  p_amount numeric,
  p_owed_by uuid,
  p_discount_pct numeric default 0,
  p_note text default null,
  p_split_group_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_id uuid;
  v_id uuid;
begin
  perform public._check_rate_limit('bill_write', 30, interval '5 minutes');

  select id into v_bill_id from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  insert into public.bill_items (bill_id, description, amount, owed_by, discount_pct, note, split_group_id)
  values (v_bill_id, p_description, p_amount, p_owed_by, coalesce(p_discount_pct, 0), p_note, p_split_group_id)
  returning id into v_id;

  update public.bills set updated_at = now() where id = v_bill_id;
  return v_id;
end;
$$;

-- ── update_bill_item_by_token: p_note, p_split_group_id ──
drop function if exists public.update_bill_item_by_token(text, uuid, text, numeric, uuid, numeric);

create or replace function public.update_bill_item_by_token(
  p_token text,
  p_item_id uuid,
  p_description text,
  p_amount numeric,
  p_owed_by uuid,
  p_discount_pct numeric default 0,
  p_note text default null,
  p_split_group_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_id uuid;
begin
  perform public._check_rate_limit('bill_write', 30, interval '5 minutes');

  select id into v_bill_id from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  update public.bill_items set
    description = p_description,
    amount = p_amount,
    owed_by = p_owed_by,
    discount_pct = coalesce(p_discount_pct, 0),
    note = p_note,
    split_group_id = p_split_group_id
  where id = p_item_id and bill_id = v_bill_id;

  update public.bills set updated_at = now() where id = v_bill_id;
end;
$$;

grant execute on function public.add_bill_item_by_token(text, text, numeric, uuid, numeric, text, uuid) to anon, authenticated;
grant execute on function public.update_bill_item_by_token(text, uuid, text, numeric, uuid, numeric, text, uuid) to anon, authenticated;

-- ── add_expense_by_token / update_expense_by_token: p_note ──
drop function if exists public.add_expense_by_token(text, text, text, numeric, text, numeric, uuid, text, jsonb, text);

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
  p_note text default null
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
    trip_id, description, category, amount, currency, exchange_rate, paid_by, split_type, receipt_path, note
  ) values (
    v_trip_id, p_description, p_category, p_amount, p_currency, p_exchange_rate, p_paid_by, p_split_type, p_receipt_path, p_note
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

drop function if exists public.update_expense_by_token(text, uuid, text, text, numeric, text, numeric, uuid, text, jsonb, text, boolean);

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
  p_note text default null
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
    note = p_note
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

grant execute on function public.add_expense_by_token(text, text, text, numeric, text, numeric, uuid, text, jsonb, text, text) to anon, authenticated;
grant execute on function public.update_expense_by_token(text, uuid, text, text, numeric, text, numeric, uuid, text, jsonb, text, boolean, text) to anon, authenticated;
