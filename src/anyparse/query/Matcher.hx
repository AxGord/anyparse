package anyparse.query;

import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.Pattern.Metavar;
import anyparse.query.Pattern.PatternStar;
import anyparse.runtime.Span;

/**
 * Pattern-vs-input structural matcher for `apq search`.
 *
 * Language-agnostic: operates on `Pattern` (which is `QueryNode` with
 * metavariables) and `QueryNode` input trees produced by any
 * `GrammarPlugin`. The matcher never inspects grammar-specific kind
 * names — every comparison is between strings (kind, name) and array
 * positions (children).
 *
 * Semantics (frozen in `docs/cli-query-tool.md`):
 *  - Metavariable `$X` matches any subtree at its position. Reusing
 *    `$X` inside the same pattern requires every subsequent occurrence
 *    to match a structurally-identical subtree to the first.
 *  - Metavariable `$_` is a wildcard — independent per occurrence,
 *    no binding.
 *  - Name-position metavar `$X` (kind matches, name starts with `$`)
 *    binds to the input node's name slot; structural identity
 *    constraints across reuses apply to the bound NAME string.
 *  - Child matching is ordered and adjacent — positional one-to-one
 *    between pattern children and input children, no skip-ahead and
 *    no length mismatch.
 *  - The one exception is the `...` ellipsis (`PatternStar`): at most
 *    ONE per child list, it anchors the pattern children before it as
 *    a prefix and those after it as a suffix, and absorbs the run
 *    between. It does not bind.
 *  - Whitespace and comments in patterns are ignored (handled by the
 *    plugin's pattern preprocessing, not the matcher).
 */
@:nullSafety(Strict)
final class Matcher {

	/**
	 * Walk `tree` at every node and attempt to unify it with `pattern.root`.
	 * Returns one `Match` per successful unification. Matches are
	 * reported in pre-order — outer matches before any nested matches
	 * that fall within them.
	 */
	public static function search(pattern: Pattern, tree: QueryNode, ?kindFilter: String): Array<Match> {
		final out: Array<Match> = [];
		walk(pattern.root, tree, pattern.kindEquivalence, out, kindFilter);
		return out;
	}

	private static function walk(
		pattern: QueryNode, input: QueryNode, eq: Null<KindEquivalence>, out: Array<Match>, kindFilter: Null<String>
	): Void {
		if (kindFilter == null || input.kind == kindFilter) {
			final bindings: Map<String, QueryNode> = [];
			if (unify(pattern, input, eq, bindings)) {
				final span: Null<Span> = input.span;
				if (span != null) out.push(new Match(span, bindings));
			}
		}
		for (c in input.children) walk(pattern, c, eq, out, kindFilter);
	}

	/**
	 * Bottom-up structural unification: returns `true` iff `input` is
	 * acceptable for the pattern. Side-effect: populates `bindings` with
	 * any metavar → subtree mappings discovered along the way. Each
	 * call site must supply a fresh `bindings` map; nested unifications
	 * share the same map so cross-position constraints (e.g. `$x = $x +
	 * 1`) are enforced.
	 */
	private static function unify(pattern: QueryNode, input: QueryNode, eq: Null<KindEquivalence>, bindings: Map<String, QueryNode>): Bool {
		// A star is consumed by its PARENT's child loop below and never reaches
		// here as a whole-subtree pattern — `PatternStar.validate` refuses a
		// star root at parse time. Fail closed rather than match everything if
		// some future caller builds a `Pattern` without that gate.
		if (pattern.kind == PatternStar.KIND) return false;
		// Whole-subtree metavar (e.g. bare `$x` / `$_`).
		if (pattern.kind == Metavar.KIND) {
			final n: Null<String> = pattern.name;
			if (n == null) return false;
			if (n == Metavar.WILDCARD_NAME) return true;
			final prior: Null<QueryNode> = bindings[n];
			if (prior != null) return RefactorSupport.structurallyEqual(prior, input);
			bindings[n] = input;
			return true;
		}
		// Kind must match for non-metavar patterns. A plugin may supply
		// a search-only equivalence so position-variant kinds of one
		// construct unify (Haxe `var`: VarDecl/VarMember/VarStmt); the
		// matcher consults the opaque relation, never the kind names.
		// `null` (no plugin equivalence) = strict string equality.
		if (eq == null ? pattern.kind != input.kind : !eq.equivalent(pattern.kind, input.kind)) return false;
		// Name-position match: either literal equality OR pattern carries
		// a `$<name>` metavar binding for the name slot.
		final pname: Null<String> = pattern.name;
		final iname: Null<String> = input.name;
		if (pname == null) {
			if (iname != null) return false;
		} else if (StringTools.startsWith(pname, '$')) {
			final bare: String = pname.substring(1);
			if (bare != Metavar.WILDCARD_NAME) {
				if (iname == null) return false;
				final prior: Null<QueryNode> = bindings[bare];
				if (prior == null) {
					bindings[bare] = new QueryNode('NameOnly', iname, [], input.span);
				} else if (prior.kind == 'NameOnly') {
					if (prior.name != iname) return false;
				} else {
					return false;
				}
			}
		} else if (pname != iname)
			return false;
		return unifyType(pattern.type, input.type, eq, bindings) && unifyChildren(pattern.children, input.children, eq, bindings);
	}

