package anyparse.query;

import anyparse.query.format.json.LintFindingDataJson;
import anyparse.query.format.json.LintFindingJson;
import anyparse.query.format.json.LintReportJsonParser;
import anyparse.query.format.json.LintTruthEntryJson;
import anyparse.query.format.json.LintTruthJson;
import anyparse.query.format.json.LintTruthJsonParser;
import haxe.Exception;
import haxe.Json;

using Lambda;
using StringTools;

/** One scoring bucket — a family, or the whole rule — counted over keys, not findings. */
typedef LintScoreBucket = {

	/** The family, or `LintScore.ALL` for the whole rule. */
	final family: String;

	/** Findings scored. */
	final findings: Int;

	/** Distinct keys among them; `findings - keys` are duplicates of a key already counted. */
	final keys: Int;

	/** Verdict -> keys whose truth entry carries it, in `LintScore.VERDICTS` order. */
	final matched: Map<String, Int>;

	/** Keys no truth entry labels — a finding without `data` among them. */
	final unlabelled: Int;

	/** `real-long` keys over the keys with a known verdict (`unknown` and unlabelled ones aside); null with none. */
	final precision: Null<Float>;

	/** Recall entries (`real-long`, or `recall: true`) of the bucket. */
	final recallEntries: Int;

	/** Those the report still finds. */
	final recallHit: Int;
}

/** A finding key of the report: the key's parts, how many findings carry it, and the file of the first. */
typedef LintScoreKey = {
	final family: String;
	final member: String;
	final subject: String;
	final count: Int;
	final file: String;
}

/** The whole score: the truth's rule and provenance, per-family buckets and the overall one, and the two lists a reader acts on. */
typedef LintScoreResult = {
	final rule: String;
	final project: String;
	final commit: String;
	final severity: String;
	final families: Array<LintScoreBucket>;
	final overall: LintScoreBucket;

	/** Recall entries no finding matches any more — each one fails the run. */
	final lost: Array<LintTruthEntryJson>;

	/** Report keys no truth entry labels, in report order. */
	final unlabelled: Array<LintScoreKey>;
}

/**
 * `apq lint-score` — a rule-agnostic scorer of a lint report against a ground-truth file (`LintTruthJson`), the
 * instrument behind a precision campaign: change the rule, re-run lint, re-score, and see what moved.
 *
 * Findings and truth entries meet by KEY — `(family, function, subject)` of a finding's `data` (`Check.FindingData`) —
 * never by message or line: both move under edits that change no finding, and a chain the rule re-renders through
 * another path is the same finding. Several findings with one key are ONE hit plus duplicates, so a rule reporting one
 * stall at three call sites is not three times as right.
 *
 * precision = `real-long` keys / keys with a known verdict (`unknown` and unlabelled keys aside); recall = recall
 * entries hit / recall entries, a recall entry being a `real-long` one or one marked `recall: true`. A lost recall
 * entry is what the caller's exit status reports: a precision gain that costs one real stall is not a gain.
 *
 * Pure, like `LintDiff`: the CLI reads the two files and prints.
 */
@:nullSafety(Strict)
final class LintScore {

	/** The bucket name of the whole rule. */
	public static inline final ALL: String = 'all';

	/** The verdicts a truth entry may carry, in the order every rendering lists them. */
	public static final VERDICTS: Array<String> = ['real-long', 'real-short', 'rare', 'false', 'dup-of', 'unknown'];

	/** The kinds of evidence a verdict may rest on. */
	public static final EVIDENCE_KINDS: Array<String> = ['measured', 'test', 'code'];

	/** The verdict a precision counts as right. */
	private static inline final REAL_LONG: String = 'real-long';

	/** The verdict a precision leaves out, like an unlabelled key. */
	private static inline final UNKNOWN: String = 'unknown';

	/** The verdict that names the key it duplicates. */
	private static inline final DUP_OF: String = 'dup-of';

	/** The family of a finding that carries no `data`: it can match no entry. */
	private static inline final NO_DATA: String = '-';

	/** A ratio is printed to two decimals. */
	private static inline final RATIO_SCALE: Float = 100;

	/** Read and validate a truth file; throws naming every defect `validate` finds. */
	public static function parseTruth(raw: String): LintTruthJson {
		final truth: LintTruthJson = LintTruthJsonParser.parse(raw);
		final errors: Array<String> = validate(truth);
		if (errors.length > 0) throw new Exception('invalid truth file: ${errors.join('; ')}');
		return truth;
	}

	/**
	 * Read a lint report: the bare array `lint --format json` prints (`LintDiff.parseReport`), or the
	 * `{"findings": […], …}` envelope an `--explain-long` run prints.
	 */
	public static function parseFindings(raw: String): Array<LintFindingJson> {
		final trimmed: String = raw.trim();
		return trimmed.startsWith('{') ? LintReportJsonParser.parse(trimmed).findings : LintDiff.parseReport(trimmed);
	}

