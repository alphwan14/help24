// node --test lib/invite-acceptance.test.mjs   (Node ≥ 22.18: the .ts module loads through type stripping)
//
// The decisions in accepting an invitation, against recorded effects. The same
// flow runs in a real browser in e2e/run.mjs.
import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { INVITE_ERRORS, acceptInvitation, inviteErrorMessage, isCompletedInvite, validateInviteForm } from "./invite-acceptance.ts";

const INVITED = "dave@help24.co.ke";
const PASSWORD = "Dave-initial-1";
const form = (over = {}) => ({
  token: "invite-token",
  name: "Dave Otieno",
  password: PASSWORD,
  confirm: PASSWORD,
  claimedEmail: INVITED,
  ...over,
});
const apiError = (status, message) => Object.assign(new Error(message), { status, message });
const COMPLETED = apiError(410, "This invitation has already been completed.");

/**
 * Effects that record every call. By default: provisioning succeeds for the
 * invited address, the password signs in, and the credential is a linked admin.
 */
function effects({ provision, signIn, isAdmin = true } = {}) {
  const calls = [];
  const fx = {
    async provision(input) {
      calls.push(["provision", input]);
      if (provision) return provision(input);
      return { email: INVITED, arbitrationToken: "arb-token" };
    },
    async signIn(email, password) {
      calls.push(["signIn", email]);
      if (signIn) return signIn(email, password);
      return email === INVITED && password === PASSWORD ? { userId: "dave-auth-id" } : null;
    },
    async isDashboardAdmin(userId) {
      calls.push(["isDashboardAdmin", userId]);
      if (isAdmin instanceof Error) throw isAdmin;
      return isAdmin;
    },
    async signOut() {
      calls.push(["signOut"]);
    },
    async storeArbitrationToken(token) {
      calls.push(["storeArbitrationToken", token]);
    },
  };
  return { fx, calls, names: () => calls.map((c) => c[0]) };
}

describe("validation, before anything is sent", () => {
  for (const [name, over, message] of [
    ["a missing token", { token: "  " }, "missing-token"],
    ["a missing name", { name: " J " }, "name"],
    ["a short password", { password: "short", confirm: "short" }, "password-short"],
    ["a mismatched confirmation", { confirm: PASSWORD + "!" }, "password-mismatch"],
  ]) {
    test(`${name} is refused locally`, async () => {
      const e = effects();
      assert.equal(validateInviteForm(form(over)), message);
      assert.deepEqual(await acceptInvitation(form(over), e.fx), { kind: "error", code: message });
      assert.deepEqual(e.calls, []);
    });
  }
});

describe("a fresh, valid invitation", () => {
  test("provisions, signs in as the BACKEND's address, pre-connects arbitration, goes to the dashboard", async () => {
    const e = effects();
    const outcome = await acceptInvitation(form(), e.fx);
    assert.deepEqual(outcome, { kind: "dashboard" });
    assert.deepEqual(e.calls, [
      ["provision", { token: "invite-token", name: "Dave Otieno", password: PASSWORD }],
      ["signIn", INVITED],
      ["isDashboardAdmin", "dave-auth-id"],
      ["storeArbitrationToken", "arb-token"],
    ]);
  });

  test("the address typed into the page plays no part in a first acceptance", async () => {
    const e = effects();
    const outcome = await acceptInvitation(form({ claimedEmail: "mallory@evil.test" }), e.fx);
    assert.deepEqual(outcome, { kind: "dashboard" });
    assert.ok(!e.calls.some(([n, arg]) => n === "signIn" && arg !== INVITED));
  });

  test("an invitee not yet linked to an admin identity is signed back out and told it is pending", async () => {
    const e = effects({ isAdmin: false });
    assert.deepEqual(await acceptInvitation(form(), e.fx), { kind: "pending-activation" });
    assert.deepEqual(e.names().slice(-2), ["isDashboardAdmin", "signOut"]);
    assert.ok(!e.names().includes("storeArbitrationToken"), "no arbitration token for someone who cannot open the dashboard");
  });

  test("an identity check that fails is treated as not-an-admin (fail closed)", async () => {
    const e = effects({ isAdmin: new Error("service key missing") });
    assert.deepEqual(await acceptInvitation(form(), e.fx), { kind: "pending-activation" });
  });

  test("provisioned but the sign-in did not work: send them to sign in, never claim failure", async () => {
    for (const signIn of [() => null, () => { throw new TypeError("fetch failed"); }]) {
      const e = effects({ signIn });
      assert.deepEqual(await acceptInvitation(form(), e.fx), { kind: "sign-in" });
      assert.ok(!e.names().includes("storeArbitrationToken"));
    }
  });
});

