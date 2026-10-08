package anyparse.query.format;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import anyparse.check.LongLockExplain.LongLockKind;
import anyparse.check.LongLockExplain.LongLockReason;
import anyparse.check.LongLockExplain.LongLockReport;
import anyparse.check.Severity;
import anyparse.runtime.LineIndex;
import anyparse.runtime.Span;
import haxe.Json;

using Lambda;
using StringTools;

/**
 * Machine-readable renderers for analysis-check violations — the JSON and
 * checkstyle-XML counterparts of `Text.renderViolations`. Both take a flat
 * violation list (already filtered and ordered by the caller) plus a
 * `file -> source` map, from which each renderer builds one `LineIndex` per
 * file and resolves every line/column through it.
 * Symmetric with the `checkstyle.json` config the project already consumes:
 * emitting checkstyle XML lets the same CI tooling ingest apq findings.
 */
@:nullSafety(Strict)
final class LintFormat {

	/** Files named under each rule of a summary that spans several rules. */
	public static inline final SUMMARY_FILES_PER_RULE: Int = 3;

	/** Files named, one per line, when a summary covers ONE rule — the by-file breakdown a `--rule` run asks for. */
	public static inline final SUMMARY_FILES_SINGLE_RULE: Int = 10;

	/** The column an `--explain-long` reason's kind is padded to: the longest kind, `spans-blocking`. */
	private static inline final LONG_REASON_WIDTH: Int = 14;

	/**
	 * `violations` condensed for a reader who cannot use them one per line: one line per rule —
	 * `<rule>  <count>  <severity>  <files> file(s)` — sorted by count, most first (ties by rule id),
	 * each followed by the files holding most of that rule's findings.
	 *
	 * Several rules name their top `SUMMARY_FILES_PER_RULE` files on one indented line; a summary of
	 * ONE rule (a `--rule` run over a wide scope) is a by-file breakdown instead, the top
	 * `SUMMARY_FILES_SINGLE_RULE` files one per line. Either way a file cut off is counted, never
	 * dropped silently. A rule reported at more than one severity (a per-directory override) lists
	 * each, most severe first.
	 */
	public static function summary(violations: Array<Violation>): String {
		final rules: Array<String> = [];
		final byRule: Map<String, Array<Violation>> = [];
		for (v in violations) {
			final group: Null<Array<Violation>> = byRule[v.rule];
			if (group == null) {
				rules.push(v.rule);
				byRule[v.rule] = [v];
			} else
				group.push(v);
		}
		final countOf: String -> Int = rule -> byRule[rule]?.length ?? 0;
		rules.sort((a, b) -> countOf(a) != countOf(b) ? countOf(b) - countOf(a) : Reflect.compare(a, b));
		final idWidth: Int = rules.fold((rule, width) -> rule.length > width ? rule.length : width, 0);
		final countWidth: Int = rules.fold((rule, width) -> '${countOf(rule)}'.length > width ? '${countOf(rule)}'.length : width, 0);
		final buf: StringBuf = new StringBuf();
		for (rule in rules) {
			final group: Array<Violation> = byRule[rule] ?? [];
			final files: Array<{ file: String, count: Int }> = countByFile(group);
			buf.add(
				'${rule.rpad(' ', idWidth)}  ${'${group.length}'.lpad(' ', countWidth)}  ${severitiesOf(group)}  ${files.length} file(s)\n'
			);
			if (rules.length == 1) {
				for (f in files.slice(0, SUMMARY_FILES_SINGLE_RULE)) buf.add('  ${'${f.count}'.lpad(' ', countWidth)}  ${f.file}\n');
				if (files.length > SUMMARY_FILES_SINGLE_RULE) buf.add('  ... +${files.length - SUMMARY_FILES_SINGLE_RULE} more file(s)\n');
			} else {
				final named: Array<String> = [for (f in files.slice(0, SUMMARY_FILES_PER_RULE)) '${f.file} (${f.count})'];
				if (files.length > SUMMARY_FILES_PER_RULE) named.push('+${files.length - SUMMARY_FILES_PER_RULE} more');
				buf.add('    ${named.join(', ')}\n');
			}
		}
		return buf.toString();
	}

