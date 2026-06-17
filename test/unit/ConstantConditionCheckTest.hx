package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ConstantCondition;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `constant-condition` check: a boolean literal used as an `if` condition
 * (`if (true)` / `if (false)`, statement or expression form) is flagged
 * `Warning`. A non-literal condition and a loop condition (`while (true)`, an
 * idiomatic infinite loop) are not. `fix` replaces the `if` with the
 * always-taken branch; a no-else `if (false)` in expression position is the
 * lone report-only case.
 */
class ConstantConditionCheckTest extends Test {

	public function testIfTrueFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tif (true) g();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('constant-condition', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('condition is always true', vs[0].message);
	}

	public function testIfFalseFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tif (false) g();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('condition is always false', vs[0].message);
	}

	public function testIfExprFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Int {\n\t\treturn if (true) 1 else 2;\n\t}\n}').length);
	}

	public function testNonLiteralConditionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(x:Bool):Void {\n\t\tif (x) g();\n\t}\n}').length);
	}

	public function testWhileTrueNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\twhile (true) g();\n\t}\n}').length);
	}

	public function testFixIfTrueToThen(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (true) g();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg();\n\t}\n}', applyFix(src));
	}

	public function testFixIfFalseNoElseDeleted(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (false) g();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t}\n}', applyFix(src));
	}

	public function testFixIfTrueElseToThen(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (true) a(); else b();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\ta();\n\t}\n}', applyFix(src));
	}

	public function testFixIfFalseElseToElse(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (false) a(); else b();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tb();\n\t}\n}', applyFix(src));
	}

	public function testFixExprIfTrueToThen(): Void {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\treturn if (true) 1 else 2;\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}', applyFix(src));
	}

	public function testFixExprIfFalseNoElseSkipped(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar x = if (false) 1;\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixBlockBranchKeepsBraces(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (true) { var z = 1; g(z); }\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t{ var z = 1; g(z); }\n\t}\n}', applyFix(src));
	}

	public function testFixIfFalseAsBranchBodyToEmptyBlock(): Void {
		// A no-else `if (false)` that is the single-statement body of an enclosing
		// `if` must NOT be deleted (that would orphan the branch and capture the
		// following statement) — it is replaced with `{}` and `g();` stays put.
		final src: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) if (false) a();\n\t\tg();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) {}\n\t\tg();\n\t}\n}', applyFix(src));
	}

	public function testFixNestedKeepsOuterEdit(): Void {
		// Outer `if (true)` is rewritten to its then-branch (the inner `if`); the
		// contained inner edit is dropped and converges on a later `--fix` pass.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (true) if (false) a();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tif (false) a();\n\t}\n}', applyFix(src));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('constant-condition'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('constant-condition'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new ConstantCondition().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: ConstantCondition = new ConstantCondition();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
