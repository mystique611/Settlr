-- Settlr — rotate a trip/bill's share_token the moment it's claimed into
-- an account, so the pre-claim guest link stops working afterwards.
--
-- Before this migration, claim_trip/claim_bill only set owner_user_id —
-- the original guest share_token kept working forever, even after the
-- record was saved to someone's account. That's a real access-leak risk
-- if the old link was ever shared or bookmarked by someone else.
--
-- Both functions are otherwise byte-identical to their 0010 versions,
-- just with a fresh hex token generated and written in the same update,
-- and returned in the response so the frontend can swap the displayed
-- link immediately. Requires extensions on the search path for
-- gen_random_bytes(), same as 0001/0005/0006.

set search_path = public, extensions;

create or replace function public.claim_trip(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  t public.trips%rowtype;
  v_new_token text;
begin
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  if v_uid is null then
    raise exception 'You must be signed in to claim a trip' using errcode = '28000';
  end if;

  select * into t from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid trip link' using errcode = '28000';
  end if;

  if t.owner_user_id is not null and t.owner_user_id <> v_uid then
    raise exception 'This trip has already been claimed by another account' using errcode = '28000';
  end if;

  v_new_token := encode(gen_random_bytes(9), 'hex');

  update public.trips
  set owner_user_id = v_uid, share_token = v_new_token, updated_at = now()
  where id = t.id;

  return jsonb_build_object('trip_id', t.id, 'name', t.name, 'share_token', v_new_token);
end;
$$;

create or replace function public.claim_bill(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  b public.bills%rowtype;
  v_new_token text;
begin
  perform public._check_rate_limit('bill_write', 30, interval '5 minutes');

  if v_uid is null then
    raise exception 'You must be signed in to claim a bill split' using errcode = '28000';
  end if;

  select * into b from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid bill link' using errcode = '28000';
  end if;

  if b.owner_user_id is not null and b.owner_user_id <> v_uid then
    raise exception 'This bill split has already been claimed by another account' using errcode = '28000';
  end if;

  v_new_token := encode(gen_random_bytes(9), 'hex');

  update public.bills
  set owner_user_id = v_uid, share_token = v_new_token, updated_at = now()
  where id = b.id;

  return jsonb_build_object('bill_id', b.id, 'name', b.name, 'share_token', v_new_token);
end;
$$;
