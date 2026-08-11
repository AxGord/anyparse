package anyparse.check;

import haxe.Exception;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import anyparse.check.Check.Violation;

using StringTools;

/**
 * Flags every `#if false … #end` conditional-compilation region — dead
 * code the compiler never sees on any target, kept only as a poor
 * man's block comment — long-lived codebases accumulate dozens of them.
 * Also flags every `#if true … #end` region — the mirror smell: the
 * guard buys nothing since the body compiles on every target regardless,
 * so the directive is pure noise around live code.
 *
 * Detection is SOURCE-based, not shape-based: conditional nodes across
 * every scope (member `Conditional`, statement `Conditional`,
 * case-group `Conditional`, `ConditionalExpr`, `ConditionalArgs`,
 * `CondSpliceExpr`/`CondSpliceTail` raws) do not project their
 * condition as a child, but ALL of them span source that starts with
 * the `#if` keyword — so any node whose span text opens with
 * `#if false` (or `#if (false)`) or `#if true` (or `#if (true)`) is a
 * hit, uniformly and future-proof for new conditional productions.
 *
 * `fix`:
 *  - `#if false X #end` → delete the whole region (plus the line's
 *    leading indent when the region owns its lines) — ONLY when `X` is
 *    trivial (empty, or a bare `;`); see "Non-trivial dead body" below.
 *  - `#if false X #else Y #end` → replace the region with Y (the
 *    branch the compiler actually keeps) — again only when the
 *    eliminated `X` is trivial.
 *  - `#if true X #end` → unwrap to `X` — UNCONDITIONALLY, regardless of
 *    `X`'s content: nothing is erased, so there is no triviality gate.
 *  - `#if true X #else Y #end` → unwrap to `X`, dropping `Y` — same
 *    triviality gate as the false arm, but on `Y`: only auto-applied
 *    when `Y` is trivial (empty, or a bare `;`).
 *  - `#elseif` chains are report-only for BOTH polarities — rewriting
 *    `#if false X #elseif C Y #end` (or the `true` mirror) is a semantic
 *    transform left to a human.
 *
 * ## Non-trivial dead body: report-only
 *
 * The branch a fix would ERASE (`X` for the false arm, `Y` for the true
 * arm's `#else`) can be more than filler: a whole alternate
 * implementation left behind a guard is a common way to preserve
 * unfinished or reverted work. (`ConstantCondition`, this check's
 * `if (true)` / `if (false)` sibling, documents a real case: a
 * `final hasSelection:Bool = true;` stub whose dead `else` branch was the
 * only trace of a dropped feature.) So `fix` withholds the edit whenever
 * the eliminated branch contains anything beyond an empty block or bare
 * `;` — the violation still reports (same severity), with a human-review
 * note appended to the message. Trivial (empty) bodies keep the
 * automatic delete/replace/unwrap unchanged. Detection here stays
 * SOURCE-text based (comments are not stripped before the check), so a
 * body holding only a comment is conservatively treated as non-trivial
 * too.
 */
@:nullSafety(Strict)
final class IfFalseDeadCode implements Check {

	/** ASCII-only note appended when a non-trivial dead body withholds the autofix. */
	private static inline final DEAD_BRANCH_NOTE: String = ' (dead branch - verify intent before deleting)';

	/** Base message for a flagged `#if false` region — always dead code. */
	private static inline final FALSE_MESSAGE: String = 'dead `#if false` region — no compilation target ever includes it';

	/** Base message for a flagged `#if true` region — the guard is always redundant. */
	private static inline final TRUE_MESSAGE: String = 'redundant `#if true` region — every compilation target already includes it';

	public function new() {}

	public function id(): String {
		return 'if-false';
	}

