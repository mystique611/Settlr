-- Settlr — rate limiting on every anon-facing guest RPC function.
--
-- Every guest function's real authorization check is "does this token
-- exist" — there's no login, so the only thing standing between a
-- share_token (a random 9-byte/18-hex-char value, ~72 bits of entropy)
-- and an attacker is how many guesses they can throw at it. Brute-forcing
-- the token itself is already astronomically impractical, but nothing
-- previously stopped a script from hammering these functions at high
-- volume for scraping/abuse/DoS purposes. This adds a simple sliding-
-- window limiter keyed on the caller's IP address (read from the
-- request headers PostgREST forwards into the session), independent of
-- which token is being tried.
--
-- Two tiers: a generous one for read/bootstrap calls (a real session
-- reloading a trip repeatedly is normal), and a tighter one for every
-- mutation (create/add/update/delete/claim), since those happen far
-- less often in genuine use.

create table public._rpc_attempt_log (
  id          bigserial primary key,
  ip          text not null,
  fn          text not null,
  created_at  timestamptz not null default now()
);

create index idx_rpc_attempt_log_lookup on public._rpc_attempt_log (ip, fn, created_at);

-- Not reachable by anon/authenticated directly (see revoke below) —
-- only ever called from inside the SECURITY DEFINER functions below,
-- which run as their owner regardless of who the original caller was.
create or replace function public._check_rate_limit(p_fn text, p_max int, p_window interval)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_ip text;
  v_count int;
begin
  -- request.headers is set by PostgREST per-request; outside that
  -- context (direct SQL, local testing) it's null, so fall back to a
  -- single shared bucket rather than erroring.
  v_ip := coalesce(
    split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1),
    'unknown'
  );

  select count(*) into v_count
  from public._rpc_attempt_log
  where ip = v_ip and fn = p_fn and created_at > now() - p_window;

  if v_count >= p_max then
    raise exception 'Too many requests — please slow down and try again in a few minutes' using errcode = '57014';
  end if;

  insert into public._rpc_attempt_log (ip, fn) values (v_ip, p_fn);

  -- Opportunistic cleanup instead of a scheduled job — cheap, and
  -- keeps the table from growing unbounded without needing pg_cron.
  if random() < 0.01 then
    delete from public._rpc_attempt_log where created_at < now() - interval '1 day';
  end if;
end;
$$;

revoke all on function public._check_rate_limit(text, int, interval) from public;

-- ═══════════════════════════════════════════════════════
-- Trip functions — every body below is byte-for-byte the same as its
-- previous version (0004/0007/0008/0009), with one added line: a rate
-- limit check right after the declare block, before anything else runs.
-- ═══════════════════════════════════════════════════════

create or replace function public.get_trip_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.trips%rowtype;
  v_result jsonb;
