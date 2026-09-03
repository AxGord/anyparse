package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferTernaryReturn;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-ternary-return` check: an `if (cond) return a;` immediately
 * followed by a `return b;` is flagged `Info` and `fix` collapses the pair to
 * `return cond ? a : b;`. Only a no-else `if` that is a direct block statement
 * with a value-returning then-branch and an immediately-following value
 * `return` qualifies; the condition is parenthesised only when it binds no
 * tighter than `?:`.
 */
class PreferTernaryReturnCheckTest extends Test {

	public function testBasicPairFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-ternary-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this if/return pair can be a single ternary return', vs[0].message);
	}

	public function testBracedThenFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t}\n\t\treturn 0;\n\t}\n}').length);
	}

	public function testVoidReturnThenNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) return;\n\t\treturn;\n\t}\n}').length);
	}

	public function testVoidReturnNextNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\treturn;\n\t}\n}').length);
	}

	public function testElsePresentNotFlagged(): Void {
		// An else makes this `redundant-else-after-return`'s job; once de-nested it
		// becomes the no-else form this check then collapses.
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\telse return 2;\n\t}\n}').length);
	}

	public function testStatementBetweenNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\tb();\n\t\treturn 0;\n\t}\n}').length);
	}

	public function testThenNotReturnNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tif (a) b();\n\t\treturn 0;\n\t}\n}').length);
	}

	public function testNextNotReturnNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) return 1;\n\t\tb();\n\t}\n}').length);
	}

	public function testInlineNonBlockIfNotFlagged(): Void {
		// The inner `if` is the un-braced body of the outer `if`; the trailing
		// `return` is a sibling of the OUTER statement, not the inner `if`.
		Assert.equals(
			0, violations('class C {\n\tfunction f():Int {\n\t\tif (outer)\n\t\t\tif (a) return 1;\n\t\treturn 0;\n\t}\n}').length
		);
	}

	public function testFixBasic(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return a ? 1 : 0;', es[0].text);
	}

	public function testFixBracedThen(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t}\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return a ? 1 : 0;', es[0].text);
	}

	public function testFixComparisonConditionNotWrapped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\tif (x > 0) return 1;\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return x > 0 ? 1 : 0;', es[0].text);
	}

	public function testFixTernaryConditionWrapped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Bool {\n\t\tif (a ? b : c) return 1;\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return (a ? b : c) ? 1 : 0;', es[0].text);
	}

	public function testFixAssignmentConditionWrapped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Bool {\n\t\tif (x = g()) return 1;\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return (x = g()) ? 1 : 0;', es[0].text);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-ternary-return'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-ternary-return'));
	}

	/**
	 * A null-narrowing guard in the condition (`s != null && s.g()`) is NOT flagged:
	 * flattening it into a ternary return would lose the narrowing and fail to
	 * compile under @:nullSafety(Strict).
	 */
	public function testNullNarrowingGuardNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f(s:Null<S>):Bool {\n\t\tif (s != null && s.g() != null) return true;\n\t\treturn c;\n\t}\n}')
				.length
		);
	}

	public function testNullGuardValueBranchesFlaggedAndFixed(): Void {
		// A VALUE ternary keeps the if-condition narrowing (`cond ? a : b` types like
		// if/else), so a null-narrowing guard refuses only bool-literal collapses.
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(res:Null<R>):String {\n\t\tif (res != null && res.d != null) return t(res.d);\n\t\treturn t("x");\n'
			+ '\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return res != null && res.d != null ? t(res.d) : t("x");', es[0].text);
	}

	/** A null-check WITHOUT accessing the same ident still flags (no narrowing to lose). Value returns keep this off the stuck-boolean gate. */
	public function testNullCheckWithoutAccessFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tfunction f(s:Null<S>):Int {\n\t\tif (s != null) return 1;\n\t\treturn 0;\n\t}\n}').length
		);
	}

	/** A null-checked ident reused via INDEX access (`x[0]`) is guarded too (not just field/call). */
	public function testIndexAccessGuardNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(x:Null<Array<Int>>):Bool {\n\t\tif (x != null && x[0] > 0) return true;\n\t\treturn c;\n\t}\n}'
			).length
		);
	}

	/** A null-checked ident reused as a function ARGUMENT (`g(x)`) is guarded too. */
	public function testArgPositionGuardNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f(x:Null<S>):Bool {\n\t\tif (x != null && g(x)) return true;\n\t\treturn c;\n\t}\n}').length
		);
	}

	/**
	 * `if (c) return true; return g();` would be a stuck `c ? true : g()` (`g()` not provably
	 * Bool): left as a guard. The host function is UNANNOTATED — the gate now has a second
	 * proof (`RefactorSupport.declaresNonNullBool`) and an inferred return type supplies
	 * none, so this pins the refusal that survives it. The declared-`:Bool` twin of this
	 * shape is `testCallTailInBoolFunctionFlagged`, which collapses.
	 */
	public function testStuckBooleanCallNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(c:Bool) {\n\t\tif (c) return true;\n\t\treturn g();\n\t}\n}').length);
	}

	/** A provably-Bool other side (`x > 0`) collapses — simplify-boolean-ternary then reduces it cleanly. */
	public function testBooleanWithProvableOtherFlagged(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f(c:Bool, x:Int):Bool {\n\t\tif (c) return true;\n\t\treturn x > 0;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return c ? true : x > 0;', es[0].text);
	}

	/** Both branches boolean literals (`? true : false`) still collapses (simplify then reduces to `c`). */
	public function testBothBooleanLiteralsFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f(c:Bool):Bool {\n\t\tif (c) return true;\n\t\treturn false;\n\t}\n}').length);
	}

	/** An `if`/`return` pair wholly inside one `#if` branch collapses — the branch is its own statement list. */
	public function testPairInsideConditionalBranchFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(c:Bool):Int {\n\t\t#if A\n\t\tif (c) return 1;\n\t\treturn 2;\n\t\t#end\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return c ? 1 : 2;', es[0].text);
	}

	/**
	 * The `if` ends one branch and the `return` opens the next: collapsing them would splice
	 * across `#else` and delete the directive. The two are not siblings in one statement list.
	 */
	public function testPairStraddlingTwoBranchesNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f(c:Bool):Int {\n\t\t#if A\n\t\tif (c) return 1;\n\t\t#else\n\t\treturn 2;\n\t\t#end\n\t}\n}')
				.length
		);
	}

	/**
	 * A comment still on the guard's own line describes THAT guard's value, so it
	 * rides the then-branch of the rebuilt ternary. Hoisting it above the merged
	 * `return` (the pre-slice behaviour) re-reads it as a description of the whole
	 * collapsed chain. The break is mandatory for a `//` — glued before the `:` it
	 * would comment the else-branch out.
	 */
	public function testGuardLineTrailingCommentRidesItsBranch(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(a:Bool):Int {\n\t\tif (a) return 1; // already linked\n\t\treturn 0;\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return a\n? 1 // already linked\n: 0;', es[0].text);
	}

	/** An OWN-LINE comment between the two statements is not about either value — it keeps the leading-block hoist. */
	public function testOwnLineCommentBetweenStatementsStillHoists(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(a:Bool):Int {\n\t\tif (a) return 1;\n\t\t// why zero\n\t\treturn 0;\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('// why zero\nreturn a ? 1 : 0;', es[0].text);
	}

	/** Both kinds at once: the guard-line one attaches, the own-line one hoists — neither is dropped. */
	public function testBothPositionsSplitCorrectly(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(a:Bool):Int {\n\t\tif (a) return 1; // linked\n\t\t// why zero\n\t\treturn 0;\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('// why zero\nreturn a\n? 1 // linked\n: 0;', es[0].text);
	}

	/** A block comment on the guard line rides the branch too — inline-safe, so the writer may re-flatten it. */
	public function testGuardLineBlockCommentRidesItsBranch(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f(a:Bool):Int {\n\t\tif (a) return 1; /* linked */\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return a\n? 1 /* linked */\n: 0;', es[0].text);
	}

	/**
	 * THE SLICE: a `Call` tail in a function DECLARING `:Bool` collapses. The declared
	 * return type is the proof `provablyBoolOperand` cannot supply — under
	 * `@:nullSafety(Strict)` the original `return g();` cannot compile unless `g()` is a
	 * non-null `Bool`, and without Strict the guard / ternary / `&&` forms are
	 * observationally identical anyway (measured over `{null,true,false}` x `{true,false}`
	 * on `--interp`, `js` and `--jvm`).
	 */
	public function testCallTailInBoolFunctionFlagged(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f(c:Bool):Bool {\n\t\tif (c) return true;\n\t\treturn g();\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return c ? true : g();', es[0].text);
	}

	/** The motivating shape: a null guard with a `false` default and a method-call tail. */
	public function testNullGuardCallTailInBoolFunctionFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Bool {\n\t\tif (xs == null) return false;\n\t\treturn xs.foreach(p);\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return xs == null ? false : xs.foreach(p);', es[0].text);
	}

	/** `Null<Bool>` gives no such guarantee — a nullable declared return type stays refused. */
	public function testCallTailInNullBoolFunctionNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f(c:Bool):Null<Bool> {\n\t\tif (c) return true;\n\t\treturn g();\n\t}\n}').length
		);
	}

	/** `Dynamic` / `Any` are null-safety escape hatches, not the non-null `Bool` nominal — refused. */
	public function testCallTailInDynamicFunctionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(c:Bool):Dynamic {\n\t\tif (c) return true;\n\t\treturn g();\n\t}\n}').length);
	}

	/**
	 * The proof is the NEAREST enclosing function's: a `:Bool` outer does not license an inner
	 * lambda, which promises nothing. Both lambda spellings, because `FnExpr` and
	 * `ThinParenLambdaExpr` live in `lambdaKinds` and NOT in `functionKinds` — a walk rebinding
	 * on `functionKinds` alone leaks the method's `Bool` into every lambda inside it.
	 */
	public function testInnerLambdaDoesNotInheritOuterBoolReturn(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Bool {\n\t\tvar h = function(c:Bool) {\n\t\t\tif (c) return true;\n'
				+ '\t\t\treturn g();\n\t\t};\n\t\treturn h(true);\n\t}\n}'
			).length
		);
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Bool {\n\t\tvar k = (c:Bool) -> {\n\t\t\tif (c) return true;\n'
				+ '\t\t\treturn g();\n\t\t};\n\t\treturn k(true);\n\t}\n}'
			).length
		);
	}

	/** A `null`-literal tail stays refused: `!c && null` is degenerate, and under Strict the site cannot exist. */
	public function testNullLiteralTailInBoolFunctionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(c:Bool):Bool {\n\t\tif (c) return true;\n\t\treturn null;\n\t}\n}').length);
	}

	/** A statement-like tail (`switch` / `try` / `if` expression) stays refused: the flat form is uglier than the guard. */
	public function testStatementLikeTailInBoolFunctionNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(c:Bool):Bool {\n\t\tif (c) return true;\n\t\treturn switch (x) {\n'
				+ '\t\t\tcase 1: true;\n\t\t\tcase _: false;\n\t\t}\n\t}\n}'
			).length
		);
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(c:Bool):Bool {\n\t\tif (c) return true;\n\t\treturn try g() catch (e:Dynamic) false;\n\t}\n}'
			).length
		);
	}

	/**
	 * A tail that is itself a ternary MID-REDUCTION waits one `--fix` pass. Collapsing onto it
	 * strands the inner ternary out of return-value position, where it can never regain its
	 * licence — the hybrid `a || (b ? false : g())` measured on `PreferInline.hx` /
	 * `TrivialGetter.hx`. Once `simplify-boolean-ternary` has flattened the inner one to `&&`,
	 * the outer pair collapses through the original kind-only proof.
	 */
	public function testPendingBooleanTernaryTailNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f(c:Bool, d:Bool):Bool {\n\t\tif (c) return true;\n\t\treturn d ? false : g();\n\t}\n}')
				.length
		);
	}

	/**
	 * The mid-reduction gate is INDEPENDENT of the stuck-boolean one: a VALUE ternary collapse
	 * (neither value a bool literal) buries the tail just as thoroughly, and never consults the
	 * stuck check at all. `dropContainedEdits` keeps the OUTER of two overlapping edits, so the
	 * inner reduction is dropped rather than deferred — measured on anyparse's own
	 * `MagicNumber.childPositionCtx`, which came out as `p ? i >= 1 : q ? c : false`.
	 */
	public function testValueCollapseOntoPendingTernaryNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(p:Bool, i:Int, q:Bool, c:Bool):Bool {\n\t\tif (p) return i >= 1;\n'
				+ '\t\treturn q ? c : false;\n\t}\n}'
			).length
		);
	}

	/** …and once it HAS flattened, the same pair collapses. */
	public function testFlattenedTailThenFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(c:Bool, d:Bool):Bool {\n\t\tif (c) return true;\n\t\treturn !d && g();\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return c ? true : !d && g();', es[0].text);
	}

	/**
	 * A pair that is the TAIL of a cascade `prefer-if-expression-return` claims is deferred to it:
	 * collapsing it alone writes the three-rung ternary `prefer-if-expression-chain` then condemns,
	 * so the reader is shown one finding, applies it, and the next run reports something the first
	 * never mentioned. The control is the same pair with no rung in front of it, which stays here
	 * because two leaf values ARE the ternary canon.
	 */
	public function testTailOfClaimedCascadeDeferred(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Int {\n\t\tif (a) return e();\n\t\tif (b) return g();\n\t\treturn h();\n\t}\n}').length,
			'the tail pair belongs to the cascade the other rule rewrites whole'
		);
		Assert.equals(
			1, violations('class C {\n\tfunction f():Int {\n\t\tif (b) return g();\n\t\treturn h();\n\t}\n}').length,
			'the same pair alone is this rule\'s'
		);
	}

	/**
	 * The head of the run comes from `prefer-if-expression-return` itself, so a statement that is a
	 * rung by SHAPE but not one it collects — a no-`else` `if` that does not return a value — cannot
	 * pull this rule's walk-back past the real head. Derived locally it did: the deferral asked about
	 * an index the claiming rule never uses, answered `false`, and both rules reported one control
	 * flow. Measured on heaps' `poly2tri/Point.hx`, `cpp/_std/StringBuf.hx` and `php/_std/EReg.hx`.
	 *
	 * Both spellings of that statement, plus the control with nothing in front of the cascade.
	 */
	public function testNonReturnRungDoesNotBreakTheDeferral(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\tif (x) g();\n\t\tif (a) return e();\n\t\tif (b) return g();\n\t\treturn h();\n\t}\n}'
			).length,
			'a non-returning if in front of the cascade does not break the deferral'
		);
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\tif (x) return;\n\t\tif (a) return e();\n\t\tif (b) return g();\n\t\treturn h();\n'
				+ '\t}\n}'
			).length,
			'nor does a bare `return;` rung, which is a rung by shape and by nothing else'
		);
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Int {\n\t\tif (a) return e();\n\t\tif (b) return g();\n\t\treturn h();\n\t}\n}').length,
			'and the bare cascade is deferred as before'
		);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferTernaryReturn().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferTernaryReturn = new PreferTernaryReturn();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