	public function description(): String {
		return 'an `#if false … #end` region — dead code — or an `#if true … #end` region — a redundant directive';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final isTrueBranch: Bool = isIfTrueAt(source, span.from);
			final region: Null<EliminatedRegion> = eliminatedRegion(source.substring(span.from, span.to), isTrueBranch);
			if (region == null) continue;
			if (isTrueBranch) {
				if (region.elsePos != -1 && !isTrivialBody(region.otherwise)) continue;
				edits.push({ span: span, text: region.then.trim() });
			} else {
				if (!isTrivialBody(region.then)) continue;
				edits.push({ span: span, text: region.otherwise });
			}
		}
		return edits;
	}

	/** `true` iff the source at `from` opens with `#if false` / `#if (false)` (word-bounded). */
	private static inline function isIfFalseAt(source: String, from: Int): Bool {
		return isIfLiteralAt(source, from, 'false');
	}

	/** `true` iff the source at `from` opens with `#if true` / `#if (true)` (word-bounded). */
	private static inline function isIfTrueAt(source: String, from: Int): Bool {
		return isIfLiteralAt(source, from, 'true');
	}

	private static inline function isWs(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\r'.code || c == '\n'.code;
	}

	private static inline function isWordChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode): Void {
		final span: Null<Span> = node.span;
		final isFalse: Bool = span != null && isIfFalseAt(source, span.from);
		final isTrueBranch: Bool = span != null && !isFalse && isIfTrueAt(source, span.from);
		if (span != null && (isFalse || isTrueBranch))
			out.push({
				file: file,
				span: span,
				rule: 'if-false',
				severity: Severity.Warning,
				message: deadRegionMessage(source.substring(span.from, span.to), isTrueBranch)
			});
		else
			for (c in node.children) walk(out, file, source, c);
	}

	/**
	 * The violation message for a flagged region's `slice`: the base message
	 * for its polarity (`isTrueBranch`), extended with an ASCII human-review
	 * note when the branch a fix would eliminate is non-trivial (see the
	 * class doc) — the false arm's `#if false` body, or the true arm's
	 * `#else` body when one exists (an elseless `#if true` region eliminates
	 * nothing, so it never gets the note). An `#elseif` chain (or a
	 * malformed region `eliminatedRegion` cannot resolve) keeps the base
	 * message — report-only for an unrelated reason (the rewrite is a
	 * semantic transform, not a triviality question).
	 */
	private static function deadRegionMessage(slice: String, isTrueBranch: Bool): String {
		final base: String = isTrueBranch ? TRUE_MESSAGE : FALSE_MESSAGE;
		final region: Null<EliminatedRegion> = eliminatedRegion(slice, isTrueBranch);
		if (region == null) return base;
		final eliminated: Null<String> = isTrueBranch ? (region.elsePos == -1 ? null : region.otherwise) : region.then;
		return eliminated == null || isTrivialBody(eliminated) ? base : base + DEAD_BRANCH_NOTE;
	}

	/**
	 * Resolve a flagged region's `slice` into its `then` branch (the `#if`
	 * body, regardless of polarity) plus the raw marker offsets `fix` needs
	 * to build its edit — the SINGLE source of truth `fix` and
	 * `deadRegionMessage` both read, so the two can never disagree about the
	 * same violation. `otherwise` is the `#else` branch's source (trimmed),
	 * or `''` when there is none. Which one a caller treats as ELIMINATED
	 * depends on polarity: the false arm always erases `then`; the true arm
	 * erases `otherwise` (and only when an `#else` exists at all — an
	 * elseless `#if true` region erases nothing). Null for an `#elseif`
	 * chain (`fix` stays report-only; `deadRegionMessage` keeps the base
	 * message) or a malformed region (`#else` with no matching `#end`).
	 */
	private static function eliminatedRegion(slice: String, isTrueBranch: Bool): Null<EliminatedRegion> {
		if (findTopLevelMarker(slice, '#elseif') != -1) return null;
		final elsePos: Int = findTopLevelMarker(slice, '#else');
		final endPos: Int = slice.lastIndexOf('#end');
		if (elsePos != -1 && endPos <= elsePos) return null;
		final bodyEnd: Int = elsePos == -1 ? endPos : elsePos;
		return {
			then: slice.substring(bodyStart(slice, isTrueBranch), bodyEnd),
			elsePos: elsePos,
			otherwise: elsePos == -1 ? '' : slice.substring(elsePos + '#else'.length, endPos).trim()
		};
	}

	/** `true` iff the source at `from` opens with `#if <literal>` / `#if (<literal>)` (word-bounded). */
	private static function isIfLiteralAt(source: String, from: Int, literal: String): Bool {
		if (!sliceStartsWith(source, from, '#if')) return false;
		var i: Int = from + '#if'.length;
		while (i < source.length && isWs(source.charCodeAt(i) ?? 0)) i++;
		var parens: Bool = false;
		if (i < source.length && source.charCodeAt(i) == '('.code) {
			parens = true;
			i++;
			while (i < source.length && isWs(source.charCodeAt(i) ?? 0)) i++;
		}
		if (!sliceStartsWith(source, i, literal)) return false;
		final after: Int = source.charCodeAt(i + literal.length) ?? 0;
		if (isWordChar(after)) return false;
		if (!parens) return true;
		var j: Int = i + literal.length;
		while (j < source.length && isWs(source.charCodeAt(j) ?? 0)) j++;
		return source.charCodeAt(j) == ')'.code;
	}

	/**
	 * Index in `slice` (which itself opens with the region's own `#if
	 * <literal>` / `#if (<literal>)`) right after the condition, where the
	 * THEN body begins — the same skip `isIfLiteralAt` performs, restarted
	 * at `slice[0]`.
	 */
	private static function bodyStart(slice: String, isTrueBranch: Bool): Int {
		final literal: String = isTrueBranch ? 'true' : 'false';
		var i: Int = '#if'.length;
		while (i < slice.length && isWs(slice.charCodeAt(i) ?? 0)) i++;
		var parens: Bool = false;
		if (i < slice.length && slice.charCodeAt(i) == '('.code) {
			parens = true;
			i++;
			while (i < slice.length && isWs(slice.charCodeAt(i) ?? 0)) i++;
		}
		i += literal.length;
		if (parens) {
			while (i < slice.length && isWs(slice.charCodeAt(i) ?? 0)) i++;
			if (i < slice.length && slice.charCodeAt(i) == ')'.code) i++;
		}
		return i;
	}

	/**
	 * Whether `body` — the source text of a would-be-eliminated branch — is
	 * TRIVIAL: empty, a bare `;`, or an empty block `{}` (any amount of inner
	 * whitespace). Anything else (a real statement, a declaration, a non-empty
	 * block) is non-trivial; see the class doc for why that withholds the fix.
	 */
	private static function isTrivialBody(body: String): Bool {
		final trimmed: String = body.trim();
		return trimmed == '' || trimmed == ';'
			|| (trimmed.length >= 2 && trimmed.charAt(0) == '{' && trimmed.charAt(trimmed.length - 1) == '}'
				&& trimmed.substring(1, trimmed.length - 1).trim() == '');
	}

	/**
	 * Offset of `marker` at `#if`-nesting depth 0 inside `slice` (which
	 * itself starts with the region's own `#if` — counted from depth 0
	 * AFTER that opener), or -1. String/comment content is not scanned
	 * around — dead regions with a literal `"#else"` inside a string are
	 * rare enough that the resulting skip (marker found → conservative
	 * report-only or a larger keep) stays safe: the fix output always
	 * re-parses through the canonicalize gate before being written.
	 */
	private static function findTopLevelMarker(slice: String, marker: String): Int {
		var depth: Int = 0;
		var i: Int = 3;
		while (i < slice.length) {
			if (slice.charCodeAt(i) == '#'.code) {
				if (sliceStartsWith(slice, i, '#if'))
					depth++;
				else if (sliceStartsWith(slice, i, '#end'))
					depth--;
				else if (depth == 0 && sliceStartsWith(slice, i, marker))
					return i;
			}
			i++;
		}
		return -1;
	}

	private static function sliceStartsWith(s: String, at: Int, what: String): Bool {
		return at + what.length <= s.length && s.substr(at, what.length) == what;
	}

}

/** The resolved region `eliminatedRegion` reads in both `fix` and `deadRegionMessage`. */
private typedef EliminatedRegion = {
	final then: String;
	final elsePos: Int;
	final otherwise: String;
};
