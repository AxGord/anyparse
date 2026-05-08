package anyparse.grammar.haxe;

/**
 * Plugin-side AST predicates over `HxExpr` consumed by macro-neutral
 * runtime adapters on `WriteOptions`.
 *
 * Lives in the grammar package so macro core stays free of any
 * `HxExpr`-specific logic. `HaxeFormat.defaultWriteOptions` wires the
 * static methods here into the adapter fields the macro emits calls
 * for (e.g. `endsWithCloseBrace` for `@:fmt(trailOptShapeGate)`).
 *
 * All predicates take `Dynamic` because the same adapter is invoked
 * from both Plain-mode writers (which pass `HxExpr` enum values) and
 * Trivia-mode writers (which pass `Trivial<HxExprT>` struct wrappers
 * around the paired enum). Constructor identification goes through
 * `Type.enumConstructor` rather than direct pattern matching so the
 * switch arms match against both the Plain `HxExpr` and the synthesised
 * `HxExprT` enum — they share constructor names but are distinct types
 * at runtime, so a literal `case BlockExpr(_)` would only fire on one.
 */
@:nullSafety(Strict)
final class HxExprUtil {

	/**
	 * True iff `raw` is a control-flow expression whose `}` may serve
	 * as a statement terminator on the rhs of `var x = …`. Drives the
	 * writer-side gate for `@:trailOpt(';')` on `var` / `final`
	 * declarations.
	 *
	 * **Drop `;`** (gate true):
	 *  - `SwitchExpr` / `SwitchExprBare` — `var x = switch (y) { … }`
	 *    (haxe-formatter `issue_119_expression_case`,
	 *    `issue_254_case_colon{,_next,_keep}`).
	 *  - `FnExpr` with `body=BlockBody` — `var f = function() { … }`
	 *    (haxe-formatter `inline_calls`). Bare-expression bodies
	 *    (`function(x) trace(x)`) keep the `;`.
	 *  - `TryExpr` whose last catch clause's body is itself in this set
	 *    (recursive). Bare-catch `try foo() catch (_) null` keeps the
	 *    `;` because `null` is not in the set.
	 *
	 * **Keep `;`** (gate false — explicit non-set):
	 *  - `BlockExpr` — `var x = { 1; 2; };` is a block-as-expression
	 *    value, not a statement.
	 *  - `ObjectLit` — `var o = {a: 1};` (haxe-formatter
	 *    `issue_101_comment_in_object_literal`, `space_in_anonymous_object`).
	 *  - `IfExpr` — `var x = if (a) { 1; } else { 2; };` (haxe-formatter
	 *    `issue_42_if_after_assign_with_blocks_on_same_line`).
	 *  - All prefix / infix / postfix wrappers and everything else.
	 *
	 * The discrimination follows haxe-formatter's empirical rule from
	 * the corpus: only "control-flow expressions that visually look
	 * like statements" (switch / try / function-block) drop the
	 * trailing `;`; literal-shaped expressions (object / block / array
	 * / paren / if-as-expression) keep it.
	 */
	/**
	 * HxExpr ctor names that — when wrapped in `ExprStmt(expr)` and
	 * standing as the sole statement of a case body — refuse inline
	 * emission. Empirical scope (probed against fork CLI): only `And`
	 * (`&&`) and `Or` (`||`). All other binops, ternary, and
	 * assignment variants nest hierarchically under one `dblDot` child
	 * in fork's tokentree and are allowed inline.
	 */
	private static final REFUSED_CASE_BODY_CTORS:Array<String> = ['And', 'Or'];

