// node --test lib/contact-links.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { internationalDigits, mailtoHref, telHref, whatsappHref } from "./contact-links.ts";

test("Kenyan numbers in every form people type them become 254…", () => {
  for (const typed of ["0712 345 678", "+254 712 345 678", "254712345678", "712345678", "(0712) 345-678"]) {
    assert.equal(internationalDigits(typed), "254712345678", typed);
  }
  assert.equal(internationalDigits("0110 123 456"), "254110123456");
});

test("other countries are kept as typed; undiallable numbers get no link", () => {
  assert.equal(internationalDigits("+44 20 7946 0958"), "442079460958");
  assert.equal(internationalDigits("12345"), null);
  assert.equal(internationalDigits(""), null);
  assert.equal(whatsappHref(null), null);
});

test("links", () => {
  assert.equal(telHref("0712345678"), "tel:+254712345678");
  assert.equal(whatsappHref("0712345678"), "https://wa.me/254712345678");
  assert.equal(mailtoHref(" a@b.co "), "mailto:a@b.co");
  assert.equal(mailtoHref("not-an-email"), null);
});
