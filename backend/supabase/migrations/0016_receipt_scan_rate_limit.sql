-- Rate limiting for the receipt-scan Edge Function (OCR via Gemini).
--
-- This is a different mechanism from _check_rate_limit/_rpc_attempt_log
-- (0010), which only guards Postgres RPCs called through PostgREST. The
-- receipt scan is called directly from the browser to a Supabase Edge
-- Function, which then calls the Gemini API using a project-level API
-- key that costs real (if free-tier) quota per call — so it needs its
-- own IP-based throttle, enforced inside the Edge Function itself using
-- the service role key.
--
-- Note on extensions.gen_random_uuid(): on hosted Supabase projects,
-- pgcrypto's functions live in the extensions schema rather than
-- public. Every migration file runs in its own session and doesn't
-- inherit an earlier file's SET, so this needs its own search_path line
-- (same pattern as 0001/0005).
set search_path = public, extensions;

create table if not exists public.receipt_scan_log (
  id uuid primary key default gen_random_uuid(),
  client_ip text not null,
  created_at timestamptz not null default now()
);

alter table public.receipt_scan_log enable row level security;
-- Deliberately no policies: anon and authenticated get zero access.
-- Only the service role (used exclusively by the scan-receipt Edge
-- Function) can read/write this table.

create index if not exists receipt_scan_log_ip_created_idx
  on public.receipt_scan_log (client_ip, created_at desc);

-- Opportunistic cleanup so this table doesn't grow forever — same idea
-- as _rpc_attempt_log in 0010, just triggered from the Edge Function
-- rather than from a Postgres RPC. Kept here as a standalone callable in
-- case a scheduled job is ever added later; not required for the
-- feature to work.
create or replace function public._prune_receipt_scan_log()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.receipt_scan_log where created_at < now() - interval '7 days';
$$;

revoke all on function public._prune_receipt_scan_log() from public, anon, authenticated;
