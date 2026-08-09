package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags a function parameter written `name:Null<T> = null` or `name:T = null` — a
 * nullable-or-plain type with a `null` default — that the `?` optional-parameter
 * shorthand `?name:T` replaces, and an already-optional parameter carrying a redundant
 * `null` default (`?name:T = null`). The user's rule: for an optional nullable parameter
 * prefer `?style:ScrollBarStyle` over `style:Null<ScrollBarStyle> = null`; and, since a
 * `null`-defaulted plain-type parameter types identically, `?position:Point` over
 * `position:Point = null` too. `Severity.Info` (a style cleanup), with an autofix that
 * rewrites the parameter to `?name:T` — unwrapping one `Null<>` layer when present (else
 * keeping the type as-is), dropping the ` = null`, and prepending `?`; for an
 * already-optional parameter the type is kept verbatim and only the ` = null` is
 * dropped. Grammar-agnostic over `RefShape.paramKinds` (unset -> no-op).
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
 * gates. For the already-optional arm the equivalence is immediate: an omitted `?x:T`
 * argument already yields `null`, so an explicit `= null` default changes nothing.
 *
 * ## What is flagged
 *
 * A `paramKinds` node whose last child (the default value) is the `null` literal and
 * which is either: a plain required parameter (source does not start with `?`) whose
 * type text — between the name's `:` and the default's `=` — is a single balanced
 * `Null<...>` (the outer `Null<>` balanced to its matching `>` at the type's end, inner
 * `T` source-spliced with nested `<>` and a function-type `->` balanced correctly) or
 * any other non-empty type text (`name:T = null`) that does not itself open as a `Null<`
 * wrapper; or an already-optional parameter (`?name:T = null`) with any non-empty type
 * text — the `?` sigil already makes it optional, so the `= null` is redundant and the
 * fix drops it, keeping the type verbatim (`?name:Null<T> = null` fixes to
 * `?name:Null<T>`, no unwrap).
 *
 * ## Deliberate misses
 *
 * - `name:Null<T> = <non-null default>` — a different default semantics, left alone.
 * - `?name:T` and `?name:Null<T>` without a default — nothing redundant to drop; the
 *   nested `Null<Null<T>>` fix produces `?name:Null<T>`, which this convention leaves
 *   as-is (unwrapping only ONE layer, per the rule).
 * - `name = null` and `?name = null` (no type annotation) — skipped: no type text to
 *   carry the rewrite.
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
		return
			'a nullable-defaulted parameter (name:Null<T> = null or name:T = null) the ? shorthand (?name:T) replaces, or a redundant = null default on an already-optional ?name:T';
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
				final shape: Null<{ inner: String, raw: String, opt: Bool }> = nullableDefaultInner(node, source);
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
			final shape: Null<{ inner: String, raw: String, opt: Bool }> = nullableDefaultInner(node, source);
			final span: Null<Span> = node.span;
			if (name != null && shape != null && span != null) out.push({
				file: file,
				span: span,
				rule: 'optional-param-shorthand',
				severity: Severity.Info,
				message: 'prefer ?$name:${shape.inner} over ${shape.opt ? '?' : ''}$name:${shape.raw} = null'
			});
		}
		for (c in node.children) walk(out, file, source, c, params);
	}


	/**
	 * The nullable-defaulted parameter shape of a parameter that reads `name:Null<T> = null`,
	 * `name:T = null`, or `?name:T = null`, else null. The parameter's last child (the
	 * default value) must be exactly the `null` literal. For a required parameter (no
	 * leading `?`), when the type text between the name's `:` and the default's `=` unwraps
	 * as a single `Null<T>`, `inner` is `T` (the wrapped arm); otherwise the type text
	 * stands as its own `inner` (the bare-type arm) — a live compiler probe confirmed
	 * `p:T = null` and `?p:T` type identically to `(?p:Null<T>)`, so the rewrite is safe
	 * without unwrapping. A `Null<`-prefixed text that `unwrapNull` rejected (decorated or
	 * malformed) is refused rather than claimed by the bare arm. For an already-optional
	 * parameter (`opt` true) the `= null` default is redundant — `inner` is the type text
	 * verbatim (no unwrap, so `?x:Null<T> = null` keeps `Null<T>`), and the fix only drops
	 * the ` = null`. `raw` is always the trimmed type text, used to compose the violation
	 * message.
	 */
	private static function nullableDefaultInner(node: QueryNode, source: String): Null<{ inner: String, raw: String, opt: Bool }> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final opt: Bool = source.fastCodeAt(span.from) == '?'.code;
		final kids: Array<QueryNode> = node.children;
		if (kids.length == 0) return null;
		final defSpan: Null<Span> = kids[kids.length - 1].span;
		if (defSpan == null || source.substring(defSpan.from, defSpan.to) != 'null') return null;
		final colon: Int = source.indexOf(':', span.from);
		if (colon < 0 || colon >= defSpan.from) return null;
		final eq: Int = source.lastIndexOf('=', defSpan.from - 1);
		if (eq <= colon) return null;
		final typeText: String = source.substring(colon + 1, eq);
		final raw: String = typeText.trim();
		if (opt) return raw.length > 0 ? { inner: raw, raw: raw, opt: true } : null;
		final unwrapped: Null<String> = unwrapNull(typeText);
		return if (unwrapped != null)
			{ inner: unwrapped, raw: raw, opt: false }
		else if (raw.length > 0 && !nullWrapperPrefixed(raw))
			{ inner: raw, raw: raw, opt: false }
		else
			null;
	}

	/**
	 * The inner `T` of a `Null<T>` type text, else null. The text (trimmed) must be `Null`
	 * followed by a `<...>` whose matching close is the final character — so a same-prefix
	 * name (`Nullable<T>`) or trailing tokens are rejected. A `>` preceded by `-` is the
	 * arrow `->` of a function-type parameter, not an angle close, and does not decrement
	 * the depth.
	 */
	private static function unwrapNull(typeText: String): Null<String> {
		final t: String = typeText.trim();
		if (!t.startsWith('Null')) return null;
		var i: Int = 4;
		while (i < t.length && t.isSpace(i)) i++;
		if (i >= t.length || t.fastCodeAt(i) != '<'.code) return null;
		final open: Int = i;
		var depth: Int = 0;
		var close: Int = -1;
		while (i < t.length) {
			switch t.fastCodeAt(i) {
				case '<'.code:
					depth++;
				case '>'.code if (t.fastCodeAt(i - 1) != '-'.code):
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
		while (j > close && t.isSpace(j)) j--;
		if (j != close) return null;
		final inner: String = t.substring(open + 1, close).trim();
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
		if (!t.startsWith('Null')) return false;
		var i: Int = 4;
		while (i < t.length && t.isSpace(i)) i++;
		return i < t.length && t.fastCodeAt(i) == '<'.code;
	}

}
