package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a plain string literal that appears three or more times (configurable)
 * in ONE file — a repeated literal the project rule says to hoist into a single
 * named constant, so an edit to the value happens in one place. Report-only:
 * like `magic-number`, the constant's NAME is intent a human supplies, not a
 * mechanical rewrite, so `fix` produces no edits.
 *
 * ## What is flagged
 *
 * A literal whose file-local occurrence count reaches `minOccurrences`
 * (default 3) yields ONE finding, anchored at its FIRST occurrence with the
 * total count in the message (the SonarQube-S1192 idiom — one advisory names
 * the whole duplication, not N redundant per-site copies), when ALL hold:
 *
 *  1. it is a PLAIN string literal — one carrying no interpolation. The check
 *     reads literals through `StringFoldSupport.literalOf` (the same seam
 *     `fold-adjacent-string-literals` / `prefer-single-quotes` use), which
 *     yields null for an interpolated string (`'total $n'`) and for a
 *     non-literal node. An interpolated literal is not a constant candidate —
 *     it captures surrounding values — so it never counts toward a group, in
 *     EITHER direction (three `'total $n'` do not group, and an interpolated
 *     occurrence does not inflate a plain literal's count). An escaped `$$`
 *     stays plain (no substitution) and is eligible.
 *  2. its raw inner content is at least `minLength` characters (default 4).
 *     Empty (`""`) and single-character (`"x"`) literals are therefore exempt
 *     BY CONSTRUCTION — a one-letter delimiter or an empty string carries no
 *     naming value and hoisting it into a constant would hurt readability, not
 *     help it. The length is measured on the RAW source between the quotes, so
 *     an escape sequence (`\n`) counts by its source characters, not its
 *     decoded length — a conservative, spelling-stable metric.
 *  3. it is NOT inside a metadata argument (a `MetaShape.metaKinds` ancestor —
 *     Haxe `@:meta('…')`). A string in metadata is usually a contract token (a
 *     `@:native` name, a `@:build` macro path) bound to that annotation, not a
 *     value duplicated across logic; extracting it would break the annotation's
 *     meaning. Such a literal neither counts toward a group nor is reported.
 *
 * ## Grouping
 *
 * Literals group by their RAW inner content, so quote STYLE is ignored — a
 * `"foo"` and a `'foo'` are the same string value and count together. Two
 * differently-ESCAPED spellings of the same value (`"a'b"` vs `'a\'b'`) have
 * different raw content and are treated as distinct groups — a sound
 * under-count (never a false group), acceptable for v1.
 *
 * ## Grammar-agnostic
 *
 * The string semantics live behind `GrammarPlugin.stringFoldSupport`; a grammar
 * with no string-literal concept (a binary format) returns null and the check
 * no-ops. Metadata exclusion reads `GrammarPlugin.metaShape().metaKinds`; a
 * grammar with no metadata leaves the set empty and simply excludes nothing.
 *
 * ## Configuration
 *
 * Both thresholds are read per-file from a discovered `apqlint.json`:
 * `string-literal-dup.minOccurrences` and `string-literal-dup.minLength`
 * (integer options). An absent or malformed value falls back to the default.
 */
@:nullSafety(Strict)
final class StringLiteralDup implements Check implements ConfigAware {

	/** Least repetitions of a literal before its occurrences are flagged. */
	private static inline final DEFAULT_MIN_OCCURRENCES: Int = 3;

	/** Least raw-content length a literal must have to be a candidate (excludes empty / single-char by construction). */
	private static inline final DEFAULT_MIN_LENGTH: Int = 4;

	/** Longest literal content echoed verbatim in a finding message before it is elided. */
	private static inline final MESSAGE_PREVIEW: Int = 40;

	/** This check's stable id — named once so the literal is not itself a repeated string. */
	private static inline final RULE_ID: String = 'string-literal-dup';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a plain string literal repeated many times in one file that should be a named constant';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (support == null) return [];
		final metaKinds: Array<String> = plugin.metaShape().metaKinds;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			final minOcc: Int = positiveOr(config.intOption(RULE_ID, 'minOccurrences'), DEFAULT_MIN_OCCURRENCES);
			final minLen: Int = positiveOr(config.intOption(RULE_ID, 'minLength'), DEFAULT_MIN_LENGTH);
			scanFile(violations, entry.file, entry.source, tree, support, metaKinds, minOcc, minLen);
		}
		return violations;
	}

	/** No mechanical autofix — the constant's name is intent a human supplies (like `magic-number`). */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Collect every eligible plain literal grouped by its content, then emit one
	 * `Info` for each group whose size reaches `minOcc`, anchored at the group's
	 * FIRST occurrence (the SonarQube-S1192 idiom): the message carries the total
	 * count, so a single advisory names the whole duplication rather than N
	 * redundant per-site copies. Findings are span-sorted so the report is
	 * deterministic regardless of map iteration order.
	 */
	private static function scanFile(
		out: Array<Violation>, file: String, source: String, tree: QueryNode, support: StringFoldSupport, metaKinds: Array<String>,
		minOcc: Int, minLen: Int
	): Void {
		final groups: Map<String, Array<Span>> = [];
		collect(tree, source, support, metaKinds, minLen, false, groups);
		final findings: Array<Finding> = [
			for (content => spans in groups)
				if (spans.length >= minOcc)
					{
						at: earliest(spans),
						message: 'string literal ${preview(content)} repeated ${spans.length} times — extract into a named constant'
					}
		];
		findings.sort((a, b) -> a.at.from - b.at.from);
		for (finding in findings) out.push({
			file: file,
			span: finding.at,
			rule: RULE_ID,
			severity: Severity.Info,
			message: finding.message
		});
	}

	/**
	 * Walk `node`, recording each eligible plain literal's span under its content
	 * key. `inMeta` is sticky: once a `metaKinds` node is entered, every literal in
	 * its subtree is a contract token and is skipped. A literal shorter than
	 * `minLen`, or interpolated / non-literal (`literalOf` null), is not recorded.
	 */
	private static function collect(
		node: QueryNode, source: String, support: StringFoldSupport, metaKinds: Array<String>, minLen: Int, inMeta: Bool,
		groups: Map<String, Array<Span>>
	): Void {
		final here: Bool = inMeta || metaKinds.contains(node.kind);
		if (!here) {
			final literal: Null<StringLiteral> = support.literalOf(node, source);
			final span: Null<Span> = node.span;
			if (literal != null && span != null && literal.content.length >= minLen) {
				final at: Span = span;
				final bucket: Null<Array<Span>> = groups[literal.content];
				if (bucket == null)
					groups[literal.content] = [at];
				else
					bucket.push(at);
			}
		}
		for (child in node.children) collect(child, source, support, metaKinds, minLen, here, groups);
	}

	/** A configured value when it is a positive integer, else the built-in default (a zero / negative option is ignored). */
	private static inline function positiveOr(value: Null<Int>, fallback: Int): Int {
		return value != null && value > 0 ? value : fallback;
	}

	/** `content` quoted for a message, elided to `MESSAGE_PREVIEW` characters so a long literal does not bloat the report. */
	private static function preview(content: String): String {
		final shown: String = content.length > MESSAGE_PREVIEW ? '${content.substr(0, MESSAGE_PREVIEW)}…' : content;
		return '\'$shown\'';
	}

	/** The document-earliest span of a group — the first occurrence the single finding anchors to. */
	private static function earliest(spans: Array<Span>): Span {
		var first: Span = spans[0];
		for (span in spans) if (span.from < first.from) first = span;
		return first;
	}

}

/** A pending finding: the anchor span of a repeated literal and its rendered message. */
private typedef Finding = {
	final at: Span;
	final message: String;
};
