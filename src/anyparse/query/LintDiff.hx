package anyparse.query;

import anyparse.query.format.json.LintFindingJson;
import anyparse.query.format.json.LintReportJson;
import anyparse.query.format.json.LintReportJsonParser;
import haxe.Exception;

using StringTools;

/**
 * `apq lint-diff` — compare two `apq lint --format json --all` snapshots as
 * MULTISETS of `(file, rule, severity, message)` keys.
 *
 * This is the blast-radius gate every slice ends with, and the reason it is a
 * multiset over four fields rather than a text diff is that the two obvious
 * cheaper answers both lie:
 *
 *  - A byte diff of the two reports reports half the tree. Line and column
 *    move under any edit above them, so a one-line insertion re-keys every
 *    finding below it. `line`, `col` and `address` are therefore not part of
 *    the key at all — and `LintFindingJson` does not even model them.
 *  - Keying on the raw fields is not enough either, because two of them are
 *    not stable under changes that are not findings. Both normalizations
 *    below come from a false positive observed on real snapshots, not from
 *    anticipation, and each has its own test.
 *
 * Normalization 1 — PATHS. A snapshot taken with a relative scope argument
 * (`apq lint src test`) records relative paths; one taken with an absolute
 * argument records absolute ones, and a `./src` scope records a third spelling
 * again. On two runs whose 2954 findings were otherwise identical, a literal
 * comparison reported 1812 added and 1812 removed; a `./src`-against-`src`
 * pair disagreed on 269 of 468. `--root <prefix>` strips the prefix from whichever side carries it —
 * from the `file` field AND from the paths a message quotes, since
 * `duplicate-code` names its partner block by path — so a relative and an
 * absolute snapshot of the same tree compare equal.
 *
 * Normalization 2 — the MEASUREMENTS a message quotes, and the checks own it.
 * A rule that writes a source coordinate into its own prose re-keys on an edit
 * that changed no finding: `duplicate-code` names its partner block
 * `<path>:<line>`, `unused-local` the re-declaration that took a binding over,
 * `oversized-type` the type's line extent. The last one made the gate cry wolf
 * on exactly the work this project does — a writer slice moved four types by a
 * few lines each (`WrapList` 4184 -> 4194, plus `WriterLowering` / `Cli` /
 * `SymbolIndex`) and the gate printed eight moves against total findings 2256
 * versus a base of 2256. Waiving it became reflex, and a gate waived by reflex
 * has stopped being a gate.
 *
 * So a check declares its own volatile parts (`Check.VolatileMessage`) and
 * `identities` — built by `Linter.messageIdentities` — maps rule id to that
 * declaration. This module holds NO list of rules: a new rule that quotes a
 * coordinate joins by writing one method on itself, and nothing here changes.
 * The list it replaced was two ids long and could say only "mask every digit in
 * this rule's messages", which is both too coarse (it ate `duplicate-code`'s
 * statement count and any digit in a partner filename — 57% of that rule's
 * findings on anyparse and 78% on tm shared a key with a sibling, and a
 * substitution inside such a group was invisible) and unable to express the
 * oversized-type case at all, where one number in the message drifts and the
 * one beside it IS the finding.
 *
 * What is still deliberately NOT normalized: `string-literal-dup`'s repetition
 * count, `complexity`'s score, `anon-type-dup`'s occurrence tally,
 * `oversized-type`'s MEMBER count. Those digits move only when the code moves,
 * so a file crossing from 50 to 51 members reports one added and one removed,
 * and that is the gate working rather than noise. Masking them would turn the
 * gate off for the movement it exists to catch — which is the failure mode to
 * watch for in any future `VolatileMessage`.
 *
 * Everything here is pure — the CLI layer reads the files, builds the identity
 * map, calls `parseReport` / `tally` / `compare` / `render` and prints. That
 * split is what lets the suite test both normalizations directly rather than
 * through a process.
 */
@:nullSafety(Strict)
final class LintDiff {

	/**
	 * Print order for the severity breakdown, most severe first. A severity
	 * outside this list still prints — after these, alphabetically — rather
	 * than being dropped, so a new severity cannot silently vanish from the
	 * breakdown while still counting in the totals.
	 */
	private static final SEVERITY_ORDER: Array<String> = ['error', 'warning', 'info'];

