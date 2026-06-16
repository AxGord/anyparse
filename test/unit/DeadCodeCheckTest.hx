package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DeadCode;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `dead-code` check: a statement after an unconditional `return` / `throw`
 * / `break` / `continue` in the same block is flagged `Warning`; reachable code
 * is not. A terminal nested inside an `if` body does not make its following
 * siblings unreachable. `fix` deletes the whole dead run.
 */
class DeadCodeCheckTest extends Test {

	public function testCodeAfterReturnFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t\ttrace("x");\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('dead-code', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('unreachable code', vs[0].message);
	}

	public function testCodeAfterThrowFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tthrow "e";\n\t\ttrace("x");\n\t}\n}').length);
	}

	public function testCodeAfterBreakFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tfunction f():Void {\n\t\twhile (a) {\n\t\t\tbreak;\n\t\t\ttrace("x");\n\t\t}\n\t}\n}').length
		);
	}

	public function testCodeAfterContinueFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tfunction f():Void {\n\t\twhile (a) {\n\t\t\tcontinue;\n\t\t\ttrace("x");\n\t\t}\n\t}\n}').length
		);
	}

	public function testReturnAtEndNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int { return 1; }\n}').length);
	}

	public function testConditionalReturnNotFlagged(): Void {
		// The `return` is nested inside the `if`, not a direct sibling — code after is reachable.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) return;\n\t\ttrace("x");\n\t}\n}').length);
	}

	public function testMultiStatementDeadRunFlaggedOnce(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\treturn;\n\t\ta();\n\t\tb();\n\t\tc();\n\t}\n}').length);
	}

	public function testNestedBlockReached(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\t{\n\t\t\treturn;\n\t\t\tdead();\n\t\t}\n\t}\n}').length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testFixDeletesDeadRun(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\treturn;\n\t\ta();\n\t\tb();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\treturn;\n\t}\n}', applyFix(src));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('dead-code'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('dead-code'));
	}

	private function violations(src: String): Array<Violation> {
		return new DeadCode().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: DeadCode = new DeadCode();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	public function testFixNestedDeadRunDeletesOuter(): Void {
		// An outer dead run contains a nested block with its own dead run; the outer
		// deletion subsumes the inner one — `fix` returns a single non-overlapping
		// edit and the whole outer run (incl. the nested block) is removed.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\treturn;\n\t\twhile (true) {\n\t\t\tbreak;\n\t\t\tinner();\n\t\t}\n\t\touter();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\treturn;\n\t}\n}', applyFix(src));
	}

}
