package anyparse.check.common.loops;

import anyparse.query.CanonicalEdit;
import anyparse.query.ElementSpan;
import anyparse.query.LexicalRegions;
import anyparse.query.NodeShape;
import anyparse.query.OccurrenceScan;
import anyparse.query.ShapeVocab;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.query.UnchangedLocal;

/**
 * The `RefShape` kinds `PreferRangeLoop` reads (plus the shape itself
 * for binding resolution), bundled once so the walkers take one argument.
 */
private typedef Seams = {
	var shape: RefShape;
	var whileStmtKind: String;
	var ltKind: String;
	var lteKind: Null<String>;
	var postIncrKind: String;
	var preIncrKind: Null<String>;
	var identKind: String;
	var blockStmtKind: String;
	var exprStmtKind: String;
	var continueKind: String;
	var mutableKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var writeParentKinds: Array<String>;
	var numericLiteralKinds: Array<String>;
	var unaryMinusKinds: Array<String>;
	var closureKinds: Array<String>;
	var atomicKinds: Array<String>;
	var opaqueKinds: Array<String>;
}

/**
 * One matched counter loop: the loop variable, its init and bound nodes, the `while` and
 * its body. `hiOffset` is what the range's upper end adds to the bound, `stepInCondition`
 * marks the `while (i++ < B)` family (the `var` is dropped, the `while` header rewritten).
 */
private typedef RangeMatch = {
	var declSpan: Span;
	var loopVar: String;
	var initNode: QueryNode;
	var boundNode: QueryNode;
	var whileNode: QueryNode;
	var body: QueryNode;
	var hiOffset: Int;
	var stepInCondition: Bool;
}

