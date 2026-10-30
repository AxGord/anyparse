# Lint

Running the checks, fixing, suppressing and reporting. The project configuration is in [lint-config.md](lint-config.md); every rule by category in the [rule index](../lint-rules.md), its prose in [lint/](lint/).

`lint <scope> [--rule <id>] [--fix]` runs grammar-agnostic checks and reports violations
grouped by file; `--fix` applies the auto-fixable subset (re-parse-validated like every
rewrite), iterating to a fixed point so a fix that exposes another finding — a deleted
dead-code run leaving a local unused, a de-nested `else` revealing the next — is resolved
in the same run. A check is a plugin — a new one is a new class, not a core change.

A finding whose span sits inside a `macro …` QUOTATION is dropped, for every rule at once — source written there is the AST the surrounding program builds, not code the file runs, so a rewrite that is equivalent anywhere else silently hands the macro different data (`macro switch x { case A \| B: … }` reifies its label as one `EBinop(OpOr, …)` value where `case A, B:` reifies as two; `default:` reifies as `ESwitch.edef` where `case _:` becomes another entry of `cases`), and a report-only finding there is un-actionable besides. The drop is enforced centrally — at `Linter.run`, at the `RiskyFix` verifier, and at the oracle-assisted batch, the three points a check's own findings enter the pipeline — so it covers rules not yet written; the compiler oracle cannot stand in for it, since an edited quotation still typechecks. A check that analyses quotations AS DATA, or whose rewrite is proven to build the same program inside one, opts out with the `QuotationAware` marker — `redundant-parens` is the one builtin that does (a pair in a delimited slot reifies as `EParenthesis`, which types transparently; its class doc lists the gates for the shapes that do not).

Findings are suppressible inline: a trailing `// noqa` (or `// noqa: <rule>,<rule>` for
named rules) clears any finding whose source span covers its line — so a directive the
writer reflowed onto a continuation line still lands — and `// CHECKSTYLE:OFF` …
`// CHECKSTYLE:ON` clears a region (matching the finding's reported line) — so one stubborn false positive never makes a rule unusable. `--fail-on
<error|warning|info>` exits non-zero when a finding at or above that severity survives
(default: report-only, exit 0), and `--format <text|json|checkstyle>` switches the
output — checkstyle XML the same CI tooling that reads `checkstyle.json` can ingest.
A TEXT report that would list more findings than the top-level `"reportSummaryThreshold"`
(default 200, `0` = never) prints a per-rule summary instead — count, severity and top
files per rule, most findings first; one rule gets its top files one per line — and a
stderr line naming the ways to the full list: `--full` (always list), `--rule <id>` or a
smaller scope, `--format json` (json and checkstyle always list). `--summary` forces the
summary.
`--list-rules` prints every registered check as `id  description` (the rules by
category: [`docs/lint-rules.md`](../lint-rules.md)), one per line, in
registration order and exits — the machine-consumable listing (review tooling
subtracts linter-owned rules from manual checklists by it; the rule pages under
[`lint/`](lint/) are the prose counterpart).
