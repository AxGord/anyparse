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
 * always-taken branch — but ONLY when the ELIMINATED (not-taken) branch is
 * trivial (empty, or a bare `;`); a non-trivial eliminated branch (a real
 * statement) is left report-only, with a human-review note appended to the
 * message. A no-else `if (false)` in expression position stays report-only
 * regardless (its value slot cannot be emptied).
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
		// No else: the eliminated then-branch `h();` is a real statement, so
		// the message carries the non-trivial human-review note.
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tif (false) h();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('condition is always false (dead branch - verify intent before deleting)', vs[0].message);
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
		// No else at all: nothing is eliminated, so this stays trivially fixable.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (true) g();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg();\n\t}\n}', applyFix(src));
	}

	public function testFixIfFalseNoElseTrivialBodyDeleted(): Void {
		// The eliminated then-branch is a bare `;` — trivial, so the whole
		// statement is still deleted automatically.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (false) ;\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t}\n}', applyFix(src));
	}

	public function testFixIfFalseNoElseNonTrivialBodyLeftUntouched(): Void {
		// The eliminated then-branch `h();` is a real statement: the site is
		// still reported (see testIfFalseFlagged) but collects no edit.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (false) h();\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixIfTrueElseNonTrivialLeftUntouched(): Void {
		// The eliminated else-branch `b();` is a real statement.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (true) a(); else b();\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixIfTrueTrivialElseToThen(): Void {
		// The eliminated else-branch is an empty block — trivial, so the
		// autofix still collapses to the taken then-branch.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (true) a(); else {}\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\ta();\n\t}\n}', applyFix(src));
	}

	public function testFixIfFalseElseNonTrivialLeftUntouched(): Void {
		// The eliminated then-branch `a();` is a real statement.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (false) a(); else b();\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixIfFalseTrivialThenElseToElse(): Void {
		// The eliminated then-branch is an empty block — trivial, so the
		// autofix still collapses to the taken else-branch.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (false) {} else b();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tb();\n\t}\n}', applyFix(src));
	}

	public function testFixExprIfTrueNonTrivialLeftUntouched(): Void {
		// The eliminated else-value `2` is a real (non-empty) expression.
		final src: String = 'class C {\n\tfunction f():Int {\n\t\treturn if (true) 1 else 2;\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixExprIfFalseNoElseSkipped(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar x = if (false) 1;\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixBlockBranchKeepsBraces(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (true) { var z = 1; g(z); }\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t{ var z = 1; g(z); }\n\t}\n}', applyFix(src));
	}

	public function testFixIfFalseAsBranchBodyNonTrivialLeftUntouched(): Void {
		// The eliminated then-branch `a();` is a real statement, so the outer
		// no-else `if (false)` branch body is left as-is.
		final src: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) if (false) a();\n\t\tg();\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixIfFalseTrivialAsBranchBodyToEmptyBlock(): Void {
		// A no-else `if (false)` whose eliminated then-branch is a bare `;`
		// (trivial) that is itself the single-statement body of an enclosing
		// `if` must NOT be deleted (that would orphan the branch and capture
		// the following statement) — it is replaced with `{}` and `g();` stays put.
		final src: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) if (false) ;\n\t\tg();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) {}\n\t\tg();\n\t}\n}', applyFix(src));
	}

	public function testFixNestedKeepsOuterEdit(): Void {
		// Outer `if (true)` is rewritten to its then-branch (the inner `if`); the
		// contained inner edit is dropped and converges on a later `--fix` pass.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (true) if (false) a();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tif (false) a();\n\t}\n}', applyFix(src));
	}

	public function testFixMixedTrivialAndNonTrivialSites(): Void {
		// Two sites in one file: `if (true) g();` eliminates nothing (trivial,
		// auto-fixed); `if (false) h();` eliminates the real statement `h();`
		// (non-trivial, left untouched) — the fix-count must reflect exactly
		// the one edit actually produced, not the two violations reported.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (true) g();\n\t\tif (false) h();\n\t}\n}';
		final check: ConstantCondition = new ConstantCondition();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(2, vs.length);
		Assert.equals('condition is always true', vs[0].message);
		Assert.equals('condition is always false (dead branch - verify intent before deleting)', vs[1].message);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(1, edits.length);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg();\n\t\tif (false) h();\n\t}\n}', out);
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
