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

/**
 * The `guard-return` check: a block whose LAST TWO statements are a bare
 * `if (cond) { BLOCK }` (no `else`, `BLOCK` terminal and holding at least two
 * statements) and a lone trailing `return TAIL;` is flagged `Info` and inverted into
 * an early-return guard — `if (!cond) return TAIL; <BLOCK de-nested>`. The inversion
 * runs through the shared `CheckScan.negateConditionText`, so `==` / `!=` flip
 * (NaN-safe), `!e` strips, `a && b` De Morgans to `!a || !b`, and an ordered
 * comparison stays wrapped `!(a < b)`. Gates: a ONE-statement then-branch is
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
		final expected: String = 'class C {\n\tfunction f(a:Int):Void {\n\t\tif (!(a > 0)) return;\n\t\tlog(a);\n\t\treturn;\n\t}\n}\n';
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

	public function testLessThanWrappedNotFlipped(): Void {
		Assert.isTrue(fx(cond('x < 10')).indexOf('if (!(x < 10)) return false;') != -1);
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

	public function testStrandedNarrowingFallsBackToVerbatimWrap(): Void {
		// `b`'s narrowing comes from operand 2 and would not reach operand 3 of the
		// negated `||` chain, so the whole condition is wrapped instead.
		final fixed: String = fx(cond('a != null && b != null && p(a.length, b.length)'));
		Assert.isTrue(fixed.indexOf('if (!(a != null && b != null && p(a.length, b.length))) return false;') != -1);
	}

	public function testStrandedNarrowingMultiLineConditionNotFlagged(): Void {
		// The verbatim wrap of an ALREADY multi-line condition reads worse than the
		// branch it would replace, so the site is left alone.
		Assert.equals(0, v(cond('a != null\n\t\t\t&& b != null\n\t\t\t&& p(a.length, b.length)')).length);
	}

	public function testDeMorganedMultiLineConditionStillFlagged(): Void {
		// The same multi-line shape WITHOUT a stranded narrowing keeps its de-nest.
		Assert.equals(1, v(cond('a != null\n\t\t\t&& b != null\n\t\t\t&& c != null')).length);
	}

	public function testParenNestedStrandedNarrowingFallsBackToVerbatimWrap(): Void {
		// The negation DROPS the parens, so the emitted chain is the same flat three-operand
		// `||` as the unparenthesised shape — the gate must see through the parens too.
		final fixed: String = fx(cond('a != null && (b != null && p(a.length, b.length))'));
		Assert.isTrue(fixed.indexOf('if (!(a != null && (b != null && p(a.length, b.length)))) return false;') != -1);
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
		// The region folds the `if` into a `Conditional` statement, so the block's
		// second-to-last slot is not an `if` at all.
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
		Assert.equals(112, Linter.builtins().length);
	}

	// --- helpers --------------------------------------------------------------------------

	private function wrap(bodyCode: String): String {
		return 'class C {\n\tfunction f(a:Int, b:Node):Bool {\n\t\t$bodyCode\n\t}\n}\n';
	}

	private function cond(c: String): String {
		return 'if ($c) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;';
	}

	private function v(bodyCode: String): Array<Violation> {
		return new GuardReturn().run([{ file: 'C.hx', source: wrap(bodyCode) }], new HaxeQueryPlugin());
	}

	private function edits(source: String): Array<{ span: Span, text: String }> {
		final check: GuardReturn = new GuardReturn();
		return check.fix(source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Canonicalise the body then invert to a fixpoint, exactly as the `lint --fix` CLI does. */
	private function fx(bodyCode: String): String {
		return fxSource(wrap(bodyCode));
	}

	private function fxSource(source: String): String {
		var cur: String = canon(source);
		while (true) {
			final next: String = applyFixOnce(cur);
			if (next == cur) return cur;
			cur = next;
		}
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
