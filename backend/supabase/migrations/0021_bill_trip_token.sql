-- Settlr — fix: trip-linked bills failing to sync their total into the
-- trip's Settle Up.
--
-- Root cause: syncing a trip-linked bill's total into a mirrored trip
-- expense needs the PARENT TRIP's own share_token (to call
-- add_expense_by_token/update_expense_by_token), but a bill has no way
-- to read that from its own data — get_bill_by_token only ever
-- returned the bill's own row. The frontend was instead trying to
-- resolve it from whatever trip happened to already be loaded in
-- memory that session (window.allTrips[bill.tripId]?.shareToken) —
-- which works when a bill is opened by tapping its row inside the
-- trip's own expense list (the trip is obviously already loaded then),
-- but silently fails whenever a trip-linked bill is opened any other
-- way: from the account's "Your Bills" list, from a bookmarked/shared
-- bill link, etc. — the sync function would see no tripToken and
-- quietly no-op, leaving the trip's Settle Up never knowing this bill
-- existed.
--
-- Fix: get_bill_by_token now also returns the parent trip's
-- share_token directly, as a top-level `trip_share_token` key,
-- whenever bills.trip_id is set. Safe to expose here under the same
-- trust model as everything else in this app (0020 already exposes
-- each trip-linked bill's own share_token the other direction, via
-- get_trip_by_token) — anyone holding a trip-linked bill's token was
-- always meant to have that trip's own level of access, since the
-- bill's members ARE the trip's mates. The frontend can now always
-- resolve tripToken fresh on every fetch, regardless of entry point,
-- instead of depending on in-memory session state.

set search_path = public, extensions;

create or replace function public.get_bill_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.bills%rowtype;
  v_trip_share_token text;
  v_result jsonb;
begin
  perform public._check_rate_limit('bill_read', 60, interval '5 minutes');

  select * into b from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  if b.trip_id is not null then
    select share_token into v_trip_share_token from public.trips where id = b.trip_id;
  end if;

  select jsonb_build_object(
    'bill', to_jsonb(b) - 'share_token',
    'trip_share_token', v_trip_share_token,
    'members', coalesce((
      select jsonb_agg(to_jsonb(m)) from public.bill_members m where m.bill_id = b.id
    ), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(to_jsonb(i) order by i.created_at, i.id) from public.bill_items i where i.bill_id = b.id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- Signature is unchanged from 0018 (still just p_token text), so no
-- drop/re-grant needed — create or replace keeps the existing grants.
