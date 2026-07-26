// Settlr — minimal service worker, just enough to satisfy PWA
// installability (a registered service worker with a fetch handler).
//
// This deliberately does NOT try to make the app work offline — every
// screen depends on live Supabase data (trips, bills, auth session),
// so caching that would mean showing stale or wrong balances rather
// than a helpful offline mode. All it caches is the static app shell
// (this file, the manifest, the icons) so a repeat visit loads those
// instantly from cache; everything else (the page itself, and every
// Supabase/API call) always goes to the network.

const CACHE_NAME = 'settlr-shell-v1';
const SHELL_FILES = [
  'manifest.json',
  'icon/Settlr.svg',
  'icon/icon-192.png',
  'icon/icon-512.png',
  'icon/apple-touch-icon.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  const isShellAsset = SHELL_FILES.some((f) => url.pathname.endsWith(f));
  if (!isShellAsset) return; // let the browser handle everything else normally

  event.respondWith(
    caches.match(event.request).then((cached) => cached || fetch(event.request))
  );
});
