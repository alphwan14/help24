// node --test lib/start-early.test.mjs
//
// startEarly lets a page start its data read before the access check and read
// it only after. Two properties make that safe: a read discarded on the denial
// path must never surface as an unhandledRejection (Node would log it, or with
// --unhandled-rejections=throw, crash the request), and a read that IS awaited
// must still throw exactly the error it always did, so the page's own
// try/catch and notFound() handling are unchanged.
import assert from "node:assert/strict";
import { test } from "node:test";
import { setTimeout as tick } from "node:timers/promises";
import { startEarly } from "./start-early.ts";

class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

test("a read discarded on the denial path never becomes an unhandled rejection", async () => {
  const seen = [];
  const onUnhandled = (reason) => seen.push(reason);
  process.on("unhandledRejection", onUnhandled);
  try {
    // Shape of a page: start the read, deny access, return without reading it.
    const page = async () => {
      startEarly(Promise.reject(new ApiError(401, "Not connected to the arbitration backend.")));
      const admin = null;
      if (!admin) return "RestoringAccess";
      throw new Error("unreachable");
    };
    assert.equal(await page(), "RestoringAccess");
    await tick(20); // unhandledRejection fires after the microtask queue drains
  } finally {
    process.off("unhandledRejection", onUnhandled);
  }
  assert.deepEqual(seen, []);
});

test("an awaited read still throws the original error, untouched", async () => {
  const original = new ApiError(404, "Dispute not found.");
  const request = startEarly(Promise.reject(original));
  await assert.rejects(request, (err) => err === original && err.status === 404);
});

test("an awaited read resolves to the original value", async () => {
  const rows = [{ id: "d1" }];
  assert.equal(await startEarly(Promise.resolve(rows)), rows);
});

test("the read really is started before the access check completes", async () => {
  const order = [];
  const read = () => new Promise((resolve) => { order.push("read started"); setTimeout(() => resolve("data"), 5); });
  const check = () => new Promise((resolve) => { order.push("check started"); setTimeout(() => resolve({ id: "a1" }), 5); });

  const request = startEarly(read());
  const admin = await check();
  assert.ok(admin);
  assert.equal(await request, "data");
  assert.deepEqual(order, ["read started", "check started"]);
});
