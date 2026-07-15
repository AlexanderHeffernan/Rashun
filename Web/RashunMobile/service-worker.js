const CACHE = "rashun-shell-v10",
  ASSETS = [
    "./",
    "index.html",
    "app.css",
    "app.js",
    "RashunWidget.js",
    "manifest.webmanifest",
    "assets/rashun-icon.jpg",
    "assets/amp.png",
    "assets/codex.png",
    "assets/copilot.png",
    "assets/cursor.png",
    "assets/gemini.png",
  ];
self.addEventListener("install", (e) =>
  e.waitUntil(
    caches
      .open(CACHE)
      .then((c) => c.addAll(ASSETS))
      .then(() => self.skipWaiting()),
  ),
);
self.addEventListener("activate", (e) =>
  e.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)),
        ),
      )
      .then(() => self.clients.claim()),
  ),
);
self.addEventListener("fetch", (e) => {
  if (e.request.method !== "GET") return;
  const url = new URL(e.request.url);
  if (url.origin !== self.location.origin || url.pathname.startsWith("/v1/"))
    return;

  if (e.request.mode === "navigate") {
    e.respondWith(
      caches.match("index.html").then((cached) => cached || fetch(e.request)),
    );
    return;
  }

  e.respondWith(
    caches.match(e.request).then(
      (cached) =>
        cached ||
        fetch(e.request).then((response) => {
          if (response.ok)
            caches
              .open(CACHE)
              .then((cache) => cache.put(e.request, response.clone()));
          return response;
        }),
    ),
  );
});
self.addEventListener("push", (event) => {
  let payload = { title: "Rashun", body: "Your usage notification is ready." };
  try {
    payload = { ...payload, ...event.data.json() };
  } catch {}
  event.waitUntil(
    self.registration.showNotification(payload.title, {
      body: payload.body,
      icon: "assets/rashun-icon.jpg",
      badge: "assets/rashun-icon.jpg",
      data: payload.url || "./",
    }),
  );
});
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(
    clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then(
        (windows) =>
          windows[0]?.focus() ||
          clients.openWindow(event.notification.data || "./"),
      ),
  );
});
