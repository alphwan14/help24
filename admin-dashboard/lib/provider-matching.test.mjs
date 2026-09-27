// node --test lib/provider-matching.test.mjs   (Node ≥ 22.18: the .ts module loads through type stripping)
import assert from "node:assert/strict";
import { test } from "node:test";
import { buildRegistry, candidatesFor, countByTier, distanceKm, fmtPhone, telHref } from "./provider-matching.ts";

// The live registry's shapes, including its quirks: delivery-rider points at a
// category id that does not exist, and legacy labels like "Cleaning" and
// "Repair" are not category names.
const registry = buildRegistry(
  [
    { id: "delivery-rider", name: "Delivery Rider", group_id: "logistics", category_id: "delivery", aliases: ["delivery", "rider"] },
    { id: "driver", name: "Driver", group_id: "logistics", category_id: "driver", aliases: [] },
    { id: "cleaner", name: "Cleaner", group_id: "cleaning", category_id: "house-cleaning", aliases: [] },
    { id: "laundry-attendant", name: "Laundry Attendant", group_id: "cleaning", category_id: "laundry", aliases: ["mama fua"] },
    { id: "plumber", name: "Plumber", group_id: "skilled-trades", category_id: "plumbing", aliases: [] },
    { id: "electrician", name: "Electrician", group_id: "skilled-trades", category_id: "electrical", aliases: [] },
    { id: "phone-repair-technician", name: "Phone Repair Technician", group_id: "it", category_id: "phone-repair", aliases: [] },
    { id: "other", name: "Other", group_id: "other", category_id: "other", aliases: [] },
  ],
  [
    { id: "delivery-rider", name: "Delivery Rider" },
    { id: "driver", name: "Driver" },
    { id: "house-cleaning", name: "House Cleaning" },
    { id: "laundry", name: "Laundry" },
    { id: "plumbing", name: "Plumbing" },
    { id: "electrical", name: "Electrical" },
    { id: "phone-repair", name: "Phone Repair" },
    { id: "computer-repair", name: "Computer Repair" },
    { id: "other", name: "Other" },
  ],
);

const request = (category, extra = {}) => ({
  title: "A job",
  description: null,
  category,
  latitude: null,
  longitude: null,
  author_user_id: "client",
  ...extra,
});
let n = 0;
const offer = (category, extra = {}) => ({
  id: `o${++n}`,
  title: `${category} offer`,
  category,
  location: "Mombasa",
  latitude: null,
  longitude: null,
  author_user_id: null,
  created_at: "2026-09-01T00:00:00Z",
  ...extra,
});
const seed = (userId, { offers = [], professionIds = [] } = {}) => ({ userId, offers, professionIds });
const tierFor = (req, s) => candidatesFor(req, [s], registry)[0]?.tier ?? null;

test("an open offer in the request's own category is the same work", () => {
  assert.equal(tierFor(request("Plumbing"), seed("p", { offers: [offer("Plumbing")] })), "same");
});

test('an offer label the registry resolves by alias reaches the trade — "Delivery" is the same work as "Delivery Rider"', () => {
  assert.equal(tierFor(request("Delivery Rider"), seed("p", { offers: [offer("Delivery")] })), "same");
});

test("an adjacent trade in the same group is related, never the same", () => {
  assert.equal(tierFor(request("Driver"), seed("p", { offers: [offer("Delivery")] })), "related");
});

test("a profile trade counts, as in the feed: the same category, then the same group", () => {
  const electrician = seed("p", { professionIds: ["electrician"] });
  assert.equal(tierFor(request("Electrical"), electrician), "same");
  assert.equal(tierFor(request("Plumbing"), electrician), "related");
  assert.equal(candidatesFor(request("Plumbing"), [electrician], registry)[0].profile.trade, "Electrician");
});

test("a label the registry cannot place borrows a category that contains it — and never claims the same work", () => {
  const cleaning = seed("p", { offers: [offer("Cleaning")] });
  assert.equal(tierFor(request("Laundry"), cleaning), "related"); // cleaner and laundry share a group
  assert.equal(tierFor(request("House Cleaning"), cleaning), "related"); // loose, so not "same"
  assert.equal(tierFor(request("Cleaning"), cleaning), "same"); // the very same label
  // "Repair" sits in two categories and means neither surely.
  assert.equal(tierFor(request("Phone Repair"), seed("p", { offers: [offer("Repair")] })), "related");
});

test("text evidence matches whole words only — a rider is not a provider", () => {
  const rider = seed("p", { offers: [offer("Delivery")] });
  assert.equal(tierFor(request("Other", { title: "Need a provider for my garden" }), rider), null);
  assert.equal(tierFor(request("Other", { title: "Need a rider to take a parcel" }), rider), "mentions");
});

test("a free-text trade reaches a request through its distinctive words, only as a mention", () => {
  const grinder = seed("p", { professionIds: ["Posho Mill Grinder"] });
  assert.equal(tierFor(request("Posho Mill Grinding", { title: "Operate my posho mill" }), grinder), "mentions");
  // Generic words carry nothing: "Repair Services" is not evidence for every repair request.
  assert.equal(tierFor(request("Other", { title: "Services needed" }), seed("q", { professionIds: ["Repair Services"] })), null);
});

test('"Other" matches nothing by category', () => {
  assert.equal(tierFor(request("Other"), seed("p", { offers: [offer("Other")] })), null);
});

test("the client is never suggested to themselves", () => {
  assert.deepEqual(candidatesFor(request("Plumbing"), [seed("client", { offers: [offer("Plumbing")] })], registry), []);
});

test("strongest evidence first; within it the nearest known distance, and an unknown distance is never ranked as near", () => {
  const req = request("Plumbing", { latitude: -4.0435, longitude: 39.6682 });
  const near = seed("near", { offers: [offer("Plumbing", { latitude: -4.0, longitude: 39.7 })] });
  const far = seed("far", { offers: [offer("Plumbing", { latitude: -1.2921, longitude: 36.8219 })] });
  const unknown = seed("unknown", { offers: [offer("Plumbing")] });
  const related = seed("related", { professionIds: ["electrician"] });
  const order = candidatesFor(req, [related, unknown, far, near], registry);
  assert.deepEqual(order.map((c) => c.userId), ["near", "far", "unknown", "related"]);
  assert.deepEqual(countByTier(order), { same: 3, related: 1, mentions: 0 });
  assert.ok(order[0].distanceKm < 10);
  assert.equal(order[2].distanceKm, null);
});

test("distance is great-circle, and null unless both sides have coordinates", () => {
  const km = distanceKm({ latitude: -4.0435, longitude: 39.6682 }, { latitude: -1.2921, longitude: 36.8219 });
  assert.ok(km > 430 && km < 450, `Mombasa–Nairobi was ${km}`);
  assert.equal(distanceKm({ latitude: -4, longitude: 39 }, { latitude: null, longitude: 36 }), null);
});

test("phone numbers: Kenyan numbers dial with +254, anything else is shown as stored and not dialled", () => {
  assert.equal(fmtPhone("254712345678"), "+254 712 345 678");
  assert.equal(telHref("254712345678"), "tel:+254712345678");
  assert.equal(telHref("0712345678"), "tel:+254712345678");
  assert.equal(telHref("not a number"), null);
  assert.equal(fmtPhone("not a number"), "not a number");
});
