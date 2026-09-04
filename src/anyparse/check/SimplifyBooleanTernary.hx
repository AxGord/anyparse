package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.BoolExprShape;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a ternary whose then- or else-branch is a boolean literal — a
 * `cond ? false : x` / `cond ? x : true` style expression that reduces to plain
 * boolean logic (`!cond && x` / `!cond || x`). `Severity.Info` with an autofix.
 *
 * Composes with `prefer-ternary-return` through the `--fix` fixed-point loop: that
 * check turns an `if (cond) return false; return x;` guard into
 * `return cond ? false : x;`, and this one then reduces it to
 * `return !cond && x;` — so a boolean-returning guard chain collapses all the way
 * to a single flat boolean `return`, with no `if` and no ternary left.
 *
 * ## It owns a boolean-reducible CHAIN HEAD
 *
 * `a ? false : b ? c : d` is both this shape and a three-value chain, and both rules used to
 * report the same span: whichever ran first decided the file's fixed point (`--rule
 * prefer-if-expression-chain --rule simplify-boolean-ternary` wrote the six-line `if (a) false
 * else if (b) c else d`, the two flags swapped wrote `!a && (b ? c : d)` -- same input, same
 * engine). The reduction wins, because after it BOTH canons hold: no boolean-literal branch for
 * this rule, and whatever remains is still reachable by the chain rule, which converts it when it
 * is still three values. The chain rewrite instead leaves a `false` leaf nothing can ever reach
 * again. `prefer-if-expression-chain` defers by asking `claimedSpans`, which shares `walkClaims`
 * -- and therefore `claims` -- with `run`, so the two answers cannot drift apart.
 *
 * ## Grammar-agnostic
 *
 * Locates ternary nodes via `RefShape.ternaryKind` and delegates the rewrite to
 * `BooleanLogicSupport.simplifyBooleanTernary` (the seam owning the
 * language-specific De Morgan negation, precedence, and parenthesisation). A
 * grammar without the kind or the seam makes the check a no-op. A real-valued
 * ternary (neither branch a boolean literal) yields null from the seam and is
 * left alone.
 */
@:nullSafety(Strict)
final class SimplifyBooleanTernary implements Check {

	public function new() {}

	public function id(): String {
		return 'simplify-boolean-ternary';
	}

	public function description(): String {
		return 'a ternary with a boolean-literal branch that reduces to a boolean expression';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final shape: RefShape = seams.shape;
		final ternaryKind: String = seams.ternaryKind;
		final support: BooleanLogicSupport = seams.support;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, ternaryKind, support, shape, null, false);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final ternaryKind: String = seams.ternaryKind;
		final support: BooleanLogicSupport = seams.support;
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final shape: RefShape = seams.shape;
		final nodeBySpan: Map<String, QueryNode> = [];
		final licenceBySpan: Map<String, Bool> = [];
		indexTernaries(tree, source, ternaryKind, shape, null, false, nodeBySpan, licenceBySpan);
		// The type probe licenses the ordered-comparison FLIP inside a negated condition
		// (`(x < 0) ? false : p == true` -> `x >= 0 && p == true` for an `Int` x); without it
		// the negation keeps the sound `!(x < 0)` wrap. `run` builds none — see `walk`.
		final types: Null<(QueryNode) -> Null<String>> = CheckScan.typeNominalResolver(source, plugin, tree, violations[0].file, index);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = nodeBySpan['${span.from}:${span.to}'];
			if (node == null) continue;
			final key: String = '${span.from}:${span.to}';
			final replacement: Null<String> = support.simplifyBooleanTernary(node, source, types, licenceBySpan[key] == true);
			if (replacement == null) continue;
			edits.push({ span: span, text: replacement });
		}
		return edits;
	}

	/**
	 * Whether this check claims `node` — its whole trigger, in one place.
	 *
	 * `run` asks it through `walkClaims` and `prefer-if-expression-chain` asks it through
	 * `claimedSpans`, so the deferral there can never rest on a mirrored gate that drifts
	 * when this one moves. The `retType` / `isReturnValue` pair is the context
	 * `boolReturnLicence` needs and no caller can reconstruct at the node.
	 */
	public static function claims(
		node: QueryNode, source: String, ternaryKind: String, support: BooleanLogicSupport, shape: RefShape, retType: Null<String>,
		isReturnValue: Bool
	): Bool {
		return node.kind == ternaryKind && !condGuarded(node, shape)
			&& support.simplifyBooleanTernary(node, source, null, boolReturnLicence(node, source, shape, retType, isReturnValue)) != null;
	}

	/**
	 * The `"$from:$to"` span key of every ternary this check claims in `source`, for a rule that
	 * must defer to it.
	 *
	 * A SET rather than a per-node predicate because the claim needs the enclosing function's
	 * declared return type and whether the node sits in a value-return slot — context only a walk
	 * from the root carries. The caller holds the tree already, so the set costs one extra
	 * traversal per file and is memoised at the call site.
	 */
	public static function claimedSpans(source: String, tree: QueryNode, plugin: GrammarPlugin): Map<String, Bool> {
		final out: Map<String, Bool> = [];
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return out;
		walkClaims(tree, source, seams.ternaryKind, seams.support, seams.shape, null, false, claimed -> {
			final span: Null<Span> = claimed.span;
			if (span != null) out['${span.from}:${span.to}'] = true;
		});
		return out;
	}

	/**
	 * Walk `node`, flagging each ternary the seam can reduce, except a null-narrowing-guarded one.
	 *
	 * No type resolver is passed, and none is needed: the probe only decides whether a negated
	 * ordered comparison FLIPS or stays wrapped, never whether the seam can reduce at all (no
	 * `return null` path in `simplifyBooleanTernary` consults the negation), so the yes/no answer
	 * this pass needs is resolver-independent. `fix` builds it, since only `fix` consumes the text.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, ternaryKind: String, support: BooleanLogicSupport,
		shape: RefShape, retType: Null<String>, isReturnValue: Bool
	): Void {
		walkClaims(node, source, ternaryKind, support, shape, retType, isReturnValue, claimed -> {
			final span: Null<Span> = claimed.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'simplify-boolean-ternary',
				severity: Severity.Info,
				message: 'this ternary can be a boolean expression'
			});
		});
	}

	/**
	 * The three grammar seams every entry point reads, or null when the grammar lacks one — the
	 * check is then a no-op. Read in ONE place so `run`, `fix` and `claimedSpans` cannot disagree
	 * about whether this check is live at all.
	 */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ternaryKind: Null<String> = shape.ternaryKind;
		final support: Null<BooleanLogicSupport> = plugin.booleanLogicSupport();
		return ternaryKind == null || support == null ? null : { shape: shape, ternaryKind: ternaryKind, support: support };
	}

	/**
	 * Visit every ternary this check claims under `node`, threading the return-type context
	 * `boolReturnLicence` needs. The ONE traversal behind both `run`'s report and
	 * `claimedSpans`, so a deferring rule can never be told a different answer from the one
	 * this check acts on.
	 */
	private static function walkClaims(
		node: QueryNode, source: String, ternaryKind: String, support: BooleanLogicSupport, shape: RefShape, retType: Null<String>,
		isReturnValue: Bool, onClaim: (QueryNode) -> Void
	): Void {
		if (claims(node, source, ternaryKind, support, shape, retType, isReturnValue)) onClaim(node);
		eachChild(
			node, source, shape, retType,
			(kid, kidRet, kidIsReturnValue) -> walkClaims(kid, source, ternaryKind, support, shape, kidRet, kidIsReturnValue, onClaim)
		);
	}

	/**
	 * Visit each child of `node` with the two facts a boolean-licence decision needs about it:
	 * the return-type source in force there (rebound whenever `node` is a function) and whether
	 * it sits in the function's RETURN-VALUE slot — the first child of a `valueReturnKinds`
	 * host, which covers the `return e;` statement form and the expression-bodied `return e`
	 * form alike. The ONE copy of the threading, shared by `run`'s `walk` and `fix`'s
	 * `indexTernaries`: the two must agree about which ternaries are licensed, and duplicating
	 * the descent is how they would silently stop agreeing.
	 */
	private static function eachChild(
		node: QueryNode, source: String, shape: RefShape, retType: Null<String>,
		visit: (kid:QueryNode, kidRetType:Null<String>, kidIsReturnValue:Bool) -> Void
	): Void {
		final kids: Array<QueryNode> = node.children;
		final childRetType: Null<String> = TypeResolver.childReturnTypeSource(
			node, source, retType, shape.functionKinds ?? [], shape.lambdaKinds ?? [], shape.functionBodyKinds ?? [],
			shape.paramKinds ?? []
		);
		final hostsReturnValue: Bool = (shape.valueReturnKinds ?? []).contains(node.kind);
		for (i in 0...kids.length) visit(kids[i], childRetType, hostsReturnValue && i == 0);
	}

	/**
	 * Whether the caller may tell the seam that this ternary's VALUE is a non-null boolean —
	 * the proof `provablyBool` cannot read off a branch's kind. Three conditions, all required:
	 *
	 *  1. the ternary is the DIRECT value of a value-returning `return` (`valueReturnKinds`,
	 *     which covers the statement form and the expression-bodied `return e` form alike).
	 *     A ternary nested deeper inside the returned expression is typed by whatever encloses
	 *     it, not by the function's signature, so it gets nothing;
	 *  2. the enclosing function DECLARES the non-null boolean nominal
	 *     (`RefactorSupport.declaresNonNullBool` — `Null<Bool>`, `Dynamic`, `Any` and a missing
	 *     annotation all refuse);
	 *  3. the non-literal branch is not a `null` literal or a statement-like expression
	 *     (`RefactorSupport.statementLikeOrNullTail`) — those reduce soundly but read worse
	 *     than the ternary, which is the very thing the gate exists to prevent.
	 *
	 * A ternary with two boolean-literal branches, or none, returns false: the seam decides
	 * those without any type proof, and handing it a licence it does not consult would only
	 * blur what the flag means.
	 */
	private static function boolReturnLicence(
		node: QueryNode, source: String, shape: RefShape, retType: Null<String>, isReturnValue: Bool
	): Bool {
		if (!isReturnValue || node.children.length != 3 || !BoolExprShape.declaresNonNullBool(retType, shape)) return false;
		final boolLitKind: Null<String> = shape.boolLitKind;
		if (boolLitKind == null) return false;
		final thenBool: Bool = node.children[1].kind == boolLitKind;
		final elseBool: Bool = node.children[2].kind == boolLitKind;
		if (thenBool == elseBool) return false;
		final other: QueryNode = thenBool ? node.children[2] : node.children[1];
		return !BoolExprShape.statementLikeOrNullTail(other, shape) && !BoolExprShape.pendingBooleanTernaryTail(other, shape);
	}

	/**
	 * True when the ternary's condition carries a null-narrowing guard
	 * (`x != null && x.f`): reducing it to flat boolean logic would drop the
	 * narrowing and fail to compile under `@:nullSafety(Strict)`, so it is skipped.
	 */
	private static function condGuarded(node: QueryNode, shape: RefShape): Bool {
		return node.children.length > 0 && BoolExprShape.hasNullNarrowingGuard(node.children[0], shape);
	}

	/**
	 * Index every ternary node by its `from:to` span key (for `fix` to re-find a flagged node),
	 * and alongside it the `boolReturnLicence` that node was judged with. The licence has to be
	 * recomputed here rather than carried on the violation: a `Violation` is a span plus a
	 * message, and `fix` re-parses the source into a FRESH tree, so the walk that produced the
	 * finding no longer exists. Mirroring `walk`'s threading exactly is what keeps `run` and
	 * `fix` from disagreeing about which ternaries reduce.
	 */
	private static function indexTernaries(
		node: QueryNode, source: String, ternaryKind: String, shape: RefShape, retType: Null<String>, isReturnValue: Bool,
		out: Map<String, QueryNode>, licences: Map<String, Bool>
	): Void {
		if (node.kind == ternaryKind) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out['${span.from}:${span.to}'] = node;
				licences['${span.from}:${span.to}'] = boolReturnLicence(node, source, shape, retType, isReturnValue);
			}
		}
		eachChild(
			node, source, shape, retType,
			(kid, kidRet, kidIsReturnValue) -> indexTernaries(kid, source, ternaryKind, shape, kidRet, kidIsReturnValue, out, licences)
		);
	}

}

/** The grammar seams this check needs to be live at all: the ternary kind, the boolean-logic engine, and the shape. */
private typedef Seams = {
	var shape: RefShape;
	var ternaryKind: String;
	var support: BooleanLogicSupport;
}