	/**
	 * Read an `apq lint --format json` snapshot into its records.
	 *
	 * The report is a bare top-level JSON array and the ByName lowering
	 * cannot root on one, so the text is wrapped into the `LintReportJson`
	 * envelope first — see that typedef for the measured constraint. The
	 * leading-`[` check is the cheap sanity gate on that wrap: it turns an
	 * object or a fragment into a message naming the real problem instead of a
	 * parse error about a key nobody wrote. It is NOT a validation of the whole
	 * document — text that opens with a well-formed array and then carries a
	 * second `"findings"` key satisfies the check and wins the duplicate. Every
	 * other malformation the parser catches (trailing garbage, a truncated
	 * array, two arrays); the realistic trigger for that one is a
	 * half-overwritten cache file, which shows up as a one-sided wipe rather
	 * than a quiet zero.
	 */
	public static function parseReport(raw: String): Array<LintFindingJson> {
		final trimmed: String = raw.trim();
		if (!trimmed.startsWith('[')) {
			throw new Exception('not an `apq lint --format json` report — expected a top-level JSON array');
		}
		final report: LintReportJson = LintReportJsonParser.parse('{"findings":$trimmed}');
		return report.findings;
	}

	/**
	 * Fold a report into a multiset: how many times each normalized
	 * `(file, rule, severity, message)` key occurs, plus the first record seen
	 * for each key so the renderer can print a readable example.
	 *
	 * `order` preserves first-appearance order, which is document order in
	 * the report — so the examples a run prints are stable across runs and
	 * two invocations on the same inputs produce byte-identical output.
	 */
	public static function tally(findings: Array<LintFindingJson>, root: String, identities: LintMessageIdentities): LintDiffTally {
		final counts: Map<String, Int> = [];
		final rows: Map<String, LintDiffRow> = [];
		final order: Array<String> = [];
		for (f in findings) {
			final file: String = normalizePath(f.file, root);
			final message: String = normalizeMessage(f.rule, f.message, root, identities);
			final key: String = keyOf(file, f.rule, f.severity, message);
			final seen: Null<Int> = counts[key];
			if (seen == null) {
				order.push(key);
				rows[key] = {
					file: file,
					rule: f.rule,
					message: message,
					severity: f.severity
				};
				counts[key] = 1;
			} else
				counts[key] = seen + 1;
		}
		return {
			total: findings.length,
			order: order,
			counts: counts,
			rows: rows
		};
	}

	/**
	 * Multiset difference in both directions.
	 *
	 * A key present three times before and five times after contributes 2 to
	 * `added` and nothing to `removed` — counting keys rather than occurrences
	 * would report that pair as unchanged, and duplicated findings inside one
	 * file are exactly where a regression hides.
	 */
	public static function compare(before: LintDiffTally, after: LintDiffTally): LintDiffResult {
		final added: Array<LintDiffEntry> = surplus(after, before);
		final removed: Array<LintDiffEntry> = surplus(before, after);
		var addedTotal: Int = 0;
		var removedTotal: Int = 0;
		for (e in added) addedTotal += e.count;
		for (e in removed) removedTotal += e.count;
		return {
			oldTotal: before.total,
			newTotal: after.total,
			added: added,
			removed: removed,
			addedTotal: addedTotal,
			removedTotal: removedTotal,
			severities: severityDeltas(added, removed)
		};
	}

	/**
	 * Render the verdict as plain lines, most-summary first: one headline
	 * always, then — only when something actually moved — the severity
	 * breakdown the ratchets are scoped by, then up to `limit` example keys
	 * per sign (`limit < 0` prints every one).
	 *
	 * A clean run is deliberately ONE line per tree: the battery prints this
	 * twice on every slice, and a breakdown of zeros would train the reader
	 * to skip the block that matters.
	 */
	public static function render(result: LintDiffResult, label: String, limit: Int): Array<String> {
		final tag: String = label == '' ? 'lint-diff' : 'lint-diff $label';
		final lines: Array<String> = [
			'$tag: ${result.newTotal} findings (base ${result.oldTotal}) — ${result.addedTotal} added / ${result.removedTotal} removed'
		];
		if (result.addedTotal == 0 && result.removedTotal == 0) return lines;
		final parts: Array<String> = [for (s in result.severities) '${s.severity} +${s.added} -${s.removed}'];
		if (parts.length > 0) lines.push('  by severity  ${parts.join('   ')}');
		pushExamples(lines, '+', 'added', result.added, limit);
		pushExamples(lines, '-', 'removed', result.removed, limit);
		return lines;
	}

	/**
	 * Strip `root` (and any leading `./`) from a report path.
	 *
	 * Applied to BOTH sides, which is what makes the relative/absolute pair
	 * compare equal: the side that does not carry the prefix is left alone,
	 * so passing a root is safe even when neither snapshot needs it. A
	 * trailing slash on `root` is tolerated — it is what a shell `$PWD/`
	 * or a tab-completed directory produces.
	 */
	public static function normalizePath(file: String, root: String): String {
		return normalizePathText(file, rootPrefix(root));
	}