	/**
	 * True when a single-statement case body should refuse inline
	 * because its outermost expression is `&&` or `||`. Mirrors
	 * haxe-formatter's `MarkSameLine.markExpressionCase` body-shape
	 * heuristic. Wired on `WriteOptions.caseBodyRefusesFlat` so the
	 * writer-side `@:fmt(refuseFlatOnComplexExpr)` flat-gate AND-clause
	 * dispatches through the plugin without engine→plugin coupling.
	 *
	 * `Dynamic` argument so the same predicate fires on both Plain-mode
	 * `HxStatement` enum values and Trivia-mode `Trivial<HxStatementT>`
	 * struct wrappers — `Type.enumConstructor` matches against both
	 * enums (Plain `HxStatement` and synthesised `HxStatementT`) since
	 * they share constructor names. Returns `false` for null,
	 * non-enum, or non-`ExprStmt` shapes.
	 */
	public static function refusesCaseFlat(raw:Null<Dynamic>):Bool {
		final s:Null<Dynamic> = unwrap(raw);
		if (s == null) return false;
		if (Type.enumConstructor(s) != 'ExprStmt') return false;
		final params:Null<Array<Dynamic>> = Type.enumParameters(s);
		if (params == null || params.length == 0) return false;
		final inner:Null<Dynamic> = unwrap(params[0]);
		if (inner == null) return false;
		final ctor:Null<String> = Type.enumConstructor(inner);
		if (ctor == null) return false;
		return REFUSED_CASE_BODY_CTORS.contains(ctor);
	}

	public static function endsWithCloseBrace(raw:Null<Dynamic>):Bool {
		final e:Null<Dynamic> = unwrap(raw);
		if (e == null) return false;
		final ctor:Null<String> = Type.enumConstructor(e);
		if (ctor == null) return false;
		return switch ctor {
			case 'SwitchExpr', 'SwitchExprBare': true;
			case 'FnExpr':
				final fn:Null<Dynamic> = Type.enumParameters(e)[0];
				if (fn == null) false;
				else {
					final body:Null<Dynamic> = unwrap(Reflect.field(fn, 'body'));
					body != null && Type.enumConstructor(body) == 'BlockBody';
				}
			case 'TryExpr':
				final stmt:Null<Dynamic> = Type.enumParameters(e)[0];
				if (stmt == null) false;
				else {
					final catches:Null<Array<Dynamic>> = Reflect.field(stmt, 'catches');
					if (catches == null || catches.length == 0) false;
					else {
						final last:Null<Dynamic> = catches[catches.length - 1];
						if (last == null) false;
						else {
							final lastInner:Dynamic = Reflect.hasField(last, 'node') ? last.node : last;
							final body:Null<Dynamic> = Reflect.field(lastInner, 'body');
							body != null && endsWithCloseBrace(body);
						}
					}
				}
			case _: false;
		};
	}

	/**
	 * Returns the inner enum value for `raw`. Handles three shapes:
	 *  - `null` → `null`
	 *  - direct enum value (Plain-mode AST node) → `raw` unchanged
	 *  - `Trivial<T>` struct wrapper (Trivia-mode AST node) → `raw.node`
	 */
	private static inline function unwrap(raw:Null<Dynamic>):Null<Dynamic> {
		if (raw == null) return null;
		return Type.getEnum(raw) != null ? raw : Reflect.field(raw, 'node');
	}