/**
 * Flags a manual counter loop — a `var i = A;` declaration immediately followed
 * by `while (i < B) { BODY; i++; }` — which the user's rule replaces with a range
 * `for`: use `for (i in A...B)` instead of a `while` with a manual `i++`.
 * `Severity.Info`; paired with an autofix (the rewrite is sound only under every gate
 * below, and several — i-not-read-after, no-other-write — are exactly the analyses
 * most likely to hide a subtle bug, so the fix refuses any shape the gates do not admit).
 * Purely structural, so it holds without a type-checker. Grammar-agnostic over
 * `RefShape`.
 *
 * ## The shape it accepts
 *
 * Two ADJACENT statements in one block: a `var i = A;` (NOT `final`) whose single
 * initializer `A` is any expression, then a `while (i < B)` whose braced body ends
 * with exactly `i++;`. The suggestion transcribes `A` and `B` verbatim from source
 * as the range bounds — `for (i in A...B)`.
 *
 * ## The step-in-condition form
 *
 * `var i = A;`, statements that neither read nor write `i`, then `while (i++ < B) body`
 * (also `++i`, `<=`): the `for` replaces the `while` in place and the `var` is dropped.
 * `i` must not be written in the body or read after the loop, and with statements in
 * between `A` (evaluated later) must be a literal or an untouched, uncaptured local (`initSurvivesBetween`).
 * Decimal literal bounds fold (`var i = 8; while (i++ < 36)` → `9...37`).
 *
 * ## Soundness gates (all required for a flag)
 *
 * - **Adjacent var-with-init.** The declaration is a single-variable `var` (a
 *   `final` cannot `i++`, and `mutableLocalDeclKinds` excludes it; a multi-
 *   declaration `var i, j = n` — one node, top-level comma — is skipped) with
 *   exactly one initializer child, the immediately preceding block sibling of the
 *   `while`.
 * - **Condition is exactly `i < B`.** The loop variable is on the LEFT of a strict
 *   less-than (`i <= B`, a reversed `B > i` and a `!=` form are not an `A...B`
 *   range and are skipped).
 * - **Trailing `i++`.** The body is a braced block whose LAST statement is exactly
 *   `i++;` (a `++i` / `i += 1` / `i = i + 1` is not matched), and no OTHER statement
 *   writes `i` — the only direct write of `i` in the body is that trailing
 *   increment (`i--`, `i =`, a nested `i++` all disqualify it).
 * - **`i` not read after the loop.** A range `for` scopes `i` to the loop, whereas
 *   the `while` leaves `i == B` visible afterwards; if `i` is referenced anywhere
 *   after the `while`'s span within the enclosing scope, the transform would drop a
 *   live binding, so it is skipped (positional `RefactorSupport.referencedInRange`).
 * - **`B` is stable.** `A...B` evaluates `B` ONCE while `while (i < B)` evaluates it
 *   each iteration, so `B` must be a value the body cannot change: a numeric literal,
 *   or a plain identifier that is NOT `i` (which would read the counter) and is never
 *   written in the body. Anything else (a call, a field / array access, a compound
 *   expression) is skipped.
 * - **No `continue`.** In the `while` form a `continue` SKIPS the trailing `i++`
 *   (a deliberate retry, or a bug); in a range `for` it advances the counter, so a
 *   body containing any `continue` is skipped. A `break` is fine (same semantics).
 * - **Non-empty body.** The body must hold at least one statement besides the
 *   trailing `i++` (an empty range loop is pointless — skipped to avoid noise).
 * - **No shadowing.** Nothing in the body re-declares `i` (a nested `var i` would
 *   confuse the counter identity).
 * - **No capturing closure.** A range `for` re-scopes `i` per iteration, whereas
 *   the `while`'s `i` is one function-scoped binding a closure captures by
 *   reference; if any lambda / local-function subtree in the enclosing scope
 *   references `i`, the transform would change what the closure observes, so it
 *   is skipped.
 *
 * ## Grammar-agnostic
 *
 * Driven by `whileStmtKind`, `ltKind`, `postIncrKind`, `blockStmtKind`,
 * `exprStatementKind`, `continueStatementKind` and `mutableLocalDeclKinds` (any
 * unset → the check is a no-op), plus `identKind` / `writeParentKinds` (the write
 * scan), `numericLiteralKinds` (a literal bound), `localDeclKinds` (the shadow gate),
 * `lambdaKinds` / `localFunctionKinds` (the closure-capture gate) and `opaqueKinds`
 * to skip reification subtrees.
 */
@:nullSafety(Strict)
final class PreferRangeLoop extends RuleBase {

	/** Minimum body statements: at least one real statement plus the trailing `i++`. */
	private static inline final MIN_BODY_STATEMENTS: Int = 2;

	/** Cap on the init / bound excerpt length in the suggestion message. */
	private static inline final EXCERPT_MAX: Int = 40;

	/** The `Int` nominal every range operand must not provably differ from. */
	private static final INT_TYPE: String = 'Int';

	/** A decimal literal small enough to fold without overflow. */
	private static final DECIMAL_INT: EReg = ~/^[0-9]{1,9}$/;

