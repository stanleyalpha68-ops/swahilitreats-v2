/* ──────────────────────────────────────────────────────────────────────────
   Swahili Treats — TRACKING-PAGE-ONLY service worker

   Scope: "/" but the fetch handler only ever caches the tiny tracking
   app shell listed below — it never touches admin.html, admin-sw.js,
   employee/, or products.html, and it never intercepts calls to
   Supabase (those always go straight to the network so order status is
   never served stale).

   Kept deliberately minimal per Phase 5.1's "fast loading, lightweight"
   requirement — this is just enough to make track.html installable and
   to let the static shell load instantly on a repeat visit, even on a
   flaky connection. It is NOT a substitute for the realtime data on the
   page, which always comes fresh from the network.
   ────────────────────────────────────────────────────────────────────── */

const CACHE_VERSION = "track-pwa-v1";
const CACHE_NAME    = `swahili-treats-track-${CACHE_VERSION}`;

const TRACK_APP_SHELL = [
  "/track.html",
  "/track-manifest.json",
  "/favicon-32.png",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
  "/icons/icon-512-maskable.png",
];

function isTrackAsset(url) {
  return url.origin === self.location.origin && TRACK_APP_SHELL.includes(url.pathname);
}

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      Promise.all(
        TRACK_APP_SHELL.map((path) =>
          fetch(path, { cache: "no-cache" })
            .then((res) => (res.ok ? cache.put(path, res) : null))
            .catch(() => null)
        )
      )
    )
  );
  // Phase 7.5.6: removed the unconditional self.skipWaiting() that was
  // here — admin-sw.js and employee-sw.js both deliberately dropped this
  // same call in an earlier phase, for the same reason: it lets a new
  // worker take over a tab that's still open mid-session, which can hand
  // that open tab a mix of old page JS and newly-cached shell files. A
  // tab left open on a customer's tracking page is exactly the case
  // worth protecting here. track.html has no update-prompt UI (unlike
  // admin.html/employee/index.html), so this worker simply waits and
  // activates the normal way — next time the page is opened fresh with
  // no older tab of it still controlling the page — rather than needing
  // a SKIP_WAITING message handler of its own.
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((k) => k.startsWith("swahili-treats-track-") && k !== CACHE_NAME)
          .map((k) => caches.delete(k))
      )
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);
  if (req.method !== "GET" || !isTrackAsset(url)) return; // everything else (Supabase included) → normal network fetch

  event.respondWith(
    fetch(req)
      .then((res) => {
        caches.open(CACHE_NAME).then((c) => c.put(req, res.clone()));
        return res;
      })
      .catch(() => caches.match(req))
  );
});

/* ──────────────────────────────────────────────────────────────────────────
   PHASE 5.2 — future Web Push hook (Part 16 / Part 18)

   Nothing below is active yet: no push subscription is ever created
   anywhere in track.html, so this listener never fires today and this
   file's existing install/activate/fetch behavior above is completely
   unchanged. It's here purely so a future phase can turn Web Push on
   by (a) subscribing via `registration.pushManager.subscribe(...)` in
   track.html once the customer opts in, (b) sending that subscription
   to a server that can call the Push API, and (c) filling in the
   `showNotification` call below — using the exact same notification
   shape (icon/title/message/orderId) that createNotification() in
   track.html already builds for every order-status update. No other
   changes to this service worker would be needed.
   ────────────────────────────────────────────────────────────────────── */
self.addEventListener("push", (event) => {
  if (!event.data) return;
  // TODO (future phase): parse event.data.json() — expected shape matches
  // createNotification()'s output in track.html: { title, message, icon,
  // orderId }. Then:
  //   event.waitUntil(self.registration.showNotification(payload.title, {
  //     body: payload.message,
  //     icon: "/icons/icon-192.png",
  //     data: { orderId: payload.orderId },
  //   }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const orderId = event.notification.data?.orderId;
  const url = orderId ? `/track.html?order=${encodeURIComponent(orderId)}` : "/track.html";
  event.waitUntil(self.clients.openWindow(url));
});