	/**
	 * ω-cond-comp-tail-transparency — classifies the tail leaf decl of a
	 * `HxConditionalDecl` (or its Trivia synth pair `HxConditionalDeclT`)
	 * for the between-cascade in `WriterLowering.triviaEofStarExpr`.
	 *
	 * Walk priority (LAST non-empty branch wins — strict positional):
	 *  1. `elseBody` Star — if non-empty, classify its last element and
	 *     return that result directly (`null` is propagated up so the
	 *     caller treats the conditional as opaque). The other branches
	 *     are NOT consulted.
	 *  2. else `elseifs[last].body` … `elseifs[0].body` — scan from
	 *     tail back to find a non-empty clause body; classify its last
	 *     element and return that result directly. Branch fall-through
	 *     skips empty clauses but stops at the FIRST non-empty one.
	 *  3. else `body` Star — last element classification, returned
	 *     directly.
	 *  4. else `null` (no non-empty branch — cascade falls through to
	 *     kind=0/path='').
	 *
	 * The strict "last branch wins" semantic matches what the cascade
	 * expects from a positional trailing-element walker: a conditional
	 * whose tail branch ends in a non-import (e.g. `class Foo {}`)
	 * should NOT classify as an import even when an earlier branch
	 * does, because the source's last sibling-emitted decl is the
	 * non-import.
	 *
	 * Element classification: unwrap `Trivial<HxTopLevelDeclT>` if
	 * present, read `.decl` field (`HxDecl` or `HxDeclT` enum). On
	 * `Conditional` ctor, recurse into the wrapped payload (handles
	 * nested `#if … #if … #end #end`). On `ImportDecl` /
	 * `ImportWildDecl` / `UsingDecl` / `UsingWildDecl`, return
	 * `{ctorName, path}` with the path String the parser captured
	 * (`HxTypeName` / `HxWildPath` are abstract over String — runtime
	 * values are plain Strings). On any other ctor, return `null` —
	 * cascade treats the conditional as opaque (kind=0/path='').
	 *
	 * Wired on `WriteOptions.betweenImportsTailLeafClassify` via
	 * `HaxeFormat.defaultWriteOptions`. Same shared adapter feeds both
	 * Imports and Usings between infos on `HxModule.decls`; the engine
	 * does the per-info `_r.ctorName == '<info ctor>'` filter so each
	 * info only sees a leaf classification matching its own ctorNames.
	 *
	 * `Null<Dynamic>` argument because the same predicate fires on
	 * both Plain-mode (`HxConditionalDecl` plain struct) and Trivia-mode
	 * (`HxConditionalDeclT` paired struct); both have the same field
	 * names (`body`, `elseifs`, `elseBody`) so `Reflect.field` reads
	 * uniformly.
	 */
	public static function tailLeafClassifyImports(payload:Null<Dynamic>):Null<{ctorName:String, path:String}> {
		if (payload == null) return null;
		final elseBody:Null<Array<Dynamic>> = Reflect.field(payload, 'elseBody');
		if (elseBody != null && elseBody.length > 0)
			return classifyTopLevelDeclElement(elseBody[elseBody.length - 1], Tail);
		final elseifs:Null<Array<Dynamic>> = Reflect.field(payload, 'elseifs');
		if (elseifs != null && elseifs.length > 0) {
			var i:Int = elseifs.length - 1;
			while (i >= 0) {
				final clause:Null<Dynamic> = unwrapTrivialStruct(elseifs[i]);
				if (clause != null) {
					final clauseBody:Null<Array<Dynamic>> = Reflect.field(clause, 'body');
					if (clauseBody != null && clauseBody.length > 0)
						return classifyTopLevelDeclElement(clauseBody[clauseBody.length - 1], Tail);
				}
				i--;
			}
		}
		final body:Null<Array<Dynamic>> = Reflect.field(payload, 'body');
		if (body != null && body.length > 0)
			return classifyTopLevelDeclElement(body[body.length - 1], Tail);
		return null;
	}

	/**
	 * ω-imports-using-transition — classifies the head leaf decl of a
	 * `HxConditionalDecl` (or its Trivia synth pair `HxConditionalDeclT`)
	 * for the between-cascade in `WriterLowering.triviaEofStarExpr`.
	 *
	 * Walk priority (FIRST non-empty branch wins — strict positional,
	 * source order: `body` → `elseifs[0..]` → `elseBody`). Mirror of
	 * `tailLeafClassifyImports` but reversed: the conditional's head is
	 * what its first source-order branch contributes first.
	 *
	 *  1. `body` Star — if non-empty, classify its first element and
	 *     return that result directly (`null` propagates up so the
	 *     caller treats the conditional as opaque). Other branches
	 *     are NOT consulted.
	 *  2. else `elseifs[0].body` … `elseifs[last].body` — scan from
	 *     head to find the first non-empty clause body; classify its
	 *     first element and return directly.
	 *  3. else `elseBody` Star — first element classification.
	 *  4. else `null`.
	 *
	 * Recurses into nested `Conditional` ctors via the `Head` direction
	 * so `#if a #if b import x; #end #end` resolves to `import x` as
	 * the head leaf, not the inner conditional opaquely.
	 *
	 * Wired on `WriteOptions.betweenImportsHeadLeafClassify` via
	 * `HaxeFormat.defaultWriteOptions`. Used by both `betweenImports`
	 * cascade head-transparent path and the cross-subset transition
	 * cascade (`blankLinesOnTransitionAcross`) on `HxModule.decls`.
	 */
	public static function headLeafClassifyImports(payload:Null<Dynamic>):Null<{ctorName:String, path:String}> {
		if (payload == null) return null;
		final body:Null<Array<Dynamic>> = Reflect.field(payload, 'body');
		if (body != null && body.length > 0)
			return classifyTopLevelDeclElement(body[0], Head);
		final elseifs:Null<Array<Dynamic>> = Reflect.field(payload, 'elseifs');
		if (elseifs != null && elseifs.length > 0) {
			var i:Int = 0;
			while (i < elseifs.length) {
				final clause:Null<Dynamic> = unwrapTrivialStruct(elseifs[i]);
				if (clause != null) {
					final clauseBody:Null<Array<Dynamic>> = Reflect.field(clause, 'body');
					if (clauseBody != null && clauseBody.length > 0)
						return classifyTopLevelDeclElement(clauseBody[0], Head);
				}
				i++;
			}
		}
		final elseBody:Null<Array<Dynamic>> = Reflect.field(payload, 'elseBody');
		if (elseBody != null && elseBody.length > 0)
			return classifyTopLevelDeclElement(elseBody[0], Head);
		return null;
	}

