package anyparse.query;

import anyparse.query.format.json.LintFindingJson;
import anyparse.query.format.json.LintReportJson;
import anyparse.query.format.json.LintReportJsonParser;
import haxe.Exception;

using StringTools;

/**
 * `apq lint-diff` — compare two `apq lint --format json --all` snapshots as MULTISETS of
 * `(file, rule, severity, message)` keys. The blast-radius gate every slice ends with.
 *
 * Four fields rather than a text diff, because the cheaper answers lie. A byte diff reports
 * half the tree: line and column move under any edit above them, so a one-line insertion
 * re-keys every finding below it — `line`, `col` and `address` are not part of the key at all,
 * and `LintFindingJson` does not model them. Keying on the raw fields is not enough either,
 * because two of them are not stable under changes that are not findings.
 *
 * NORMALIZATION 1 — PATHS. A relative scope argument records relative paths, an absolute one
 * absolute paths, and a `./src` scope a third spelling again, so a literal comparison reports
 * most of the tree twice over. `--root <prefix>` strips the prefix from whichever side carries
 * it — from the `file` field AND from the paths a message quotes, since `duplicate-code` names
 * its partner block by path — so a relative and an absolute snapshot of one tree compare equal.
 *
 * NORMALIZATION 2 — the NUMBERS a message quotes, and the CHECKS own it. A rule writing a
 * coordinate or a tally into its own prose re-keys on an edit that changed no finding
 * (`duplicate-code`'s partner block, `unused-local`'s re-declaration, `oversized-type`'s line
 * extent): the finding was there before the digit changed and is there after, so the gate
 * prints one added plus one removed for no movement, and a gate waived by reflex has stopped
 * being a gate. A check declares its own volatile parts (`Check.VolatileMessage`) and
 * `identities`, built by `Linter.messageIdentities`, maps rule id to that declaration. This
 * module holds NO list of rules: a rule quoting a coordinate joins by writing one method on itself.
 *
 * NOT normalized, and the question to ask before masking a future tally: `duplicate-code`'s
 * statement COUNT and the `(max N)` THRESHOLD every limit rule quotes. A threshold is
 * configuration — changing it IS a change. The statement count is the last DISCRIMINATOR its
 * key has, both coordinates in that message being masked and the partner path shared by every
 * clone against one file. So the test is not "does this digit move only with the code" but "is
 * anything else telling two neighbouring findings apart"; `fragmented-doc-comment` refuses
 * masking on that ground and says so on its own constant.
 *
 * Two prices, knowingly: there is no MAGNITUDE bound (the gate answers whether a finding appeared or
 * disappeared, not by how much), and masking a number can COLLAPSE two keys into one, which is
 * SCOPE-DEPENDENT rather than a property of the policy.
 *
 * Everything here is pure: the CLI layer reads the files, builds the identity map, calls
 * `parseReport` / `tally` / `compare` / `render` and prints, which is what lets the suite test
 * both normalizations directly rather than through a process.
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
	 *
	 * Both surpluses are occurrence counts over the same two multisets, so
	 * `addedTotal - removedTotal` is ALWAYS `newTotal - oldTotal`. The identity is
	 * worth stating because reading that pair backwards is what produced a backlog
	 * item: a verdict of `66 added / 9 removed` was read as "57 findings FEWER", the
	 * apparent contradiction was blamed on a normalization this module was said to be
	 * missing, and a fix for it entered the queue. 66 - 9 = 57 findings MORE, which is
	 * what the same reader's own per-rule tally (`+50 comment-width`, `+3
	 * duplicate-code`, `+5 unused-return-value`, `+1` twice, `-2`, `-1` — net +57) had
	 * already said. `render` now publishes the net, and `ruleDeltas` the per-rule
	 * breakdown, so neither question needs a reader's arithmetic.
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
			severities: severityDeltas(added, removed),
			rules: ruleDeltas(before, after, added, removed)
		};
	}

	/**
	 * Render the verdict as plain lines, most-summary first: one headline
	 * always, then — only when something actually moved — the per-rule
	 * breakdown, the severity breakdown the ratchets are scoped by, and up to
	 * `limit` example keys per sign (`limit < 0` prints every one).
	 *
	 * A clean run is deliberately ONE line per tree: the battery prints this
	 * twice on every slice, and a breakdown of zeros would train the reader
	 * to skip the block that matters.
	 *
	 * The headline states the NET as well as the two surpluses. It is arithmetically
	 * redundant — `compare` guarantees `added - removed == new - base` — and that is
	 * exactly why it is there: the one recorded misreading of this tool inverted the
	 * `N findings (base M)` pair, and no amount of the two numbers being present
	 * catches that. A third statement of the same fact does.
	 *
	 * The per-rule block comes FIRST because it answers the question the gate exists
	 * for — "did a rule OTHER than the one I touched move" — which until now needed a
	 * reader to filter 190-odd example lines by hand, or to re-count the two JSON
	 * reports in another language.
	 *
	 * It is one row per rule, under the same `limit` and elision note the examples get.
	 * The first version joined the rows onto ONE line, and on a half-tree diff that line
	 * came out 1125 characters against 44 for the severity line — a gate whose own output
	 * is unbounded, printed twice per slice, in the name of readability.
	 */
	public static function render(result: LintDiffResult, label: String, limit: Int): Array<String> {
		final tag: String = label == '' ? 'lint-diff' : 'lint-diff $label';
		final net: String = signed(result.newTotal - result.oldTotal);
		final lines: Array<String> = [
			'$tag: ${result.newTotal} findings (base ${result.oldTotal}, net $net)'
				+ ' — ${result.addedTotal} added / ${result.removedTotal} removed'
		];
		if (result.addedTotal == 0 && result.removedTotal == 0) return lines;
		pushCapped(
			lines, result.rules, limit, 'rule(s) that moved',
			r -> '  by rule      ${r.rule} ${r.before}->${r.after} (+${r.added} -${r.removed})'
		);
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
	 * The path work is not a `file`-field concern that leaked in here. A check pointing at a SECOND
	 * location spells it in the message — `duplicate-code` names its partner block `<path>:<line>` — and
	 * that path is recorded exactly as the scope argument was written, so it carries every spelling the
	 * `file` field carries. With only the file field normalized, an absolute-against-relative pair and a
	 * `./src`-against-`src` pair each disagree on a large fraction of their findings. Whatever the file
	 * field forgives, the message has to forgive too, or `--root` is true by half.
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

	/** A total delta written so its DIRECTION is unmistakable: `+57`, `-3`, `+0`. */
	private static inline function signed(delta: Int): String {
		return delta < 0 ? '$delta' : '+$delta';
	}

	/**
	 * `root` reduced to the exact prefix the snapshot's paths carry: trailing
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

	/**
	 * Both surplus lists folded into per-bucket occurrence counts, with the bucket names in
	 * first-seen order.
	 *
	 * `key` rather than a fixed field because the severity breakdown and the per-rule one are
	 * the same fold over the same two lists, differing only in which field of an entry names
	 * the bucket — writing that fold twice is how the two would drift, and `duplicate-code`
	 * reported exactly those three declarations when they were.
	 */
	private static function bucket(
		added: Array<LintDiffEntry>, removed: Array<LintDiffEntry>, key: (LintDiffEntry) -> String
	): LintDiffBuckets {
		final names: Array<String> = [];
		final addedBy: Map<String, Int> = [];
		final removedBy: Map<String, Int> = [];
		inline function fold(entries: Array<LintDiffEntry>, into: Map<String, Int>): Void {
			for (e in entries) {
				final name: String = key(e);
				into[name] = (into[name] ?? 0) + e.count;
				if (!names.contains(name)) names.push(name);
			}
		}
		fold(added, addedBy);
		fold(removed, removedBy);
		return { names: names, added: addedBy, removed: removedBy };
	}

	/**
	 * Rule id -> occurrences of that rule in one snapshot, summed over the keys it owns.
	 *
	 * Derived from the tally rather than counted during it: `tally` already records the
	 * rule on every row, and a second pass over `order` costs one walk of the distinct
	 * keys, which is what keeps `tally`'s own contract (fold a report into a multiset)
	 * from growing a reporting concern.
	 */
	private static function ruleTotals(tally: LintDiffTally): Map<String, Int> {
		final out: Map<String, Int> = [];
		for (key in tally.order) {
			final rule: String = rowOf(tally, key).rule;
			out[rule] = (out[rule] ?? 0) + (tally.counts[key] ?? 0);
		}
		return out;
	}

	/**
	 * The per-rule breakdown: for every rule that MOVED, both snapshot totals and the two
	 * surpluses.
	 *
	 * A rule that moved nothing is left out on purpose. Most registered rules fire on no given tree, so
	 * printing every one with its totals would bury the two or three that changed — and "which rules exist"
	 * is `lint --list-rules`'s question, not this gate's.
	 *
	 * Movement is the ADDED/REMOVED surplus, not a difference of the two totals: a finding
	 * that migrated from one file to another leaves the rule's total untouched while
	 * genuinely moving, and a summary keyed on totals alone would report that rule as silent. So
	 * a rule's two totals can be equal while its surplus is not, and that is the row worth having.
	 *
	 * Ordered by how much each rule moved, then by id — the reader is looking for the
	 * biggest mover, and a stable tie-break keeps two runs on one input byte-identical.
	 */
	private static function ruleDeltas(
		before: LintDiffTally, after: LintDiffTally, added: Array<LintDiffEntry>, removed: Array<LintDiffEntry>
	): Array<LintDiffRuleDelta> {
		final counted: LintDiffBuckets = bucket(added, removed, e -> e.rule);
		final beforeBy: Map<String, Int> = ruleTotals(before);
		final afterBy: Map<String, Int> = ruleTotals(after);
		final out: Array<LintDiffRuleDelta> = [
			for (n in counted.names)
				{
					rule: n,
					before: beforeBy[n] ?? 0,
					after: afterBy[n] ?? 0,
					added: counted.added[n] ?? 0,
					removed: counted.removed[n] ?? 0
				}
		];
		out.sort(compareRuleMovement);
		return out;
	}

	/** Most movement first, then rule id — a total order, so the render is reproducible. */
	private static function compareRuleMovement(a: LintDiffRuleDelta, b: LintDiffRuleDelta): Int {
		final ma: Int = a.added + a.removed;
		final mb: Int = b.added + b.removed;
		return if (ma != mb)
			mb - ma
		else if (a.rule < b.rule)
			-1
		else
			(a.rule > b.rule ? 1 : 0);
	}

	/**
	 * The row `tally` recorded for a key it put in `order`.
	 *
	 * `tally` pushes the key and writes its row in one breath, so the row is always there.
	 * Throwing rather than skipping is the point: a dropped surplus UNDERSTATES the blast
	 * radius, which is the single failure this whole tool exists to prevent. Spelled once
	 * because `bucket` argues one folder over two copies and the same argument applies to a
	 * guard — the two copies of this one were `duplicate-code`'s next candidate.
	 */
	private static function rowOf(tally: LintDiffTally, key: String): LintDiffRow {
		final row: Null<LintDiffRow> = tally.rows[key];
		if (row == null) throw new Exception('lint-diff: tally invariant broken — no row for a key in document order');
		return row;
	}

	/** Keys occurring more often in `a` than in `b`, in `a`'s document order. */
	private static function surplus(a: LintDiffTally, b: LintDiffTally): Array<LintDiffEntry> {
		final out: Array<LintDiffEntry> = [];
		for (key in a.order) {
			final mine: Int = a.counts[key] ?? 0;
			final theirs: Int = b.counts[key] ?? 0;
			if (mine <= theirs) continue;
			final row: LintDiffRow = rowOf(a, key);
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
		final counted: LintDiffBuckets = bucket(added, removed, e -> e.severity);
		counted.names.sort(compareSeverity);
		return [
			for (n in counted.names) { severity: n, added: counted.added[n] ?? 0, removed: counted.removed[n] ?? 0 }
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
		pushCapped(lines, entries, limit, '$word key(s)', e -> {
			final multiplicity: String = e.count > 1 ? ' (x${e.count})' : '';
			return '  $sign ${e.file}  ${e.rule}  ${e.message}$multiplicity';
		});
	}

	/**
	 * Append at most `limit` rendered rows, then a note naming how many were left out
	 * (`limit < 0` prints every row and no note).
	 *
	 * Shared by the per-rule block and both example blocks, which differ only in how one row
	 * renders and what the note calls it. Every list this render prints goes through here, so
	 * an unbounded one has to be written on purpose rather than by omission — which is exactly
	 * how the per-rule block shipped as a single 1125-character line.
	 */
	private static function pushCapped<T>(lines: Array<String>, rows: Array<T>, limit: Int, noun: String, render: (T) -> String): Void {
		final cap: Int = limit < 0 || limit > rows.length ? rows.length : limit;
		for (i in 0...cap) lines.push(render(rows[i]));
		final rest: Int = rows.length - cap;
		if (rest > 0) lines.push('  … $rest more $noun not shown — raise --limit');
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

/** Both snapshot totals and both surpluses for one rule — the per-rule half of the verdict. */
typedef LintDiffRuleDelta = {

	var rule: String;

	/** Occurrences of this rule in the BASE snapshot. */
	var before: Int;

	/** Occurrences of this rule in the compared snapshot. */
	var after: Int;

	var added: Int;

	var removed: Int;
};

/**
 * One fold of the two surplus lists into buckets: the names in first-seen order and the
 * occurrence count each side contributed.
 *
 * A named type rather than an inline anonymous one because two callers read it and the
 * project's own `anon-type-dup` counts a structure written twice.
 */
typedef LintDiffBuckets = {

	var names: Array<String>;

	var added: Map<String, Int>;

	var removed: Map<String, Int>;
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

	/** Every rule that moved, most movement first — the gate's headline question. */
	var rules: Array<LintDiffRuleDelta>;
};
