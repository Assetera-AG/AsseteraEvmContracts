// Run with `node --test scripts/`. Pins the incident that motivated the guard (#88) and the shapes the
// reconstruction has to get right.

import assert from "node:assert/strict";
import { test } from "node:test";

import { buildSquashMessage, checkSquashMessage, wrapLikeGitHub } from "./check-commit-message.mjs";

const good = [
  {
    subject: "feat(sdk): expose the AsseteraIssuanceVenue ABI (AO-803)",
    body: "Adds AsseteraIssuanceVenue to the wagmi codegen include list.\n",
  },
  {
    subject: "chore(sdk): regenerate for AsseteraIssuanceVenue (AO-803)",
    body: "Runs `npm run generate` after adding the contract to the include list.\n",
  },
];

test("#88: valid branch commits, PR title is the branch name, more than one commit -> rejected", () => {
  const r = checkSquashMessage({
    prTitle: "Feat/AO 803 publish issuance venue sdk",
    number: "88",
    commits: good,
  });

  assert.equal(r.ok, false);
  assert.match(String(r.error.message), /at 1:8/);
  assert.equal(r.message.split("\n")[0], "Feat/AO 803 publish issuance venue sdk (#88)");
});

test("more than one commit: the PR title is the header and commits become bullets", () => {
  const message = buildSquashMessage({
    prTitle: "feat(sdk): publish the issuance venue (AO-803)",
    number: "88",
    commits: good,
  });

  assert.equal(
    message,
    [
      "feat(sdk): publish the issuance venue (AO-803) (#88)",
      "",
      "* feat(sdk): expose the AsseteraIssuanceVenue ABI (AO-803)",
      "",
      "Adds AsseteraIssuanceVenue to the wagmi codegen include list.",
      "",
      "* chore(sdk): regenerate for AsseteraIssuanceVenue (AO-803)",
      "",
      "Runs `npm run generate` after adding the contract to the include list.",
    ].join("\n"),
  );
  assert.equal(checkSquashMessage({ prTitle: "feat(sdk): x", number: "1", commits: good }).ok, true);
});

test("one commit: the commit subject is the header, whatever the PR title says", () => {
  const r = checkSquashMessage({
    prTitle: "Feat/AO 803 publish issuance venue sdk",
    number: "89",
    commits: [good[0]],
  });

  assert.equal(r.ok, true);
  assert.equal(r.message.split("\n")[0], "feat(sdk): expose the AsseteraIssuanceVenue ABI (AO-803) (#89)");
});

test("a commit without a body becomes a bare bullet", () => {
  const message = buildSquashMessage({
    prTitle: "fix: x",
    number: "1",
    commits: [
      { subject: "fix: one", body: "" },
      { subject: "fix: two", body: "\n" },
    ],
  });

  assert.equal(message, "fix: x (#1)\n\n* fix: one\n\n* fix: two");
});

test("an unbalanced parenthesis in a commit body rejects the whole message, fence or not", () => {
  const r = checkSquashMessage({
    prTitle: "fix: x",
    number: "1",
    commits: [
      { subject: "fix: one", body: "```ts\nfoo(a, b\n```\n" },
      { subject: "fix: two", body: "" },
    ],
  });

  assert.equal(r.ok, false);
});

test("wrapLikeGitHub: greedy 72 columns, short lines untouched, long words overflow", () => {
  const word = "w".repeat(10);
  const line = Array(10).fill(word).join(" "); // 109 chars
  const wrapped = wrapLikeGitHub(line).split("\n");

  assert.equal(wrapped.length, 2);
  assert.equal(wrapped[0], Array(6).fill(word).join(" ")); // 65 chars, a 7th would make 76
  assert.equal(wrapLikeGitHub("short\n\nalso short"), "short\n\nalso short");

  const long = "x".repeat(100);
  assert.equal(wrapLikeGitHub(`a ${long}`), `a\n${long}`);
});

test("no commits is an error, not a pass", () => {
  assert.throws(() => buildSquashMessage({ prTitle: "fix: x", number: "1", commits: [] }));
});