	/**
	 * The type SLOT — not a child, so `unifyChildren` never sees it, and until it was
	 * unified here a pattern that WROTE a type had it silently dropped: `final $x:Int = $v`
	 * matched `final b:String = 1`, and `($e : String)` matched `(o : Bytes)`.
	 *
	 * Asymmetric on purpose. A pattern with NO type slot constrains nothing, so the
	 * long-standing spelling `final $x = $v` keeps matching an annotated declaration; a
	 * pattern that names a type requires the input to carry one and to unify with it. The
	 * slot's subtree is an ordinary tree, so a metavariable inside it (`final $x:Array<$T> = $v`)
	 * binds exactly as it does anywhere else.
	 */
	private static function unifyType(
		pType: Null<QueryNode>, iType: Null<QueryNode>, eq: Null<KindEquivalence>, bindings: Map<String, QueryNode>
	): Bool {
		return pType == null || iType != null && unify(pType, iType, eq, bindings);
	}

	/**
	 * Children: ordered + adjacent. Without an ellipsis the length must match
	 * exactly; with one, the pattern's children split into a PREFIX (matched
	 * left-to-right from the start) and a SUFFIX (matched right-to-left from
	 * the end), and the star absorbs the — possibly empty — run between them.
	 * One star per child list is a parse-time invariant
	 * (`PatternStar.validate`), which is what keeps this single-pass and
	 * backtracking-free.
	 */
	private static function unifyChildren(
		pChildren: Array<QueryNode>, iChildren: Array<QueryNode>, eq: Null<KindEquivalence>, bindings: Map<String, QueryNode>
	): Bool {
		final star: Int = starIndex(pChildren);
		if (star < 0) {
			if (pChildren.length != iChildren.length) return false;
			for (k in 0...pChildren.length) {
				if (!unify(pChildren[k], iChildren[k], eq, bindings)) return false;
			}
			return true;
		}
		final suffix: Int = pChildren.length - star - 1;
		// Prefix and suffix must both FIT: a star spans zero or more children,
		// never a negative run, so an input shorter than the anchors is a miss
		// rather than an overlap (`h(1, ..., 1)` does not match `h(1)`).
		if (iChildren.length < star + suffix) return false;
		for (k in 0...star) {
			if (!unify(pChildren[k], iChildren[k], eq, bindings)) return false;
		}
		for (k in 0...suffix) {
			if (!unify(pChildren[pChildren.length - 1 - k], iChildren[iChildren.length - 1 - k], eq, bindings)) return false;
		}
		return true;
	}

	/** Position of the single `...` in a pattern's child list, or `-1` when there is none. */
	private static function starIndex(children: Array<QueryNode>): Int {
		for (k in 0...children.length) if (children[k].kind == PatternStar.KIND) return k;
		return -1;
	}

}

/**
 * One structural-pattern match: the matched source `span` plus `bindings` mapping each pattern metavariable (`$x`) to the node it captured.
 */
@:nullSafety(Strict)
final class Match {

	public final span: Span;
	public final bindings: Map<String, QueryNode>;

	public function new(span: Span, bindings: Map<String, QueryNode>) {
		this.span = span;
		this.bindings = bindings;
	}

}
