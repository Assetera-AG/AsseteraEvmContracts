// Fail a PR whose SQUASH COMMIT MESSAGE release-please would not be able to parse.
//
// Why this exists (2026-09-03): PR #88 merged, the release-please workflow ran, went GREEN, and released
// nothing. Its log said
//
//     commit could not be parsed: d1197279 Feat/AO 803 publish issuance venue sdk (#88)
//     error message: Error: unexpected token ' ' at 1:8, valid tokens [(, !, :]
//     Considering: 0 commits
//     No commits for path: packages/sdk, skipping
//
// The two branch commits were valid Conventional Commits and passed the commitlint hook. But this repo
// squashes with `COMMIT_OR_PR_TITLE` + `COMMIT_MESSAGES`, so as soon as a PR has MORE THAN ONE commit the
// squash title is the PR TITLE, which nothing checked. A commit release-please cannot parse is silently
// dropped from the release: the workflow exits 0, the change never reaches the changelog, no version is
// published. The only place left to catch it is the PR, while the title can still be edited.
//
// AsseteraUI has the same guard (scripts/check-commit-message.mjs there) after two incidents of its own.
// This is that guard adapted to THIS repo's squash settings, which differ in one way that matters:
//
//   AsseteraUI      squash body = PR DESCRIPTION            -> reconstruct from the PR body
//   EvmContracts    squash body = BRANCH COMMIT MESSAGES    -> reconstruct from `git log base..head`
//
// What GitHub composes here, observed on #88:
//
//   one commit    "<commit subject> (#N)\n\n<commit body>"
//   many commits  "<PR title> (#N)\n\n* <subject 1>\n\n<body 1>\n\n* <subject 2>\n\n<body 2>..."
//
// Both are rebuilt below and fed to @conventional-commits/parser, the parser release-please uses.
//
// Lessons carried over from AsseteraUI, both of which slipped past a naive check there:
//   - A fenced code block protects nothing. The parser reads the whole message as one document, so an
//     unbalanced "(" anywhere in the body rejects the commit.
//   - GitHub hard-wraps the description to 72 columns when it composes the squash body, and the wrap alone
//     can push a "(" token onto its own line and break the parse. Whether GitHub also re-wraps commit
//     bodies is not documented, so this check wraps them the same way before parsing. Commit bodies are
//     normally wrapped at 72 already, in which case the wrap is a no-op.
//
// Caveat: the message can still be edited by hand in the merge dialog after this check has passed. This
// narrows the window rather than sealing it.

import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

import { parser } from "@conventional-commits/parser";

// GitHub's wrap: greedy, 72 columns, per existing line, and a word longer than the limit is left to
// overflow rather than broken. Only lines over the limit are touched.
export const WRAP_COLUMNS = 72;

export function wrapLikeGitHub(text) {
  return text
    .split("\n")
    .map((line) => {
      if (line.length <= WRAP_COLUMNS) return line;

      const wrapped = [];
      let current = "";

      for (const word of line.split(" ")) {
        if (current === "") current = word;
        else if (`${current} ${word}`.length <= WRAP_COLUMNS) current += ` ${word}`;
        else {
          wrapped.push(current);
          current = word;
        }
      }

      if (current !== "") wrapped.push(current);
      return wrapped.join("\n");
    })
    .join("\n");
}

/**
 * The message GitHub composes for a squash merge under `COMMIT_OR_PR_TITLE` + `COMMIT_MESSAGES`.
 *
 * @param {{ prTitle: string, number: string, commits: { subject: string, body: string }[] }} pr
 */
export function buildSquashMessage({ prTitle, number = "0", commits }) {
  if (commits.length === 0) {
    throw new Error("no commits between base and head; nothing to squash");
  }

  const normalize = (s) => s.replace(/\r\n/g, "\n").trim();

  if (commits.length === 1) {
    const [{ subject, body }] = commits;
    return `${normalize(subject)} (#${number})\n\n${wrapLikeGitHub(normalize(body))}`;
  }

  const bullets = commits
    .map(({ subject, body }) => {
      const b = normalize(body);
      return b ? `* ${normalize(subject)}\n\n${b}` : `* ${normalize(subject)}`;
    })
    .join("\n\n");

  return `${normalize(prTitle)} (#${number})\n\n${wrapLikeGitHub(bullets)}`;
}