	/**
	 * Normalize a finding's message for keying: apply the SAME path normalization to
	 * every path the message quotes, then hand the result to the rule's OWN
	 * `messageIdentity` when it declared one.
	 *
	 * The rule lookup is a map, not a branch: `lint-diff` never learns a rule id, and
	 * a rule with no declaration passes through byte-identical — the state of every
	 * builtin but three.
	 *
	 * The path work is not a `file`-field concern that leaked in here. A check
	 * pointing at a SECOND location spells it in the message — `duplicate-code`
	 * names its partner block `<path>:<line>` — and that path is recorded
	 * exactly as the scope argument was written, so it carries every spelling
	 * the `file` field carries. Both were measured on real snapshots: an
	 * absolute-against-relative pair disagreed on 590 of 2954 findings with only
	 * the file field normalized, and a `./src`-against-`src` pair on 269 of 468.
	 * Whatever the file field forgives, the message has to forgive too, or
	 * `--root` is true by half.
	 */
	public static function normalizeMessage(rule: String, message: String, root: String, identities: LintMessageIdentities): String {
		final rooted: String = normalizeQuotedPaths(message, rootPrefix(root));
		final identity: Null<(String) -> String> = identities[rule];
		return identity == null ? rooted : identity(rooted);
	}

	/**
	 * Build the multiset key for one finding.
	 *
	 * The leading fields are LENGTH-PREFIXED rather than joined by a separator
	 * character: a separator has to be a character none of the fields can
	 * contain, and a lint message is free prose written by a check author, so
	 * no such character can be promised. `<len>:<text>` is self-delimiting, so
	 * the encoding is injective for arbitrary prose — including prose full of
	 * colons and digits — and the delimiters stay ASCII, which keeps the key
	 * readable when it shows up in a failing assertion.
	 *
	 * `severity` is part of the key even though it is not part of what a reader
	 * calls "the finding". A rule that keeps its message and changes severity
	 * has moved the blast radius — the project has done exactly that once,
	 * capping a `guarded import` advisory from warning to info — and the render
	 * publishes a per-severity breakdown, so leaving severity out would let a
	 * flip pass as a clean, exit-0 run while the number the reader is watching
	 * changed underneath.
	 */
	public static function keyOf(file: String, rule: String, severity: String, message: String): String {
		return '${file.length}:$file${rule.length}:$rule${severity.length}:$severity$message';
	}

	/**
	 * `root` reduced to the exact prefix a path in this tree carries: trailing
	 * slashes dropped, empty when there is nothing to strip. Shared by the path
	 * and the message normalization so the two can never disagree about what
	 * the root is.
	 */
	private static function rootPrefix(root: String): String {
		var prefix: String = root;
		while (prefix.endsWith('/')) prefix = prefix.substr(0, prefix.length - 1);
		return prefix;
	}

	/**
	 * One path spelling reduced to the canonical one: a leading `prefix/`
	 * dropped, then any `./` the scope argument left in front. The single place
	 * both the `file` field and the paths quoted inside a message go through, so
	 * the two cannot drift into normalizing different amounts — which is exactly
	 * how the `./` half of this was missed the first time.
	 */
	private static function normalizePathText(path: String, prefix: String): String {
		var out: String = path;
		if (prefix != '' && out.startsWith('$prefix/')) out = out.substr(prefix.length + 1);
		while (out.startsWith('./')) out = out.substr(2);
		return out;
	}

	/**
	 * `normalizePathText` applied to the paths a free-prose message quotes.
	 *
	 * A quoted path starts at the message start or after a space — that is how
	 * every check naming a second file writes one — so the `./` strip is
	 * anchored there rather than run over the whole string. Anchoring is what
	 * keeps a `../` segment whole and leaves ordinary prose containing a dot
	 * alone; under-reaching on an exotic spelling costs a false finding, while
	 * over-reaching would silently merge two different findings onto one key.
	 */
	private static function normalizeQuotedPaths(message: String, prefix: String): String {
		var out: String = prefix == '' ? message : message.replace('$prefix/', '');
		while (out.startsWith('./')) out = out.substr(2);
		while (out.indexOf(' ./') >= 0) out = out.replace(' ./', ' ');
		return out;
	}

	/** Add one surplus list's occurrence counts into `into`, recording each new severity in `names`. */
	private static function accumulate(entries: Array<LintDiffEntry>, into: Map<String, Int>, names: Array<String>): Void {
		for (e in entries) {
			into[e.severity] = (into[e.severity] ?? 0) + e.count;
			if (!names.contains(e.severity)) names.push(e.severity);
		}
	}

