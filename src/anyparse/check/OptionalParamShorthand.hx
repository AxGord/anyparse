package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.RefactorSupport;

/**
 * Flags a function parameter written `name:Null<T> = null` — a nullable type with a
 * `null` default — that the `?` optional-parameter shorthand `?name:T` replaces. The
 * user's rule: for an optional nullable parameter prefer `?style:ScrollBarStyle` over
 * `style:Null<ScrollBarStyle> = null`. `Severity.Info` (a style cleanup), with an
 * autofix that rewrites the parameter to `?name:T` — unwrapping ONE `Null<>` layer,
 * dropping the ` = null`, and prepending `?`. Grammar-agnostic over
 * `RefShape.paramKinds` (unset -> no-op).
 *
 * ## Equivalence — why the rewrite is safe
 *
 * `?x:T` and `x:Null<T> = null` are equivalent for a nullable-defaulted parameter:
 * the `?` widens `x`'s type to `Null<T>` (so the body sees the same nullable value on
 * static targets), and both permit omitting the argument at trailing call sites — the
 * `= null` default and the `?` sigil compile the same calls. No call site changes.
 *
 * ## What is flagged
 *
 * A `paramKinds` node whose source does NOT start with `?` (a plain required
 * parameter), whose last child (the default value) is the `null` literal, and whose
 * type text — between the name's `:` and the default's `=` — is exactly `Null<...>`
 * (the outer `Null<>` balanced to its matching `>` at the type's end). The inner `T` is
 * source-spliced (nested `<>` and a function-type `->` are balanced correctly).
 *
 * ## Deliberate misses
 *
 * - `name:Null<T> = <non-null default>` — a different default semantics, left alone.
 * - `name:T = null` where `T` is not `Null<...>` — the type is not nullable, skipped.
 * - `?name:T` and `?name:Null<T>` — already optional (source starts with `?`); the
 *   nested `Null<Null<T>>` fix produces `?name:Null<T>`, which this convention leaves
 *   as-is (unwrapping only ONE layer, per the rule).
 */
@:nullSafety(Strict)
final class OptionalParamShorthand implements Check {

	public function new() {}

	public function id(): String {
		return 'optional-param-shorthand';
	}

	public function description(): String {
		return 'a nullable-defaulted parameter (name:Null<T> = null) the ? shorthand (?name:T) replaces';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final params: Array<String> = plugin.refShape().paramKinds ?? [];
		if (params.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, params);
		}
		return violations;
	}

	/**
	 * Rewrite each flagged parameter to `?name:T`. The parameter node is re-found by its
	 * reported span and the inner type re-derived, so the edit fires only when the bytes
	 * still match `name:Null<T> = null` (a guard against any unexpected span). The whole
	 * parameter span is replaced — commas, the surrounding parentheses, and the other
	 * parameters sit outside it, so position and trivia stay intact.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final params: Array<String> = plugin.refShape().paramKinds ?? [];
		if (params.length == 0) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];
		final byKey: Map<String, QueryNode> = [];
		RefactorSupport.indexNodesByKind(tree, params, byKey);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = byKey['${span.from}:${span.to}'];
			if (node == null) continue;
			final name: Null<String> = node.name;
			final inner: Null<String> = nullableDefaultInner(node, source);
			final ns: Null<Span> = node.span;
			if (name == null || inner == null || ns == null) continue;
			edits.push({ span: ns, text: '?$name:$inner' });
		}
		return edits;
	}

	/**
	 * Walk `node`, flagging every parameter that matches `name:Null<T> = null`. The whole
	 * tree is walked so class methods, constructors, and local functions are all reached
	 * (lambda parameters project as the same kind but the grammar does not record a
	 * default for them, so none match).
	 */
	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, params: Array<String>): Void {
		if (params.contains(node.kind)) {
			final name: Null<String> = node.name;
			final inner: Null<String> = nullableDefaultInner(node, source);
			final span: Null<Span> = node.span;
			if (name != null && inner != null && span != null) out.push({
				file: file,
				span: span,
				rule: 'optional-param-shorthand',
				severity: Severity.Info,
				message: 'prefer ?$name:$inner over $name:Null<$inner> = null'
			});
		}
		for (c in node.children) walk(out, file, source, c, params);
	}


	/**
	 * The inner type `T` of a parameter that reads `name:Null<T> = null`, else null. The
	 * parameter must be required (its span does not open with `?`), its last child (the
	 * default value) must be exactly the `null` literal, and the type text between the
	 * name's `:` and the default's `=` must be a single balanced `Null<...>`.
	 */
	private static function nullableDefaultInner(node: QueryNode, source: String): Null<String> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		// A leading `?` marks an already-optional parameter — including `?x:Null<T> = null`,
		// which this convention leaves alone (one-layer unwrap only).
		if (StringTools.fastCodeAt(source, span.from) == '?'.code) return null;
		final kids: Array<QueryNode> = node.children;
		if (kids.length == 0) return null;
		final defSpan: Null<Span> = kids[kids.length - 1].span;
		if (defSpan == null || source.substring(defSpan.from, defSpan.to) != 'null') return null;
		final colon: Int = source.indexOf(':', span.from);
		if (colon < 0 || colon >= defSpan.from) return null;
		final eq: Int = source.lastIndexOf('=', defSpan.from - 1);
		return eq <= colon ? null : unwrapNull(source.substring(colon + 1, eq));
	}

	/**
	 * The inner `T` of a `Null<T>` type text, else null. The text (trimmed) must be `Null`
	 * followed by a `<...>` whose matching close is the final character — so a same-prefix
	 * name (`Nullable<T>`) or trailing tokens are rejected. A `>` preceded by `-` is the
	 * arrow `->` of a function-type parameter, not an angle close, and does not decrement
	 * the depth.
	 */
	private static function unwrapNull(typeText: String): Null<String> {
		final t: String = StringTools.trim(typeText);
		if (!StringTools.startsWith(t, 'Null')) return null;
		var i: Int = 4;
		while (i < t.length && StringTools.isSpace(t, i)) i++;
		if (i >= t.length || StringTools.fastCodeAt(t, i) != '<'.code) return null;
		final open: Int = i;
		var depth: Int = 0;
		var close: Int = -1;
		while (i < t.length) {
			switch StringTools.fastCodeAt(t, i) {
				case '<'.code:
					depth++;
				case '>'.code if (StringTools.fastCodeAt(t, i - 1) != '-'.code):
					depth--;
					if (depth == 0) {
						close = i;
						break;
					}
				case _:
			}
			i++;
		}
		if (close < 0) return null;
		// The matching `>` must be the last non-space character, else the text is not a
		// clean single `Null<...>` (e.g. `Null<Int>Foo`).
		var j: Int = t.length - 1;
		while (j > close && StringTools.isSpace(t, j)) j--;
		if (j != close) return null;
		final inner: String = StringTools.trim(t.substring(open + 1, close));
		return inner.length > 0 ? inner : null;
	}

}
