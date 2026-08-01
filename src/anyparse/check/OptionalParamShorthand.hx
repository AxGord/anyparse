package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a function parameter written `name:Null<T> = null` or `name:T = null` — a
 * nullable-or-plain type with a `null` default — that the `?` optional-parameter
 * shorthand `?name:T` replaces. The user's rule: for an optional nullable parameter
 * prefer `?style:ScrollBarStyle` over `style:Null<ScrollBarStyle> = null`; and, since a
 * `null`-defaulted plain-type parameter types identically, `?position:Point` over
 * `position:Point = null` too. `Severity.Info` (a style cleanup), with an autofix that
 * rewrites the parameter to `?name:T` — unwrapping one `Null<>` layer when present (else
 * keeping the type as-is), dropping the ` = null`, and prepending `?`. Grammar-agnostic
 * over `RefShape.paramKinds` (unset -> no-op).
 *
 * ## Equivalence — why the rewrite is safe
 *
 * `?x:T` and `x:Null<T> = null` are equivalent for a nullable-defaulted parameter: the
 * `?` widens `x`'s type to `Null<T>` (so the body sees the same nullable value on static
 * targets), and both permit omitting the argument at trailing call sites — the `= null`
 * default and the `?` sigil compile the same calls. No call site changes. A live compiler
 * probe additionally confirmed `x:T = null` types identically: `$type` gives
 * `(?p:Null<T>) -> Void` for BOTH `p:Int = null` and `?p:Int`, and the `haxe.PosInfos`
 * call-site auto-fill magic fires in both forms — so the bare-type arm needs no extra
 * gates.
 *
 * ## What is flagged
 *
 * A `paramKinds` node whose source does NOT start with `?` (a plain required parameter),
 * whose last child (the default value) is the `null` literal, and whose type text —
 * between the name's `:` and the default's `=` — is either a single balanced `Null<...>`
 * (the outer `Null<>` balanced to its matching `>` at the type's end, inner `T`
 * source-spliced with nested `<>` and a function-type `->` balanced correctly) or any
 * other non-empty type text (`name:T = null`) that does not itself open as a `Null<`
 * wrapper.
 *
 * ## Deliberate misses
 *
 * - `name:Null<T> = <non-null default>` — a different default semantics, left alone.
 * - `?name:T` and `?name:Null<T>` — already optional (source starts with `?`); the
 *   nested `Null<Null<T>>` fix produces `?name:Null<T>`, which this convention leaves
 *   as-is (unwrapping only ONE layer, per the rule).
 * - `name = null` (no type annotation) — nothing to move the `?` onto, skipped.
 * - A `Null<`-prefixed type text that `unwrapNull` rejects — decorated (e.g. a comment
 *   between the type and the `=`) or malformed; coercing it into the bare-type arm
 *   would prepend `?` without unwrapping, so it stays a safe miss.
 */
@:nullSafety(Strict)
final class OptionalParamShorthand implements Check {

	public function new() {}

	public function id(): String {
		return 'optional-param-shorthand';
	}

	public function description(): String {
		return 'a nullable-defaulted parameter (name:Null<T> = null or name:T = null) the ? shorthand (?name:T) replaces';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final params: Array<String> = plugin.refShape().paramKinds ?? [];
		if (params.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
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
		return params.length == 0
			? []
			: CheckScan.applyBySpan(plugin, source, violations, params, (node, span) -> {
				final name: Null<String> = node.name;
				final shape: Null<{ inner: String, raw: String }> = nullableDefaultInner(node, source);
				return name == null || shape == null ? null : { span: span, text: '?$name:${shape.inner}' };
			});
	}

	/**
	 * Walk `node`, flagging every parameter that matches a nullable-defaulted parameter
	 * shape (`name:Null<T> = null` or `name:T = null`). The whole tree is walked so class
	 * methods, constructors, and local functions are all reached (lambda parameters project
	 * as the same kind but the grammar does not record a default for them, so none match).
	 */
	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, params: Array<String>): Void {
		if (params.contains(node.kind)) {
			final name: Null<String> = node.name;
			final shape: Null<{ inner: String, raw: String }> = nullableDefaultInner(node, source);
			final span: Null<Span> = node.span;
			if (name != null && shape != null && span != null) out.push({
				file: file,
				span: span,
				rule: 'optional-param-shorthand',
				severity: Severity.Info,
				message: 'prefer ?$name:${shape.inner} over $name:${shape.raw} = null'
			});
		}
		for (c in node.children) walk(out, file, source, c, params);
	}


	/**
	 * The nullable-defaulted parameter shape of a parameter that reads `name:Null<T> = null`
	 * or `name:T = null`, else null. The parameter must be required (its span does not open
	 * with `?`), and its last child (the default value) must be exactly the `null` literal.
	 * When the type text between the name's `:` and the default's `=` unwraps as a single
	 * `Null<T>`, `inner` is `T` (the wrapped arm); otherwise the type text stands as its own
	 * `inner` (the bare-type arm) — a live compiler probe confirmed `p:T = null` and `?p:T`
	 * type identically to `(?p:Null<T>)`, so the rewrite is safe without unwrapping. A
	 * `Null<`-prefixed text that `unwrapNull` rejected (decorated or malformed) is refused
	 * rather than claimed by the bare arm. `raw` is always the trimmed type text, used to
	 * compose the violation message.
	 */
	private static function nullableDefaultInner(node: QueryNode, source: String): Null<{ inner: String, raw: String }> {
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
		if (eq <= colon) return null;
		final typeText: String = source.substring(colon + 1, eq);
		final raw: String = StringTools.trim(typeText);
		final unwrapped: Null<String> = unwrapNull(typeText);
		if (unwrapped != null) return { inner: unwrapped, raw: raw };
		return raw.length > 0 && !nullWrapperPrefixed(raw) ? { inner: raw, raw: raw } : null;
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


	/**
	 * Whether the trimmed type text opens as a `Null<` wrapper — `Null` followed, after
	 * optional spaces, by `<`. Such a text that `unwrapNull` still rejected is a decorated
	 * or malformed `Null<...>` (e.g. a trailing comment before the default's `=`), which
	 * the bare-type arm must not claim: coercing it would prepend `?` without unwrapping,
	 * violating the one-layer-unwrap contract.
	 */
	private static function nullWrapperPrefixed(t: String): Bool {
		if (!StringTools.startsWith(t, 'Null')) return false;
		var i: Int = 4;
		while (i < t.length && StringTools.isSpace(t, i)) i++;
		return i < t.length && StringTools.fastCodeAt(t, i) == '<'.code;
	}

}
