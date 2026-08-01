# Settlr

Split costs with your mates — trips and one-off bill splits, with guest-mode sharing (no account needed) and full accounts for people who want their history synced.

This repo currently holds a working, single-file frontend prototype and a complete Supabase backend that it's wired against.

## Structure

```
Settlr/
├── index.html                             ← the app (open directly in a browser, or serve as-is)
├── manifest.json                          ← PWA manifest (installable app metadata)
├── sw.js                                  ← service worker (caches only the static shell, never live data)
├── icon/                                  ← app icons (source SVG + rasterized favicon/PWA PNGs)
├── ARCHITECTURE.md                        ← reference doc: how the whole system fits together
├── <date>-v<NN>/                          ← dated backups, taken before each editing session (see below)
└── backend/
    └── supabase/
        ├── README.md                      ← backend architecture + API reference
        ├── migrations/                    ← 17 SQL migrations, run in order
        └── functions/
            └── scan-receipt/              ← Edge Function: proxies receipt photos to Gemini for OCR
```

`index.html` sits at the repo root specifically so GitHub Pages serves it directly at the site's base URL (e.g. `https://<user>.github.io/Settlr/`) instead of falling back to a rendered `README.md`.

**Backups:** before any editing session touches the app, the current `index.html` (and any other files about to change) gets copied into a new dated subfolder first, named `YYMMDD-vNN` (e.g. `260726-v01`), starting at `v01` and incrementing per session on the same day. All ongoing edits then happen directly on the root files. These subfolders are plain historical snapshots — nothing reads from them at runtime.

## Running the frontend

`index.html` is a self-contained HTML/CSS/JS file — no build step, no dependencies. Open it directly in a browser (double-click, or `open`/`start` from a terminal) to try it.

It's wired to a live Supabase project (URL and anon key are inlined near the top of the `<script>` block — see [Deploying your own backend](#deploying-your-own-backend) if you want to point it at your own project instead).

**Note on OAuth:** Google and Microsoft sign-in are fully wired (`signInWithOAuth`), but need provider credentials configured on your own Supabase project (Google Cloud / Azure app registration + the corresponding Supabase dashboard config) before they'll work on a fresh deployment — and critically, the app needs to be served over `http://`/`https://` rather than opened as a raw `file://` path, since OAuth redirects require a real origin.

## What works today

