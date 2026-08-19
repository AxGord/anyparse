package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.GuardReturn;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import anyparse.query.SymbolIndex;
import anyparse.query.CachingGrammarPlugin;

/**
 * The `guard-return` check: a block whose LAST TWO statements are a bare
 * `if (cond) { BLOCK }` (no `else`, `BLOCK` terminal and holding at least two
 * statements) and a lone trailing `return TAIL;` is flagged `Info` and inverted into
 * an early-return guard — `if (!cond) return TAIL; <BLOCK de-nested>`. The inversion
 * runs through the shared `NegationScan.negateConditionText`, so `==` / `!=` flip
 * (NaN-safe), `!e` strips, `a && b` De Morgans to `!a || !b`, and an ordered
 * comparison stays wrapped `!(a < b)` unless BOTH its operands resolve to a
 * type `<` orders TOTALLY — free of both NaN and `null`, so never `String` — which
 * flips it (`a <= b`). Gates: a ONE-statement then-branch is
 * `prefer-ternary-return`'s shape and is skipped, a non-terminal then-branch, an
 * `else`, an unbraced then-branch, a statement between the `if` and the tail, a
 * conditional-compilation region, a dropped-glue comment, a comment on the tail
 * return, and a de-nested local that would same-scope re-declare a preceding sibling
 * all refuse.
 */
class GuardReturnCheckTest extends Test {

	// --- positives: flagged + fixed ------------------------------------------------

	public function testReferenceShapeFlaggedAndFixed(): Void {
		final code: String =
			'if (b.folder) {\n\t\t\tif (b.children == null) load(b);\n\t\t\treturn b.childExists(a);\n\t\t}\n\t\treturn false;';
		final vs: Array<Violation> = v(code);
		Assert.equals(1, vs.length);
		Assert.equals('guard-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this trailing if can invert into an early-return guard', vs[0].message);
		Assert.equals(
			canon(wrap('if (!b.folder) return false;\n\t\tif (b.children == null) load(b);\n\t\treturn b.childExists(a);')), fx(code)
		);
	}

	public function testThrowTerminalFixed(): Void {
		Assert.equals(
			canon(wrap('if (!ok) return false;\n\t\tlog(a);\n\t\tthrow \'bad\';')),
			fx('if (ok) {\n\t\t\tlog(a);\n\t\t\tthrow \'bad\';\n\t\t}\n\t\treturn false;')
		);
	}

	public function testBreakTerminalFixed(): Void {
		// De-nesting out of an `if` crosses no loop boundary, so a `break` keeps its target.
		Assert.equals(
			canon(wrap('while (more) {\n\t\t\tif (!ok) return false;\n\t\t\tlog(a);\n\t\t\tbreak;\n\t\t}\n\t\treturn true;')),
			fx('while (more) {\n\t\t\tif (ok) {\n\t\t\t\tlog(a);\n\t\t\t\tbreak;\n\t\t\t}\n\t\t\treturn false;\n\t\t}\n\t\treturn true;')
		);
	}

	public function testVoidReturnTailFixed(): Void {
		final source: String =
			'class C {\n\tfunction f(a:Int):Void {\n\t\tif (a > 0) {\n\t\t\tlog(a);\n\t\t\treturn;\n\t\t}\n\t\treturn;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f(a:Int):Void {\n\t\tif (a <= 0) return;\n\t\tlog(a);\n\t\treturn;\n\t}\n}\n';
		Assert.equals(canon(expected), fxSource(source));
	}

	public function testNestedBlockFlagged(): Void {
		// The pattern in a plain nested `{ … }` block, not only a function body.
		Assert.equals(1, v('{\n\t\t\tif (ok) {\n\t\t\t\tlog(a);\n\t\t\t\treturn true;\n\t\t\t}\n\t\t\treturn false;\n\t\t}').length);
	}

	public function testPrecedingStatementsKept(): Void {
		Assert.equals(
			canon(wrap('setup();\n\t\tif (!ok) return false;\n\t\tlog(a);\n\t\treturn true;')),
			fx('setup();\n\t\tif (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;')
		);
	}

	// --- negation submatrix ---------------------------------------------------------