describe("invitations that cannot be accepted", () => {
  for (const [name, err, message] of [
    ["an expired invitation", apiError(410, "This invitation has expired."), "invitation"],
    ["an unknown token", apiError(404, "Invite not found."), "invitation"],
    ["details the backend refuses", apiError(400, "Please provide your full name."), "rejected"],
    ["a backend that cannot be reached", apiError(503, "Cannot reach the arbitration backend."), "unavailable"],
    ["an unexpected failure", new TypeError("boom"), "unexpected"],
  ]) {
    test(`${name}: an error on the form, and no sign-in attempted`, async () => {
      const e = effects({ provision: () => { throw err; } });
      assert.deepEqual(await acceptInvitation(form(), e.fx), { kind: "error", code: message });
      assert.deepEqual(e.names(), ["provision"]);
    });
  }

  test("only the backend's 'already completed' counts as completed", () => {
    assert.equal(isCompletedInvite(COMPLETED), true);
    assert.equal(isCompletedInvite(apiError(410, "This invitation has expired.")), false);
    assert.equal(isCompletedInvite(apiError(404, "Invite not found.")), false);
    assert.equal(isCompletedInvite(null), false);
  });
});

describe("retrying an acceptance that already went through", () => {
  test("with the password that was set: signed in and taken to the dashboard", async () => {
    const e = effects({ provision: () => { throw COMPLETED; } });
    assert.deepEqual(await acceptInvitation(form(), e.fx), { kind: "dashboard" });
    assert.deepEqual(e.names(), ["provision", "signIn", "isDashboardAdmin"]);
    assert.ok(!e.names().includes("storeArbitrationToken"), "no token to store — the shell restores one");
  });

  test("with a different password: an honest 'already used', and no session", async () => {
    const e = effects({ provision: () => { throw COMPLETED; } });
    const outcome = await acceptInvitation(form({ password: "Not-the-one-9", confirm: "Not-the-one-9" }), e.fx);
    assert.deepEqual(outcome, { kind: "error", code: "already-used" });
    assert.match(INVITE_ERRORS["already-used"], /already been used.*sign in/);
    assert.deepEqual(e.names(), ["provision", "signIn"]);
  });

  test("a used invitation with no address to try still gets the honest message", async () => {
    const e = effects({ provision: () => { throw COMPLETED; } });
    const outcome = await acceptInvitation(form({ claimedEmail: "" }), e.fx);
    assert.deepEqual(outcome, { kind: "error", code: "already-used" });
    assert.deepEqual(e.names(), ["provision"]);
  });

  test("a retry that signs in an unlinked credential is still pending, not admitted", async () => {
    const e = effects({ provision: () => { throw COMPLETED; }, isAdmin: false });
    assert.deepEqual(await acceptInvitation(form(), e.fx), { kind: "pending-activation" });
    assert.equal(e.names().at(-1), "signOut");
  });

  test("a double submit: both resolve to the dashboard, and only the first provisions anything", async () => {
    let consumed = false;
    const provisioned = [];
    const e = effects({
      provision: (input) => {
        if (consumed) throw COMPLETED;
        consumed = true;
        provisioned.push(input.token);
        return { email: INVITED, arbitrationToken: "arb-token" };
      },
    });
    const [first, second] = await Promise.all([acceptInvitation(form(), e.fx), acceptInvitation(form(), e.fx)]);
    assert.deepEqual([first, second], [{ kind: "dashboard" }, { kind: "dashboard" }]);
    assert.deepEqual(provisioned, ["invite-token"]);
  });
});

test("no outcome ever carries the password or the arbitration token", async () => {
  const runs = [
    effects(),
    effects({ isAdmin: false }),
    effects({ signIn: () => null }),
    effects({ provision: () => { throw COMPLETED; } }),
    effects({ provision: () => { throw apiError(410, "This invitation has expired."); } }),
  ];
  for (const e of runs) {
    const shown = JSON.stringify(await acceptInvitation(form(), e.fx));
    assert.ok(!shown.includes(PASSWORD) && !shown.includes("arb-token"), shown);
  }
});

test("an error travels as a code from a fixed list — nothing typed into the URL reaches the page", () => {
  assert.equal(inviteErrorMessage("password-mismatch"), "Passwords do not match.");
  for (const hostile of [null, undefined, "", "Call +254700000000 to verify", "__proto__", "constructor", "toString"]) {
    assert.equal(inviteErrorMessage(hostile), null, String(hostile));
  }
});
