package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DuplicateCase;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `duplicate-case` check: a switch branch whose pattern repeats an earlier
 * branch in the same switch is flagged `Warning`. Distinct patterns, and guarded
 * branches with the same pattern but different guards, are not flagged.
 * Report-only — `fix` yields no edits.
 */
class DuplicateCaseCheckTest extends Test {

	public function testDuplicateLiteralCaseFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f():Void {\n\t\tswitch k {\n\t\t\tcase 1: a();\n\t\t\tcase 1: b();\n\t\t\tcase _: c();\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('duplicate-case', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('duplicate case label', vs[0].message);
	}

	public function testDistinctCasesNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tswitch k {\n\t\t\tcase 1: a();\n\t\t\tcase 2: b();\n\t\t\tcase _: c();\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testGuardedCasesNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tswitch k {\n\t\t\tcase x if (p): a();\n\t\t\tcase x if (q): b();\n\t\t\tcase _: c();\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tswitch k {\n\t\t\tcase 1: a();\n\t\t\tcase 1: b();\n\t\t}\n\t}\n}';
		final check: DuplicateCase = new DuplicateCase();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('duplicate-case'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('duplicate-case'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new DuplicateCase().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
