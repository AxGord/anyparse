package anyparse.query.format;

import anyparse.check.Check.Violation;
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
	 * `{file, line, col, endLine, endCol, severity, rule, message}` records: `line`/`col`
	 * is the span's start and `endLine`/`endCol` its EXCLUSIVE end, both 1-based as every
	 * other `Span` this CLI prints, so a consumer can ask whether two findings' regions
	 * nest. A violation with no span resolves all four to null. `addressOf` (when given)
	 * adds an `address` field — the finding's canonical edit-stable selector
	 * (`Address.describe`), directly usable as a mutation-op `--select` argument.
	 * Escaping is delegated to `Json.stringify`.
	 */
	public static function json(
		violations: Array<Violation>, sourceOf: Map<String, String>, ?addressOf: Violation -> Null<String>
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
		return Json.stringify(records, null, '  ');
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

	/** One JSON record for a violation; a null span yields null coordinates. */
	private static function recordOf(v: Violation, index: LineIndex): Dynamic {
		final span: Null<Span> = v.span;
		final pos: Null<Position> = posOf(v, index);
		final end: Null<Position> = span == null ? null : index.lineColAt(span.to);
		return {
			file: v.file,
			line: pos?.line,
			col: pos?.col,
			endLine: end?.line,
			endCol: end?.col,
			severity: v.severity.label(),
			rule: v.rule,
			message: v.message
		};
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