**Guest mode** (no account, get a shareable link):
- Create or join a trip via link; add/rename/remove trip mates (at least one is required); rename the trip and change its currencies via a tag-style search field (type to add, tap a chip's ✕ to remove)
- Trip and bill links are real, clickable URLs (`<your-site>/?t=<token>` / `?b=<token>`) — opening one loads that trip/bill straight to its dashboard, no pasting the token into "Join a Trip" required. A trip joined this way (or opened via link) stays in guest state — with the usual "Save to My Account" button — unless it's already yours
- Add, edit, and delete expenses with equal/percentage/exact splits across multiple currencies — the split amounts are recomputed/validated server-side, not just trusted from the browser
- Settle up: mark a debt paid in full or partially, undo a settlement
- Delete a trip entirely (with confirmation)
- Split a Bill: a lighter one-receipt flow with per-item ownership, an optional discount (either a per-item % or a bill-level % / flat amount off the subtotal, applied before tax), tax/service/GST/tip handled at the bill level (Service Tax defaults to 10%, GST to 9%), and the same create/edit/delete/settle/delete-bill parity as trips — including an Edit Bill screen (reuses Create Bill Split) for renaming, changing currency, and adding/renaming/removing people after creation
- Add Item supports multi-selecting who an item is payable by, with a Split Equally / Duplicate Amount toggle — Split Equally divides the entered amount across everyone selected (one line item each in the bill overview); Duplicate Amount gives everyone the full amount instead (e.g. everyone had the same $12 drink)
- **Scan Receipt**: photograph or upload a receipt and Settlr reads it with AI (Gemini) instead of you typing every line by hand. A Review Scanned Items screen shows each detected item with an editable description/amount and the same payable-by chips as manual entry (defaulting to everyone, since the AI can't know who actually shared what) — nothing is added to the bill until you confirm. Works in guest mode too, no sign-in required. Needs a one-time setup step on your own Supabase project — see [Enabling receipt scanning](#enabling-receipt-scanning-optional) below; without it, the button fails gracefully with a clear message instead of breaking anything else.
- Settle Up's breakdown (on-screen and in the exported image) groups items by person; the exported PNG offers your phone's native share sheet (Save to Photos, etc.) instead of a plain file download when the browser supports it, and is credited "Generated by Settlr" at the bottom
- A guest trip/bill shows a "Save to My Account" button once you're signed in, which claims it onto your account without losing history — the old guest link is rotated to a fresh one on claim, so it stops working once the record belongs to an account

**Account mode** (real Supabase Auth):
- Sign up / sign in / sign out with email + password, session persists across reloads — an already-signed-in visitor goes straight to their account dashboard instead of seeing the landing page first, and the only way back to the landing page from there is Sign Out
- "Forgot your password?" sends a real reset email and lets you set a new password
- Google and Microsoft sign-in, once you've configured your own provider credentials (see the backend README)
- Creating a trip or bill while signed in saves it for real (not local-only), and "Your Trips" / "Your Bills" list your actual account data
- Because every trip/bill still gets a share link regardless of who created it, all the guest-mode editing above already works on your own account's trips too
- Attach a receipt photo to any expense — uploads straight to a private Supabase Storage bucket under your own account, with a paperclip icon on the expense list to view it afterward and a Remove option on the Add/Edit Expense screen. Guest mode still can't attach receipts (no account for the file to live in)

**Installable as an app:**
- Settlr can be installed as a PWA (Add to Home Screen / desktop install) — real favicon, apple-touch-icon, and manifest icons (including Android maskable variants) are wired in, backed by a minimal service worker that only caches static shell files, never app data (every screen still needs a live connection to Supabase)

**Not yet wired:**
- Nothing major left — receipt uploads (the last documented gap) are now wired end-to-end
- Trip/bill deletion is intentionally unrestricted — anyone holding a valid share link can delete a trip or bill, regardless of who created or claimed it (considered adding a creator/claimed-account restriction; explicitly decided against it for now)

## Deploying your own backend

See [`backend/supabase/README.md`](backend/supabase/README.md) for the full schema, RLS design, and guest-token API reference.

Quick version:

1. Install the Supabase CLI (`scoop install supabase` on Windows, `brew install supabase/tap/supabase` on macOS, or as an npm dev dependency elsewhere).
2. `supabase login`, then `supabase link --project-ref <your-project-ref>` from the `backend` folder.
3. `supabase db push` to apply all 15 migrations in order. Migration `0015` creates the `receipts` Storage bucket + RLS policies — this is the one migration the project's local pglite test harness can't exercise (Storage is a Supabase-platform feature), so give it a quick live check after pushing: upload a receipt as one account, confirm a second account can't fetch it.
4. Swap the `SUPABASE_URL` / `SUPABASE_ANON_KEY` constants near the top of the prototype's `<script>` block for your own project's values (Project Settings → API in the Supabase dashboard). The anon key is safe to embed client-side by design — it has no table access on its own; the RLS policies and guest RPC functions are the actual gate.

### Enabling receipt scanning (optional)

Scan Receipt calls a Supabase Edge Function (`backend/supabase/functions/scan-receipt`), which forwards the photo to Google's Gemini API. This needs two things the CLI push above doesn't cover:

1. Get a free Gemini API key at [aistudio.google.com](https://aistudio.google.com) — sign in with a Google account, click "Get API key." Gemini's free tier has no expiring trial credit; it's a genuine ongoing daily quota.
2. Set it as a secret and deploy the function from the `backend` folder:
   ```
   supabase secrets set GEMINI_API_KEY=<your key> --project-ref <your-project-ref>
   supabase functions deploy scan-receipt --project-ref <your-project-ref>
   ```
   Optionally also set `GEMINI_MODEL` (defaults to `gemini-2.5-flash`) if you ever need to point at a different model without redeploying code.

Skip this and the rest of the app works exactly the same — Scan Receipt just shows an error message instead of a parsed item list, and Add Item still works as before.

## Tech

Vanilla HTML/CSS/JS frontend (no framework, no bundler), [supabase-js](https://github.com/supabase/supabase-js) and [Font Awesome](https://fontawesome.com/) both loaded from a CDN, and a Postgres backend on Supabase (schema + Row Level Security + `SECURITY DEFINER` RPC functions for the guest-link flows).

See [`CHANGELOG.md`](CHANGELOG.md) for the build history.
