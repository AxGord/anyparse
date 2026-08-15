package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a value that is IMMEDIATELY returned right after it is produced, collapsing the pair
 * to a single return. The value is produced either by a local DECLARATION or by a plain
 * ASSIGNMENT to a pre-existing param / local:
 *
 * ```haxe
 * final x:Int = compute();
 * return x;
 * // ->
 * return compute();
 * ```
 *
 * `Info` -- the code is correct, this is a readability simplification. The `return` sibling
 * of `join-declaration-assignment`: where that joins a declaration and its next assignment,
 * this joins a declaration and its next return.
 *
 * ## The type annotation can be load-bearing
 *
 * A `:Type` annotation on the local is not always cosmetic -- it can drive an implicit
 * `@:from` conversion the plain value would not:
 *
 * ```haxe
 * final color:types.Color = str; // str : String, Color has @:from String
 * return color;
 * ```
 *
 * So the annotation is preserved unless the enclosing function's OWN explicit return type
 * already re-states it (then the conversion happens at the return boundary regardless):
 *
 * - unannotated decl -> always `return e;`;
 * - annotated decl AND the enclosing function's explicit return type equals the annotation
 *   (byte-identical source, whitespace ignored) -> `return e;`;
 * - annotated decl whose initializer is a constructor call `new T(...)` -- `T` byte-identical
 *   (whitespace ignored) to the annotation and carrying no type parameters -> `return e;` too:
 *   the constructor call already fixes the value's own type, so the ascription would restate
 *   it with nothing left to pin. A generic annotation (`Map<String, Int>`) still ascribes --
 *   its type parameters are exactly what the ascription pins on an otherwise inference-open
 *   `new Map()`;
 * - annotated decl otherwise (a differing or inferred function return type, or an initializer
 *   that is not a matching bare `new T(...)`) -> the annotation is kept as a type-check
 *   ascription `return (e : Type);`.
 *
 * ## What is flagged
 *
 * Two CONSECUTIVE statements of one statement list (`ControlFlowSupport.blockKinds`) where:
 *
 * - the first is a single-variable local declaration (`localDeclKinds`) WITH an initializer
 *   -- exactly one child, the initializer expression; a multi-declarator (`final a, b = …`)
 *   is skipped via a top-level comma in the pre-initializer text;
 * - the second is `return name;` (`returnStatementKind` with one child) whose returned
 *   expression is exactly the declared identifier (`identKind`, same name);
 * - the declared local has NO reference other than that return -- resolved through `Refs`,
 *   so a self-reference in the initializer or a use in unreachable trailing code disqualifies;
 * - no comment sits in a region the collapse drops (anything but the initializer text).
 *
 * Adjacency is required: only the IMMEDIATELY following return qualifies. The reported span
 * is the declaration.
 *
 * ## Autofix
 *
 * `fix` replaces both statements with the single return (verbatim initializer, plus the
 * ascription when the annotation must survive). Needs `localDeclKinds`, `returnStatementKind`
 * and `controlFlowSupport` (any unset makes the check a no-op); function return-type
 * detection additionally reads `functionKinds` / `lambdaKinds` / `paramKinds` /
 * `functionBodyKinds`, and when those are unset an annotated decl always ascribes (a
 * type-check that always compiles). The `new T(...)`-matches-annotation ascription skip
 * additionally reads `newExprKind`; unset, that skip never fires and an annotated decl keeps
 * ascribing -- still correct, just more conservative.
 * ## The assignment arm
 *
 * The second form is an assignment `x = e;` to a PRE-EXISTING binding (a param, or a local
 * declared earlier), immediately followed by `return x;`:
 *
 * ```haxe
 * str = normalise(str);
 * return str;
 * // ->
 * return normalise(str);
 * ```
 *
 * Because `x` already exists, sole-reference counting does not apply; safety rests on
 * reference analysis (through `Refs`, needs `exprStatementKind` / `assignKind`, else this arm
 * is a no-op) over the whole function:
 *
 * - `x` must resolve to a LOCAL or PARAM, never a field -- a bare field write (`this.x = e`
 *   spelled `x = e`) would silently drop the store the collapse removes;
 * - `x` is captured by NO lambda (`lambdaKinds`) -- a closure could observe the dropped store
 *   after the function returns, so any capture is a conservative escape gate;
 * - `x` has NO read after the assignment other than this return (a trailing / branch read,
 *   even unreachable, disqualifies -- the return is the function tail);
 * - `x` keeps a SURVIVING read (a read before the assignment or inside `e`), so the collapse
 *   does not orphan the binding into a dead local;
 * - a plain `=` only (a compound `+=` / `-=` is a distinct node kind and never joins).
 *
 * The DECLARATION arm keeps priority: when the statement before the return is a decl it is
 * matched there, never here. `x`'s declared type drives the SAME ascription decision as the
 * declaration arm -- plain `return e;` when it matches the function return type or `x` is
 * unannotated, else `return (e : T);`.
 */