	public function testEqNullFlipped(): Void {
		Assert.isTrue(fx(cond('a == null')).indexOf('if (a != null) return false;') != -1);
	}

	public function testNotEqNullFlipped(): Void {
		Assert.isTrue(fx(cond('a != null')).indexOf('if (a == null) return false;') != -1);
	}

	public function testNotStripped(): Void {
		Assert.isTrue(fx(cond('!ready')).indexOf('if (ready) return false;') != -1);
	}

	public function testNestedNotStrippedAndParenUnwrapped(): Void {
		Assert.isTrue(fx(cond('!(p || q)')).indexOf('if (p || q) return false;') != -1);
	}

	public function testUnprovableOrderedNotFlagged(): Void {
		// `x` has no resolvable type, so the flip is not licensed and the inversion would have
		// to wrap `!(x < 10)` — worse than the positive branch it replaces.
		Assert.equals(0, v(cond('x < 10')).length);
	}

	public function testOrderedFlippedWhenBothOperandsInt(): Void {
		Assert.isTrue(fx(cond('a > 0')).indexOf('if (a <= 0) return false;') != -1);
	}

	public function testOrderedFloatOperandNotFlagged(): Void {
		final source: String = 'class C {\n\tfunction f(a:Float):Bool {\n\t\tif (a > 0) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n'
			+ '\t\treturn false;\n\t}\n}\n';
		Assert.equals(0, new GuardReturn().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()).length);
	}

	public function testOrderedFloatLiteralOperandNotFlagged(): Void {
		Assert.equals(0, v(cond('a > 0.5')).length);
	}

	public function testOrderedStringOperandsNotFlagged(): Void {
		// `String` carries no NaN, but Haxe has no non-nullable string type, so the ordered flip
		// is not licensed: with a null operand `!(s < k)` is `true` where `s >= k` is `false`. The
		// engine declines, `negationIsClean` answers false, and the site is not flagged — the
		// inversion would have had to emit `if (!(s < k)) return false;`, worse than the positive
		// branch it replaces. `testOrderedFlippedWhenBothOperandsInt` is the same GUARD shape over a
		// licensed nominal and still fires; it compares against a LITERAL, so this fixture is also the
		// only one in the file that asks the resolver to prove BOTH operands from declarations.
		final source: String = 'class C {\n\tfunction f(s:String, k:String):Bool {\n\t\tif (s < k) {\n\t\t\tlog(s);\n\t\t\treturn true;\n'
			+ '\t\t}\n\t\treturn false;\n\t}\n}\n';
		Assert.equals(0, new GuardReturn().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()).length);
	}

	public function testOrderedFlippedThroughMemberPath(): Void {
		Assert.isTrue(
			fixedWith(memberPathSource(), 'typedef Res = {\n\tcount:Int\n};\n').indexOf('if (res.count <= 0) return false;') != -1
		);
	}

	public function testOrderedFlippedThroughStructuralExtension(): Void {
		final model: String = 'typedef Base = {\n\tcount:Int\n};\n\ntypedef Res = {\n\t> Base,\n\tname:String\n};\n';
		Assert.isTrue(fixedWith(memberPathSource(), model).indexOf('if (res.count <= 0) return false;') != -1);
	}

	public function testOrderedFloatMemberPathNotFlagged(): Void {
		Assert.equals(0, scopedViolations(memberPathSource(), 'typedef Res = {\n\tcount:Float\n};\n').length);
	}

	public function testAndDeMorganed(): Void {
		Assert.isTrue(fx(cond('p && q')).indexOf('if (!p || !q) return false;') != -1);
	}

	public function testAtomicIdentNoParens(): Void {
		Assert.isTrue(fx(cond('ready')).indexOf('if (!ready) return false;') != -1);
	}

	public function testAtomicCallNoParens(): Void {
		Assert.isTrue(fx(cond('ready()')).indexOf('if (!ready()) return false;') != -1);
	}

	public function testSafeNullChainKeepsDeMorgan(): Void {
		// No operand consumes a narrowing from a non-first operand, so De Morgan stands.
		Assert.isTrue(
			fx(cond('a != null && b != null && c != null')).indexOf('if (a == null || b == null || c == null) return false;') != -1
		);
	}

	public function testStrandedNarrowingRegroupsDeMorgan(): Void {
		// `b`'s fact would not survive a FLAT `||` chain (Haxe carries only the first
		// operand's narrowing that far), so the negation right-nests the tail: inside
		// the group `b == null` is first again and its fact reaches `p`.
		final fixed: String = fx(cond('a != null && b != null && p(a.length, b.length)'));
		Assert.isTrue(fixed.indexOf('if (a == null || (b == null || !p(a.length, b.length))) return false;') != -1);
	}

	public function testStrandedMultiLineConditionStillDeMorgans(): Void {
		// The regrouped De Morgan leaves no verbatim-wrap tier for a stranded chain, so
		// the old multi-line refusal has nothing left to protect — the site de-nests and
		// the condition collapses to the one-line grouped disjunction.
		final fixed: String = fx(cond('a != null\n\t\t\t&& b != null\n\t\t\t&& p(a.length, b.length)'));
		Assert.isTrue(fixed.indexOf('if (a == null || (b == null || !p(a.length, b.length))) return false;') != -1);
	}

	public function testDeMorganedMultiLineConditionStillFlagged(): Void {
		// The same multi-line shape WITHOUT a stranded narrowing keeps its de-nest.
		Assert.equals(1, v(cond('a != null\n\t\t\t&& b != null\n\t\t\t&& c != null')).length);
	}

	public function testParenNestedStrandedNarrowingRegroupsDeMorgan(): Void {
		// The negation DROPS the parens, so the flattened chain is the same three
		// operands as the unparenthesised shape — and regroups at the same seam.
		final fixed: String = fx(cond('a != null && (b != null && p(a.length, b.length))'));
		Assert.isTrue(fixed.indexOf('if (a == null || (b == null || !p(a.length, b.length))) return false;') != -1);
	}

	public function testStrandedNarrowingFirstOperandStillDeMorgans(): Void {
		// The FIRST operand's fact does survive the `||` chain, so this one is safe.
		Assert.isTrue(
			fx(cond('a != null && q() && p(a.length, 0)')).indexOf('if (a == null || !q() || !p(a.length, 0)) return false;') != -1
		);
	}

	// --- gates: safe misses ----------------------------------------------------------

	public function testSingleStatementThenNotFlagged(): Void {
		// One statement is `prefer-ternary-return`'s shape.
		Assert.equals(0, v('if (ok) {\n\t\t\treturn true;\n\t\t}\n\t\treturn false;').length);
	}

	public function testNonTerminalThenNotFlagged(): Void {
		Assert.equals(0, v('if (ok) {\n\t\t\tlog(a);\n\t\t\tstep();\n\t\t}\n\t\treturn false;').length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(
			0, v('if (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t} else {\n\t\t\treturn false;\n\t\t}\n\t\treturn false;').length
		);
	}

	public function testElseIfChainNotFlagged(): Void {
		Assert.equals(
			0,
			v(
				'if (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t} else if (p) {\n\t\t\tlog(a);\n\t\t\treturn false;\n\t\t}\n\t\treturn false;'
			).length
		);
	}

	public function testStatementBetweenIfAndReturnNotFlagged(): Void {
		Assert.equals(0, v('if (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\tstep();\n\t\treturn false;').length);
	}

	public function testUnbracedThenNotFlagged(): Void {
		Assert.equals(0, v('if (ok) return true;\n\t\treturn false;').length);
	}

	public function testUnbracedCompoundThenNotFlagged(): Void {
		// An unbraced then-branch that still has 2 children and a terminal last child —
		// only the braced-block gate rejects it (`editFor` would slice off `w` and `;`).
		Assert.equals(0, v('if (ok) while (more) return true;\n\t\treturn false;').length);
	}

	public function testNoTrailingReturnNotFlagged(): Void {
		Assert.equals(0, v('if (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\tstep();').length);
	}

	public function testIfUnderDeclarationNotFlagged(): Void {
		// An expression-position `if` never occupies the block's second-to-last slot —
		// here that slot is the `var` statement that holds it.
		Assert.equals(0, v('final x = if (ok) 1 else 2;\n\t\treturn x > 0;').length);
	}

	public function testConditionalRegionInsideThenNotFlagged(): Void {
		Assert.equals(
			0,
			v('if (ok) {\n\t\t\t#if debug\n\t\t\tlog(a);\n\t\t\t#end\n\t\t\tstep();\n\t\t\treturn true;\n\t\t}\n\t\treturn false;').length
		);
	}

	public function testConditionalRegionWrappingIfNotFlagged(): Void {
		// Branch-aware or not, a run never reaches across `#end`: the trailing `return` is
		// outside the region, so the branch holds ONE statement and the block's
		// second-to-last slot is a `Conditional`, not an `if`.
		Assert.equals(0, v('#if debug\n\t\tif (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\t#end\n\t\treturn false;').length);
	}

	public function testConditionalRegionInTailReturnNotFlagged(): Void {
		// A `#if` splice INSIDE the trailing return — only the tail arm of the
		// conditional-region gate rejects this one.
		Assert.equals(0, v('if (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn #if debug 2 > 1 #else 3 > 1 #end;').length);
	}

	public function testGlueCommentNotFlagged(): Void {
		Assert.equals(0, v('if (ok) /* x */ {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;').length);
	}

	public function testIfKeywordGlueCommentNotFlagged(): Void {
		// The `if` … `(` arm of the glue gate, distinct from the `)` … `{` arm above.
		Assert.equals(0, v('if /* x */ (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;').length);
	}

	public function testCommentBeforeTailReturnNotFlagged(): Void {
		Assert.equals(0, v('if (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\t// fall through\n\t\treturn false;').length);
	}

	public function testTrailingCommentOnTailReturnNotFlagged(): Void {
		Assert.equals(0, v('if (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false; // default').length);
	}

	public function testLocalCollisionNotFlagged(): Void {
		Assert.equals(
			0, v('final n = pre();\n\t\tif (ok) {\n\t\t\tfinal n = other();\n\t\t\treturn n > 0;\n\t\t}\n\t\treturn n > 1;').length
		);
	}

	public function testNoCollisionFlagged(): Void {
		Assert.equals(
			1, v('final n = pre();\n\t\tif (ok) {\n\t\t\tfinal m = other();\n\t\t\treturn m > n;\n\t\t}\n\t\treturn n > 1;').length
		);
	}

	// --- comments that survive --------------------------------------------------------

	public function testThenBodyCommentPreserved(): Void {
		Assert.equals(
			canon(wrap('if (!ok) return false;\n\t\t// explain\n\t\tlog(a);\n\t\treturn true;')),
			fx('if (ok) {\n\t\t\t// explain\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;')
		);
	}

	public function testConditionCommentPreservedInEdit(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (p /* keep */ && q) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;'));
		Assert.equals(1, es.length);
		Assert.isTrue(es[0].text.indexOf('/* keep */') != -1);
	}

	public function testTailReturnCommentRidesAlong(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn /* why */ false;'));
		Assert.equals(1, es.length);
		Assert.isTrue(es[0].text.indexOf('if (!ok) return /* why */ false;') != -1);
	}

	// --- idempotence + robustness -------------------------------------------------------

	public function testIdempotent(): Void {
		final fixed: String = fx('if (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;');
		Assert.equals(fixed, applyFixOnce(fixed));
	}

	public function testNestedPairConverges(): Void {
		Assert.equals(
			canon(wrap('if (!p) return 3;\n\t\tif (!q) return 2;\n\t\tstep();\n\t\treturn 1;')),
			fx('if (p) {\n\t\t\tif (q) {\n\t\t\t\tstep();\n\t\t\t\treturn 1;\n\t\t\t}\n\t\t\treturn 2;\n\t\t}\n\t\treturn 3;')
		);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, new GuardReturn().run([{ file: 'C.hx', source: 'class Bad { function f() { if (a) { g();' }], new HaxeQueryPlugin()).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('guard-return'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('guard-return'));
		Assert.equals(166, Linter.builtins().length);
	}

	// --- implicit Void tail: an `if` with no explicit trailing return -----------------------

	/**
	 * The reference shape: a bare trailing `if` as the whole body of a `: Void` method, whose
	 * then-branch ends in a plain CALL — the terminal gate the explicit-pair arm applies would
	 * reject it, and the implicit-tail arm deliberately does not.
	 */
	public function testImplicitVoidTailFlaggedAndFixed(): Void {
		final source: String = 'class C {\n\tpublic function disable():Void {\n\t\tif (_handle != null) {\n\t\t\tlog(_handle);\n'
			+ '\t\t\tdetach(_handle);\n\t\t}\n\t}\n}\n';
		final expected: String = 'class C {\n\tpublic function disable():Void {\n\t\tif (_handle == null) return;\n\t\tlog(_handle);\n'
			+ '\t\tdetach(_handle);\n\t}\n}\n';
		Assert.equals(1, vSource(source).length);
		Assert.equals(canon(expected), fxSource(source));
	}

	/** A function with NO return annotation and no value `return` in its own scope infers `Void`. */
	public function testUnannotatedNoValueReturnFlagged(): Void {
		Assert.equals(1, vSource('class C {\n\tfunction f(a:Int) {\n\t\tif (a > 0) {\n\t\t\tp(a);\n\t\t\tq(a);\n\t\t}\n\t}\n}\n').length);
	}

	/** A constructor carries no return-type child and no value return, so the inference branch proves it. */
	public function testConstructorImplicitTailFlagged(): Void {
		Assert.equals(
			1, vSource('class C {\n\tpublic function new(a:Int) {\n\t\tif (a > 0) {\n\t\t\tp(a);\n\t\t\tq(a);\n\t\t}\n\t}\n}\n').length
		);
	}

	/**
	 * THE VOID-GATE DISCRIMINATOR: every other gate passes for this one. The body COMPILES —
	 * the trailing `if` is unreachable after the `throw` — and holds no value `return`, so only
	 * the declared `: Int` annotation stands between the arm and an inserted `return;` that
	 * would not compile.
	 */
	public function testAnnotatedNonVoidUnreachableTailNotFlagged(): Void {
		Assert.equals(
			0,
			vSource('class C {\n\tfunction f(a:Int):Int {\n\t\tthrow \'no\';\n\t\tif (a > 0) {\n\t\t\tp(a);\n\t\t\tq(a);\n\t\t}\n\t}\n}\n')
				.length
		);
	}

	/** An un-annotated function holding a value `return` elsewhere does not infer `Void`. */
	public function testValueReturnInScopeNotFlagged(): Void {
		Assert.equals(
			0,
			vSource(
				'class C {\n\tfunction f(a:Int) {\n\t\tif (a < 0) return 1;\n\t\tif (a > 0) {\n\t\t\tp(a);\n\t\t\tq(a);\n\t\t}\n\t}\n}\n'
			).length
		);
	}

	/**
	 * THE TAIL-POSITION DISCRIMINATOR: a loop body is not the function's tail — falling off its
	 * end goes round again, not out — so a trailing `if` there stays `guard-continue`'s turf.
	 */
	public function testIfLastInLoopBodyNotFlagged(): Void {
		Assert.equals(0, vVoid('while (more()) {\n\t\t\tp(a);\n\t\t\tif (a > 0) {\n\t\t\t\tr(a);\n\t\t\t\ts(a);\n\t\t\t}\n\t\t}').length);
	}

	/** A plain nested `{ … }` block is not the function's tail either — only the body block is. */
	public function testIfLastInNestedBlockNotFlagged(): Void {
		Assert.equals(0, vVoid('{\n\t\t\tp(a);\n\t\t\tif (a > 0) {\n\t\t\t\tr(a);\n\t\t\t\ts(a);\n\t\t\t}\n\t\t}').length);
	}

	/** EVERY branch of a tail-position `#if` region is itself a tail — mutually exclusive configurations. */
	public function testConditionalBranchImplicitTailFlaggedAndFixed(): Void {
		final code: String = 'p(a);\n\t\t#if debug\n\t\tif (a > 0) {\n\t\t\tr(a);\n\t\t\ts(a);\n\t\t}\n\t\t#else\n\t\tif (a > 1) {'
			+ '\n\t\t\tt(a);\n\t\t\tu(a);\n\t\t}\n\t\t#end';
		Assert.equals(2, vVoid(code).length);
		Assert.equals(
			canon(wrapVoid(
				'p(a);\n\t\t#if debug\n\t\tif (a <= 0) return;\n\t\tr(a);\n\t\ts(a);\n\t\t#else\n\t\tif (a <= 1) return;'
				+ '\n\t\tt(a);\n\t\tu(a);\n\t\t#end'
			)),
			fxVoid(code)
		);
	}

	/** A region that is NOT the body's last statement is no tail: the inserted `return` would skip what follows `#end`. */
	public function testConditionalRegionNotLastNotFlagged(): Void {
		Assert.equals(0, vVoid('#if debug\n\t\tif (a > 0) {\n\t\t\tr(a);\n\t\t\ts(a);\n\t\t}\n\t\t#end\n\t\tafter(a);').length);
	}

	/** `MIN_THEN_STATEMENTS` applies to this arm too — one statement is not worth a guard. */
	public function testOneStatementThenBranchNotFlagged(): Void {
		Assert.equals(0, vVoid('if (a > 0) {\n\t\t\tr(a);\n\t\t}').length);
	}

	/** A comment trailing the `if`'s closing brace would end up documenting the last de-nested statement. */
	public function testTrailingCommentAfterIfNotFlagged(): Void {
		Assert.equals(0, vVoid('if (a > 0) {\n\t\t\tr(a);\n\t\t\ts(a);\n\t\t} // note').length);
	}

	/**
	 * THE LAMBDA-EXCLUSION DISCRIMINATOR. `FnExpr` is the one lambda kind whose body really is a
	 * `blockBodyKind`, so it is the only shape that would open a tail chain if the lambda kinds
	 * joined `functionKinds` - the arrow forms are already rejected one level earlier, by the
	 * `VarStmt` that is not a `#if` region (the same clause the loop / nested-block cases test).
	 * Lambdas are excluded wholesale because an ARROW function with a block body DOES yield its
	 * last expression's value, so de-nesting could change its inferred return type and make the
	 * inserted `return;` illegal.
	 */
	public function testLambdaBlockTailNotFlagged(): Void {
		Assert.equals(0, vVoid('var g = function() {\n\t\t\tif (a > 0) {\n\t\t\t\tp(a);\n\t\t\t\tq(a);\n\t\t\t}\n\t\t};').length);
	}

	/**
	 * The positive twin of `testAnnotatedNonVoidUnreachableTailNotFlagged`: WITHOUT an annotation
	 * the same body infers `Void` - a `throw`-only path does not make the return type a free
	 * monomorph (measured on Haxe 4.3.7) - so no throw guard stands between the arm and the fix.
	 */
	public function testUnannotatedThrowThenTailFlagged(): Void {
		Assert.equals(
			1,
			vSource('class C {\n\tfunction f(a:Int) {\n\t\tthrow \'no\';\n\t\tif (a > 0) {\n\t\t\tp(a);\n\t\t\tq(a);\n\t\t}\n\t}\n}\n')
				.length
		);
	}

	/**
	 * A type-parameter CONSTRAINT projects the same node kind in the same child slot as a return
	 * annotation, and `<T: Void>` is legal Haxe - so reading the child before the body as the
	 * annotation would PROVE Void on a function that returns `Int`. `CheckScan.returnAnnotationText`
	 * tells them apart by position relative to the parameter list, and the un-annotated inference
	 * branch then sees the `return 1` and refuses. The body compiles (the trailing `if` is
	 * unreachable), so this is a real shape, not a parse curiosity.
	 */
	public function testVoidConstrainedGenericNotFlagged(): Void {
		Assert.equals(0, vSource(constrainedGeneric('if (flag) return 1;\n\t\t')).length);
	}

	/**
	 * The control for `testVoidConstrainedGenericNotFlagged`: the SAME `<T:Void>` header with the
	 * value `return` dropped IS flagged. Every gate but the value-`return` scan therefore passes
	 * for that shape, which is what makes the sibling's zero attributable to the Void proof - and
	 * what a "child before the body" reading of the annotation would skip.
	 */
	public function testConstrainedGenericWithoutValueReturnFlagged(): Void {
		Assert.equals(1, vSource(constrainedGeneric('')).length);
	}

	/** The inner `if` is not a tail until the outer one de-nests, so the pair flattens over two `--fix` passes. */
	public function testNestedVoidTailsFlattenOverPasses(): Void {
		Assert.equals(
			canon(wrapVoid('if (a <= 0) return;\n\t\tp(a);\n\t\tif (b == null) return;\n\t\tq(a);\n\t\tr(a);')),
			fxVoid('if (a > 0) {\n\t\t\tp(a);\n\t\t\tif (b != null) {\n\t\t\t\tq(a);\n\t\t\t\tr(a);\n\t\t\t}\n\t\t}')
		);
	}

	/** A trailing `if` + `return` inside a `#if` branch inverts like any other, directives intact. */
	public function testConditionalBranchTrailingIfFlaggedAndFixed(): Void {
		final code: String =
			'#if debug\n\t\tif (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;\n\t\t#end\n\t\treturn true;';
		Assert.equals(1, v(code).length);
		Assert.equals(
			canon(wrap('#if debug\n\t\tif (!ok) return false;\n\t\tlog(a);\n\t\treturn true;\n\t\t#end\n\t\treturn true;')), fx(code)
		);
	}

	/** A SIBLING branch's local never refuses — the two configurations are mutually exclusive. */
	public function testSiblingBranchLocalDoesNotRefuse(): Void {
		final code: String = '#if x\n\t\tfinal n = pre();\n\t\treturn n > 0;\n\t\t#elseif y\n\t\tif (ok) {\n\t\t\tfinal n = other();'
			+ '\n\t\t\tlog(n);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;\n\t\t#end\n\t\treturn true;';
		Assert.equals(1, v(code).length);
		Assert.equals(
			canon(wrap(
				'#if x\n\t\tfinal n = pre();\n\t\treturn n > 0;\n\t\t#elseif y\n\t\tif (!ok) return false;\n\t\tfinal n = other();'
				+ '\n\t\tlog(n);\n\t\treturn true;\n\t\t#end\n\t\treturn true;'
			)),
			fx(code)
		);
	}

	/**
	 * A local in a DIFFERENT `#if` region of the same block IS visible to the collision gate:
	 * it is not a sibling of the flagged `if`, but under `-D x -D y` both regions are live and
	 * the de-nest would re-declare the name — and re-bind the `return n` that follows it.
	 */
	public function testOtherConditionalRegionLocalRefuses(): Void {
		Assert.equals(
			0,
			v(
				'#if x\n\t\tfinal n = pre();\n\t\t#end\n\t\t#if y\n\t\tif (ok) {\n\t\t\tfinal n = other();\n\t\t\tlog(n);'
				+ '\n\t\t\treturn true;\n\t\t}\n\t\treturn n > 1;\n\t\t#end\n\t\treturn true;'
			).length
		);
	}

	/** The enclosing function's parameters are part of the collision set (`ScopeFrames.ownParamNames`). */
	public function testParamCollisionNotFlagged(): Void {
		Assert.equals(0, v('if (ok) {\n\t\t\tfinal a = other();\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;').length);
	}

	/** The control for `testParamCollisionNotFlagged`: the same shape with a free name IS flagged. */
	public function testNonParamNameFlagged(): Void {
		Assert.equals(1, v('if (ok) {\n\t\t\tfinal z = other();\n\t\t\tlog(z);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;').length);
	}

	/** A `#if` branch still sees the enclosing function's parameters — it is not a scope boundary. */
	public function testParamCollisionInsideBranchNotFlagged(): Void {
		Assert.equals(
			0,
			v(
				'#if x\n\t\tif (ok) {\n\t\t\tfinal a = other();\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;'
				+ '\n\t\t#end\n\t\treturn true;'
			).length
		);
	}

	/** The member-path fixture the resolution tests share: `res.count > 0` wrapping a two-statement branch. */
	private inline function memberPathSource(): String {
		return 'class C {\n\tfunction f(res:Res):Bool {\n\t\tif (res.count > 0) {\n\t\t\tlog(res);\n\t\t\treturn true;\n\t\t}\n'
			+ '\t\treturn false;\n\t}\n}\n';
	}

	// --- helpers --------------------------------------------------------------------------

	private function wrap(bodyCode: String): String {
		return 'class C {\n\tfunction f(a:Int, b:Node):Bool {\n\t\t$bodyCode\n\t}\n}\n';
	}

	/** `wrap`'s `: Void` twin — the return type the implicit-tail arm's proof needs. */
	private function wrapVoid(bodyCode: String): String {
		return 'class C {\n\tfunction f(a:Int, b:Node):Void {\n\t\t$bodyCode\n\t}\n}\n';
	}

	/**
	 * A PARAMETERLESS `<T:Void>`-constrained method — the one header where the constraint occupies
	 * the child slot a return annotation would — with `head` prefixed to its body. Conditions are
	 * bare booleans so the negation is a clean `!flag`, licensed with no operand types.
	 */
	private function constrainedGeneric(head: String): String {
		return 'class C {\n\tvar flag:Bool;\n\tvar other:Bool;\n\n\tfunction m<T:Void>() {\n\t\t${head}throw \'no\';'
			+ '\n\t\tif (other) {\n\t\t\tp(1);\n\t\t\tq(1);\n\t\t}\n\t}\n}\n';
	}

	private function cond(c: String): String {
		return 'if ($c) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;';
	}

	private function v(bodyCode: String): Array<Violation> {
		return vSource(wrap(bodyCode));
	}

	/** The check's violations for a whole `source`, no wrapper. */
	private function vSource(source: String): Array<Violation> {
		return new GuardReturn().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	/** `v` through `wrapVoid` — a body whose enclosing function returns nothing. */
	private function vVoid(bodyCode: String): Array<Violation> {
		return vSource(wrapVoid(bodyCode));
	}

	private function edits(source: String): Array<{ span: Span, text: String }> {
		final check: GuardReturn = new GuardReturn();
		return check.fix(source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Canonicalise the body then invert to a fixpoint, exactly as the `lint --fix` CLI does. */
	private function fx(bodyCode: String): String {
		return fxSource(wrap(bodyCode));
	}

	/** `fx` through `wrapVoid`. */
	private function fxVoid(bodyCode: String): String {
		return fxSource(wrapVoid(bodyCode));
	}

	private function fxSource(source: String): String {
		var cur: String = canon(source);
		while (true) {
			final next: String = applyFixOnce(cur);
			if (next == cur) return cur;
			cur = next;
		}
	}

	/**
	 * The check's violations for `source` with `model` in a RESOLUTION SCOPE — `run` reads the
	 * operand types off the plugin host, not off the index `fix` receives, so a member-path
	 * fixture must declare the scope or the gate refuses it for want of types rather than for
	 * the reason under test.
	 */
	private function scopedViolations(source: String, model: String): Array<Violation> {
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: source }];
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({
			declared: true,
			sources: () -> {report: report, library: new LibrarySources([{ file: 'Res.hx', source: model }]) }
		});
		return new GuardReturn().run(report, scoped);
	}

	/**
	 * `source` fixed once with `model` in the resolution scope — the member-path arm of the
	 * operand-type probe needs a scope in `run` AND an index in `fix`.
	 */
	private function fixedWith(source: String, model: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: GuardReturn = new GuardReturn();
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: source }, { file: 'Res.hx', source: model }];
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final es: Array<{ span: Span, text: String }> = check.fix(source, scopedViolations(source, model), plugin, index);
		return switch RefactorSupport.canonicalize(source, es, false, plugin) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

	private function applyFixOnce(source: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: GuardReturn = new GuardReturn();
		final es: Array<{ span: Span, text: String }> = check.fix(source, check.run([{ file: 'C.hx', source: source }], plugin), plugin);
		return es.length == 0
			? source
			: switch RefactorSupport.canonicalize(source, es, false, plugin) {
				case Ok(text): text;
				case Err(message): throw message;
			};
	}

	private function canon(source: String): String {
		return switch RefactorSupport.canonicalize(source, [], true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