	/**
	 * Render `violations` as a pretty-printed JSON array of
	 * `{file, line, col, endLine, endCol, severity, rule, message[, data]}` records: `line`/`col`
	 * is the span's start and `endLine`/`endCol` its EXCLUSIVE end, both 1-based as every
	 * other `Span` this CLI prints, so a consumer can ask whether two findings' regions
	 * nest. A violation with no span resolves all four to null. `addressOf` (when given)
	 * adds an `address` field — the finding's canonical edit-stable selector
	 * (`Address.describe`), directly usable as a mutation-op `--select` argument.
	 * Escaping is delegated to `Json.stringify`.
	 *
	 * Given `explain` (`lint --explain-long`), the document is the `{"findings": […], "longLocks": {…} | null}` envelope
	 * instead — null when the rule ran and explained nothing. `longLocks.long` lists each long lock as `{lock, reasons,
	 * circular, aside}` (`circular`: how many re-takes of the lock itself were left out), a reason as `{kind, file, line,
	 * col, function}` plus `call`, `chain`, `via` for `spans-blocking` and `unresolved` (`[{name, line, col}]`) for
	 * `blind`, `aside` null or such reasons; `longLocks.mainShort` lists each
	 * main-thread take of a lock that is not long as `{lock, file, line, col, function,
	 * quiet}`, and `longLocks.dominated` each lock others dominate as `{lock, by}`.
	 */
	public static function json(
		violations: Array<Violation>, sourceOf: Map<String, String>, ?addressOf: Violation -> Null<String>, ?explain: ExplainedLocks
	): String {
		final indexes: Map<String, LineIndex> = [];
		final records: Array<Dynamic> = [
			for (v in violations) {
				final record: Dynamic = recordOf(v, indexFor(v.file, sourceOf, indexes));
				if (addressOf != null) {
					final address: Null<String> = addressOf(v);
					if (address != null) Reflect.setField(record, 'address', address);
				}
				record;
			}
		];
		if (explain == null) return Json.stringify(records, null, '  ');
		final longLocks: Null<LongLockReport> = explain.report;
		if (longLocks == null) return Json.stringify({ findings: records, longLocks: null }, null, '  ');
		final explained: Dynamic = {
			long: [
				for (l in longLocks.long)
					{
						lock: l.lock,
						reasons: [for (r in l.reasons) reasonRecord(r, sourceOf, indexes)],
						circular: l.circular,
						aside: l.aside == null ? null : [for (r in l.aside) reasonRecord(r, sourceOf, indexes)]
					}
			],
			mainShort: [
				for (t in longLocks.mainShort) {
					final record: Dynamic = siteRecord(t.lock, t.file, t.span, t.holder, indexFor(t.file, sourceOf, indexes));
					Reflect.setField(record, 'quiet', t.quiet);
					record;
				}
			],
			dominated: [for (d in longLocks.dominated) { lock: d.lock, by: d.by }]
		};
		return Json.stringify({ findings: records, longLocks: explained }, null, '  ');
	}

	/**
	 * Render `violations` as a checkstyle XML document, grouped by file in
	 * first-seen order. Each finding becomes an
	 * `<error line= column= severity= message= source=/>` with
	 * `source="apq.<rule>"`; attribute values are XML-escaped. A null span
	 * yields `line="0" column="0"`.
	 */
	public static function checkstyle(violations: Array<Violation>, sourceOf: Map<String, String>): String {
		final order: Array<String> = [];
		final byFile: Map<String, Array<Violation>> = [];
		for (v in violations) {
			var list: Null<Array<Violation>> = byFile[v.file];
			if (list == null) {
				list = [];
				byFile[v.file] = list;
				order.push(v.file);
			}
			list.push(v);
		}

		final indexes: Map<String, LineIndex> = [];
		final buf: StringBuf = new StringBuf();
		buf.add('<?xml version="1.0" encoding="UTF-8"?>\n');
		buf.add('<checkstyle version="8.0">\n');
		for (file in order) {
			final group: Null<Array<Violation>> = byFile[file];
			if (group == null) continue;
			final index: LineIndex = indexFor(file, sourceOf, indexes);
			buf.add('  <file name="${xml(file)}">\n');
			for (v in group) {
				final pos: Null<Position> = posOf(v, index);
				final line: Int = pos != null ? pos.line : 0;
				final col: Int = pos != null ? pos.col : 0;
				buf.add('    <error line="$line" column="$col" severity="${v.severity.label()}"');
				buf.add(' message="${xml(v.message)}" source="apq.${xml(v.rule)}"/>\n');
			}
			buf.add('  </file>\n');
		}
		buf.add('</checkstyle>\n');
		return buf.toString();
	}

