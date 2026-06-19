package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using StringTools;

/**
 * One suppression directive resolved to a line range and an optional rule
 * filter. `lineFrom`/`lineTo` are 1-indexed inclusive; `rules` is the set of
 * rule-ids the directive silences, or `null` for "all rules". `region`
 * distinguishes the two directive families, which match a finding differently:
 * a `noqa` (`region == false`, a single line) silences a finding whose source
 * span COVERS that line — so a directive on a continuation line of a reflowed
 * statement still lands — while a `CHECKSTYLE:OFF`/`ON` region
 * (`region == true`) silences a finding REPORTED inside it (its start line
 * within the region), the conventional region containment rule.
 */
private typedef Entry = {
	var lineFrom: Int;
	var lineTo: Int;
	var rules: Null<Array<String>>;
	var region: Bool;
}
@:nullSafety(Strict)
final class Suppression {

	/**
	 * Return `violations` minus every finding silenced by an inline directive
	 * in its file. `files` supplies each file's source for the comment scan
	 * and for line resolution; a violation whose file is absent from `files`,
	 * or whose span is null, is kept unchanged.
	 */
	public static function apply(violations: Array<Violation>, files: Array<{ file: String, source: String }>): Array<Violation> {
		if (violations.length == 0) return violations;

		final sourceByFile: Map<String, String> = [];
		final entriesByFile: Map<String, Array<Entry>> = [];
		for (f in files) {
			sourceByFile[f.file] = f.source;
			entriesByFile[f.file] = collectEntries(f.source);
		}

		return violations.filter(v -> {
			final span: Null<Span> = v.span;
			if (span == null) return true;
			final source: Null<String> = sourceByFile[v.file];
			if (source == null) return true;
			final entries: Null<Array<Entry>> = entriesByFile[v.file];
			if (entries == null || entries.length == 0) return true;
			final fromLine: Int = span.lineCol(source).line;
			final toLine: Int = new Span(span.to, span.to).lineCol(source).line;
			return !suppressedInRange(entries, fromLine, toLine, v.rule);
		});
	}

	/**
	 * True if any entry silences `rule` (or all rules) for a finding spanning lines
	 * `[fromLine, toLine]`. A `noqa` (single line, `region == false`) hits when its
	 * line falls anywhere in the finding's span — so it lands even when the writer
	 * reflowed the offending statement and the comment ended up on a continuation
	 * line, not the line the finding is reported at. A `CHECKSTYLE` region
	 * (`region == true`) hits when the finding's REPORT line (`fromLine`) is inside
	 * the region — the conventional containment rule; matching the finding's whole
	 * span would let a region silence a wide decl-level finding reported outside it.
	 */
	private static function suppressedInRange(entries: Array<Entry>, fromLine: Int, toLine: Int, rule: String): Bool {
		for (e in entries) {
			final hit: Bool = e.region ? fromLine >= e.lineFrom && fromLine <= e.lineTo : e.lineFrom <= toLine && fromLine <= e.lineTo;
			if (hit) {
				final rules: Null<Array<String>> = e.rules;
				if (rules == null || rules.contains(rule)) return true;
			}
		}
		return false;
	}

	/**
	 * Scan `source` for suppression directives and resolve each to an `Entry`.
	 * Comments are visited in source order so `CHECKSTYLE:OFF`/`ON` pairs match
	 * by nesting; an unclosed `OFF` extends to end of file.
	 */
	private static function collectEntries(source: String): Array<Entry> {
		final entries: Array<Entry> = [];
		var openLine: Int = -1;
		for (tok in RefactorSupport.collectCommentTokens(source)) {
			final line: Int = new Span(tok.from, tok.from).lineCol(source).line;
			final body: Span = RefactorSupport.commentBody(source, tok);
			final text: String = source.substring(body.from, body.to).trim();

			if (text.startsWith('CHECKSTYLE:OFF')) {
				if (openLine < 0) openLine = line;
			} else if (text.startsWith('CHECKSTYLE:ON')) {
				if (openLine >= 0) {
					entries.push({
						lineFrom: openLine,
						lineTo: line,
						rules: null,
						region: true
					});
					openLine = -1;
				}
			} else {
				final noqa: Null<Entry> = parseNoqa(text, line);
				if (noqa != null) entries.push(noqa);
			}
		}
		if (openLine >= 0) {
			final lastLine: Int = new Span(source.length, source.length).lineCol(source).line;
			entries.push({
				lineFrom: openLine,
				lineTo: lastLine,
				rules: null,
				region: true
			});
		}
		return entries;
	}

	/**
	 * Parse a `noqa` directive from a comment body, or null if the body is not
	 * one. `noqa` -> all rules on `line`; `noqa: a, b` -> only rules `a`/`b`. The
	 * keyword is matched case-insensitively (flake8 convention); rule-ids keep
	 * their as-typed case. An empty rule list (`noqa:`) degrades to all rules.
	 */
	private static function parseNoqa(text: String, line: Int): Null<Entry> {
		final lower: String = text.toLowerCase();
		if (lower == 'noqa') return {
			lineFrom: line,
			lineTo: line,
			rules: null,
			region: false
		};
		if (!lower.startsWith('noqa:')) return null;
		final rules: Array<String> = [
			for (part in text.substr('noqa:'.length).split(',')) {
				final id: String = part.trim();
				if (id.length > 0)
					id;
			}
		];
		return {
			lineFrom: line,
			lineTo: line,
			rules: rules.length > 0 ? rules : null,
			region: false
		};
	}

}
