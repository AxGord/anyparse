package anyparse.query;

import anyparse.query.Pattern.Metavar;
import anyparse.query.Pattern.KindEquivalence;
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
 *  - Star-children matching is ordered and adjacent — positional
 *    one-to-one between pattern children and input children, no
 *    skip-ahead and no length mismatch.
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
		// Whole-subtree metavar (e.g. bare `$x` / `$_`).
		if (pattern.kind == Metavar.KIND) {
			final n: Null<String> = pattern.name;
			if (n == null) return false;
			if (n == Metavar.WILDCARD_NAME) return true;
			final prior: Null<QueryNode> = bindings[n];
			if (prior == null) {
				bindings[n] = input;
				return true;
			}
			return structurallyEqual(prior, input);
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
		} else {
			if (pname != iname) return false;
		}
		// Children: ordered + adjacent. Length must match exactly.
		final pChildren: Array<QueryNode> = pattern.children;
		final iChildren: Array<QueryNode> = input.children;
		if (pChildren.length != iChildren.length) return false;
		for (k in 0...pChildren.length) {
			if (!unify(pChildren[k], iChildren[k], eq, bindings)) return false;
		}
		return true;
	}

	private static function structurallyEqual(a: QueryNode, b: QueryNode): Bool {
		if (a.kind != b.kind) return false;
		if (a.name != b.name) return false;
		if (a.children.length != b.children.length) return false;
		for (k in 0...a.children.length) {
			if (!structurallyEqual(a.children[k], b.children[k])) return false;
		}
		return true;
	}

}

@:nullSafety(Strict)
final class Match {

	public final span: Span;
	public final bindings: Map<String, QueryNode>;

	public function new(span: Span, bindings: Map<String, QueryNode>) {
		this.span = span;
		this.bindings = bindings;
	}

}
