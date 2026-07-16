package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferFind;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `prefer-find` check: a manual first-match `for` loop — Form A
 * `for (x in xs) if (cond) return x; return null;` and Form B
 * `var r = null; for (x in xs) if (cond) { r = x; break; }` — is flagged `Info`,
 * report-only, suggesting `xs.find(x -> cond)`. A non-null Form-A fallback appends
 * `?? <fallback>`; a transformed return, an `else`, a Form-B `continue` (last match,
 * not first), an extra Form-B statement, a key-value loop and a non-adjacent trailing
 * return are all safe misses.
 */
class PreferFindCheckTest extends Test {

	public function testBasicReturnFormFlagged(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return x;\n\t\treturn null;', 'Null<Int>'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-find', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('xs.find(x -> x > 2)') != -1);
	}

	public function testBracedReturnFormFlagged(): Void {
		Assert.equals(1, violations(fn('for (x in xs) if (x > 2) { return x; }\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testNonNullFallbackFlaggedWithCoalesce(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return x;\n\t\treturn 0;', 'Int'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('xs.find(x -> x > 2) ?? 0') != -1);
	}

	public function testBreakFormFlagged(): Void {
		final vs: Array<Violation> = violations(fn(
			'var r:Null<Int> = null;\n\t\tfor (x in xs) if (x > 2) { r = x; break; }\n\t\treturn r;', 'Null<Int>'
		));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-find', vs[0].rule);
		Assert.isTrue(vs[0].message.indexOf('xs.find(x -> x > 2)') != -1);
	}

	public function testBreakFormWithContinueNotFlagged(): Void {
		Assert.equals(
			0,
			violations(fn('var r:Null<Int> = null;\n\t\tfor (x in xs) if (x > 2) { r = x; continue; }\n\t\treturn r;', 'Null<Int>')).length
		);
	}

	public function testBreakFormExtraStatementNotFlagged(): Void {
		Assert.equals(
			0,
			violations(fn('var r:Null<Int> = null;\n\t\tfor (x in xs) if (x > 2) { r = x; trace(x); break; }\n\t\treturn r;', 'Null<Int>')).length
		);
	}

	public function testTransformedReturnNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return x + 1;\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return x; else return 0;\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testKeyValueLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (k => v in m) if (v > 2) return v;\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testRangeIndexLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (i in 0...xs.length) if (xs[i] > 2) return i;\n\t\treturn -1;', 'Int')).length);
	}

	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(
			0, violations(fn('for (x in xs) if (x > 2) return x;\n\t\tfinal n = xs.length;\n\t\treturn null;', 'Null<Int>')).length
		);
	}

	public function testMessageContainsConditionExcerpt(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return x;\n\t\treturn null;', 'Null<Int>'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('x > 2') != -1);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-find'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-find'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { for (x in xs) if (x > 2) return').length);
	}

	private function fn(body: String, ret: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, m:Map<String, Int>):' + ret + ' {\n\t\t' + body + '\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferFind().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

}