begin
  perform public._check_rate_limit('trip_read', 60, interval '5 minutes');

  select * into t from public.trips where share_token = p_token;

  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  select jsonb_build_object(
    'trip', to_jsonb(t) - 'share_token',
    'members', coalesce((
      select jsonb_agg(to_jsonb(m)) from public.trip_members m where m.trip_id = t.id
    ), '[]'::jsonb),
    'expenses', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.created_at desc)
      from public.expenses e where e.trip_id = t.id
    ), '[]'::jsonb),
    'expense_splits', coalesce((
      select jsonb_agg(to_jsonb(s))
      from public.expense_splits s
      join public.expenses e on e.id = s.expense_id
      where e.trip_id = t.id
    ), '[]'::jsonb),
    'settlements', coalesce((
      select jsonb_agg(to_jsonb(st) order by st.settled_at desc)
      from public.settlements st where st.trip_id = t.id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

create or replace function public.create_guest_trip(
  p_name text,
  p_home_currency text,
  p_travel_currencies text[],
  p_member_names text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.trips%rowtype;
  m_name text;
begin
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  insert into public.trips (name, home_currency, travel_currencies)
  values (p_name, p_home_currency, p_travel_currencies)
  returning * into t;

  foreach m_name in array p_member_names loop
    insert into public.trip_members (trip_id, display_name) values (t.id, m_name);
  end loop;

  return jsonb_build_object(
    'trip_id', t.id,
    'share_token', t.share_token
  );
end;
$$;

create or replace function public.add_trip_member_by_token(p_token text, p_display_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
  v_id uuid;
begin
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  insert into public.trip_members (trip_id, display_name)
  values (v_trip_id, p_display_name)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.add_expense_by_token(
  p_token text,
  p_description text,
  p_category text,
  p_amount numeric,
  p_currency text,
  p_exchange_rate numeric,
  p_paid_by uuid,
  p_split_type text,
  p_splits jsonb
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
    trip_id, description, category, amount, currency, exchange_rate, paid_by, split_type
  ) values (
    v_trip_id, p_description, p_category, p_amount, p_currency, p_exchange_rate, p_paid_by, p_split_type
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

create or replace function public.delete_expense_by_token(p_token text, p_expense_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
begin
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  delete from public.expenses where id = p_expense_id and trip_id = v_trip_id;
end;
$$;

create or replace function public.record_settlement_by_token(
  p_token text,
  p_from_member uuid,
  p_to_member uuid,
  p_amount numeric,
  p_currency text,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
  v_id uuid;
begin
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  insert into public.settlements (trip_id, from_member_id, to_member_id, amount, currency, note)
  values (v_trip_id, p_from_member, p_to_member, p_amount, p_currency, p_note)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.claim_trip(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  t public.trips%rowtype;
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

  update public.trips set owner_user_id = v_uid, updated_at = now() where id = t.id;

  return jsonb_build_object('trip_id', t.id, 'name', t.name);
end;
$$;

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
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

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

create or replace function public.delete_trip_by_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
begin
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  delete from public.trips where id = v_trip_id;
end;
$$;

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
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  update public.trip_members set display_name = p_display_name
  where id = p_member_id and trip_id = v_trip_id;
end;
$$;

create or replace function public.delete_trip_member_by_token(p_token text, p_member_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
begin
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  delete from public.trip_members where id = p_member_id and trip_id = v_trip_id;
end;
$$;

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
  p_splits jsonb
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
    split_type = p_split_type
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

create or replace function public.delete_settlement_by_token(p_token text, p_settlement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
begin
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  delete from public.settlements where id = p_settlement_id and trip_id = v_trip_id;
end;
$$;

-- ═══════════════════════════════════════════════════════
-- Bill functions — same treatment.
-- ═══════════════════════════════════════════════════════

create or replace function public.get_bill_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.bills%rowtype;
  v_result jsonb;
begin
  perform public._check_rate_limit('bill_read', 60, interval '5 minutes');

  select * into b from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  select jsonb_build_object(
    'bill', to_jsonb(b) - 'share_token',
    'members', coalesce((
      select jsonb_agg(to_jsonb(m)) from public.bill_members m where m.bill_id = b.id
    ), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(to_jsonb(i)) from public.bill_items i where i.bill_id = b.id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

create or replace function public.create_guest_bill(
  p_name text,
  p_currency text,
  p_member_names text[],
  p_payer_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.bills%rowtype;
  m_name text;
  v_new_member_id uuid;
  v_payer_id uuid;
begin
  perform public._check_rate_limit('bill_write', 30, interval '5 minutes');

  insert into public.bills (name, currency) values (p_name, p_currency) returning * into b;

  foreach m_name in array p_member_names loop
    insert into public.bill_members (bill_id, display_name)
    values (b.id, m_name)
    returning id into v_new_member_id;
    if m_name = p_payer_name then
      v_payer_id := v_new_member_id;
    end if;
  end loop;

  update public.bills set payer_member_id = v_payer_id where id = b.id;

  return jsonb_build_object('bill_id', b.id, 'share_token', b.share_token);
end;
$$;

create or replace function public.add_bill_item_by_token(
  p_token text,
  p_description text,
  p_amount numeric,
  p_owed_by uuid
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

  insert into public.bill_items (bill_id, description, amount, owed_by)
  values (v_bill_id, p_description, p_amount, p_owed_by)
  returning id into v_id;

  update public.bills set updated_at = now() where id = v_bill_id;
  return v_id;
end;
$$;

create or replace function public.delete_bill_item_by_token(p_token text, p_item_id uuid)
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

  delete from public.bill_items where id = p_item_id and bill_id = v_bill_id;
  update public.bills set updated_at = now() where id = v_bill_id;
end;
$$;

create or replace function public.update_bill_settings_by_token(
  p_token text,
  p_payer_member_id uuid,
  p_tax_included boolean,
  p_service_pct numeric,
  p_gst_on_service boolean,
  p_gst_pct numeric,
  p_tip_mode text,
  p_tip_percent numeric,
  p_tip_exact numeric
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

  update public.bills set
    payer_member_id = coalesce(p_payer_member_id, payer_member_id),
    tax_included = p_tax_included,
    service_pct = p_service_pct,
    gst_on_service = p_gst_on_service,
    gst_pct = p_gst_pct,
    tip_mode = p_tip_mode,
    tip_percent = p_tip_percent,
    tip_exact = p_tip_exact,
    updated_at = now()
  where id = v_bill_id;
end;
$$;

create or replace function public.claim_bill(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  b public.bills%rowtype;
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

  update public.bills set owner_user_id = v_uid, updated_at = now() where id = b.id;

  return jsonb_build_object('bill_id', b.id, 'name', b.name);
end;
$$;

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
  perform public._check_rate_limit('bill_write', 30, interval '5 minutes');

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

create or replace function public.delete_bill_by_token(p_token text)
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

  delete from public.bills where id = v_bill_id;
end;
$$;

-- All grants/revokes on the functions above are unchanged from wherever
-- they were originally set (0003/0004/0005/0007/0008/0009) — CREATE OR
-- REPLACE keeps existing GRANTs as long as the signature doesn't change,
-- and none of these signatures changed here.