/** `{ ok: true, message }`, or `{ ok: false, message, error }` with the parser's own error. */
export function checkSquashMessage(pr) {
  const message = buildSquashMessage(pr);

  try {
    parser(message);
    return { ok: true, message };
  } catch (error) {
    return { ok: false, message, error };
  }
}

/** The PR's commits, oldest first, as GitHub lists them for the squash body. */
export function readCommits(baseSha, headSha) {
  const shas = execFileSync("git", ["rev-list", "--reverse", `${baseSha}..${headSha}`], {
    encoding: "utf8",
  })
    .split("\n")
    .filter(Boolean);

  return shas.map((sha) => ({
    sha,
    subject: execFileSync("git", ["show", "-s", "--format=%s", sha], { encoding: "utf8" }),
    body: execFileSync("git", ["show", "-s", "--format=%b", sha], { encoding: "utf8" }),
  }));
}

function main() {
  const prTitle = process.env.PR_TITLE ?? "";
  const number = process.env.PR_NUMBER ?? "0";
  const baseSha = process.env.BASE_SHA ?? "";
  const headSha = process.env.HEAD_SHA ?? "";

  if (!prTitle || !baseSha || !headSha) {
    console.error(
      "PR_TITLE, BASE_SHA and HEAD_SHA must all be set; the workflow is not passing the pull-request context through.",
    );
    process.exit(1);
  }

  const commits = readCommits(baseSha, headSha);
  const { ok, message, error } = checkSquashMessage({ prTitle, number, commits });

  const source =
    commits.length === 1
      ? "one commit, so the squash title is that commit's subject"
      : `${commits.length} commits, so the squash title is the PR TITLE`;

  if (ok) {
    console.log(`✔ the squash commit message parses (${source}); release-please will see this commit`);
    return;
  }

  const raw = String(error?.message ?? error);
  const detail = raw.replace(/\s*\n\s*/g, " ").trim();
  const at = /at (\d+):(\d+)/.exec(raw);
  const lines = message.split("\n");

  console.error("✖ release-please could NOT parse this PR's squash commit message.");
  console.error(`  ${detail}`);
  console.error(`  (${source})`);
  if (at) {
    const n = Number(at[1]);
    const column = Number(at[2]);
    const line = lines[n - 1] ?? "";

    console.error(`\n  line ${n}: ${JSON.stringify(line)}`);
    if (Number.isFinite(column) && column > 0) {
      console.error(`  ${" ".repeat(column + 9)}^ column ${column}`);
    }
    console.error(
      n === 1
        ? commits.length === 1
          ? "  (this is the commit subject; amend it and force-push)"
          : "  (this is the PR TITLE; edit it, no push needed, this check re-runs on edit)"
        : "  (this is in a branch commit body, wrapped at 72 columns as GitHub composes the squash body;\n" +
            "   reword that commit and force-push)",
    );
  }
  console.error(
    [
      "",
      "Line 1 must be a Conventional Commit header: `type(scope): subject`. With more than one commit",
      "on the branch GitHub takes the PR TITLE as that header, so a title like `Feat/AO-123 thing` is",
      "what breaks the release even when every branch commit is fine.",
      "",
      "Below line 1 the usual cause is an unbalanced parenthesis in a commit body. A fenced code block",
      "does NOT protect it; the parser reads the whole message as one document.",
      "",
      "If this is not fixed, the merge is silently dropped from the next release: the release-please",
      "workflow still succeeds, but the commit never reaches the changelog and no version is published.",
    ].join("\n"),
  );
  process.exit(1);
}

// Only act as a CLI when invoked directly, so the functions above can be unit-tested.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