@:nullSafety(Strict)
final class JoinReturn implements Check {

	/** A single-variable declaration with an initializer projects as exactly one child: the initializer. */
	private static inline final INIT_CHILD_COUNT: Int = 1;

	/** A valued `return` node has exactly one child: the returned expression. */
	private static inline final RETURN_VALUE_CHILD_COUNT: Int = 1;

	/** An expression statement wraps exactly one expression (here, the assignment). */
	private static inline final EXPR_STMT_CHILD_COUNT: Int = 1;

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return 'join-return';
	}

	public function description(): String {
		return 'a local declaration whose value is immediately returned, joinable to a single return';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, entry.source);
			if (tree == null) continue;
			final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(entry.source);
			final declTypeSources: () -> Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(plugin, entry.source);
			final lambdaSpans: Array<Span> = [];
			collectLambdaSpans(tree, seams.shape.lambdaKinds ?? [], lambdaSpans);
			final matches: Array<Match> = [];
			collectMatches(tree, entry.source, comments, null, seams, tree, declTypeSources, lambdaSpans, matches);
			for (m in matches) violations.push({
				file: entry.file,
				span: m.declSpan,
				rule: 'join-return',
				severity: Severity.Info,
				message: m.message
			});
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, source);
		if (tree == null) return [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final declTypeSources: () -> Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(plugin, source);
		final lambdaSpans: Array<Span> = [];
		collectLambdaSpans(tree, seams.shape.lambdaKinds ?? [], lambdaSpans);
		final matches: Array<Match> = [];
		collectMatches(tree, source, comments, null, seams, tree, declTypeSources, lambdaSpans, matches);
		final byKey: Map<String, Match> = [];
		for (m in matches) byKey['${m.declSpan.from}:${m.declSpan.to}'] = m;

		return RefactorSupport.dropContainedEdits(
			CheckScan.collectSpanEdits(violations, byKey, (m, _) -> ({ span: m.editSpan, text: m.text }))
		);
	}

	/**
	 * The verbatim source of `fn`'s explicit return type, or null when it declares none. The
	 * return type is the child immediately before the body (`functionBodyKinds`) when that
	 * child is not a parameter (`paramKinds`).
	 */
	private static inline function functionReturnTypeSource(fn: QueryNode, s: Seams, source: String): Null<String> {
		return TypeResolver.functionReturnTypeSource(fn, source, s.bodyKinds, s.paramKinds);
	}

	/** Bundle the required `RefShape` / control-flow kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final localDeclKinds: Null<Array<String>> = shape.localDeclKinds;
		if (localDeclKinds == null || localDeclKinds.length == 0) return null;
		final returnKind: Null<String> = shape.returnStatementKind;
		if (returnKind == null) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final functionKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? []);
		return {
			localDeclKinds: localDeclKinds,
			returnKind: returnKind,
			exprStmtKind: shape.exprStatementKind,
			assignKind: shape.assignKind,
			identKind: shape.identKind,
			functionKinds: functionKinds,
			paramKinds: shape.paramKinds ?? [],
			bodyKinds: shape.functionBodyKinds ?? [],
			blockKinds: support.blockKinds(),
			newExprKind: shape.newExprKind,
			shape: shape
		};
	}

	/**
	 * Collect every joinable (declaration, return) pair reachable under `node`. `retType` is
	 * the source of the nearest enclosing function's explicit return type (null when it has
	 * none), rebound whenever descent enters a function so a pair is judged against its OWN
	 * function.
	 */
	private static function collectMatches(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, retType: Null<String>, s: Seams,
		tree: QueryNode, declTypeSources: () -> Map<Int, String>, lambdaSpans: Array<Span>, out: Array<Match>
	): Void {
		final childRetType: Null<String> = s.functionKinds.contains(node.kind) ? functionReturnTypeSource(node, s, source) : retType;
		if (s.blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length - 1) {
				var m: Null<Match> = matchPair(kids[i], kids[i + 1], source, comments, retType, s, tree, declTypeSources);
				if (m == null) m = matchAssignPair(kids[i], kids[i + 1], source, comments, retType, s, tree, declTypeSources, lambdaSpans);
				if (m != null) out.push(m);
			}
		}
		for (c in node.children) collectMatches(c, source, comments, childRetType, s, tree, declTypeSources, lambdaSpans, out);
	}

	/**
	 * The join match for a `decl` immediately followed by `ret`, or null when they are not a
	 * single-var initialized declaration and its own sole-reference return (see the class doc
	 * for every gate). `retType` is the enclosing function's return-type source.
	 */
	private static function matchPair(
		decl: QueryNode, ret: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, retType: Null<String>,
		s: Seams, tree: QueryNode, declTypeSources: () -> Map<Int, String>
	): Null<Match> {
		if (!s.localDeclKinds.contains(decl.kind) || decl.children.length != INIT_CHILD_COUNT) return null;
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		if (name == null || declSpan == null) return null;
		// The decl span includes its trailing `;`; a bare single-var decl ends in one.
		if (declSpan.to <= declSpan.from || source.charAt(declSpan.to - 1) != ';') return null;
		final init: QueryNode = decl.children[0];
		final initSpan: Null<Span> = init.span;
		if (initSpan == null) return null;
		if (RefactorSupport.isMultiDeclarator(decl, s.shape.localDeclContinuationKinds ?? [])) return null; // multi-declarator

		if (ret.kind != s.returnKind || ret.children.length != RETURN_VALUE_CHILD_COUNT) return null;
		final retIdent: QueryNode = ret.children[0];
		if (retIdent.kind != s.identKind || retIdent.name != name) return null;
		final retSpan: Null<Span> = ret.span;
		if (retSpan == null) return null;

		// The declared local must be referenced ONLY by this return: exactly one non-decl
		// reference resolving to it. A self-reference in the initializer or a use in
		// unreachable trailing code makes the join unsafe.
		final declNameFrom: Null<Int> = CheckScan.soleReferenceNameFrom(name, declSpan, tree, s.shape);
		if (declNameFrom == null) return null;
		if (CheckScan.escapesConditionalRegion(name, declSpan, tree, s.shape)) return null;

		if (droppedComment(declSpan, initSpan, retSpan.to, comments)) return null;

		final annotation: Null<String> = declTypeSources()[declNameFrom];
		final initSource: String = source.substring(initSpan.from, initSpan.to);
		// Re-bind to a non-null local: narrowing does not reach the struct literal below.
		final keySpan: Span = declSpan;
		return ({
			declSpan: keySpan,
			editSpan: new Span(keySpan.from, retSpan.to),
			text: buildReturn(initSource, annotation, retType, init, s.newExprKind),
			message: 'this declaration and its next-line return can be joined into a single return'
		}: Match);
	}

	/**
	 * The single-return replacement text -- plain, or a type-check ascription when the
	 * annotation must survive. `initNode` is the initializer's / r-value's own node, consulted
	 * only for the `new T(...)`-matches-annotation skip (see `isRedundantNewAscription`).
	 */
	private static function buildReturn(
		initSource: String, annotation: Null<String>, retType: Null<String>, initNode: QueryNode, newExprKind: Null<String>
	): String {
		if (annotation == null) return 'return $initSource;';
		final ann: String = annotation;
		return if (retType != null && TypeResolver.stripWs(retType) == TypeResolver.stripWs(ann))
			'return $initSource;'
		else if (isRedundantNewAscription(initNode, ann, newExprKind))
			'return $initSource;'
		else
			'return ($initSource : $ann);';
	}

	/**
	 * Whether `initNode` is a constructor call `new T(...)` whose class name is byte-equal
	 * (whitespace-insensitive) to the annotation `ann`, with `ann` carrying no type parameters.
	 * A bare `new T(...)` for a plain nominal `T` has an unambiguous, self-contained type --
	 * unlike `new Map()`, whose type parameters are inference-open and rely on the surrounding
	 * expected-type context (the annotation, or the ascription standing in for it once the
	 * declaration is dropped). So when `T` carries no type parameters the ascription is a pure
	 * restatement with nothing left to pin, and `buildReturn` skips it; a generic annotation
	 * always keeps the ascription -- its type parameters are exactly what it pins.
	 *
	 * The `ann`-has-no-`<` check is stated explicitly rather than left to fall out of the name
	 * comparison below: under the Haxe grammar `initNode.name` (`HxNewTypeName`) can never
	 * itself contain `<`, so a generic `ann` already fails that comparison on its own -- but
	 * that is an incidental property of ONE grammar's constructor-name terminal, not something
	 * `RefShape.newExprKind` guarantees for every plugin. Stating the condition explicitly keeps
	 * this gate correct on its own semantic terms (`T` carries no type parameters), independent
	 * of what a future grammar's constructor node happens to encode in `.name`.
	 */
	private static function isRedundantNewAscription(initNode: QueryNode, ann: String, newExprKind: Null<String>): Bool {
		if (newExprKind == null || initNode.kind != newExprKind) return false;
		final ctorName: Null<String> = initNode.name;
		return ctorName != null && TypeResolver.stripWs(ann).indexOf('<') == -1
			&& TypeResolver.stripWs(ctorName) == TypeResolver.stripWs(ann);
	}

	/**
	 * Whether a comment sits inside the joined region `[declSpan.from, retTo)` but outside the
	 * only verbatim-kept span, the initializer. Such a comment (on the declaration keyword /
	 * name / `:type` / `;` or on the `return`) would be lost by the rebuild, so the pair is
	 * skipped.
	 */
	private static function droppedComment(
		declSpan: Span, initSpan: Span, retTo: Int, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Bool {
		for (tok in comments) if (tok.from >= declSpan.from && tok.to <= retTo) {
			final inInit: Bool = tok.from >= initSpan.from && tok.to <= initSpan.to;
			if (!inInit) return true;
		}
		return false;
	}

	/**
	 * The join match for an assignment `x = e;` immediately followed by `return x;`, or null
	 * when the pair is not collapsible (see the class doc for every gate). Unlike `matchPair`,
	 * `x` is a PRE-EXISTING binding (a param or an earlier local, never a fresh decl), so safety
	 * rests on reference analysis rather than sole-reference counting: `x` resolves to a local /
	 * param (not a field), is captured by no lambda (a closure could observe the dropped store),
	 * has no read after the assignment other than this return, and keeps a surviving read (the
	 * collapse must not orphan it). `retType` is the enclosing function's return-type source.
	 */
	private static function matchAssignPair(
		assign: QueryNode, ret: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, retType: Null<String>,
		s: Seams, tree: QueryNode, declTypeSources: () -> Map<Int, String>, lambdaSpans: Array<Span>
	): Null<Match> {
		final binary: Null<QueryNode> = assignBinaryOf(assign, s);
		if (binary == null) return null;
		final lhs: QueryNode = binary.children[0];
		final name: Null<String> = lhs.name;
		if (lhs.kind != s.identKind || name == null) return null;

		if (ret.kind != s.returnKind || ret.children.length != RETURN_VALUE_CHILD_COUNT) return null;
		final retIdent: QueryNode = ret.children[0];
		if (retIdent.kind != s.identKind || retIdent.name != name) return null;

		final assignSpan: Null<Span> = assign.span;
		final rhs: QueryNode = binary.children[1];
		final rhsSpan: Null<Span> = rhs.span;
		final retSpan: Null<Span> = ret.span;
		final lhsSpan: Null<Span> = lhs.span;
		final retIdentSpan: Null<Span> = retIdent.span;
		if (assignSpan == null || rhsSpan == null || retSpan == null || lhsSpan == null || retIdentSpan == null) return null;

		// `x` must resolve to a local or param -- a bare field write (`this.x = e` spelled `x = e`)
		// would silently drop the store the collapse removes.
		final hits: Array<RefHit> = Refs.find(name, tree, s.shape);
		final binding: Null<Span> = writeBindingOf(hits, lhsSpan);
		if (binding == null) return null;
		final b: Span = binding;
		if (!TypeResolver.mayBeLocalOrParam(tree, b.from, s.localDeclKinds, s.paramKinds)) return null;
		if (!referencesPermitCollapse(hits, b, retIdentSpan, assignSpan, lambdaSpans)) return null;

		if (droppedComment(assignSpan, rhsSpan, retSpan.to, comments)) return null;

		final annotation: Null<String> = declTypeSources()[b.from];
		final initSource: String = source.substring(rhsSpan.from, rhsSpan.to);
		final keySpan: Span = assignSpan;
		return ({
			declSpan: keySpan,
			editSpan: new Span(keySpan.from, retSpan.to),
			text: buildReturn(initSource, annotation, retType, rhs, s.newExprKind),
			message: 'this assignment and its next-line return can be joined into a single return'
		}: Match);
	}

	/**
	 * The `x = e` binary the statement wraps, or null when the statement is not an
	 * expression-statement holding exactly one assignment (or the grammar declares neither seam).
	 */
	private static function assignBinaryOf(assign: QueryNode, s: Seams): Null<QueryNode> {
		final exprStmtKind: Null<String> = s.exprStmtKind;
		final assignKind: Null<String> = s.assignKind;
		if (exprStmtKind == null || assignKind == null) return null;
		if (assign.kind != exprStmtKind || assign.children.length != EXPR_STMT_CHILD_COUNT) return null;
		final binary: QueryNode = assign.children[0];
		return binary.kind == assignKind && binary.children.length == ASSIGN_CHILD_COUNT ? binary : null;
	}

	/** The binding the write at `lhsSpan` resolves to; null when no write hit covers exactly that span. */
	private static function writeBindingOf(hits: Array<RefHit>, lhsSpan: Span): Null<Span> {
		for (h in hits) if (h.kind == RefKind.Write && h.span.from == lhsSpan.from && h.span.to == lhsSpan.to) return h.bindingSpan;
		return null;
	}

	/**
	 * Whether every reference resolving to binding `b` allows the collapse (a shadowing inner `x` is
	 * skipped): no capturing lambda holds one, no read follows the assignment other than the return,
	 * and at least one read survives so the collapse does not orphan the binding.
	 */
	private static function referencesPermitCollapse(
		hits: Array<RefHit>, b: Span, retIdentSpan: Span, assignSpan: Span, lambdaSpans: Array<Span>
	): Bool {
		var survivingRead: Bool = false;
		for (h in hits) {
			final bs: Null<Span> = h.bindingSpan;
			if (bs == null || bs.from != b.from || bs.to != b.to) continue;
			if (h.kind != RefKind.Decl && inAnyLambda(h.span, lambdaSpans)) return false;
			if (h.kind != RefKind.Read) continue;
			final isReturn: Bool = h.span.from == retIdentSpan.from && h.span.to == retIdentSpan.to;
			if (isReturn) continue;
			if (h.span.from >= assignSpan.to) return false;
			survivingRead = true;
		}
		return survivingRead;
	}

	/** Whether `span` is nested inside any lambda span in `lambdaSpans` -- i.e. a captured reference. */
	private static function inAnyLambda(span: Span, lambdaSpans: Array<Span>): Bool {
		for (ls in lambdaSpans) if (ls.from <= span.from && span.to <= ls.to) return true;
		return false;
	}

	/** Collect the span of every lambda (`RefShape.lambdaKinds`) reachable under `node`. */
	private static function collectLambdaSpans(node: QueryNode, lambdaKinds: Array<String>, out: Array<Span>): Void {
		if (lambdaKinds.contains(node.kind)) {
			final sp: Null<Span> = node.span;
			if (sp != null) out.push(sp);
		}
		for (c in node.children) collectLambdaSpans(c, lambdaKinds, out);
	}

}

/** The kinds `JoinReturn` reads. */
private typedef Seams = {
	var localDeclKinds: Array<String>;
	var returnKind: String;
	var exprStmtKind: Null<String>;
	var assignKind: Null<String>;
	var identKind: String;
	var functionKinds: Array<String>;
	var paramKinds: Array<String>;
	var bodyKinds: Array<String>;
	var blockKinds: Array<String>;
	var newExprKind: Null<String>;
	var shape: RefShape;
}

/** A joinable pair: the declaration span (finding key), the replaced span, and the single-return replacement text. */
private typedef Match = {
	var declSpan: Span;
	var editSpan: Span;
	var text: String;
	var message: String;
}
