import fs from "node:fs";
import vm from "node:vm";
import crypto from "node:crypto";
import assert from "node:assert/strict";

const source =
  fs
    .readFileSync(new URL("../app.js", import.meta.url), "utf8")
    .split("async function refresh")[0] +
  ";globalThis.testAuthorization=authorization";
const context = {
  crypto: crypto.webcrypto,
  TextEncoder,
  TextDecoder,
  atob,
  btoa,
  console,
  indexedDB: {},
};
vm.createContext(context);
vm.runInContext(source, context);

const id = "123e4567-e89b-12d3-a456-426614174000";
const secret = crypto.randomBytes(32);
const header = await context.testAuthorization(
  "GET",
  "/v1/current",
  new Uint8Array(),
  { id, secret: secret.toString("base64") },
);
const parts = header.slice(7).split(":");
assert.equal(parts[0], id);
assert.equal(parts.length, 4);
const bodyHash = crypto
  .createHash("sha256")
  .update(Buffer.alloc(0))
  .digest("base64");
const canonical = ["GET", "/v1/current", bodyHash, id, parts[1], parts[2]].join(
  "\n",
);
const expected = crypto
  .createHmac("sha256", secret)
  .update(canonical)
  .digest("base64");
assert.equal(parts[3], expected);
console.log("PWA request signing vector passed");
