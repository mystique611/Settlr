-- Settlr — default a new Bill Split's Service Tax to 10% and GST to 9%,
-- matching a common receipt convention, instead of defaulting to 0 and
-- making every guest manually type these in on every single bill.
--
-- This only changes the column DEFAULT, so it only affects bills
-- created from now on — existing bills keep whatever tax settings they
-- already have. Both bill-creation paths (create_guest_bill's RPC
-- insert, and the authenticated client's direct table insert) omit
-- these columns and rely on this default, so changing it here covers
-- both without touching either insert statement.

alter table public.bills alter column service_pct set default 10;
alter table public.bills alter column gst_pct set default 9;
