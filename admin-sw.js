/* ──────────────────────────────────────────────────────────────────────────
   Swahili Treats — ADMIN-ONLY service worker  (v4 — Phase 6.7 update flow)

   Scope: "/" but fetch handler only caches the known admin shell.

   PHASE 6.7 CHANGES (Part 7 — Admin PWA Improvements):
     • v3 → v4 cache version bump (new asset list picked up).
     • Added admin-offline.html to the shell + a navigate-mode fallback,
       matching what employee-sw.js does — previously a lost connection
       mid-navigation hit the browser's bare "no internet" page instead
       of anything on-brand.
     • Removed the unconditional self.skipWaiting() on install. v3 always
       activated a new worker immediately, which is exactly the "stale
       assets" risk Part 6 asks to prevent — a tab already open when a
       deploy lands could start getting a mix of old page JS and new
       cached responses. Now the new worker waits until admin.html
       explicitly confirms the update (see the message listener below),
       same mechanism employee-sw.js uses.
   ────────────────────────────────────────────────────────────────────── */

const CACHE_VERSION = "admin-pwa-v4";
const CACHE_NAME    = `swahili-treats-admin-${CACHE_VERSION}`;

const ADMIN_APP_SHELL = [
  "/admin.html",
  "/login.html",
  "/admin-offline.html",
  "/manifest.json",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
  "/icons/icon-512-maskable.png",
  "/icons/apple-touch-icon.png",
  "/icons/favicon-32.png",
];

function isAdminAsset(url) {
  return (
    url.origin === self.location.origin &&
    ADMIN_APP_SHELL.includes(url.pathname)
  );
}

// ── Install ────────────────────────────────────────────────────────────────
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      Promise.all(
        ADMIN_APP_SHELL.map((path) =>
          fetch(path, { cache: "no-cache" })
            .then((res) => (res.ok ? cache.put(path, res) : null))
            .catch(() => null)
        )
      )
    )
  );
  // Intentionally no self.skipWaiting() here — see header comment.
});

// ── Activate ───────────────────────────────────────────────────────────────
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter(
            (k) =>
              k.startsWith("swahili-treats-admin-") && k !== CACHE_NAME
          )
          .map((k) => caches.delete(k))
      )
    )
  );
  self.clients.claim();
});

// ── Fetch ──────────────────────────────────────────────────────────────────
self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);
  if (req.method !== "GET") return;

  // Navigate-mode fallback (Part 7's "Offline Assets") — same pattern as
  // employee-sw.js: a failed navigation lands on the on-brand offline
  // page instead of the browser's default.
  if (req.mode === "navigate") {
    event.respondWith(fetch(req).catch(() => caches.match("/admin-offline.html")));
    return;
  }

  if (!isAdminAsset(url)) return;

  event.respondWith(
    fetch(req)
      .then((res) => {
        caches.open(CACHE_NAME).then((c) => c.put(req, res.clone()));
        return res;
      })
      .catch(() => caches.match(req))
  );
});

// ── Push: received from the push server (works when app is CLOSED) ─────────
self.addEventListener("push", (event) => {
  let data = {
    title: "🛍️ New Order!",
    body:  "A new order has been placed.",
    icon:  "/icons/icon-192.png",
    badge: "/icons/favicon-32.png",
    tag:   "new-order",
    url:   "/admin.html",
  };

  try {
    if (event.data) Object.assign(data, event.data.json());
  } catch (_) {/* use defaults */}

  event.waitUntil(
    self.registration.showNotification(data.title, {
      body:      data.body,
      icon:      data.icon,
      badge:     data.badge,
      tag:       data.tag,
      renotify:  true,
      vibrate:   [200, 100, 200, 100, 400],
      data:      { url: data.url },
      actions:   [{ action: "view", title: "View Orders" }],
    })
  );
});

// ── Notification click ──────────────────────────────────────────────────────
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data || {}).url || "/admin.html";

  event.waitUntil(
    clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((list) => {
        for (const c of list) {
          if (c.url.includes("admin.html") && "focus" in c) return c.focus();
        }
        return clients.openWindow(target);
      })
  );
});

// ── Message from page ────────────────────────────────────────────────────
self.addEventListener("message", (event) => {
  // PART 6 — the page asks us to activate the waiting worker (tapped
  // "Refresh Now" on the update banner).
  if (event.data && event.data.type === "SKIP_WAITING") {
    self.skipWaiting();
    return;
  }
  // Fallback in-app notify when the tab is open but push isn't reachable.
  if (!event.data || event.data.type !== "NEW_ORDER") return;
  self.registration.showNotification(event.data.title || "🛍️ New Order!", {
    body:    event.data.body || "A new order was placed.",
    icon:    "/icons/icon-192.png",
    badge:   "/icons/favicon-32.png",
    tag:     "new-order-" + Date.now(),
    renotify: true,
    vibrate: [200, 100, 200, 100, 400],
    data:    { url: "/admin.html" },
  });
});
