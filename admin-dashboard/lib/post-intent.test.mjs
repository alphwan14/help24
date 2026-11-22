// node --test lib/post-intent.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
  NUDGE_MINIMUM_SCORE,
  OFFER_HINTS,
  OFFER_PHRASES,
  REQUEST_HINTS,
  REQUEST_PHRASES,
  readPostIntent,
  suggestPostType,
} from "./post-intent.ts";

test("the minimum evidence is the app's", () => {
  const intent = readFileSync(new URL("../../mobile-app/lib/utils/post_intent.dart", import.meta.url), "utf8");
  const m = /const int kNudgeMinimumScore = (\d+);/.exec(intent);
  assert.ok(m, "kNudgeMinimumScore not found in post_intent.dart");
  assert.equal(NUDGE_MINIMUM_SCORE, Number(m[1]));
});

// The app's lists are the source; this file's copy must match them exactly.
const dart = readFileSync(new URL("../../mobile-app/lib/config/post_intent_phrases.dart", import.meta.url), "utf8");

function dartList(name) {
  const m = new RegExp(`const List<String> ${name} = \\[([\\s\\S]*?)\\];`).exec(dart);
  assert.ok(m, `${name} not found in post_intent_phrases.dart`);
  const body = m[1]
    .split("\n")
    .filter((line) => !line.trim().startsWith("//"))
    .join("\n");
  return [...body.matchAll(/'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)"/g)].map((x) => x[1] ?? x[2]);
}

test("the phrase lists are the app's, word for word and in order", () => {
  assert.deepEqual([...OFFER_PHRASES], dartList("kOfferPhrases"));
  assert.deepEqual([...OFFER_HINTS], dartList("kOfferHints"));
  assert.deepEqual([...REQUEST_PHRASES], dartList("kRequestPhrases"));
  assert.deepEqual([...REQUEST_HINTS], dartList("kRequestHints"));
});

// The same cases as mobile-app/test/post_intent_test.dart, so the console and
// the composer agree on real listings.
test("reads the listings that started it the way the app does", () => {
  assert.deepEqual(suggestPostType({ chosen: "request", title: "Edger here anyone in need of plumber" }), {
    type: "offer",
    evidence: ["anyone in need of"],
    strong: true,
  });
  assert.deepEqual(suggestPostType({ chosen: "request", title: "Help24 test I am a plumber please ignore" }), {
    type: "offer",
    evidence: ["i am a"],
    strong: true,
  });
  assert.equal(suggestPostType({ chosen: "request", title: "Am an experienced welder based in Mombasa" })?.type, "offer");
  assert.equal(suggestPostType({ chosen: "offer", title: "Looking for a plumber in Westlands" })?.type, "request");
});

test("anywhere in the title and description, any case, whole words only", () => {
  assert.equal(
    suggestPostType({ chosen: "request", title: "Plumbing", description: "WE OFFER repairs, call us!" })?.type,
    "offer",
  );
  assert.deepEqual(readPostIntent("Drama class for kids").offerPhrases, []);
  assert.deepEqual(readPostIntent("Kama sink imevuja").offerPhrases, []);
  assert.deepEqual(readPostIntent("anatafuta").requestPhrases, []);
  assert.deepEqual(readPostIntent("I’M A PLUMBER!!!").offerPhrases, ["i'm a"]);
});

test("strength and overlap: a phrase beats a hint, the longer phrase claims its words", () => {
  const r = readPostIntent("Natafuta fundi wa fridge");
  assert.equal(r.requestScore, 2);
  assert.equal(r.offerScore, 1);
  assert.equal(r.leaning, "request");
  assert.deepEqual(readPostIntent("anyone in need of a plumber").requestPhrases, []);
  assert.equal(readPostIntent("Natafuta kazi ya plumbing").leaning, "offer");
});

test("one weak word says nothing; two are listed but marked weak", () => {
  // A live request on 2026-11-17, with no description: a fundi advertising, or
  // a customer asking for one? Not enough to say anything.
  assert.equal(suggestPostType({ chosen: "request", title: "Fundi wa fridge" }), null);
  assert.equal(suggestPostType({ chosen: "offer", title: "Need a plumber" }), null);
  assert.deepEqual(suggestPostType({ chosen: "request", title: "Fundi wa stima, niko na experience" }), {
    type: "offer",
    evidence: ["fundi wa", "niko na"],
    strong: false,
  });
  assert.equal(suggestPostType({ chosen: "request", title: "Fundi wa stima, call me" })?.strong, true);
});

test("says nothing when the words agree, do not lean, or the listing is a job", () => {
  assert.equal(suggestPostType({ chosen: "offer", title: "I am a plumber" }), null);
  assert.equal(suggestPostType({ chosen: "request", title: "Kitchen sink repair" }), null);
  assert.equal(suggestPostType({ chosen: "request", title: "I am a mum looking for a nanny" }), null);
  assert.equal(suggestPostType({ chosen: "job", title: "I am a plumber" }), null);
});