	/**
	 * What the schema cannot refuse: a verdict outside `VERDICTS`, a `dup-of` without the key it duplicates or a
	 * `dupOf` on another verdict, evidence of an unknown kind, an empty key part, and one key labelled twice.
	 */
	public static function validate(truth: LintTruthJson): Array<String> {
		final errors: Array<String> = [];
		final seen: Array<String> = [];
		for (i => e in truth.entries) {
			final at: String = 'entry $i (${e.family} ${e.member} ${e.subject})';
			if (e.family == '' || e.member == '' || e.subject == '') errors.push('$at: family, function and subject must be non-empty');
			if (!VERDICTS.contains(e.verdict)) errors.push('$at: unknown verdict "${e.verdict}" (expected ${VERDICTS.join('|')})');
			final dupOf: String = e.dupOf ?? '';
			if (e.verdict == DUP_OF && dupOf == '') errors.push('$at: verdict dup-of needs "dupOf", the key it duplicates');
			if (e.verdict != DUP_OF && dupOf != '') errors.push('$at: "dupOf" belongs to verdict dup-of only');
			final kind: Null<String> = e.evidence?.kind;
			if (kind != null && !EVIDENCE_KINDS.contains(kind))
				errors.push('$at: unknown evidence kind "$kind" (expected ${EVIDENCE_KINDS.join('|')})');
			final key: String = keyOf(e.family, e.member, e.subject);
			if (seen.contains(key)) errors.push('$at: the key is labelled twice');
			seen.push(key);
		}
		return errors;
	}

	/**
	 * Score `findings` of `truth.rule` against `truth`: only those at `severity` (`warning`, `error`, `info`), or every
	 * one when it is null.
	 */
	public static function score(truth: LintTruthJson, findings: Array<LintFindingJson>, severity: Null<String>): LintScoreResult {
		final keys: Array<LintScoreKey> = keysOf(findings, truth.rule, severity);
		final found: Array<String> = [for (k in keys) keyOf(k.family, k.member, k.subject)];
		final entryOf: Map<String, LintTruthEntryJson> = [for (e in truth.entries) keyOf(e.family, e.member, e.subject) => e];
		final families: Array<String> = [];
		for (k in keys) if (!families.contains(k.family)) families.push(k.family);
		for (e in truth.entries) if (!families.contains(e.family)) families.push(e.family);
		families.sort(Reflect.compare);
		final hit: (LintTruthEntryJson) -> Bool = e -> found.contains(keyOf(e.family, e.member, e.subject));
		return {
			rule: truth.rule,
			project: truth.project,
			commit: truth.commit,
			severity: severity ?? 'all',
			families: [
				for (family in families) bucket(
					family, keys.filter(k -> k.family == family), truth.entries.filter(e -> e.family == family), entryOf, hit
				)
			],
			overall: bucket(ALL, keys, truth.entries, entryOf, hit),
			lost: [for (e in truth.entries) if (isRecall(e) && !hit(e)) e],
			unlabelled: [for (k in keys) if (!entryOf.exists(keyOf(k.family, k.member, k.subject))) k]
		};
	}

	/** A recall entry: one the score must keep finding — a `real-long` one, or one marked `recall: true`. */
	public static function isRecall(e: LintTruthEntryJson): Bool {
		return e.verdict == REAL_LONG || e.recall == true;
	}

	/**
	 * The score as text: a headline, a table with one row per family and an `all` row — findings, keys, the keys of each
	 * verdict, unlabelled keys, precision and recall — then every lost recall entry and up to `limit` unlabelled keys
	 * (`limit < 0`: all of them).
	 */
	public static function render(result: LintScoreResult, limit: Int): Array<String> {
		final o: LintScoreBucket = result.overall;
		final lines: Array<String> = [
			'lint-score ${result.rule} @ ${result.project} ${result.commit} (${result.severity}): ${o.findings} finding(s),'
				+ ' ${o.keys} key(s), ${o.findings - o.keys} duplicate(s)'
		];
		final header: Array<String> = ['family', 'findings', 'keys'].concat(VERDICTS).concat(['unlabelled', 'precision', 'recall']);
		final rows: Array<Array<String>> = [header].concat([for (b in result.families.concat([o])) row(b)]);
		final widths: Array<Int> = [
			for (c in 0...header.length) rows.fold((r, w) -> r[c].length > w ? r[c].length : w, 0)
		];
		for (r in rows) lines.push([for (c in 0...r.length) r[c].rpad(' ', widths[c])].join('  ').rtrim());
		lines.push('lost recall: ${result.lost.length}');
		for (e in result.lost) lines.push('  ${e.family}  ${e.member}  ${e.subject}  [${e.verdict}]');
		final unlabelled: Int = result.unlabelled.length;
		lines.push('unlabelled: $unlabelled');
		final shown: Int = limit < 0 || limit > unlabelled ? unlabelled : limit;
		for (k in result.unlabelled.slice(0, shown)) lines.push('  ${k.family}  ${k.member}  ${k.subject}  x${k.count}  ${k.file}');
		if (shown < unlabelled) lines.push('  … ${unlabelled - shown} more not shown — raise --limit');
		return lines;
	}