	public function new() {
		super(
			'prefer-range-loop',
			'a var-counter while loop (var i = A; while (i < B) { … i++; } or while (i++ < B) …) replaceable with for (i in A...B)',
			RuleCategory.Loops
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final typed: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		return RunScan.collectWith(files, plugin, readSeams(plugin.refShape()), (entry, tree, s, violations) -> {
			final dt: Null<Map<Int, String>> = typed?.declaredTypes(entry.source);
			walk(tree, tree, entry.file, entry.source, dt, s, violations);
		});
	}

	/**
	 * Rewrite each flagged `var i = A; while (i < B) { … i++; }` into
	 * `for (i in A...B) { … }` — dropping the counter declaration and the trailing
	 * increment. A non-atomic lower bound `A` (a ternary, a compound expression) is
	 * parenthesised so it re-parses as the interval's operand regardless of `...`'s
	 * precedence; a comment in any dropped region (see `buildRangeEdit`) refuses the
	 * rewrite, leaving that finding report-only.
	 *
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return RunScan.editsWith(plugin, source, readSeams(plugin.refShape()), (tree, s) -> {
			final typed: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
			final dt: Null<Map<Int, String>> = typed?.declaredTypes(source);
			final wanted: Array<String> = RunScan.spanKeys(violations);
			final edits: Array<{ span: Span, text: String }> = [];
			fixWalk(tree, tree, source, ElementSpan.lazyRegions(source, plugin), dt, s, wanted, edits);
			return CanonicalEdit.dropContainedEdits(edits);
		});
	}

	/** The bound's identifier name when `B` is a bare identifier, else null (a literal bound has no name to track). */
	private static inline function boundIdentName(bound: QueryNode, s: Seams): Null<String> {
		return bound.kind == s.identKind ? bound.name : null;
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final whileStmtKind: Null<String> = shape.whileStmtKind;
		if (whileStmtKind == null) return null;
		final ltKind: Null<String> = shape.ltKind;
		if (ltKind == null) return null;
		final postIncrKind: Null<String> = shape.postIncrKind;
		if (postIncrKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final continueKind: Null<String> = shape.continueStatementKind;
		if (continueKind == null) return null;
		final mutableKinds: Array<String> = shape.mutableLocalDeclKinds ?? [];
		final closureKinds: Array<String> = ShapeVocab.nestedFunctionKinds(shape);
		final atomicKinds: Array<String> = [
			for (k in [
				(shape.identKind: Null<String>),
				shape.callKind,
				shape.fieldAccessKind,
				shape.forceFieldAccessKind,
				shape.nullSafeAccessKind,
				shape.indexAccessKind,
				shape.newExprKind,
				shape.parenKind,
				shape.boolLitKind
			]) if (k != null) k
		];
		if (shape.numericLiteralKinds != null) for (n in shape.numericLiteralKinds) atomicKinds.push(n);
		return mutableKinds.length == 0 ? null : {
			shape: shape,
			whileStmtKind: whileStmtKind,
			ltKind: ltKind,
			lteKind: shape.lteKind,
			postIncrKind: postIncrKind,
			preIncrKind: shape.preIncrKind,
			identKind: shape.identKind,
			blockStmtKind: blockStmtKind,
			exprStmtKind: exprStmtKind,
			continueKind: continueKind,
			mutableKinds: mutableKinds,
			localDeclKinds: shape.localDeclKinds ?? [],
			writeParentKinds: shape.writeParentKinds,
			numericLiteralKinds: shape.numericLiteralKinds ?? [],
			unaryMinusKinds: shape.unaryMinusKinds ?? [],
			closureKinds: closureKinds,
			atomicKinds: atomicKinds,
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

	/**
	 * Descend `node`, testing each adjacent child pair `(decl, while)` and recursing;
	 * `node` doubles as the enclosing scope for the read-after gate. A reification
	 * subtree (`opaqueKinds`) is skipped wholesale.
	 */
	private static function walk(
		node: QueryNode, root: QueryNode, file: String, source: String, dt: Null<Map<Int, String>>, s: Seams, out: Array<Violation>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length - 1) {
			final v: Null<Violation> = tryMatch(kids[i], kids[i + 1], node, root, file, source, dt, s);
			if (v != null) out.push(v);
		}
		forEachStepMatch(kids, node, root, source, dt, s, m -> out.push(violationOf(m, file, source, s)));
		for (c in kids) walk(c, root, file, source, dt, s, out);
	}

	/**
	 * Whether `decl` is a `var i = A;` immediately followed by the qualifying counter
	 * loop `whileNode` inside `scope`; returns the `Info` violation when so, else null.
	 */
	private static function tryMatch(
		decl: QueryNode, whileNode: QueryNode, scope: QueryNode, root: QueryNode, file: String, source: String, dt: Null<Map<Int, String>>,
		s: Seams
	): Null<Violation> {
		final m: Null<RangeMatch> = analyze(decl, whileNode, scope, root, source, dt, s);
		return m == null ? null : violationOf(m, file, source, s);
	}

	/** The `Info` finding for `m`, spelling the range the way the fix writes it. */
	private static function violationOf(m: RangeMatch, file: String, source: String, s: Seams): Violation {
		final initSpan: Span = m.initNode.span ?? m.declSpan;
		final boundSpan: Span = m.boundNode.span ?? m.declSpan;
		final a: String = excerpt(source.substring(initSpan.from, initSpan.to));
		final b: String = excerpt(source.substring(boundSpan.from, boundSpan.to));
		return {
			file: file,
			span: m.declSpan,
			rule: 'prefer-range-loop',
			severity: Severity.Info,
			message: m.stepInCondition
				? 'this var-counter while loop can be ${excerpt(stepHeader(m, source, s))})'
				: 'this var-counter while loop can be for (${m.loopVar} in $a...$b)'
		};
	}

	/**
	 * Call `found` for each `var i = A;` among `kids` with a later step-in-condition `while`
	 * of the same block that `analyzeStep` admits (the first such loop of a declaration).
	 */
	private static function forEachStepMatch(
		kids: Array<QueryNode>, scope: QueryNode, root: QueryNode, source: String, dt: Null<Map<Int, String>>, s: Seams,
		found: RangeMatch -> Void
	): Void {
		for (j in 0...kids.length) if (s.mutableKinds.contains(kids[j].kind)) for (k in j + 1...kids.length) if (
			kids[k].kind == s.whileStmtKind
		) {
			final m: Null<RangeMatch> = analyzeStep(kids[j], kids.slice(j + 1, k), kids[k], scope, root, source, dt, s);
			if (m == null) continue;
			found(m);
			break;
		}
	}

	/** Whether `stmt` is exactly `<loopVar>++;` — an expression statement wrapping a post-increment of the loop variable. */
	private static function isPostIncrementOf(stmt: QueryNode, loopVar: String, s: Seams): Bool {
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return false;
		final incr: QueryNode = stmt.children[0];
		if (incr.kind != s.postIncrKind || incr.children.length < 1) return false;
		final target: QueryNode = incr.children[0];
		return target.kind == s.identKind && target.name == loopVar;
	}

	/** The normalized source, truncated with an ellipsis beyond the excerpt cap. */
	private static function excerpt(text: String): String {
		final flat: String = SourceText.collapseSpaces(text);
		return flat.length > EXCERPT_MAX ? '${flat.substring(0, EXCERPT_MAX)}…' : flat;
	}

	/**
	 * The counter variable of a `var i = A;` single-var declaration (not
	 * `final`, one initializer, no multi-declaration comma), or null.
	 */
	private static function matchCounterDecl(decl: QueryNode, source: String, s: Seams): Null<String> {
		if (!s.mutableKinds.contains(decl.kind) || decl.children.length != 1) return null;
		final name: Null<String> = decl.name;
		final span: Null<Span> = decl.span;
		return if (name == null || span == null)
			null
		else if (SourceText.isMultiDeclarator(decl, s.shape.localDeclContinuationKinds ?? []))
			null
		else
			name;
	}

	/**
	 * The bound `B` of a `while (i < B)` whose loop variable is on the LEFT and whose
	 * bound is a simple identifier (not `i`) or a numeric literal, or null.
	 */
	private static function matchCondition(whileNode: QueryNode, loopVar: String, s: Seams): Null<QueryNode> {
		if (whileNode.kind != s.whileStmtKind || !LoopScan.hasWhileShape(whileNode)) return null;
		final cond: QueryNode = LoopScan.whileCondition(whileNode);
		if (cond.kind != s.ltKind || !NodeShape.hasComparisonShape(cond)) return null;
		final left: QueryNode = cond.children[0];
		return left.kind != s.identKind || left.name != loopVar ? null : simpleBound(cond.children[1], loopVar, s);
	}

	/**
	 * Whether `body` is a braced block ending in exactly `i++;`, with no OTHER write of
	 * `i`, no write of an identifier bound, no `continue`, no re-declaration of `i`, and
	 * at least one statement besides the increment.
	 */
	private static function bodyIsRangeConvertible(body: QueryNode, loopVar: String, bound: QueryNode, s: Seams): Bool {
		if (body.kind != s.blockStmtKind || body.children.length < MIN_BODY_STATEMENTS) return false;
		if (!isPostIncrementOf(body.children[body.children.length - 1], loopVar, s)) return false;
		if (LoopScan.countWrites(body, loopVar, s) != 1) return false;
		final boundName: Null<String> = boundIdentName(bound, s);
		final boundWritten: Bool = boundName != null && LoopScan.countWrites(body, boundName, s) != 0;
		return !boundWritten && !LoopScan.containsKind(body, s.continueKind, s) && !LoopScan.declares(body, loopVar, s);
	}

	/**
	 * The matched counter loop `(decl, whileNode)` inside `scope` — the loop variable,
	 * its init and bound nodes, the `while` and its body block — or null when any gate
	 * fails. Shared by `tryMatch` (report) and `fixWalk` (rewrite) so both see one
	 * decision. Haxe's `...` interval requires `Int` operands, so a counter or bound
	 * that is PROVABLY non-Int — a float-syntax literal, a declared non-Int counter
	 * type, or an identifier whose declared type resolves to a non-Int nominal — also
	 * fails; an unannotated or unresolvable type still matches (the residual risk of an
	 * inferred-Float operand is undetectable without a type checker).
	 */
	private static function analyze(
		decl: QueryNode, whileNode: QueryNode, scope: QueryNode, root: QueryNode, source: String, dt: Null<Map<Int, String>>, s: Seams
	): Null<RangeMatch> {
		final loopVar: Null<String> = matchCounterDecl(decl, source, s);
		if (loopVar == null) return null;
		final bound: Null<QueryNode> = matchCondition(whileNode, loopVar, s);
		if (bound == null) return null;
		final body: QueryNode = LoopScan.whileBody(whileNode);
		return bodyIsRangeConvertible(body, loopVar, bound, s)
			? rangeMatch(decl, loopVar, bound, whileNode, scope, root, source, dt, s, 0, false)
			: null;
	}

	/**
	 * The counter loop whose step sits IN the condition — `var i = A;`, statements that
	 * never touch `i` (`between`), then `while (i++ < B)` / `++i` / `<=` — or null when any
	 * gate fails. The body is free of writes to `i` (the condition is the only step); `A` is
	 * evaluated where the `while` stood, so with statements in between it must survive them
	 * (`initSurvivesBetween`).
	 */
	private static function analyzeStep(
		decl: QueryNode, between: Array<QueryNode>, whileNode: QueryNode, scope: QueryNode, root: QueryNode, source: String,
		dt: Null<Map<Int, String>>, s: Seams
	): Null<RangeMatch> {
		final loopVar: Null<String> = matchCounterDecl(decl, source, s);
		if (loopVar == null) return null;
		final step: Null<{ bound: QueryNode, hiOffset: Int }> = matchStepCondition(whileNode, loopVar, s);
		if (step == null) return null;
		final body: QueryNode = LoopScan.whileBody(whileNode);
		final boundName: Null<String> = boundIdentName(step.bound, s);
		final boundWritten: Bool = boundName != null && LoopScan.countWrites(body, boundName, s) != 0;
		if (boundWritten || LoopScan.countWrites(body, loopVar, s) != 0 || LoopScan.declares(body, loopVar, s)) return null;
		final declSpan: Null<Span> = decl.span;
		final whileSpan: Null<Span> = whileNode.span;
		if (declSpan == null || whileSpan == null) return null;
		final region: Span = new Span(declSpan.to, whileSpan.from);
		return if (!initSurvivesBetween(decl.children[0], between, region, root, source, s))
			null
		else if (OccurrenceScan.referencedInRange(source, loopVar, region.from, region.to, []))
			null
		else
			rangeMatch(decl, loopVar, step.bound, whileNode, scope, root, source, dt, s, step.hiOffset, true);
	}

	/** Mirror of `walk` for the fix path: emit the range-loop rewrite for each wanted, convertible loop. */
	private static function fixWalk(
		node: QueryNode, root: QueryNode, source: String, regions: () -> Array<LexRegion>, dt: Null<Map<Int, String>>, s: Seams,
		wanted: Array<String>, out: Array<{ span: Span, text: String }>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length - 1) {
			final m: Null<RangeMatch> = analyze(kids[i], kids[i + 1], node, root, source, dt, s);
			if (m == null || !wanted.contains('${m.declSpan.from}:${m.declSpan.to}')) continue;
			final e: Null<{ span: Span, text: String }> = buildRangeEdit(m, source, regions(), s);
			if (e != null) out.push(e);
		}
		forEachStepMatch(kids, node, root, source, dt, s, m -> {
			if (!wanted.contains('${m.declSpan.from}:${m.declSpan.to}')) return;
			final es: Null<Array<{ span: Span, text: String }>> = buildStepEdits(m, source, regions(), s);
			if (es != null) for (e in es) out.push(e);
		});
		for (c in kids) fixWalk(c, root, source, regions, dt, s, wanted, out);
	}

	/**
	 * The single `{span, text}` replacing `[decl start, while end)` with the range loop —
	 * or null when a comment sits in ANY region the rewrite drops: before the init inside
	 * the declaration, between the init and the body's `{` (covering the decl tail, the
	 * gap to the `while`, and its condition header), or between the increment and the
	 * body's `}`. The interior `[body {, increment)` and the init/bound spans are carried
	 * verbatim, so comments there survive.
	 *
	 */
	private static function buildRangeEdit(
		m: RangeMatch, source: String, regions: Array<LexRegion>, s: Seams
	): Null<{ span: Span, text: String }> {
		final incr: QueryNode = m.body.children[m.body.children.length - 1];
		final bodySpan: Null<Span> = m.body.span;
		final incrSpan: Null<Span> = incr.span;
		final whileSpan: Null<Span> = m.whileNode.span;
		final initSpan: Null<Span> = m.initNode.span;
		final boundSpan: Null<Span> = m.boundNode.span;
		if (bodySpan == null || incrSpan == null || whileSpan == null || initSpan == null || boundSpan == null) return null;
		if (LexicalRegions.commentIntersects(incrSpan.to, bodySpan.to - 1, regions)) return null;
		if (LexicalRegions.commentIntersects(m.declSpan.from, initSpan.from, regions)) return null;
		if (LexicalRegions.commentIntersects(initSpan.to, bodySpan.from, regions)) return null;
		final interior: String = source.substring(bodySpan.from + 1, incrSpan.from);
		final rawStart: String = source.substring(initSpan.from, initSpan.to);
		final start: String = s.atomicKinds.contains(m.initNode.kind) ? rawStart : '($rawStart)';
		final boundText: String = source.substring(boundSpan.from, boundSpan.to);
		final text: String = 'for (${m.loopVar} in $start...$boundText) {$interior}';
		return { span: new Span(m.declSpan.from, whileSpan.to), text: text };
	}

	/** Whether the declaration binding at `from` carries an explicit non-`Int` nominal type annotation (per `declaredTypes`). */
	private static function declaredNonInt(from: Int, dt: Null<Map<Int, String>>): Bool {
		if (dt == null) return false;
		final typeName: Null<String> = dt[from];
		return typeName != null && typeName != INT_TYPE;
	}

	/**
	 * Whether `node` is PROVABLY not an `Int` range operand — a numeric literal in
	 * float syntax (a `.` / exponent in a non-hex literal), or a bare identifier whose
	 * binding's declared type resolves to a non-`Int` nominal. Unannotated /
	 * unresolvable stays false (the check is type-checker-free by design).
	 */
	private static function provablyNonInt(node: QueryNode, root: QueryNode, source: String, dt: Null<Map<Int, String>>, s: Seams): Bool {
		final span: Null<Span> = node.span;
		if (span == null) return false;
		if (s.numericLiteralKinds.contains(node.kind)) return isFloatSyntax(source.substring(span.from, span.to));
		if (node.kind != s.identKind || dt == null) return false;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(node, root, s.shape);
		return bindingFrom != null && declaredNonInt(bindingFrom, dt);
	}

	/** Whether a numeric literal's source is float syntax — a `.` or a decimal exponent (hex literals are `Int`). */
	private static function isFloatSyntax(text: String): Bool {
		return !text.startsWith('0x')
			&& !text.startsWith('0X')
			&& (text.indexOf('.') != -1 || text.indexOf('e') != -1 || text.indexOf('E') != -1);
	}

	/** The gates both loop shapes share: `Int`-provable operands, `i` not read after the loop, no capturing closure. */
	private static function rangeMatch(
		decl: QueryNode, loopVar: String, bound: QueryNode, whileNode: QueryNode, scope: QueryNode, root: QueryNode, source: String,
		dt: Null<Map<Int, String>>, s: Seams, hiOffset: Int, stepInCondition: Bool
	): Null<RangeMatch> {
		final declSpan: Null<Span> = decl.span;
		final whileSpan: Null<Span> = whileNode.span;
		final scopeSpan: Null<Span> = scope.span;
		return if (declSpan == null || whileSpan == null || scopeSpan == null || bound.span == null)
			null
		else if (declaredNonInt(declSpan.from, dt))
			null
		else if (provablyNonInt(decl.children[0], root, source, dt, s))
			null
		else if (provablyNonInt(bound, root, source, dt, s))
			null
		else if (OccurrenceScan.referencedInRange(source, loopVar, whileSpan.to, scopeSpan.to, []))
			null
		else if (LoopScan.capturedByClosure(scope, source, loopVar, s))
			null
		else
			{
				declSpan: declSpan,
				loopVar: loopVar,
				initNode: decl.children[0],
				boundNode: bound,
				whileNode: whileNode,
				body: LoopScan.whileBody(whileNode),
				hiOffset: hiOffset,
				stepInCondition: stepInCondition
			};
	}

	/**
	 * The bound and the range's upper offset of `while (i++ < B)` / `++i < B` / `i++ <= B` /
	 * `++i <= B` over `loopVar`, or null. The offset is the post-increment (1) plus the
	 * inclusive comparison (1): the body sees `A+1` first, and the last value it sees is
	 * `B - 1 + offset`.
	 */
	private static function matchStepCondition(whileNode: QueryNode, loopVar: String, s: Seams): Null<{ bound: QueryNode, hiOffset: Int }> {
		if (whileNode.kind != s.whileStmtKind || !LoopScan.hasWhileShape(whileNode)) return null;
		final cond: QueryNode = LoopScan.whileCondition(whileNode);
		final inclusive: Bool = s.lteKind != null && cond.kind == s.lteKind;
		if (!(cond.kind == s.ltKind || inclusive) || !NodeShape.hasComparisonShape(cond)) return null;
		final step: QueryNode = cond.children[0];
		final post: Bool = step.kind == s.postIncrKind;
		if (!(post || (s.preIncrKind != null && step.kind == s.preIncrKind)) || step.children.length < 1) return null;
		final target: QueryNode = step.children[0];
		if (target.kind != s.identKind || target.name != loopVar) return null;
		final bound: Null<QueryNode> = simpleBound(cond.children[1], loopVar, s);
		return bound == null ? null : { bound: bound, hiOffset: (post ? 1 : 0) + (inclusive ? 1 : 0) };
	}

	/** `bound` when it is a numeric literal or a plain identifier other than `loopVar`, else null. */
	private static function simpleBound(bound: QueryNode, loopVar: String, s: Seams): Null<QueryNode> {
		final boundName: Null<String> = boundIdentName(bound, s);
		final notSimpleBound: Bool = boundName == null && !s.numericLiteralKinds.contains(bound.kind);
		return notSimpleBound || boundName == loopVar ? null : bound;
	}

	/**
	 * Whether `init`, evaluated after the `between` statements instead of before them, yields the
	 * same value: a literal, or an identifier `UnchangedLocal` holds across `region` (a local or
	 * parameter no write there and no function literal can change) that no between statement
	 * re-declares. A field or an unresolved name may change behind a call, so it refuses.
	 */
	private static function initSurvivesBetween(
		init: QueryNode, between: Array<QueryNode>, region: Span, root: QueryNode, source: String, s: Seams
	): Bool {
		if (between.length == 0 || foldedInt(init, source, s) != null) return true;
		final name: Null<String> = init.kind == s.identKind ? init.name : null;
		return name != null
			&& between.foreach(stmt -> !LoopScan.declares(stmt, name, s))
			&& new UnchangedLocal(root, s.shape).holds(init, region);
	}

	/** `node` plus `offset`: a decimal Int literal (negated or not) folds, else `node + offset`, parenthesised if not atomic. */
	private static function offsetBound(node: QueryNode, offset: Int, source: String, s: Seams): String {
		final span: Null<Span> = node.span;
		if (span == null) return '';
		final literal: Null<Int> = foldedInt(node, source, s);
		if (literal != null) return '${literal + offset}';
		final raw: String = source.substring(span.from, span.to);
		return offset == 0 ? raw : (s.atomicKinds.contains(node.kind) ? raw : '($raw)') + ' + $offset';
	}

	/** The value of a decimal Int literal, or of one under a unary minus; null for any other node. */
	private static function foldedInt(node: QueryNode, source: String, s: Seams): Null<Int> {
		final negated: Bool = s.unaryMinusKinds.contains(node.kind) && node.children.length == 1;
		final literal: QueryNode = negated ? node.children[0] : node;
		final span: Null<Span> = literal.span;
		if (span == null || !s.numericLiteralKinds.contains(literal.kind)) return null;
		final raw: String = source.substring(span.from, span.to);
		final value: Null<Int> = DECIMAL_INT.match(raw) ? Std.parseInt(raw) : null;
		return if (value == null) null else if (negated) -value else value;
	}

	/** The `for` header for a step-in-condition match: `for (i in A + 1...B + k)`, bounds folded when literal. */
	private static function stepHeader(m: RangeMatch, source: String, s: Seams): String {
		return 'for (${m.loopVar} in ${offsetBound(m.initNode, 1, source, s)}...${offsetBound(m.boundNode, m.hiOffset, source, s)}';
	}

	/**
	 * The two edits of a step-in-condition match: the counter declaration's lines dropped and
	 * the `while (` header up to the condition's end replaced by the `for (` header (the `)`
	 * and the body stay verbatim). Null when a comment sits in a dropped region.
	 */
	private static function buildStepEdits(
		m: RangeMatch, source: String, regions: Array<LexRegion>, s: Seams
	): Null<Array<{ span: Span, text: String }>> {
		final whileSpan: Null<Span> = m.whileNode.span;
		final condSpan: Null<Span> = LoopScan.whileCondition(m.whileNode).span;
		if (whileSpan == null || condSpan == null) return null;
		if (LexicalRegions.commentIntersects(m.declSpan.from, m.declSpan.to, regions)) return null;
		if (LexicalRegions.commentIntersects(whileSpan.from, condSpan.to, regions)) return null;
		return [
			{ span: ElementSpan.lineExtendedSpan(source, m.declSpan), text: '' },
			{ span: new Span(whileSpan.from, condSpan.to), text: stepHeader(m, source, s) }
		];
	}

}