	/** Keys occurring more often in `a` than in `b`, in `a`'s document order. */
	private static function surplus(a: LintDiffTally, b: LintDiffTally): Array<LintDiffEntry> {
		final out: Array<LintDiffEntry> = [];
		for (key in a.order) {
			final mine: Int = a.counts[key] ?? 0;
			final theirs: Int = b.counts[key] ?? 0;
			if (mine <= theirs) continue;
			// `tally` pushes the key and writes its row in one breath, so a key in
			// `order` always has one. Throwing rather than skipping is the point:
			// a dropped surplus UNDERSTATES the blast radius, which is the single
			// failure this whole tool exists to prevent.
			final row: Null<LintDiffRow> = a.rows[key];
			if (row == null) throw new Exception('lint-diff: tally invariant broken — no row for a key in document order');
			out.push({
				file: row.file,
				rule: row.rule,
				message: row.message,
				severity: row.severity,
				count: mine - theirs
			});
		}
		return out;
	}

	/** Per-severity totals over both surplus lists, in `SEVERITY_ORDER`. */
	private static function severityDeltas(added: Array<LintDiffEntry>, removed: Array<LintDiffEntry>): Array<LintDiffSeverityDelta> {
		final names: Array<String> = [];
		final addedBy: Map<String, Int> = [];
		final removedBy: Map<String, Int> = [];
		accumulate(added, addedBy, names);
		accumulate(removed, removedBy, names);
		names.sort(compareSeverity);
		return [
			for (n in names) { severity: n, added: addedBy[n] ?? 0, removed: removedBy[n] ?? 0 }
		];
	}

	/** `SEVERITY_ORDER` rank first, unknown names after all known ones, then alphabetical. */
	private static function compareSeverity(a: String, b: String): Int {
		final ra: Int = SEVERITY_ORDER.indexOf(a);
		final rb: Int = SEVERITY_ORDER.indexOf(b);
		final ka: Int = ra < 0 ? SEVERITY_ORDER.length : ra;
		final kb: Int = rb < 0 ? SEVERITY_ORDER.length : rb;
		return if (ka != kb)
			ka - kb
		else if (a < b)
			-1
		else
			(a > b ? 1 : 0);
	}

	/** Append up to `limit` example lines for one sign, plus an elision note. */
	private static function pushExamples(
		lines: Array<String>, sign: String, word: String, entries: Array<LintDiffEntry>, limit: Int
	): Void {
		final cap: Int = limit < 0 || limit > entries.length ? entries.length : limit;
		for (i in 0...cap) {
			final e: LintDiffEntry = entries[i];
			final multiplicity: String = e.count > 1 ? ' (x${e.count})' : '';
			lines.push('  $sign ${e.file}  ${e.rule}  ${e.message}$multiplicity');
		}
		final rest: Int = entries.length - cap;
		if (rest > 0) lines.push('  … $rest more $word key(s) not shown — raise --limit');
	}

}

/**
 * Rule id -> the check's own `messageIdentity`, as `Linter.messageIdentities` builds it by
 * asking the registry which of its checks declare a `Check.VolatileMessage`.
 *
 * Passed in rather than looked up here for a dependency reason, not a testing one: `LintDiff`
 * lives in `anyparse.query` and the registry in `anyparse.check`, so looking it up would drag
 * every builtin check into every consumer of the query module. The suite exercises the REAL
 * registry through this parameter (no stub exists — all three call sites pass the same
 * expression). It is required rather than defaulted for the reason `--root` is not: a caller
 * that forgot it would get a gate reporting movement nothing made, silently.
 */
typedef LintMessageIdentities = Map<String, (String) -> String>;

/** The readable half of a tallied key: what to print as an example. */
typedef LintDiffRow = {

	var file: String;

	var rule: String;

	var message: String;

	var severity: String;
};

/** One report folded into a multiset of normalized keys. */
typedef LintDiffTally = {

	/** Records in the report, BEFORE de-duplication into keys. */
	var total: Int;

	/** Distinct keys in first-appearance (document) order. */
	var order: Array<String>;

	/** Key -> how many records share it. */
	var counts: Map<String, Int>;

	/** Key -> the first record seen under it. */
	var rows: Map<String, LintDiffRow>;
};

/** A key that occurs more often on one side, with the surplus count. */
typedef LintDiffEntry = {

	var file: String;

	var rule: String;

	var message: String;

	var severity: String;

	/** How many occurrences the other side is missing. */
	var count: Int;
};

/** Added/removed occurrence counts for one severity. */
typedef LintDiffSeverityDelta = {

	var severity: String;

	var added: Int;

	var removed: Int;
};

/** The whole verdict: totals, both surplus lists and the severity breakdown. */
typedef LintDiffResult = {

	var oldTotal: Int;

	var newTotal: Int;

	var added: Array<LintDiffEntry>;

	var removed: Array<LintDiffEntry>;

	var addedTotal: Int;

	var removedTotal: Int;

	var severities: Array<LintDiffSeverityDelta>;
};