	/**
	 * The `--explain-long` section of a text report: a headline, then each long lock with one line per reason —
	 * `<kind>  <file>:<line>:<col>  <function>`, a `spans-blocking` one followed by the path to the call that blocks — and
	 * what the lock is long by with its own reasons set aside, then each
	 * main-thread take of a lock that is not long, then each lock others dominate.
	 */
	public static function longLocksText(report: LongLockReport, sourceOf: Map<String, String>): String {
		final indexes: Map<String, LineIndex> = [];
		final buf: StringBuf = new StringBuf();
		buf.add(
			'thread-safety --explain-long: ${report.long.length} long lock(s), ${report.mainShort.length} main-thread take(s) of a lock'
			+ ' that is not long\n'
		);
		for (l in report.long) {
			buf.add('long ${l.lock}\n');
			for (r in l.reasons) buf.add('  ${reasonText(r, sourceOf, indexes)}\n');
			if (l.circular > 0) buf.add('  ${l.circular} circular re-take(s) of this lock itself, left out\n');
			final aside: Null<Array<LongLockReason>> = l.aside;
			if (aside != null && aside.length == 0) buf.add('  without its own reasons: not long\n');
			if (aside != null) for (r in aside) buf.add('  without its own reasons: ${reasonText(r, sourceOf, indexes)}\n');
		}
		if (report.mainShort.length > 0) buf.add('not long, taken on the main thread\n');
		for (t in report.mainShort) {
			final quiet: String = t.quiet ? '  (quiet)' : '';
			buf.add('  ${t.lock}  ${place(t.file, t.span, indexFor(t.file, sourceOf, indexes))}  ${t.holder}$quiet\n');
		}
		for (d in report.dominated) buf.add('dominated ${d.lock} by ${d.by.join(', ')}: a take of it under one of those is brief\n');
		return buf.toString();
	}

	/**
	 * One JSON record for a violation; a null span yields null coordinates. A violation carrying `data` gets a `data` object
	 * (`family`, `function` for its `member`, `subject`, `chain`), and one without has no such key.
	 */
	private static function recordOf(v: Violation, index: LineIndex): Dynamic {
		final span: Null<Span> = v.span;
		final pos: Null<Position> = posOf(v, index);
		final end: Null<Position> = span == null ? null : index.lineColAt(span.to);
		final record: Dynamic = {
			file: v.file,
			line: pos?.line,
			col: pos?.col,
			endLine: end?.line,
			endCol: end?.col,
			severity: v.severity.label(),
			rule: v.rule,
			message: v.message
		};
		final data: Null<FindingData> = v.data;
		if (data != null) Reflect.setField(record, 'data', {
			family: data.family,
			"function": data.member,
			subject: data.subject,
			chain: data.chain
		});
		return record;
	}

	/**
	 * One `--explain-long` reason as a JSON record: its site (`siteRecord`) and `kind`, plus a `spans-blocking` one's `call`,
	 * `chain` and `via`, and a `blind` one's `unresolved` calls with their line and column.
	 */
	private static function reasonRecord(r: LongLockReason, sourceOf: Map<String, String>, indexes: Map<String, LineIndex>): Dynamic {
		final index: LineIndex = indexFor(r.file, sourceOf, indexes);
		final record: Dynamic = siteRecord(null, r.file, r.span, r.holder, index);
		Reflect.setField(record, 'kind', r.kind);
		if (r.call != null) {
			Reflect.setField(record, 'call', r.call);
			Reflect.setField(record, 'chain', r.chain);
			Reflect.setField(record, 'via', r.via);
			if (r.errorPath != null) Reflect.setField(record, 'errorPath', r.errorPath);
		}
		if (r.kind == LongLockKind.Blind) Reflect.setField(record, 'unresolved', [
			for (c in r.unresolved) {
				final pos: Position = index.lineColAt(c.span.from);
				{ name: c.name, line: pos.line, col: pos.col };
			}
		]);
		return record;
	}

	/** A site as a JSON record — `lock` (when given), `file`, 1-based `line`/`col` (null with no span) and `function`. */
	private static function siteRecord(lock: Null<String>, file: String, span: Null<Span>, holder: String, index: LineIndex): Dynamic {
		final pos: Null<Position> = span == null ? null : index.lineColAt(span.from);
		final record: Dynamic = { file: file, line: pos?.line, col: pos?.col };
		if (lock != null) Reflect.setField(record, 'lock', lock);
		Reflect.setField(record, 'function', holder);
		return record;
	}

