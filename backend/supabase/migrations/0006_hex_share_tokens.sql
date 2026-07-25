-- Settlr — switch share_token generation from base64 to hex
--
-- base64 output can contain '/', '+', and '=' — a '/' in particular
-- breaks the settlr.app/t/<token> URL scheme (reads as an extra path
-- segment) and trips up naive client-side token extraction like
-- `link.split('/').pop()`. Hex is always [0-9a-f], which is also what
-- the frontend prototype's own local token generator (shortToken())
-- already produces, so this keeps generated links visually consistent
-- with the rest of the app.

set search_path = public, extensions;

alter table public.trips
  alter column share_token set default encode(gen_random_bytes(9), 'hex');

alter table public.bills
  alter column share_token set default encode(gen_random_bytes(9), 'hex');

-- Re-generate tokens for any rows already created under the old
-- base64 default (safe no-op if none exist yet).
update public.trips
  set share_token = encode(gen_random_bytes(9), 'hex')
  where share_token ~ '[+/=]';

update public.bills
  set share_token = encode(gen_random_bytes(9), 'hex')
  where share_token ~ '[+/=]';
