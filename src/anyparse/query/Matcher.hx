package anyparse.query;

import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.Pattern.Metavar;
import anyparse.query.Pattern.PatternStar;
import anyparse.runtime.Span;

using StringTools;

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
 *    no length mismatch — per RUN: a node's leading `typeArgCount`
 *    children (the type arguments it writes) and the rest are two runs
 *    unified apart, and a pattern writing no type arguments constrains
 *    none.
 *  - The one exception is the `...` ellipsis (`PatternStar`): at most
 *    ONE per run, it anchors the pattern children before it as
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
			final unwritten: Array<Unwritten> = [];
			if (unify(pattern, input, eq, bindings, unwritten)) {
				final span: Null<Span> = input.span;
				if (span != null) out.push(new Match(span, bindings, input, unwritten));
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
	private static function unify(
		pattern: QueryNode, input: QueryNode, eq: Null<KindEquivalence>, bindings: Map<String, QueryNode>, unwritten: Array<Unwritten>
	): Bool {
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
			if (prior != null) return MemberKinds.structurallyEqual(prior, input);
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
		} else if (pname.startsWith('$')) {
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
		return unifyType(pattern.type, input.type, eq, bindings, unwritten) && unifyChildren(pattern, input, eq, bindings, unwritten);
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
	 *
	 * The unconstrained input type is recorded in `unwritten`, as a type argument is: nothing in
	 * the pattern holds it, so `rewrite 'final $x = $v' 'var $x = $v'` over `final f:Float = 1`
	 * wrote `var f = 1` — re-parseable, and an `Int` where there was a `Float`.
	 */
	private static function unifyType(
		pType: Null<QueryNode>, iType: Null<QueryNode>, eq: Null<KindEquivalence>, bindings: Map<String, QueryNode>,
		unwritten: Array<Unwritten>
	): Bool {
		if (pType != null) return iType != null && unify(pType, iType, eq, bindings, unwritten);
		final at: Null<Span> = iType?.span;
		if (at != null) unwritten.push(TypeAnnotation(at));
		return true;
	}

	/**
	 * Children are TWO runs, unified apart: the type arguments a node writes (its leading
	 * `typeArgCount` children — `new Map<String, Int>(x)`) and the rest. Flattened into one run,
	 * `new $C($a, $b)` bound `$a`/`$b` to the TYPE arguments of `new Map<String, Int>()` and a
	 * template moving them wrote `new Map(Int, String)`. A pattern that writes no type arguments
	 * constrains none — the rule the type slot follows — and the input's node is recorded in
	 * `unwritten`, because nothing in the pattern can carry those arguments into a replacement.
	 */
	private static function unifyChildren(
		pattern: QueryNode, input: QueryNode, eq: Null<KindEquivalence>, bindings: Map<String, QueryNode>, unwritten: Array<Unwritten>
	): Bool {
		final pTypes: Int = pattern.typeArgCount;
		final iTypes: Int = input.typeArgCount;
		final pc: Array<QueryNode> = pattern.children;
		final ic: Array<QueryNode> = input.children;
		if (pTypes == 0 && iTypes > 0) {
			final at: Null<Span> = input.span;
			if (at != null) unwritten.push(TypeArguments(at));
		} else if (!unifyRun(pc, 0, pTypes, ic, 0, iTypes, eq, bindings, unwritten))
			return false;
		return unifyRun(pc, pTypes, pc.length, ic, iTypes, ic.length, eq, bindings, unwritten);
	}

	/**
	 * One child run, `p[pFrom, pTo)` against `i[iFrom, iTo)`: ordered + adjacent. Without an
	 * ellipsis the length must match exactly; with one, the pattern's run splits into a PREFIX
	 * (matched left-to-right from the start) and a SUFFIX (matched right-to-left from the end),
	 * and the star absorbs the — possibly empty — run between them. One star per run is a
	 * parse-time invariant (`PatternStar.validate`), which is what keeps this single-pass and
	 * backtracking-free.
	 */
	private static function unifyRun(
		p: Array<QueryNode>, pFrom: Int, pTo: Int, i: Array<QueryNode>, iFrom: Int, iTo: Int, eq: Null<KindEquivalence>,
		bindings: Map<String, QueryNode>, unwritten: Array<Unwritten>
	): Bool {
		final star: Int = starIndex(p, pFrom, pTo);
		final pLen: Int = pTo - pFrom;
		final iLen: Int = iTo - iFrom;
		if (star < 0) {
			if (pLen != iLen) return false;
			for (k in 0...pLen) if (!unify(p[pFrom + k], i[iFrom + k], eq, bindings, unwritten)) return false;
			return true;
		}
		final prefix: Int = star - pFrom;
		final suffix: Int = pTo - star - 1;
		// Prefix and suffix must both FIT: a star spans zero or more children,
		// never a negative run, so an input shorter than the anchors is a miss
		// rather than an overlap (`h(1, ..., 1)` does not match `h(1)`).
		if (iLen < prefix + suffix) return false;
		for (k in 0...prefix) if (!unify(p[pFrom + k], i[iFrom + k], eq, bindings, unwritten)) return false;
		for (k in 0...suffix) if (!unify(p[pTo - 1 - k], i[iTo - 1 - k], eq, bindings, unwritten)) return false;
		return true;
	}

	/** Position of the single `...` in `children[from, to)`, or `-1` when there is none. */
	private static function starIndex(children: Array<QueryNode>, from: Int, to: Int): Int {
		for (k in from ... to) if (children[k].kind == PatternStar.KIND) return k;
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

	/**
	 * The input node the pattern unified with — its kind can differ from the pattern root's
	 * under a plugin's kind-equivalence, which is what a consumer splicing over `span` needs
	 * to know (`Rewrite` aligns a statement's terminator across such a mix).
	 */
	public final node: QueryNode;

	/**
	 * The parts of the matched nodes the pattern did not write — the type arguments of `new Box<Int>(1)`
	 * under `new $C($a)`, the type of `final b:String = 1` under `final $x = $v`: the match is sound, but no
	 * metavariable holds them, so a replacement spliced over `span` would drop them — `Rewrite` refuses such
	 * a match.
	 */
	public final unwritten: Array<Unwritten>;

	public function new(span: Span, bindings: Map<String, QueryNode>, node: QueryNode, ?unwritten: Array<Unwritten>) {
		this.span = span;
		this.bindings = bindings;
		this.node = node;
		this.unwritten = unwritten ?? [];
	}

}

/** A part of a matched node its pattern did not write, so no metavariable holds it (`Match.unwritten`). */
enum Unwritten {

	/** The type arguments of a construction (`new Box<Int>(1)` under `new $C($a)`), at the construction's span. */
	TypeArguments(at: Span);

	/** The type a declaration or a check writes (`final b:String = 1` under `final $x = $v`), at the type's span. */
	TypeAnnotation(at: Span);

}
