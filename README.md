# Settlr

Split costs with your mates — trips and one-off bill splits, with guest-mode sharing (no account needed) and full accounts for people who want their history synced.

This repo currently holds a working, single-file frontend prototype and a complete Supabase backend that it's wired against.

## Structure

```
Settlr/
├── index.html                             ← the app (open directly in a browser, or serve as-is)
├── <date>-v<NN>/                          ← dated backups, taken before each editing session (see below)
└── backend/
    └── supabase/
        ├── README.md                      ← backend architecture + API reference
        └── migrations/                    ← 11 SQL migrations, run in order
```

`index.html` sits at the repo root specifically so GitHub Pages serves it directly at the site's base URL (e.g. `https://<user>.github.io/Settlr/`) instead of falling back to a rendered `README.md`.

**Backups:** before any editing session touches the app, the current `index.html` (and any other files about to change) gets copied into a new dated subfolder first, named `YYMMDD-vNN` (e.g. `260726-v01`), starting at `v01` and incrementing per session on the same day. All ongoing edits then happen directly on the root files. These subfolders are plain historical snapshots — nothing reads from them at runtime.

## Running the frontend

`index.html` is a self-contained HTML/CSS/JS file — no build step, no dependencies. Open it directly in a browser (double-click, or `open`/`start` from a terminal) to try it.

It's wired to a live Supabase project (URL and anon key are inlined near the top of the `<script>` block — see [Deploying your own backend](#deploying-your-own-backend) if you want to point it at your own project instead).

**Note on OAuth:** Google and Microsoft sign-in are fully wired (`signInWithOAuth`), but need provider credentials configured on your own Supabase project (Google Cloud / Azure app registration + the corresponding Supabase dashboard config) before they'll work on a fresh deployment — and critically, the app needs to be served over `http://`/`https://` rather than opened as a raw `file://` path, since OAuth redirects require a real origin.

## What works today

**Guest mode** (no account, get a shareable link):
- Create or join a trip via link; add/rename/remove trip mates (at least one is required); rename the trip and change its currencies
- Add, edit, and delete expenses with equal/percentage/exact splits across multiple currencies — the split amounts are recomputed/validated server-side, not just trusted from the browser
- Settle up: mark a debt paid in full or partially, undo a settlement
- Delete a trip entirely (with confirmation)
- Split a Bill: a lighter one-receipt flow with per-item ownership, tax/service/GST/tip handled at the bill level (Service Tax defaults to 10%, GST to 9%), and the same create/edit/delete/settle/delete-bill parity as trips
- A guest trip/bill shows a "Save to My Account" button once you're signed in, which claims it onto your account without losing the link or its history

**Account mode** (real Supabase Auth):
- Sign up / sign in / sign out with email + password, session persists across reloads
- "Forgot your password?" sends a real reset email and lets you set a new password
- Google and Microsoft sign-in, once you've configured your own provider credentials (see the backend README)
- Creating a trip or bill while signed in saves it for real (not local-only), and "Your Trips" / "Your Bills" list your actual account data
- Because every trip/bill still gets a share link regardless of who created it, all the guest-mode editing above already works on your own account's trips too

**Not yet wired:**
- Receipt photo uploads (Supabase Storage) — the one remaining major gap
- Rotating a trip/bill's `share_token` after it's claimed into an account (the old guest link keeps working even after claiming)

## Deploying your own backend

See [`backend/supabase/README.md`](backend/supabase/README.md) for the full schema, RLS design, and guest-token API reference.

Quick version:

1. Install the Supabase CLI (`scoop install supabase` on Windows, `brew install supabase/tap/supabase` on macOS, or as an npm dev dependency elsewhere).
2. `supabase login`, then `supabase link --project-ref <your-project-ref>` from the `backend` folder.
3. `supabase db push` to apply all 11 migrations in order.
4. Swap the `SUPABASE_URL` / `SUPABASE_ANON_KEY` constants near the top of the prototype's `<script>` block for your own project's values (Project Settings → API in the Supabase dashboard). The anon key is safe to embed client-side by design — it has no table access on its own; the RLS policies and guest RPC functions are the actual gate.

## Tech

Vanilla HTML/CSS/JS frontend (no framework, no bundler), [supabase-js](https://github.com/supabase/supabase-js) and [Font Awesome](https://fontawesome.com/) both loaded from a CDN, and a Postgres backend on Supabase (schema + Row Level Security + `SECURITY DEFINER` RPC functions for the guest-link flows).

See [`CHANGELOG.md`](CHANGELOG.md) for the build history.
