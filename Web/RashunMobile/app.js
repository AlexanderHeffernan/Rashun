"use strict";
const DB = "rashun-mobile-v2";
let pollTimer;
function openDB() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB, 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore("settings");
      request.result.createObjectStore("current");
      request.result.createObjectStore("keys");
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function get(store, key) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const request = db.transaction(store).objectStore(store).get(key);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function put(store, key, value) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const request = db
      .transaction(store, "readwrite")
      .objectStore(store)
      .put(value, key);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
  });
}
async function remove(store, key) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const request = db
      .transaction(store, "readwrite")
      .objectStore(store)
      .delete(key);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
  });
}
async function encryptionKey() {
  const existing = await get("keys", "credential");
  if (existing) return existing;
  const created = await crypto.subtle.generateKey(
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
  await put("keys", "credential", created);
  return created;
}
async function encrypt(value) {
  if (!crypto.subtle) return { plain: value };
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    await encryptionKey(),
    new TextEncoder().encode(JSON.stringify(value)),
  );
  return { iv: [...iv], data: [...new Uint8Array(data)] };
}
async function decrypt(value) {
  if (value.plain) return value.plain;
  const data = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: new Uint8Array(value.iv) },
    await encryptionKey(),
    new Uint8Array(value.data),
  );
  return JSON.parse(new TextDecoder().decode(data));
}
function fromBase64(value) {
  return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
}
function toBase64(value) {
  return btoa(String.fromCharCode(...new Uint8Array(value)));
}
async function authorization(method, path, body, credential) {
  if (!crypto.subtle)
    return `RashunBearer ${credential.id}:${credential.secret}`;
  const bodyHash = toBase64(await crypto.subtle.digest("SHA-256", body)),
    timestamp = Math.floor(Date.now() / 1000),
    nonce = randomUUID(),
    canonical = [
      method,
      path,
      bodyHash,
      credential.id.toLowerCase(),
      String(timestamp),
      nonce,
    ].join("\n"),
    key = await crypto.subtle.importKey(
      "raw",
      fromBase64(credential.secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    ),
    signature = toBase64(
      await crypto.subtle.sign(
        "HMAC",
        key,
        new TextEncoder().encode(canonical),
      ),
    );
  return `Rashun ${credential.id}:${timestamp}:${nonce}:${signature}`;
}
async function pair(password) {
  const normalized = password.trim().toUpperCase();
  if (!normalized) return false;
  const existing = await get("settings", "credential");
  if (existing) return true;
  const identity = (await get("settings", "identity")) || {
    deviceID: randomUUID(),
    epoch: randomUUID(),
  };
  await put("settings", "identity", identity);
  const response = await fetch("/v1/pairing/connect", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    credentials: "same-origin",
    body: JSON.stringify({
      password: normalized,
      requesterName: navigator.userAgent.includes("iPhone")
        ? "iPhone"
        : "Mobile device",
      requesterDeviceID: identity.deviceID,
      requesterEpoch: identity.epoch,
      scope: "mobileRead",
    }),
  });
  if (!response.ok)
    throw new Error(
      "That password has expired. Create a new one in Rashun Preferences.",
    );
  const result = await response.json(),
    credential = { id: result.credential.id, secret: result.credential.secret };
  try {
    await put("settings", "credential", await encrypt(credential));
  } catch {
    try {
      await put("settings", "credential", { plain: credential });
    } catch {}
  }
  return true;
}
async function pairFromLink() {
  const password = new URLSearchParams(location.hash.slice(1)).get("pair");
  return password ? pair(password) : false;
}
function randomUUID() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = [...bytes]
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
async function requestHeaders(method, path, body = new Uint8Array()) {
  const stored = await get("settings", "credential"),
    headers = {};
  if (stored) {
    try {
      headers.Authorization = await authorization(
        method,
        path,
        body,
        await decrypt(stored),
      );
    } catch {}
  }
  return { stored, headers };
}
async function refresh({ showProgress = false } = {}) {
  const button = document.querySelector("#refresh");
  if (showProgress) {
    button.disabled = true;
    button.classList.add("refreshing");
    document.querySelector("#updated").textContent = "Refreshing…";
  }
  const { stored, headers } = await requestHeaders("GET", "/v1/current");
  try {
    const response = await fetch("/v1/current", {
      headers,
      credentials: "same-origin",
    });
    if (!response.ok) throw new Error("Not authorized");
    const current = await response.json();
    await put("current", "latest", current);
    render(current, false);
  } catch {
    const cached = await get("current", "latest");
    if (!stored && !cached) showSetup();
    else render(cached, true);
  } finally {
    if (showProgress) {
      button.disabled = false;
      button.classList.remove("refreshing");
    }
  }
}
function render(value, stale) {
  document.querySelector("#setup").hidden = true;
  document.querySelector("#usage").hidden = false;
  document.querySelector("#reachability").textContent = stale
    ? "Offline · cached"
    : "Connected";
  document.querySelector("#status-dot").className = stale ? "" : "online";
  document.querySelector("#updated").textContent = stale
    ? "Showing cached usage"
    : relativeUpdated(value?.generatedAt);
  document.querySelector("#usage-list").innerHTML =
    (value?.items || [])
      .map((item) => {
        const percent =
            item.limit > 0
              ? Math.max(0, Math.min(100, (item.remaining / item.limit) * 100))
              : 0,
          color = validColor(item.colorHex) ? item.colorHex : "#935AFD",
          icon = item.iconName
            ? `<img src="assets/${encodeURIComponent(item.iconName)}.png" alt="">`
            : `<span class="source-fallback">${escapeHTML(initials(item.sourceName || item.providerID))}</span>`;
        return `<article class="metric-card" style="--metric:${color}"><div class="metric-header"><div class="source">${icon}<span>${escapeHTML(item.sourceName || item.providerID)}</span></div>${item.headerDetail ? `<span class="header-detail">${escapeHTML(item.headerDetail)}</span>` : ""}</div><div class="metric-line"><span class="metric-title">${escapeHTML(item.metricTitle || item.metricID)}</span><span class="bar"><i style="width:${percent}%"></i></span><span class="percent">${percent.toFixed(0)}%</span></div><div class="detail">${escapeHTML(item.detailText || resetDescription(item.resetAt, percent))}${stale ? " · Cached" : ""}</div></article>`;
      })
      .join("") ||
    '<p class="empty">No metrics are currently shown in Rashun’s desktop menu. Enable them from Preferences → Sources.</p>';
}
function initials(value) {
  return String(value || "R")
    .split(/\s+/)
    .map((part) => part[0])
    .join("")
    .slice(0, 2)
    .toUpperCase();
}
function validColor(value) {
  return /^#[0-9a-f]{6}$/i.test(value || "");
}
function relativeUpdated(value) {
  if (!value) return "";
  const seconds = Math.max(
    0,
    Math.round((Date.now() - new Date(value).getTime()) / 1000),
  );
  if (seconds < 10) return "Updated just now";
  if (seconds < 60) return `Updated ${seconds}s ago`;
  return `Updated ${Math.floor(seconds / 60)}m ago`;
}
function resetDescription(value, percent) {
  if (!value || Math.round(percent) >= 100) return "";
  const minutes = Math.round((new Date(value).getTime() - Date.now()) / 60000);
  if (minutes <= 0) return "";
  if (minutes < 60) return `Resets in ${minutes}m`;
  const hours = Math.round(minutes / 60);
  return hours < 24
    ? `Resets in ${hours}h`
    : `Resets in ${Math.round(hours / 24)} days`;
}
function showSetup(message = "") {
  document.querySelector("#setup").hidden = false;
  document.querySelector("#usage").hidden = true;
  document.querySelector("#pairing-status").textContent = message;
  document.querySelector("#manual-pairing").hidden = !location.hash;
}
async function submitPairing(event) {
  event.preventDefault();
  const input = document.querySelector("#pairing-password"),
    button = document.querySelector("#pairing-submit"),
    status = document.querySelector("#pairing-status");
  button.disabled = true;
  status.textContent = "Connecting…";
  try {
    await pair(input.value);
    history.replaceState(null, "", location.pathname + location.search);
    await activateDashboard();
  } catch (error) {
    status.textContent = error.message;
  } finally {
    button.disabled = false;
  }
}
function escapeHTML(value) {
  const element = document.createElement("div");
  element.textContent = value ?? "";
  return element.innerHTML;
}
async function pushRegistration() {
  const registration = await navigator.serviceWorker.ready;
  return {
    registration,
    subscription: await registration.pushManager.getSubscription(),
  };
}
function fromBase64URL(value) {
  return fromBase64(
    value
      .replace(/-/g, "+")
      .replace(/_/g, "/")
      .padEnd(Math.ceil(value.length / 4) * 4, "="),
  );
}
async function syncPushSubscription(subscription) {
  const json = subscription.toJSON(),
    body = new TextEncoder().encode(
      JSON.stringify({ endpoint: json.endpoint, keys: json.keys }),
    ),
    { headers } = await requestHeaders(
      "PUT",
      "/v1/mobile/push/subscription",
      body,
    ),
    response = await fetch("/v1/mobile/push/subscription", {
      method: "PUT",
      headers: { ...headers, "Content-Type": "application/json" },
      body,
      credentials: "same-origin",
    });
  if (!response.ok)
    throw new Error("Rashun could not enable notifications on this device.");
}
async function configureNotifications() {
  const toggle = document.querySelector("#notifications-toggle"),
    note = document.querySelector("#notification-note");
  if (
    !window.isSecureContext ||
    !("Notification" in window) ||
    !("serviceWorker" in navigator) ||
    !("PushManager" in window)
  ) {
    toggle.checked = false;
    toggle.disabled = true;
    note.textContent =
      "Mobile notifications require a trusted HTTPS connection.";
    return;
  }
  const { subscription } = await pushRegistration(),
    enabled = (await get("settings", "notificationsEnabled")) === true;
  toggle.disabled = false;
  toggle.checked =
    enabled && Notification.permission === "granted" && !!subscription;
  note.textContent =
    Notification.permission === "denied"
      ? "Notifications are blocked in this device’s system settings."
      : "";
}
async function toggleNotifications(event) {
  const toggle = event.currentTarget;
  toggle.disabled = true;
  const note = document.querySelector("#notification-note");
  let active;
  try {
    const { registration, subscription } = await pushRegistration();
    active = subscription;
    if (!toggle.checked) {
      if (subscription) await subscription.unsubscribe();
      const { headers } = await requestHeaders(
        "DELETE",
        "/v1/mobile/push/subscription",
      );
      await fetch("/v1/mobile/push/subscription", {
        method: "DELETE",
        headers,
        credentials: "same-origin",
      });
      await put("settings", "notificationsEnabled", false);
      return;
    }
    const permission = await Notification.requestPermission();
    if (permission !== "granted")
      throw new Error(
        "Notifications are not allowed in this device’s system settings.",
      );
    const { headers } = await requestHeaders("GET", "/v1/mobile/push/key"),
      keyResponse = await fetch("/v1/mobile/push/key", {
        headers,
        credentials: "same-origin",
      });
    if (!keyResponse.ok)
      throw new Error("Rashun could not prepare notifications.");
    const { publicKey } = await keyResponse.json();
    active =
      subscription ||
      (await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: fromBase64URL(publicKey),
      }));
    await syncPushSubscription(active);
    await put("settings", "notificationsEnabled", true);
    note.textContent = "";
  } catch (error) {
    if (active) await active.unsubscribe().catch(() => {});
    await put("settings", "notificationsEnabled", false);
    toggle.checked = false;
    note.textContent = error.message;
  } finally {
    toggle.disabled = false;
    await configureNotifications();
  }
}
async function disconnect() {
  const button = document.querySelector("#disconnect");
  button.disabled = true;
  button.textContent = "Disconnecting…";
  try {
    const { headers } = await requestHeaders("POST", "/v1/mobile/disconnect"),
      response = await fetch("/v1/mobile/disconnect", {
        method: "POST",
        headers,
        credentials: "same-origin",
      });
    if (!response.ok && response.status !== 204) throw new Error();
    await Promise.all([
      remove("settings", "credential"),
      remove("settings", "notificationsEnabled"),
      remove("current", "latest"),
    ]);
    document.querySelector("#settings-dialog").close();
    showSetup("This device has been disconnected.");
  } catch {
    button.disabled = false;
    button.textContent = "Disconnect this device";
  }
}
async function start() {
  try {
    if (await pairFromLink())
      history.replaceState(null, "", location.pathname + location.search);
  } catch (error) {
    return showSetup(error.message);
  }
  await activateDashboard();
}
async function activateDashboard() {
  document.querySelector("#usage").hidden = false;
  document.querySelector("#refresh").onclick = () =>
    refresh({ showProgress: true });
  await refresh();
  clearInterval(pollTimer);
  pollTimer = setInterval(() => {
    if (!document.hidden) refresh();
  }, 60000);
}
document
  .querySelector("#pairing-form")
  .addEventListener("submit", submitPairing);
document.querySelector("#manual-pairing").addEventListener("click", () => {
  history.replaceState(null, "", location.pathname + location.search);
  showSetup();
  document.querySelector("#pairing-password").focus();
});
document.querySelector("#settings").addEventListener("click", async () => {
  await configureNotifications();
  document.querySelector("#settings-dialog").showModal();
});
document
  .querySelector("#close-settings")
  .addEventListener("click", () =>
    document.querySelector("#settings-dialog").close(),
  );
document
  .querySelector("#notifications-toggle")
  .addEventListener("change", toggleNotifications);
document.querySelector("#disconnect").addEventListener("click", disconnect);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) refresh();
});
if ("serviceWorker" in navigator && window.isSecureContext)
  navigator.serviceWorker.register("service-worker.js");
start();
