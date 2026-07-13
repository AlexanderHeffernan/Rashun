const CACHE = "rashun-shell-v5",
  ASSETS = [
    "./",
    "index.html",
    "app.css",
    "app.js",
    "manifest.webmanifest",
    "assets/rashun-icon.jpg",
    "assets/amp.png",
    "assets/codex.png",
    "assets/copilot.png",
    "assets/cursor.png",
    "assets/gemini.png",
  ];
self.addEventListener("install", (e) =>
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS))),
);
self.addEventListener("activate", (e) =>
  e.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)),
        ),
      ),
  ),
);
self.addEventListener("fetch", (e) => {
  if (e.request.method === "GET")
    e.respondWith(
      fetch(e.request)
        .then((r) => {
          const copy = r.clone();
          caches.open(CACHE).then((c) => c.put(e.request, copy));
          return r;
        })
        .catch(() => caches.match(e.request)),
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
