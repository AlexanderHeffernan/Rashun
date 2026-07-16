import assert from "node:assert/strict";
import test from "node:test";
import { createRequire } from "node:module";

globalThis.FileManager = {
  local: () => ({
    libraryDirectory: () => "/tmp",
    joinPath: (left, right) => `${left}/${right}`,
  }),
};
globalThis.Size = class { constructor(width, height) { this.width = width; this.height = height; } };
globalThis.Rect = class { constructor(x, y, width, height) { Object.assign(this, { x, y, width, height }); } };
globalThis.Color = class { constructor(hex) { this.hex = hex; } };
globalThis.Font = { boldSystemFont: size => ({ size, weight: "bold" }) };
globalThis.DrawContext = class {
  constructor() { this.ellipses = []; }
  setFillColor(color) { this.color = color; }
  fillEllipse(rect) { this.ellipses.push({ color: this.color, rect }); }
  fillRect(rect) { this.ellipses.push({ color: this.color, rect }); }
  setFont(font) { this.font = font; }
  setTextColor(color) { this.textColor = color; }
  setTextAlignedCenter() {}
  drawTextInRect(text, rect) { this.text = { text, rect }; }
  drawImageInRect(image, rect) { this.image = { image, rect }; }
  getImage() { return { ellipses: this.ellipses }; }
};
const require = createRequire(import.meta.url);
const core = require("../RashunWidget.js");

const item = (providerID, metricID, remaining = 50) => ({
  providerID, metricID, sourceName: providerID, metricTitle: metricID,
  remaining, limit: 100, observedAt: "2026-07-13T10:00:00Z",
});
const snapshot = {
  schemaVersion: 1,
  generatedAt: "2026-07-13T10:00:00Z",
  device: { id: "device", name: "Mac" },
  appearance: {
    colorMode: "sourceSolid", centerContentMode: "logo", showMetricBadges: true,
    metrics: [
      { providerID: "Codex", metricID: "weekly" },
      { providerID: "Amp", metricID: "daily" },
    ],
  },
  items: [item("Amp", "daily", 70), item("Codex", "weekly", 31)],
};

test("parses a versioned setup code", () => {
  const payload = { version: 1, endpoint: "https://mac.example", password: "ABCD-EFGH" };
  const code = `RASHUN-WIDGET-1:${Buffer.from(JSON.stringify(payload)).toString("base64")}`;
  assert.deepEqual(core.parseSetup(code), payload);
  assert.throws(() => core.parseSetup("not-rashun"));
});

test("validates schema and rejects malformed metrics", () => {
  assert.equal(core.validSnapshot(snapshot), true);
  assert.equal(core.validSnapshot({ ...snapshot, schemaVersion: 2 }), false);
  assert.equal(core.validSnapshot({ ...snapshot, items: [item("Codex", "weekly", NaN)] }), false);
});

test("uses desktop menu-bar selection and order", () => {
  assert.deepEqual(core.selectedRings(snapshot).map(value => value.providerID), ["Codex", "Amp"]);
  assert.equal(core.percent(item("Codex", "weekly", 31)), 31);
});

test("formats freshness and reset intervals", () => {
  const now = new Date("2026-07-13T12:00:00Z");
  assert.equal(core.ageText("2026-07-13T10:00:00Z", now), "Updated 2h ago");
  assert.equal(core.resetText("2026-07-13T14:00:00Z", now), "Resets in 2h");
  assert.equal(core.observationDate(snapshot), "2026-07-13T10:00:00.000Z");
});

test("groups multi-metric sources without repeating their header", () => {
  const groups = core.groupedSources([
    item("Codex", "five-hour"), item("Codex", "weekly"), item("Amp", "daily"),
  ]);
  assert.deepEqual(groups.map(group => [group.providerID, group.items.length]), [["Codex", 2], ["Amp", 1]]);
});

test("draws progress rings using documented ellipse primitives", () => {
  const image = core.ringImage(item("Codex", "weekly", 31), snapshot.appearance, 90);
  assert.ok(image.ellipses.length > 96);
  assert.equal(image.ellipses[0].rect instanceof Rect, true);
});

test("parses Lock Screen metric parameters", () => {
  assert.deepEqual(core.parseWidgetParameter("Codex:weekly"), { providerID: "Codex", metricID: "weekly" });
  assert.deepEqual(core.parseWidgetParameter("source=Amp;metric=daily"), { providerID: "Amp", metricID: "daily" });
  assert.equal(core.selectedMetric(snapshot, "Amp:daily").providerID, "Amp");
});

test("uses server theme and display colors", () => {
  const themed = { ...snapshot.appearance, backgroundColorHex: "#010203", accentBrandColorHex: "#AABBCC" };
  assert.equal(core.theme(themed).background, "#010203");
  assert.equal(core.theme(themed).accent, "#AABBCC");
});
