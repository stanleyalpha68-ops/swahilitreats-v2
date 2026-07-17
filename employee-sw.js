/* ──────────────────────────────────────────────────────────────────────────
   Swahili Treats — EMPLOYEE PWA service worker  (Phase 6.7, v1)

   Scope: "/employee/" — never touches admin.html, admin-sw.js, track.html,
   or products.html, and never intercepts calls to Supabase (those always
   go straight to the network so orders/inventory/notifications are never
   served stale — see PART 3/PART 4 note near the bottom for what "offline"
   actually means here).

   Modeled directly on admin-sw.js's proven install/activate/fetch/push/
   notificationclick shape (Part 5's "prepare the architecture... do not
   require Firebase" is already how admin-sw.js's push works — standard
   Web Push, no third party). New here: an offline navigation fallback
   (Part 1's "Offline Landing Experience") and an explicit update flow
   (Part 6) that admin-sw.js didn't have either — see PART 6 below, which
   also got added to admin-sw.js this same phase.
   ────────────────────────────────────────────────────────────────────── */

const CACHE_VERSION = "employee-pwa-v1";
const CACHE_NAME    = `swahili-treats-employee-${CACHE_VERSION}`;

const EMPLOYEE_APP_SHELL = [
  "/employee/index.html",
  "/employee/login.html",
  "/employee/offline.html",
  "/employee-manifest.json",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
  "/icons/icon-512-maskable.png",
  "/icons/apple-touch-icon.png",
  "/favicon-32.png",
];

function isEmployeeAsset(url) {
  return url.origin === self.location.origin && EMPLOYEE_APP_SHELL.includes(url.pathname);
}

// ── Install ──────────────────────────────────────────────────────────────
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      Promise.all(
        EMPLOYEE_APP_SHELL.map((path) =>
          fetch(path, { cache: "no-cache" })
            .then((res) => (res.ok ? cache.put(path, res) : null))
            .catch(() => null)
        )
      )
    )
  );
  // PART 6 — do NOT auto-skipWaiting here. A waiting worker is exactly
  // what lets employee/index.html detect "a new version is available"
  // and show the Refresh Now / Update Later prompt. It only takes over
  // once the page explicitly posts SKIP_WAITING (see the message
  // listener below), i.e. once the employee taps "Refresh Now".
});

// ── Activate ─────────────────────────────────────────────────────────────
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((k) => k.startsWith("swahili-treats-employee-") && k !== CACHE_NAME)
          .map((k) => caches.delete(k))
      )
    )
  );
  self.clients.claim();
});

// ── Fetch — cache the static app shell; offline fallback for navigation ──
self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);
  if (req.method !== "GET") return;

  // Any navigation (typing a URL, opening from home screen, following a
  // link) that fails while offline lands on offline.html instead of the
  // browser's default "no internet" page — Part 1's offline landing
  // experience, Part 11's "error recovery."
  if (req.mode === "navigate") {
    event.respondWith(
      fetch(req).catch(() => caches.match("/employee/offline.html"))
    );
    return;
  }

  if (!isEmployeeAsset(url)) return; // everything else (Supabase included) → normal network fetch, never cached

  event.respondWith(
    fetch(req)
      .then((res) => {
        caches.open(CACHE_NAME).then((c) => c.put(req, res.clone()));
        return res;
      })
      .catch(() => caches.match(req))
  );
});

// ── PART 6 — App Updates: the page asks us to take over immediately ──────
self.addEventListener("message", (event) => {
  if (event.data && event.data.type === "SKIP_WAITING") {
    self.skipWaiting();
    return;
  }
  // Fallback in-app notify when the tab is open but a push server isn't
  // wired up yet — same pattern admin-sw.js uses for NEW_ORDER.
  if (event.data && event.data.type === "LOCAL_NOTIFY") {
    self.registration.showNotification(event.data.title || "Swahili Treats", {
      body:     event.data.body || "",
      icon:     "/icons/icon-192.png",
      badge:    "/favicon-32.png",
      tag:      event.data.tag || "st-employee-" + Date.now(),
      renotify: true,
      vibrate:  [200, 100, 200],
      data:     { url: event.data.url || "/employee/index.html" },
    });
  }
});

// ── Push (Part 5 foundation) ──────────────────────────────────────────────
// Standard Web Push — no Firebase/third party. Nothing server-side sends
// to this yet (see the phase-6.7 migration header for why), but the
// client-side subscribe → employee_devices flow in employee/index.html is
// real, so this handler is ready the moment a send path exists. Payload
// shape intentionally matches admin-sw.js's push handler so a future send
// function can target both apps identically.
self.addEventListener("push", (event) => {
  let data = {
    title: "Swahili Treats",
    body:  "You have a new update.",
    icon:  "/icons/icon-192.png",
    badge: "/favicon-32.png",
    tag:   "st-employee-update",
    url:   "/employee/index.html",
  };
  try { if (event.data) Object.assign(data, event.data.json()); } catch (_) {/* use defaults */}

  event.waitUntil(
    self.registration.showNotification(data.title, {
      body:     data.body,
      icon:     data.icon,
      badge:    data.badge,
      tag:      data.tag,
      renotify: true,
      vibrate:  [200, 100, 200],
      data:     { url: data.url },
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data || {}).url || "/employee/index.html";
  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if (c.url.includes("/employee/") && "focus" in c) return c.focus();
      }
      return clients.openWindow(target);
    })
  );
});

/* ──────────────────────────────────────────────────────────────────────────
   PART 3/4 — what "offline" and "background sync" mean in this service
   worker specifically, so this isn't overstated:

   This file only ever caches the static app SHELL (the HTML/manifest/icon
   files listed above) — never Supabase responses. That's deliberate, the
   same choice track-sw.js and admin-sw.js already made: a delivery
   employee should never see stale order/inventory data silently served
   from a cache. The actual "view assigned orders/inventory/notifications
   while offline" and "queue a status update made while offline, replay it
   on reconnect" behavior lives in employee/index.html itself, in an
   IndexedDB-backed read cache + pending-mutation queue (loadOfflineData()/
   syncOfflineChanges()) — that data is inherently per-employee and
   business-logic-shaped (which order, which field changed), which belongs
   with the app code that already knows about orders/inventory, not
   duplicated here. This service worker's job is strictly "get the app
   itself to load with no network," not "be the database."
   ────────────────────────────────────────────────────────────────────── */
