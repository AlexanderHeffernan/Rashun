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
self.addEventListener("pushsubscriptionchange", (event) => {
  event.waitUntil(
    readSetting("pushApplicationServerKey")
      .then((publicKey) => {
        if (!publicKey) throw new Error("Missing application server key");
        return self.registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: fromBase64URL(publicKey),
        });
      })
      .then(() => writeSetting("pushSubscriptionNeedsSync", true))
      .catch(() => writeSetting("pushSubscriptionNeedsSync", true)),
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

function openSettingsDB() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("rashun-mobile-v2", 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("settings")) db.createObjectStore("settings");
      if (!db.objectStoreNames.contains("current")) db.createObjectStore("current");
      if (!db.objectStoreNames.contains("keys")) db.createObjectStore("keys");
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function readSetting(key) {
  const db = await openSettingsDB();
  return new Promise((resolve, reject) => {
    const request = db.transaction("settings").objectStore("settings").get(key);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function writeSetting(key, value) {
  const db = await openSettingsDB();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction("settings", "readwrite");
    transaction.objectStore("settings").put(value, key);
    transaction.oncomplete = resolve;
    transaction.onerror = () => reject(transaction.error);
  });
}
function fromBase64URL(value) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(
    Math.ceil(value.length / 4) * 4,
    "=",
  );
  return Uint8Array.from(atob(normalized), (character) => character.charCodeAt(0));
}
