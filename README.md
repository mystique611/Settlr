# Settlr

Split costs with your mates — trips and one-off bill splits, with guest-mode sharing (no account needed) and full accounts for people who want their history synced.

This repo currently holds a working, single-file frontend prototype and a complete Supabase backend that it's wired against.

## Structure

```
Settlr/
├── prototypes/
│   └── settlr-onboarding-prototype.html   ← the app (open directly in a browser)
└── backend/
    └── supabase/
        ├── README.md                      ← backend architecture + API reference
        └── migrations/                    ← 8 SQL migrations, run in order
```

## Running the frontend

`prototypes/settlr-onboarding-prototype.html` is a self-contained HTML/CSS/JS file — no build step, no dependencies. Open it directly in a browser (double-click, or `open`/`start` from a terminal) to try it.

It's wired to a live Supabase project (URL and anon key are inlined near the top of the `<script>` block — see [Deploying your own backend](#deploying-your-own-backend) if you want to point it at your own project instead).

**Note on OAuth:** the "Continue with Google" / "Continue with Microsoft" buttons on the sign-in screen are currently decorative. Real OAuth requires provider credentials set up in Google Cloud / Azure plus the corresponding Supabase dashboard config, and — critically — the app needs to be served over `http://` (a `file://` origin won't work as an OAuth redirect target). Email/password sign-in is fully wired and works as-is.

## What works today

**Guest mode** (no account, get a shareable link):
- Create or join a trip via link; add/rename/remove trip mates; rename the trip and change its currencies
- Add, edit, and delete expenses with equal/percentage/exact splits across multiple currencies
- Settle up: mark a debt paid in full or partially, undo a settlement
- Delete a trip entirely (with confirmation)
- Split a Bill: a lighter one-receipt flow with per-item ownership, tax/service/GST/tip handled at the bill level, and the same create/edit/delete/settle/delete-bill parity as trips

**Account mode** (real Supabase Auth):
- Sign up / sign in / sign out with email + password, session persists across reloads
- Creating a trip or bill while signed in saves it for real (not local-only), and "Your Trips" / "Your Bills" list your actual account data
- Because every trip/bill still gets a share link regardless of who created it, all the guest-mode editing above already works on your own account's trips too

**Not yet wired** (see the backend README's "still to do" section for the full list):
- Real Google/Microsoft OAuth (needs your own provider credentials — see the setup guide from our conversation if you have it, or ask again)
- Claiming a guest-created trip into your account after signing in (`claim_trip`/`claim_bill` exist in the backend, just not called from the UI yet)
- Receipt photo uploads (Supabase Storage)
- Server-side recomputation of split math, and rate limiting on the guest link endpoints

## Deploying your own backend

See [`backend/supabase/README.md`](backend/supabase/README.md) for the full schema, RLS design, and guest-token API reference.

Quick version:

1. Install the Supabase CLI (`scoop install supabase` on Windows, `brew install supabase/tap/supabase` on macOS, or as an npm dev dependency elsewhere).
2. `supabase login`, then `supabase link --project-ref <your-project-ref>` from the `backend` folder.
3. `supabase db push` to apply all 8 migrations in order.
4. Swap the `SUPABASE_URL` / `SUPABASE_ANON_KEY` constants near the top of the prototype's `<script>` block for your own project's values (Project Settings → API in the Supabase dashboard). The anon key is safe to embed client-side by design — it has no table access on its own; the RLS policies and guest RPC functions are the actual gate.

## Tech

Vanilla HTML/CSS/JS frontend (no framework, no bundler), [supabase-js](https://github.com/supabase/supabase-js) loaded from a CDN, and a Postgres backend on Supabase (schema + Row Level Security + `SECURITY DEFINER` RPC functions for the guest-link flows).

See [`CHANGELOG.md`](CHANGELOG.md) for the build history.
