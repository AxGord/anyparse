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
 *    leading indent when the region owns its lines).
 *  - `#if false X #else Y #end` → replace the region with Y (the
 *    branch the compiler actually keeps).
 *  - `#elseif` chains are report-only — rewriting `#if false X
 *    #elseif C Y #end` into `#if C Y #end` is a semantic transform
 *    left to a human.
 */
@:nullSafety(Strict)
final class IfFalseDeadCode implements Check {

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
			if (elsePos == -1) {
				edits.push({ span: span, text: '' });
				continue;
			}
			final endPos: Int = slice.lastIndexOf('#end');
			if (endPos <= elsePos) continue;
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
				message: 'dead `#if false` region — no compilation target ever includes it'
			});
		else
			for (c in node.children) walk(out, file, source, c);
	}

	/** `true` iff the source at `from` opens with `#if false` / `#if (false)` (word-bounded). */
	private static function isIfFalseAt(source: String, from: Int): Bool {
		if (!sliceStartsWith(source, from, '#if')) return false;
		var i: Int = from + 3;
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
		var j: Int = i + 5;
		while (j < source.length && isWs(source.charCodeAt(j) ?? 0)) j++;
		return source.charCodeAt(j) == ')'.code;
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