	/** The score as a JSON document: the result's fields, each bucket's verdict counts as an object in `VERDICTS` order. */
	public static function json(result: LintScoreResult): String {
		return Json.stringify({
			rule: result.rule,
			project: result.project,
			commit: result.commit,
			severity: result.severity,
			overall: bucketRecord(result.overall),
			families: [for (b in result.families) bucketRecord(b)],
			lost: [for (e in result.lost) keyRecord(e.family, e.member, e.subject, e.verdict)],
			unlabelled: [
				for (k in result.unlabelled) {
					final record: Dynamic = keyRecord(k.family, k.member, k.subject, null);
					Reflect.setField(record, 'count', k.count);
					Reflect.setField(record, 'file', k.file);
					record;
				}
			]
		}, null, '  ');
	}

	/** One table row of `render`. */
	private static function row(b: LintScoreBucket): Array<String> {
		return [b.family, '${b.findings}', '${b.keys}'].concat([for (v in VERDICTS) '${b.matched[v] ?? 0}']).concat([
			'${b.unlabelled}',
			ratio(b.precision),
			b.recallEntries == 0 ? '-' : '${b.recallHit}/${b.recallEntries}'
		]);
	}

	/** A ratio to two decimals, `-` for none. */
	private static function ratio(value: Null<Float>): String {
		return value == null ? '-' : '${Math.round(value * RATIO_SCALE) / RATIO_SCALE}';
	}

	/** One bucket as a JSON record. */
	private static function bucketRecord(b: LintScoreBucket): Dynamic {
		final matched: Dynamic = {};
		for (v in VERDICTS) Reflect.setField(matched, v, b.matched[v] ?? 0);
		return {
			family: b.family,
			findings: b.findings,
			keys: b.keys,
			duplicates: b.findings - b.keys,
			matched: matched,
			unlabelled: b.unlabelled,
			precision: b.precision,
			recallEntries: b.recallEntries,
			recallHit: b.recallHit,
			recall: b.recallEntries == 0 ? null : b.recallHit / b.recallEntries
		};
	}

	/** A key as a JSON record — `family`, `function`, `subject`, and a `verdict` when given. */
	private static function keyRecord(family: String, member: String, subject: String, verdict: Null<String>): Dynamic {
		final record: Dynamic = { family: family };
		Reflect.setField(record, 'function', member);
		Reflect.setField(record, 'subject', subject);
		if (verdict != null) Reflect.setField(record, 'verdict', verdict);
		return record;
	}

	/**
	 * The distinct keys of the findings of `rule` at `severity` (every severity when null), in report order, each with how
	 * many findings carry it. A finding without `data` keys by itself: it can match no entry, and must not merge with another.
	 */
	private static function keysOf(findings: Array<LintFindingJson>, rule: String, severity: Null<String>): Array<LintScoreKey> {
		final keys: Array<LintScoreKey> = [];
		final keyIndex: Map<String, Int> = [];
		var undated: Int = 0;
		for (f in findings) if (f.rule == rule && (severity == null || f.severity == severity)) {
			final data: Null<LintFindingDataJson> = f.data;
			final family: String = data?.family ?? NO_DATA;
			final member: String = data?.member ?? '${f.file}#${undated++}';
			final subject: String = data?.subject ?? f.message;
			final key: String = keyOf(family, member, subject);
			final at: Null<Int> = keyIndex[key];
			if (at == null) {
				keyIndex[key] = keys.length;
				keys.push({
					family: family,
					member: member,
					subject: subject,
					count: 1,
					file: f.file
				});
			} else {
				final k: LintScoreKey = keys[at];
				keys[at] = {
					family: k.family,
					member: k.member,
					subject: k.subject,
					count: k.count + 1,
					file: k.file
				};
			}
		}
		return keys;
	}

	/** One bucket over its report `keys` and truth `entries`. */
	private static function bucket(
		family: String, keys: Array<LintScoreKey>, entries: Array<LintTruthEntryJson>, entryOf: Map<String, LintTruthEntryJson>,
		hit: (LintTruthEntryJson) -> Bool
	): LintScoreBucket {
		final matched: Map<String, Int> = [for (v in VERDICTS) v => 0];
		var unlabelled: Int = 0;
		var findings: Int = 0;
		for (k in keys) {
			findings += k.count;
			final entry: Null<LintTruthEntryJson> = entryOf[keyOf(k.family, k.member, k.subject)];
			if (entry == null)
				unlabelled++;
			else
				matched[entry.verdict] = (matched[entry.verdict] ?? 0) + 1;
		}
		var known: Int = 0;
		for (v in VERDICTS) if (v != UNKNOWN) known += matched[v] ?? 0;
		final recall: Array<LintTruthEntryJson> = entries.filter(isRecall);
		return {
			family: family,
			findings: findings,
			keys: keys.length,
			matched: matched,
			unlabelled: unlabelled,
			precision: known == 0 ? null : (matched[REAL_LONG] ?? 0) / known,
			recallEntries: recall.length,
			recallHit: recall.filter(hit).length
		};
	}

	/** The key of `(family, member, subject)`, each part length-prefixed so no part can run into the next. */
	private static inline function keyOf(family: String, member: String, subject: String): String {
		return '${family.length}:$family${member.length}:$member${subject.length}:$subject';
	}

}
