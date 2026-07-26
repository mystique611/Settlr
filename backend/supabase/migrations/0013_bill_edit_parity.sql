-- Settlr — bill-split parity with trips for renaming/re-currencying a
-- bill and managing its members after creation.
--
-- Until now, create_guest_bill was the only way to set a bill's name,
-- currency, and member list — there was no way to edit any of them
-- afterwards (unlike trips, which have update_trip_by_token plus
-- add/update/delete_trip_member_by_token). This closes that gap so the
-- frontend's "Edit Bill" screen (reusing Create Bill Split's UI) has
-- something to call.
--
-- Same rate-limit bucket as every other bill mutation (bill_write,
-- 30 requests / 5 minutes).

create or replace function public.update_bill_by_token(
  p_token text,
  p_name text,
  p_currency text
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

  update public.bills set name = p_name, currency = p_currency, updated_at = now()
  where id = v_bill_id;
end;
$$;

create or replace function public.add_bill_member_by_token(p_token text, p_display_name text)
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

  insert into public.bill_members (bill_id, display_name)
  values (v_bill_id, p_display_name)
  returning id into v_id;

  update public.bills set updated_at = now() where id = v_bill_id;
  return v_id;
end;
$$;

create or replace function public.update_bill_member_by_token(
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
  v_bill_id uuid;
begin
  perform public._check_rate_limit('bill_write', 30, interval '5 minutes');

  select id into v_bill_id from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  update public.bill_members set display_name = p_display_name
  where id = p_member_id and bill_id = v_bill_id;

  update public.bills set updated_at = now() where id = v_bill_id;
end;
$$;

-- Fails with a foreign-key violation (23503) if this person owes a bill
-- item (bill_items.owed_by is ON DELETE RESTRICT, same reasoning as
-- trip members and paid_by expenses — removing them shouldn't silently
-- orphan what they owe). If they're only set as the bill's payer, that
-- FK is ON DELETE SET NULL, so it clears quietly instead of blocking.
create or replace function public.delete_bill_member_by_token(p_token text, p_member_id uuid)
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

  delete from public.bill_members where id = p_member_id and bill_id = v_bill_id;
  update public.bills set updated_at = now() where id = v_bill_id;
end;
$$;

revoke all on function public.update_bill_by_token(text, text, text) from public;
revoke all on function public.add_bill_member_by_token(text, text) from public;
revoke all on function public.update_bill_member_by_token(text, uuid, text) from public;
revoke all on function public.delete_bill_member_by_token(text, uuid) from public;

grant execute on function public.update_bill_by_token(text, text, text) to anon, authenticated;
grant execute on function public.add_bill_member_by_token(text, text) to anon, authenticated;
grant execute on function public.update_bill_member_by_token(text, uuid, text) to anon, authenticated;
grant execute on function public.delete_bill_member_by_token(text, uuid) to anon, authenticated;
