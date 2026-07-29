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
 *
 * Detection is SOURCE-based, not shape-based: conditional nodes across
 * every scope (member `Conditional`, statement `Conditional`,
 * case-group `Conditional`, `ConditionalExpr`, `ConditionalArgs`,
 * `CondSpliceExpr`/`CondSpliceTail` raws) do not project their
 * condition as a child, but ALL of them span source that starts with
 * the `#if` keyword — so any node whose span text opens with
 * `#if false` (or `#if (false)`) is a hit, uniformly and
 * future-proof for new conditional productions.
 *
 * `fix`:
 *  - `#if false X #end` → delete the whole region (plus the line's
 *    leading indent when the region owns its lines) — ONLY when `X` is
 *    trivial (empty, or a bare `;`); see "Non-trivial dead body" below.
 *  - `#if false X #else Y #end` → replace the region with Y (the
 *    branch the compiler actually keeps) — again only when the
 *    eliminated `X` is trivial.
 *  - `#elseif` chains are report-only — rewriting `#if false X
 *    #elseif C Y #end` into `#if C Y #end` is a semantic transform
 *    left to a human.
 *
 * ## Non-trivial dead body: report-only
 *
 * `X` — the branch a fix would ERASE — can be more than filler: a whole
 * alternate implementation left behind a `#if false` guard is a common way
 * to preserve unfinished or reverted work. (`ConstantCondition`, this
 * check's `if (true)` / `if (false)` sibling, documents a real case: a
 * `final hasSelection:Bool = true;` stub whose dead `else` branch was the
 * only trace of a dropped feature.) So `fix` withholds the edit whenever `X`
 * contains anything beyond an empty block or bare `;` — the violation still
 * reports (same severity), with a human-review note appended to the
 * message. Trivial (empty) bodies keep the automatic delete/replace
 * unchanged. Detection here stays SOURCE-text based (comments are not
 * stripped before the check), so a body holding only a comment is
 * conservatively treated as non-trivial too.
 */
@:nullSafety(Strict)
final class IfFalseDeadCode implements Check {

	/** ASCII-only note appended when a non-trivial dead body withholds the autofix. */
	private static inline final DEAD_BRANCH_NOTE: String = ' (dead branch - verify intent before deleting)';

	public function new() {}

	public function id(): String {
		return 'if-false';
	}

	public function description(): String {
		return 'an `#if false … #end` region — dead code on every compilation target';
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
			final slice: String = source.substring(span.from, span.to);
			if (findTopLevelMarker(slice, '#elseif') != -1) continue;
			final elsePos: Int = findTopLevelMarker(slice, '#else');
			final endPos: Int = slice.lastIndexOf('#end');
			if (elsePos == -1) {
				if (!isTrivialBody(slice.substring(bodyStart(slice), endPos))) continue;
				edits.push({ span: span, text: '' });
				continue;
			}
			if (endPos <= elsePos) continue;
			if (!isTrivialBody(slice.substring(bodyStart(slice), elsePos))) continue;
			final kept: String = slice.substring(elsePos + '#else'.length, endPos).trim();
			edits.push({ span: span, text: kept });
		}
		return edits;
	}

	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode): Void {
		final span: Null<Span> = node.span;
		if (span != null && isIfFalseAt(source, span.from))
			out.push({
				file: file,
				span: span,
				rule: 'if-false',
				severity: Severity.Warning,
				message: deadRegionMessage(source.substring(span.from, span.to))
			});
		else
			for (c in node.children) walk(out, file, source, c);
	}

	/**
	 * The violation message for a flagged region's `slice`: the base detection
	 * message, extended with an ASCII human-review note when the branch a fix
	 * would eliminate is non-trivial (see the class doc). An `#elseif` chain
	 * keeps the base message — it is report-only for an unrelated reason (the
	 * rewrite is a semantic transform, not a triviality question).
	 */
	private static function deadRegionMessage(slice: String): String {
		final base: String = 'dead `#if false` region — no compilation target ever includes it';
		if (findTopLevelMarker(slice, '#elseif') != -1) return base;
		final elsePos: Int = findTopLevelMarker(slice, '#else');
		final bodyEnd: Int = elsePos == -1 ? slice.lastIndexOf('#end') : elsePos;
		final body: String = slice.substring(bodyStart(slice), bodyEnd);
		return isTrivialBody(body) ? base : base + DEAD_BRANCH_NOTE;
	}

	/** `true` iff the source at `from` opens with `#if false` / `#if (false)` (word-bounded). */
	private static function isIfFalseAt(source: String, from: Int): Bool {
		if (!sliceStartsWith(source, from, '#if')) return false;
		var i: Int = from + 3; // noqa: magic-number
		while (i < source.length && isWs(source.charCodeAt(i) ?? 0)) i++;
		var parens: Bool = false;
		if (i < source.length && source.charCodeAt(i) == '('.code) {
			parens = true;
			i++;
			while (i < source.length && isWs(source.charCodeAt(i) ?? 0)) i++;
		}
		if (!sliceStartsWith(source, i, 'false')) return false;
		final after: Int = source.charCodeAt(i + 5) ?? 0;
		if (isWordChar(after)) return false;
		if (!parens) return true;
		var j: Int = i + 5; // noqa: magic-number
		while (j < source.length && isWs(source.charCodeAt(j) ?? 0)) j++;
		return source.charCodeAt(j) == ')'.code;
	}

	/**
	 * Index in `slice` (which itself opens with the region's own `#if false` /
	 * `#if (false)`) right after the condition, where the THEN body begins —
	 * the same skip `isIfFalseAt` performs, restarted at `slice[0]`.
	 */
	private static function bodyStart(slice: String): Int {
		var i: Int = 3; // noqa: magic-number
		while (i < slice.length && isWs(slice.charCodeAt(i) ?? 0)) i++;
		var parens: Bool = false;
		if (i < slice.length && slice.charCodeAt(i) == '('.code) {
			parens = true;
			i++;
			while (i < slice.length && isWs(slice.charCodeAt(i) ?? 0)) i++;
		}
		i += 'false'.length;
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
		if (trimmed == '' || trimmed == ';') return true;
		if (trimmed.length >= 2 && trimmed.charAt(0) == '{' && trimmed.charAt(trimmed.length - 1) == '}')
			return trimmed.substring(1, trimmed.length - 1).trim() == '';
		return false;
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

	private static inline function isWs(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\r'.code || c == '\n'.code;
	}

	private static inline function isWordChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

}
