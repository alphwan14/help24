// node --test lib/greeting.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { attentionItems, dateLine, firstNameFrom, greetingForHour, hourIn } from "./greeting.ts";

test("time of day boundaries", () => {
  const cases = [[5, "Good morning"], [11, "Good morning"], [12, "Good afternoon"], [16, "Good afternoon"],
    [17, "Good evening"], [20, "Good evening"], [21, "Welcome back"], [0, "Welcome back"], [4, "Welcome back"]];
  for (const [h, g] of cases) assert.equal(greetingForHour(h), g, `hour ${h}`);
});

test("the hour and date are read in the given zone, not the machine's", () => {
  const instant = new Date("2026-10-26T05:30:00Z"); // 08:30 in Nairobi, 01:30 in New York
  assert.equal(hourIn("Africa/Nairobi", instant), 8);
  assert.equal(hourIn("America/New_York", instant), 1);
  assert.equal(dateLine("Africa/Nairobi", instant), "Monday, 26 October");
});

test("first name: profile name first, then the email, then nothing", () => {
  assert.equal(firstNameFrom("Alphonse Lincoln", "x@y.co"), "Alphonse");
  assert.equal(firstNameFrom("  ", "john.doe92@example.com"), "John");
  assert.equal(firstNameFrom(null, "alphwan14@gmail.com"), "Alphwan");
  assert.equal(firstNameFrom(null, "12345@example.com"), null);
  assert.equal(firstNameFrom(null, null), null);
});

const alert = (id, count, extra = {}) => ({ id, count, review: null, ...extra });

test("context items: summed, pluralised, zeros hidden, reviewed ignored, most pressing first", () => {
  const items = attentionItems([
    alert("requests_unanswered", 4),
    alert("urgent_unanswered", 1),
    alert("dispute_awaiting_admin", 1),
    alert("reports_untriaged", 2, { review: { note: "seen" } }),
    alert("promotion_review", 0),
  ]);
  assert.deepEqual(items.map((i) => [i.text, i.href]), [
    ["1 dispute needs review", "/dashboard/disputes"],
    ["5 requests awaiting providers", "/dashboard/marketplace/requests?status=open"],
  ]);
  assert.equal(attentionItems([alert("dispute_escalated", 2)])[0].text, "2 disputes need review");
});

test("nothing open, nothing listed — the page shows its all-clear line", () => {
  assert.deepEqual(attentionItems([]), []);
  assert.deepEqual(attentionItems([alert("payout_failed", 3, { review: { note: "handled" } })]), []);
});

test("never more than three items", () => {
  const all = ["dispute_escalated", "payout_failed", "reports_urgent", "requests_unanswered", "promotion_review"].map((id) => alert(id, 1));
  assert.equal(attentionItems(all).length, 3);
});
