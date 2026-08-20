package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
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
		final shape: RefShape = plugin.refShape();
		final ternaryKind: Null<String> = shape.ternaryKind;
		final support: Null<BooleanLogicSupport> = plugin.booleanLogicSupport();
		if (ternaryKind == null || support == null) return [];
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
		final ternaryKind: Null<String> = plugin.refShape().ternaryKind;
		final support: Null<BooleanLogicSupport> = plugin.booleanLogicSupport();
		if (ternaryKind == null || support == null || violations.length == 0) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final shape: RefShape = plugin.refShape();
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
		if (
			node.kind == ternaryKind && !condGuarded(node, shape)
			&& support.simplifyBooleanTernary(node, source, null, boolReturnLicence(node, source, shape, retType, isReturnValue)) != null
		) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'simplify-boolean-ternary',
				severity: Severity.Info,
				message: 'this ternary can be a boolean expression'
			});
		}
		final kids: Array<QueryNode> = node.children;
		final childRetType: Null<String> = childReturnType(node, source, shape, retType);
		final hostsReturnValue: Bool = (shape.valueReturnKinds ?? []).contains(node.kind);
		for (i in 0...kids.length) walk(out, file, source, kids[i], ternaryKind, support, shape, childRetType, hostsReturnValue && i == 0);
	}

	/** `TypeResolver.childReturnTypeSource` with this check's seams unpacked from `shape`. */
	private static function childReturnType(node: QueryNode, source: String, shape: RefShape, retType: Null<String>): Null<String> {
		return TypeResolver.childReturnTypeSource(
			node, source, retType, shape.functionKinds ?? [], shape.lambdaKinds ?? [], shape.functionBodyKinds ?? [],
			shape.paramKinds ?? []
		);
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
		if (!isReturnValue || node.children.length != 3 || !RefactorSupport.declaresNonNullBool(retType, shape)) return false;
		final boolLitKind: Null<String> = shape.boolLitKind;
		if (boolLitKind == null) return false;
		final thenBool: Bool = node.children[1].kind == boolLitKind;
		final elseBool: Bool = node.children[2].kind == boolLitKind;
		if (thenBool == elseBool) return false;
		final other: QueryNode = thenBool ? node.children[2] : node.children[1];
		return !RefactorSupport.statementLikeOrNullTail(other, shape) && !RefactorSupport.pendingBooleanTernaryTail(other, shape);
	}

	/**
	 * True when the ternary's condition carries a null-narrowing guard
	 * (`x != null && x.f`): reducing it to flat boolean logic would drop the
	 * narrowing and fail to compile under `@:nullSafety(Strict)`, so it is skipped.
	 */
	private static function condGuarded(node: QueryNode, shape: RefShape): Bool {
		return node.children.length > 0 && RefactorSupport.hasNullNarrowingGuard(node.children[0], shape);
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
		final kids: Array<QueryNode> = node.children;
		final childRetType: Null<String> = childReturnType(node, source, shape, retType);
		final hostsReturnValue: Bool = (shape.valueReturnKinds ?? []).contains(node.kind);
		for (i in 0...kids.length) {
			indexTernaries(kids[i], source, ternaryKind, shape, childRetType, hostsReturnValue && i == 0, out, licences);
		}
	}

}
