package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using StringTools;

/**
 * One suppression directive resolved to a line range and an optional rule
 * filter. `lineFrom`/`lineTo` are 1-indexed inclusive (a `noqa` is a single
 * line, a `CHECKSTYLE:OFF`/`ON` pair is the span between them); `rules` is
 * the set of rule-ids the directive silences, or `null` for "all rules".
 */
private typedef Entry = {
	var lineFrom: Int;
	var lineTo: Int;
	var rules: Null<Array<String>>;
}

/**
 * Inline finding-suppression for the analysis layer — grammar-agnostic, no
 * parse. Scans a file's comments (string-literal-aware, via
 * `RefactorSupport.collectCommentTokens`) for two directive families and
 * drops any `Violation` a directive silences. Applied once in `Linter.run`,
 * so every consumer (the `lint` report AND `--fix`) inherits it: a
 * suppressed finding is neither reported nor auto-fixed.
 *
 * Two directive families are recognised:
 *
 *  - **flake8-style `noqa`** (same-line): a comment whose trimmed body is
 *    `noqa` silences every rule on the comment's own physical line;
 *    `noqa: <rule>[,<rule>]` silences only the named apq rule-ids on that
 *    line. It is meant as a trailing comment on the offending line.
 *  - **checkstyle region toggle**: `CHECKSTYLE:OFF` ... `CHECKSTYLE:ON`
 *    silences every rule on every line of the enclosed region — the default
 *    `SuppressionCommentFilter` form, consistent with the project already
 *    consuming `checkstyle.json`. A named-check region
 *    (`CHECKSTYLE:OFF: <CheckName>`) is intentionally not supported: it would
 *    need a checkstyle-name-to-apq-id table; the all-rules form covers the ask.
 *
 * A violation with no span cannot be located on a line and is therefore
 * never suppressed.
 */
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

		final sourceByFile: Map<String, String> = new Map();
		final entriesByFile: Map<String, Array<Entry>> = new Map();
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
			final line: Int = span.lineCol(source).line;
			return !suppressed(entries, line, v.rule);
		});
	}

	/** True if any entry covers `line` and silences `rule` (or all rules). */
	private static function suppressed(entries: Array<Entry>, line: Int, rule: String): Bool {
		for (e in entries) if (line >= e.lineFrom && line <= e.lineTo) {
			final rules: Null<Array<String>> = e.rules;
			if (rules == null || rules.contains(rule)) return true;
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
					entries.push({ lineFrom: openLine, lineTo: line, rules: null });
					openLine = -1;
				}
			} else {
				final noqa: Null<Entry> = parseNoqa(text, line);
				if (noqa != null) entries.push(noqa);
			}
		}
		if (openLine >= 0) {
			final lastLine: Int = new Span(source.length, source.length).lineCol(source).line;
			entries.push({ lineFrom: openLine, lineTo: lastLine, rules: null });
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
		if (lower == 'noqa') return { lineFrom: line, lineTo: line, rules: null };
		if (!lower.startsWith('noqa:')) return null;
		final rules: Array<String> = [
			for (part in text.substr('noqa:'.length).split(',')) {
				final id: String = part.trim();
				if (id.length > 0)
					id;
			}
		];
		return { lineFrom: line, lineTo: line, rules: rules.length > 0 ? rules : null };
	}

}
