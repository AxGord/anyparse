package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.LoopGuard;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `loop-guard` check: a `for` / `while` whose braced body opens with a bare
 * `if (c) continue;` guard is flagged `Info` and the guard is lifted into the loop
 * header with an inverted condition (`for (x in xs) if (INV) { REST }`). The inversion
 * strips a `!`, flips `==` / `!=` (NaN-safe), wraps everything else in `!(...)`, and
 * leaves ordered comparisons unflipped. A cascade of guards, a guard-only body, an
 * unbraced body, an `else` branch and a comment inside the guard are safe misses; a
 * later `continue` deeper in the body is preserved.
 */
class LoopGuardCheckTest extends Test {

	public function testForGuardFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('for (x in xs) {\n\t\t\tif (x == 0) continue;\n\t\t\ttrace(x);\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('loop-guard', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this leading if-continue guard can move to the loop header (for/while … if)', vs[0].message);
	}

	public function testEqFlipFixed(): Void {
		Assert.equals(
			wrap('for (x in xs) if (x != 0) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (x == 0) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testNotEqFlipFixed(): Void {
		Assert.equals(
			wrap('for (x in xs) if (x == 0) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (x != 0) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testNotStripFixed(): Void {
		Assert.equals(
			wrap('for (x in xs) if (done) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (!done) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testNotStripUnwrapsParen(): Void {
		Assert.equals(
			wrap('for (x in xs) if (a && b) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (!(a && b)) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testLessThanWrappedNotFlipped(): Void {
		Assert.equals(
			wrap('for (x in xs) if (!(x < 10)) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (x < 10) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testComplexCondWrapped(): Void {
		Assert.equals(
			wrap('for (x in xs) if (!(a && b)) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (a && b) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testAtomicIdentNoParens(): Void {
		Assert.equals(
			wrap('for (x in xs) if (!skip) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (skip) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testAtomicCallNoParens(): Void {
		Assert.equals(
			wrap('for (x in xs) if (!skip()) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (skip()) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testBracedSingleContinueFlaggedAndFixed(): Void {
		Assert.equals(1, violations(wrap('for (x in xs) {\n\t\t\tif (x == 0) { continue; }\n\t\t\ttrace(x);\n\t\t}')).length);
		Assert.equals(
			wrap('for (x in xs) if (x != 0) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (x == 0) { continue; }\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testWhileLoopFlaggedAndFixed(): Void {
		final src: String = wrap('while (xs.length > 0) {\n\t\t\tif (xs.length == 3) continue;\n\t\t\ttrace(xs);\n\t\t}');
		Assert.equals(1, violations(src).length);
		Assert.equals(wrap('while (xs.length > 0) if (xs.length != 3) {\n\t\t\ttrace(xs);\n\t\t}'), applyFix(src));
	}

	public function testCascadeNotFlagged(): Void {
		Assert.equals(
			0, violations(wrap('for (x in xs) {\n\t\t\tif (x == 0) continue;\n\t\t\tif (x == 1) continue;\n\t\t\ttrace(x);\n\t\t}')).length
		);
	}

	public function testLaterContinueStillFlaggedAndPreserved(): Void {
		final src: String = wrap(
			'for (x in xs) {\n\t\t\tif (x == 0) continue;\n\t\t\ttrace(x);\n\t\t\tif (x == 5) continue;\n\t\t\ttrace(x + 1);\n\t\t}'
		);
		Assert.equals(1, violations(src).length);
		Assert.equals(
			wrap('for (x in xs) if (x != 0) {\n\t\t\ttrace(x);\n\t\t\tif (x == 5) continue;\n\t\t\ttrace(x + 1);\n\t\t}'), applyFix(src)
		);
	}

	public function testGuardOnlyBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) {\n\t\t\tif (x == 0) continue;\n\t\t}')).length);
	}

	public function testBareUnbracedBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) if (x == 0) continue;')).length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) {\n\t\t\tif (x == 0) continue; else trace(x);\n\t\t\ttrace(x);\n\t\t}')).length);
	}

	public function testCommentInsideGuardNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) {\n\t\t\tif (x == 0) /* skip */ continue;\n\t\t\ttrace(x);\n\t\t}')).length);
	}

	public function testCommentBeforeGuardNotFlagged(): Void {
		Assert.equals(
			0, violations(wrap('for (x in xs) {\n\t\t\t// explain the guard\n\t\t\tif (x == 0) continue;\n\t\t\ttrace(x);\n\t\t}')).length
		);
	}

	public function testApplyFixByteExact(): Void {
		final input: String = 'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\tfor (x in xs) {\n\t\t\tif (x == 0) continue;\n\t\t\ttrace(x);\n\t\t}\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\tfor (x in xs) if (x != 0) {\n\t\t\ttrace(x);\n\t\t}\n\t}\n}';
		Assert.equals(expected, applyFix(input));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('loop-guard'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('loop-guard'));
		Assert.equals(84, Linter.builtins().length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { for (x in xs) { if (x) continue;').length);
	}

	private function wrap(loopCode: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\t' + loopCode + '\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new LoopGuard().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		final check: LoopGuard = new LoopGuard();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = source;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