	/** One reason as a text line: `<kind>  <file>:<line>:<col>  <function>`, then a `spans-blocking` reason's path. */
	private static function reasonText(r: LongLockReason, sourceOf: Map<String, String>, indexes: Map<String, LineIndex>): String {
		final index: LineIndex = indexFor(r.file, sourceOf, indexes);
		final head: String = '${r.kind.rpad(' ', LONG_REASON_WIDTH)}  ${place(r.file, r.span, index)}  ${r.holder}';
		if (r.kind == LongLockKind.Blind)
			return '$head  unresolved: ${[for (c in r.unresolved) '${c.name} at ${lineCol(c.span, index)}'].join(', ')}';
		final call: Null<String> = r.call;
		if (call == null) return head;
		final via: String = r.via == null ? '' : ' via ${r.via}';
		final error: String = r.errorPath == null ? '' : '  only on an error path (catch at ${r.errorPath})';
		return '$head  calls $call$via: ${r.chain.join(' -> ')}$error';
	}

	/** `<line>:<col>` of `span`'s start. */
	private static function lineCol(span: Span, index: LineIndex): String {
		final pos: Position = index.lineColAt(span.from);
		return '${pos.line}:${pos.col}';
	}

	/** `<file>:<line>:<col>`, or the bare file when there is no span. */
	private static function place(file: String, span: Null<Span>, index: LineIndex): String {
		final pos: Null<Position> = span == null ? null : index.lineColAt(span.from);
		return pos == null ? file : '$file:${pos.line}:${pos.col}';
	}

	/** Resolve a violation's 1-indexed position, or null when it has no span. */
	private static function posOf(v: Violation, index: LineIndex): Null<Position> {
		final span: Null<Span> = v.span;
		return span == null ? null : index.lineColAt(span.from);
	}

	/** XML-escape an attribute value. */
	private static function xml(s: String): String {
		return s.split('&')
			.join('&amp;')
			.split('<')
			.join('&lt;')
			.split('>')
			.join('&gt;')
			.split('"')
			.join('&quot;');
	}

	/**
	 * The line index of `file`, built at most once per render. `Span.lineCol` counts newlines
	 * from offset zero on every call, so resolving one position per finding costs
	 * O(findings x file size) — the shape that made a 413 KB file with ~9750 findings dominate a
	 * whole-corpus run. `LineIndex` pays one linear pass per source instead, and its own doc
	 * states it resolves identically, clamps included.
	 */
	private static function indexFor(file: String, sourceOf: Map<String, String>, cache: Map<String, LineIndex>): LineIndex {
		final hit: Null<LineIndex> = cache[file];
		if (hit != null) return hit;
		final built: LineIndex = new LineIndex(sourceOf[file] ?? '');
		cache[file] = built;
		return built;
	}

	/** Each file of `group` with its finding count, most first (ties by path). */
	private static function countByFile(group: Array<Violation>): Array<{ file: String, count: Int }> {
		final order: Array<String> = [];
		final counts: Map<String, Int> = [];
		for (v in group) {
			final seen: Null<Int> = counts[v.file];
			if (seen == null) order.push(v.file);
			counts[v.file] = (seen ?? 0) + 1;
		}
		final files: Array<{ file: String, count: Int }> = [for (file in order) { file: file, count: counts[file] ?? 0 }];
		files.sort((a, b) -> a.count != b.count ? b.count - a.count : Reflect.compare(a.file, b.file));
		return files;
	}

	/** The distinct severity labels of `group`, most severe first, joined by `/`. */
	private static function severitiesOf(group: Array<Violation>): String {
		final levels: Array<Severity> = [Severity.Error, Severity.Warning, Severity.Info];
		return [for (level in levels) if (group.exists(v -> v.severity == level)) level.label()].join('/');
	}

	/**
	 * The findings a text report lists before summarising when no `reportSummaryThreshold` is declared.
	 * Sized for a reader rather than a tool: a few screens, and well above what one file's lint yields
	 * in practice, so a per-file run keeps its list.
	 */
	public static inline final DEFAULT_REPORT_SUMMARY_THRESHOLD: Int = 200;

}

/** What an `--explain-long` run hands the json renderer: the report, or null when the rule ran and explained nothing. */
typedef ExplainedLocks = {
	final report: Null<LongLockReport>;
}
