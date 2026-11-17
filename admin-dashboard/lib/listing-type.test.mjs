// node --test lib/listing-type.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  changeLabel,
  reclassifyBlockedReason,
  reclassifyInputError,
  reclassifyRefusalWords,
} from "./listing-type.ts";

test("an open listing nobody has been chosen for can be reclassified", () => {
  assert.equal(reclassifyBlockedReason({ status: "open", selected_provider_id: null, archived_by: null }), null);
  // Archived by its author still counts: an admin may tidy it.
  assert.equal(reclassifyBlockedReason({ status: "open", selected_provider_id: null, archived_by: "author" }), null);
});

test("a listing with a provider, or hidden by moderation, keeps its type", () => {
  assert.match(reclassifyBlockedReason({ status: "assigned", selected_provider_id: "p1", archived_by: null }), /already has a provider/);
  assert.match(reclassifyBlockedReason({ status: "open", selected_provider_id: "p1", archived_by: null }), /already has a provider/);
  assert.match(reclassifyBlockedReason({ status: "completed", selected_provider_id: null, archived_by: null }), /already has a provider/);
  assert.match(reclassifyBlockedReason({ status: "open", selected_provider_id: null, archived_by: "moderation" }), /moderation/);
});

test("the console asks for a real change, a job's employment type, and a reason", () => {
  const ok = { type: "offer", current: "request", employmentType: null, reason: "Mislabelled: it is an offer" };
  assert.equal(reclassifyInputError(ok), null);
  assert.match(reclassifyInputError({ ...ok, type: "promo" }), /Choose request, offer or job/);
  assert.match(reclassifyInputError({ ...ok, type: "request" }), /already a request/);
  assert.match(reclassifyInputError({ ...ok, type: "job" }), /employment type/);
  assert.equal(reclassifyInputError({ ...ok, type: "job", employmentType: "full_time" }), null);
  assert.match(reclassifyInputError({ ...ok, reason: "  ok " }), /at least 5/);
  assert.match(reclassifyInputError({ ...ok, reason: "x".repeat(501) }), /under 500/);
});

test("the database's refusals read as sentences, and anything else as nothing changed", () => {
  assert.equal(
    reclassifyRefusalWords("HELP24_RECLASSIFY_REFUSED: the author needs a Care check to offer this work"),
    "The author needs a Care check to offer this work.",
  );
  assert.equal(
    reclassifyRefusalWords("HELP24_ADMIN_INVALID: the acting admin is unknown or inactive"),
    "The acting admin is unknown or inactive.",
  );
  assert.equal(reclassifyRefusalWords("connection reset"), "That could not be saved just now. Nothing was changed. Please try again.");
  assert.equal(reclassifyRefusalWords(undefined).includes("—"), false);
});

test("a change is named by both kinds", () => {
  assert.equal(changeLabel("request", "offer"), "Request to Offer");
  assert.equal(changeLabel("offer", "job"), "Offer to Job");
});
