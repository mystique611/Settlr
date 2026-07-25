-- Settlr — close out the remaining guest RPC parity gaps noted in
-- the README: editing/deleting a trip, renaming/removing a trip
-- mate, editing a bill item, and deleting a bill split entirely.
-- Same SECURITY DEFINER + token-lookup pattern as every other guest
-- function in 0003/0004/0005/0007 — the token is the whole
-- authorization check, there's no separate role concept.

-- ── rename a trip / change its currencies ───────────────
-- (the frontend's Edit Trip screen reuses the Create Trip form, so
-- name + home currency + travel currencies are always saved together)
create or replace function public.update_trip_by_token(
  p_token text,
  p_name text,
  p_home_currency text,
  p_travel_currencies text[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
begin
  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  update public.trips set
    name = p_name,
    home_currency = p_home_currency,
    travel_currencies = p_travel_currencies,
    updated_at = now()
  where id = v_trip_id;
end;
$$;

-- ── delete a trip entirely ───────────────────────────────
-- Cascades to trip_members, expenses, expense_splits, and
-- settlements via the FKs declared in 0001 — nothing else to clean
-- up here.
create or replace function public.delete_trip_by_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
begin
  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  delete from public.trips where id = v_trip_id;
end;
$$;

-- ── rename a trip mate ───────────────────────────────────
create or replace function public.update_trip_member_by_token(
  p_token text,
  p_member_id uuid,
  p_display_name text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
begin
  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  update public.trip_members set display_name = p_display_name
  where id = p_member_id and trip_id = v_trip_id;
end;
$$;

-- ── remove a trip mate ───────────────────────────────────
-- Blocked by Postgres (FK violation, errcode 23503) if this member
-- is referenced as an expense's paid_by (that FK is ON DELETE
-- RESTRICT — see 0001) — removing whoever paid for a logged expense
-- would corrupt that expense's meaning. expense_splits and
-- settlements referencing this member cascade-delete along with them
-- (also declared in 0001). The frontend should surface any error
-- from this call rather than silently ignore it.
create or replace function public.delete_trip_member_by_token(p_token text, p_member_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
begin
  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  delete from public.trip_members where id = p_member_id and trip_id = v_trip_id;
end;
$$;

-- ── edit an already-logged bill item ─────────────────────
create or replace function public.update_bill_item_by_token(
  p_token text,
  p_item_id uuid,
  p_description text,
  p_amount numeric,
  p_owed_by uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_id uuid;
begin
  select id into v_bill_id from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  update public.bill_items set
    description = p_description,
    amount = p_amount,
    owed_by = p_owed_by
  where id = p_item_id and bill_id = v_bill_id;

  update public.bills set updated_at = now() where id = v_bill_id;
end;
$$;

-- ── delete a bill split entirely ─────────────────────────
-- Cascades to bill_members and bill_items via the FKs in 0005.
create or replace function public.delete_bill_by_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_id uuid;
begin
  select id into v_bill_id from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  delete from public.bills where id = v_bill_id;
end;
$$;

-- ── lock down, then open exactly what's needed ───────────
revoke all on function public.update_trip_by_token(text, text, text, text[]) from public;
revoke all on function public.delete_trip_by_token(text) from public;
revoke all on function public.update_trip_member_by_token(text, uuid, text) from public;
revoke all on function public.delete_trip_member_by_token(text, uuid) from public;
revoke all on function public.update_bill_item_by_token(text, uuid, text, numeric, uuid) from public;
revoke all on function public.delete_bill_by_token(text) from public;

grant execute on function public.update_trip_by_token(text, text, text, text[]) to anon, authenticated;
grant execute on function public.delete_trip_by_token(text) to anon, authenticated;
grant execute on function public.update_trip_member_by_token(text, uuid, text) to anon, authenticated;
grant execute on function public.delete_trip_member_by_token(text, uuid) to anon, authenticated;
grant execute on function public.update_bill_item_by_token(text, uuid, text, numeric, uuid) to anon, authenticated;
grant execute on function public.delete_bill_by_token(text) to anon, authenticated;
