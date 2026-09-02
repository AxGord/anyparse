package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.CondDirectives;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags the parentheses around a conditional-compilation condition that is one bare flag —
 * `#if (sys)`, `#elseif (mobile)` — and drops them (`#if sys`, `#elseif mobile`). A single
 * identifier is self-delimiting: nothing in the directive grammar can bind into it, so the pair
 * cannot affect how the condition parses. Cosmetic, hence `Info`.
 *
 * ## Scope
 *
 * ONE bare flag and nothing else. A compound condition keeps its parentheses — `#if (cpp && debug)`,
 * `#if (haxe_ver >= "3.1.0")` — because the directive grammar accepts a single condition and the
 * outer pair is what makes the operators one. So does a negation (`#if (!flag)`): whether the
 * unparenthesised form is accepted is a per-grammar question this rule does not answer, and the pair
 * is one character of noise either way. So does a redundantly nested pair, whose interior is not a
 * bare identifier. So does a DOTTED define (`#if (target.unicode)`): the reader delimits it
 * correctly and unwrapping it would be provably safe, but "one bare flag" is the shape this rule
 * committed to, and widening it is a deliberate follow-up rather than a silent side effect.
 *
 * ## Why a rule of its own rather than an arm of `redundant-parens`
 *
 * `redundant-parens` is node-driven end to end: it walks `RefShape.parenKind` nodes, decides each
 * pair from its host kind and its content's precedence, and its `fix` re-indexes those nodes by span
 * to map a finding back to an edit. A directive is not a node — the condition text survives only as
 * trivia on the directive line — so a directive arm would share none of that machinery and would
 * have to be a second, disjoint detection and fix path inside a rule whose whole documented model is
 * expression precedence. The incompatibility is structural, not just cosmetic: `redundant-parens`
 * bails on a file it cannot parse, and an arm inside it would inherit that gate and lose the
 * unparseable-file reach this rule pins. Same charter ("parentheses that cannot affect the parse"),
 * answered from a different layer, so it is a separate rule. Default ON, like its expression
 * sibling.
 *
 * ## Grammar-agnostic
 *
 * The whole detection rides `CondDirectives`, whose keyword vocabulary comes from
 * `RefShape.conditionalIfKeyword` / `conditionalElseKeywords` / `conditionalEndKeyword`. A grammar
 * declaring no opener scans to nothing and the rule is a no-op — no separate opt-in.
 *
 * ## Detection and fix
 *
 * A pure source scan through `CondDirectives` — the shared directive reader, which excludes a `#if`
 * written inside a comment, a string or a regex, and delimits the condition without swallowing the
 * code that follows an inline region. No parse, so the rule reports on a file the grammar cannot
 * parse.
 *
 * `fix` replaces the condition span with the bare flag and touches nothing else — the keyword, the
 * indentation, a trailing comment, an `#elseif` chain and any nested region are outside the span by
 * construction. A separator is inserted when the directive was written without one (`#if(sys)` →
 * `#if sys`, not `#ifsys`) or when the closing parenthesis was the only thing separating the flag
 * from the code after it on an inline region's line; the test is `CondDirectives.isIdentCharAt`, the
 * reader's own notion of what would lex into one token with the flag, so the two cannot drift.
 *
 * A finding lands on a directive LINE, which the writer keeps as its own line — so a trailing
 * `// noqa` is relocated off it during canonicalisation and cannot suppress this rule in a
 * canonically formatted project. Use a `CHECKSTYLE:OFF` / `ON` region, or disable the rule in
 * `apqlint.json`.
 */
@:nullSafety(Strict)
final class RedundantCondCompParens implements Check {

	/** The rule id. */
	private static final ID: String = 'redundant-condcomp-parens';

	public function new() {}

	public function id(): String {
		return ID;
	}

	public function description(): String {
		return 'parentheses around a single conditional-compilation flag - #if (sys) parses as #if sys';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (entry in files) for (site in sites(entry.source, plugin))
				{
					file: entry.file,
					span: site.condition,
					rule: ID,
					severity: Severity.Info,
					message: 'redundant parentheses around the conditional-compilation flag `${site.flag}`'
				}
		];
	}

	/** Replace each flagged condition with its bare flag, re-separated from its neighbours when the parentheses were the separator. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (site in sites(source, plugin)) if (flagged.contains('${site.condition.from}:${site.condition.to}')) {
			final lead: String = CondDirectives.isIdentCharAt(source, site.condition.from - 1) ? ' ' : '';
			final trail: String = CondDirectives.isIdentCharAt(source, site.condition.to) ? ' ' : '';
			edits.push({ span: site.condition, text: '$lead${site.flag}$trail' });
		}
		return edits;
	}

	/** Whether `source` holds a space or a tab at `at`. */
	private static inline function isSpaceAt(source: String, at: Int): Bool {
		final c: Int = source.fastCodeAt(at);
		return c == ' '.code || c == '\t'.code;
	}

	/** Every parenthesised-single-flag condition in `source`, in source order. */
	private static function sites(source: String, plugin: GrammarPlugin): Array<FlagParens> {
		final out: Array<FlagParens> = [];
		for (directive in CondDirectives.scan(source, plugin.refShape(), plugin.lexicalRegions.bind(source))) {
			final condition: Null<Span> = directive.condition;
			if (condition == null) continue;
			// Re-bound to non-null locals: strict null-safety narrowing does not reach into an
			// anonymous struct literal.
			final span: Span = condition;
			final flag: Null<String> = soleFlag(source, span);
			if (flag == null) continue;
			final name: String = flag;
			out.push({ condition: span, flag: name });
		}
		return out;
	}

	/**
	 * The bare flag `condition` wraps in one pair of parentheses, or null when the condition is
	 * unparenthesised or holds anything other than a single identifier. Interior whitespace is
	 * allowed (`#if ( sys )`); anything else — an operator, a second operand, a nested pair, a
	 * comment — fails the shape and keeps its parentheses.
	 */
	private static function soleFlag(source: String, condition: Span): Null<String> {
		final close: Int = condition.to - 1;
		if (source.fastCodeAt(condition.from) != '('.code || source.fastCodeAt(close) != ')'.code) return null;
		var from: Int = condition.from + 1;
		while (from < close && isSpaceAt(source, from)) from++;
		if (from >= close || !CondDirectives.isIdentStart(source.fastCodeAt(from))) return null;
		var to: Int = from;
		while (to < close && CondDirectives.isIdentChar(source.fastCodeAt(to))) to++;
		final flag: String = source.substring(from, to);
		while (to < close && isSpaceAt(source, to)) to++;
		return to == close ? flag : null;
	}

}

/** One flagged site: the condition span the fix replaces, and the bare flag it replaces it with. */
private typedef FlagParens = {
	final condition: Span;
	final flag: String;
};