	/**
	 * Classify one element from a `HxConditionalDecl.body` /
	 * `elseifs[i].body` / `elseBody` Star. Element shape is
	 * `HxTopLevelDecl` (Plain mode) or `Trivial<HxTopLevelDeclT>`
	 * (Trivia mode); both expose a `.decl` field of an `HxDecl` /
	 * `HxDeclT` enum value. Returns `null` on null input, missing
	 * `.decl`, or any unsupported ctor.
	 *
	 * `direction` selects which sub-walker recurses into a nested
	 * `Conditional` payload — `Head` keeps walking into first-branch /
	 * first-element, `Tail` into last-branch / last-element. Direction
	 * does NOT affect terminal `ImportDecl` / `UsingDecl` etc. cases.
	 */
	private static function classifyTopLevelDeclElement(elem:Null<Dynamic>, direction:LeafDirection):Null<{ctorName:String, path:String}> {
		final inner:Null<Dynamic> = unwrapTrivialStruct(elem);
		if (inner == null) return null;
		final decl:Null<Dynamic> = Reflect.field(inner, 'decl');
		if (decl == null) return null;
		final ctor:Null<String> = Type.enumConstructor(decl);
		if (ctor == null) return null;
		final params:Null<Array<Dynamic>> = Type.enumParameters(decl);
		if (params == null || params.length == 0) return null;
		return switch ctor {
			case 'Conditional': direction == Tail ? tailLeafClassifyImports(params[0]) : headLeafClassifyImports(params[0]);
			case 'ImportDecl' | 'ImportWildDecl' | 'UsingDecl' | 'UsingWildDecl':
				final path:Null<String> = params[0];
				path == null ? null : {ctorName: ctor, path: path};
			case _: null;
		};
	}

	/**
	 * Unwrap a `Trivial<T>` wrapper struct around another struct (e.g.
	 * `Trivial<HxTopLevelDeclT>` → `HxTopLevelDeclT`). Distinct from
	 * `unwrap` above because that one targets enum values and uses
	 * `Type.getEnum` to discriminate; here both wrapper and wrapped are
	 * structs, so the discriminator is `Reflect.hasField('node')`. Plain
	 * structs (`HxTopLevelDecl` directly, no wrapper) have no `node`
	 * field and pass through unchanged.
	 */
	private static inline function unwrapTrivialStruct(raw:Null<Dynamic>):Null<Dynamic> {
		if (raw == null) return null;
		return Reflect.hasField(raw, 'node') ? Reflect.field(raw, 'node') : raw;
	}
}

/**
 * Recursion direction selector for `classifyTopLevelDeclElement` when
 * encountering a nested `Conditional` ctor. `Head` recurses via
 * `headLeafClassifyImports` (first branch / first element); `Tail`
 * recurses via `tailLeafClassifyImports` (last branch / last element).
 */
private enum abstract LeafDirection(Int) {
	final Head = 0;
	final Tail = 1;
}
