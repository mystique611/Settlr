-- Settlr — discount on Bill Split (per-item and bill-level subtotal)
--
-- Two different discount entry points, two different implementations:
--
-- Per-item discount % is applied client-side at the moment an item is
-- saved (manual Add Item, or the scanned-receipt review screen) — the
-- discounted amount is simply what gets written to bill_items.amount,
-- same as how "split equally" already collapses an entered amount into
-- per-person pieces before saving. No schema change needed for that
-- one; the discount percent itself isn't retained per item, only its
-- effect on the saved amount (editing an already-saved item later
-- starts its discount field back at 0%, since the discount is already
-- baked into the amount shown).
--
-- Bill-level discount (off the whole subtotal) is a genuine new bill
-- setting, alongside tax_included/service_pct/gst_pct/tip_*, so it
-- needs real columns plus a matching update_bill_settings_by_token
-- signature. That's what this migration adds.

set search_path = public, extensions;

alter table public.bills
  add column discount_mode    text not null default 'percent' check (discount_mode in ('percent', 'exact')),
  add column discount_percent numeric(5,2) not null default 0,
  add column discount_exact   numeric(12,2) not null default 0;

comment on column public.bills.discount_mode is 'Whether discount_percent or discount_exact is the active discount value — same pattern as tip_mode.';
comment on column public.bills.discount_percent is 'Discount taken off the item subtotal, before service tax/GST/tip are calculated.';
comment on column public.bills.discount_exact is 'Flat discount amount off the item subtotal, used when discount_mode = ''exact''.';

-- Signature is changing (three new params), so the old function has to
-- be dropped first — create or replace can't add parameters.
drop function if exists public.update_bill_settings_by_token(text, uuid, boolean, numeric, boolean, numeric, text, numeric, numeric);

create or replace function public.update_bill_settings_by_token(
  p_token text,
  p_payer_member_id uuid,
  p_tax_included boolean,
  p_service_pct numeric,
  p_gst_on_service boolean,
  p_gst_pct numeric,
  p_tip_mode text,
  p_tip_percent numeric,
  p_tip_exact numeric,
  p_discount_mode text,
  p_discount_percent numeric,
  p_discount_exact numeric
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

  update public.bills set
    payer_member_id = coalesce(p_payer_member_id, payer_member_id),
    tax_included = p_tax_included,
    service_pct = p_service_pct,
    gst_on_service = p_gst_on_service,
    gst_pct = p_gst_pct,
    tip_mode = p_tip_mode,
    tip_percent = p_tip_percent,
    tip_exact = p_tip_exact,
    discount_mode = coalesce(p_discount_mode, discount_mode),
    discount_percent = p_discount_percent,
    discount_exact = p_discount_exact,
    updated_at = now()
  where id = v_bill_id;
end;
$$;

revoke all on function public.update_bill_settings_by_token(text, uuid, boolean, numeric, boolean, numeric, text, numeric, numeric, text, numeric, numeric) from public;
grant execute on function public.update_bill_settings_by_token(text, uuid, boolean, numeric, boolean, numeric, text, numeric, numeric, text, numeric, numeric) to anon, authenticated;
