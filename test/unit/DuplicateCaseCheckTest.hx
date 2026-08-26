package unit;

import anyparse.check.Check.Violation;
import anyparse.check.DuplicateCase;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `duplicate-case` check: a switch branch whose pattern repeats an earlier
 * branch in the same switch is flagged `Warning`. Distinct patterns, and guarded
 * branches with the same pattern but different guards, are not flagged.
 * `fix` deletes the later (dead) duplicate arm.
 */
class DuplicateCaseCheckTest extends Test {

	/** The trigger shape written INSIDE a `macro …` quotation, where the arms are AST the macro builds. */
	private static inline final QUOTED: String = 'class C {\n\tfunction f(k:Int):Void {\n\t\tfinal e = macro switch m {\n'
		+ '\t\t\tcase 1: a();\n\t\t\tcase 1: b();\n\t\t\tcase _: c();\n\t\t};\n\t}\n}\n';

	/** The same shape quoted AND then written as real code — exactly one of the two is a finding. */
	private static inline final QUOTED_THEN_RUNTIME: String = 'class C {\n\tfunction f(k:Int):Void {\n\t\tfinal e = macro switch m {\n'
		+ '\t\t\tcase 1: a();\n\t\t\tcase 1: b();\n\t\t\tcase _: c();\n\t\t};\n\t\tswitch k {\n\t\t\tcase 1: a();\n\t\t\tcase 1: b();\n'
		+ '\t\t\tcase _: c();\n\t\t}\n\t}\n}\n';

	/** Deleting a dead arm inside a REIFICATION subtree changes the `cases` array the macro emits. */
	public function testMacroQuotationNotFlagged(): Void {
		Assert.equals(0, linted(QUOTED).length);
	}

	/** …and the skip is the quotation's SUBTREE, not everything that follows it. */
	public function testSwitchAfterMacroQuotationStillFlagged(): Void {
		CheckFixture.assertOnlyAfterQuotation(linted(QUOTED_THEN_RUNTIME), QUOTED_THEN_RUNTIME, 'switch');
	}

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
				'class C {\n\tfunction f():Void {\n\t\tswitch k {\n\t\t\tcase 1: a();\n\t\t\tcase 2: b();\n\t\t\tcase _: c();\n\t\t}\n'
				+ '\t}\n}'
			).length
		);
	}

	public function testGuardedCasesNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tswitch k {\n\t\t\tcase x if (p): a();\n\t\t\tcase x if (q): b();\n'
				+ '\t\t\tcase _: c();\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testFixDeletesDeadArm(): Void {
		final out: String = applyFix(
			'class C {\n\tfunction f():Void {\n\t\tswitch k {\n\t\t\tcase 1: a();\n\t\t\tcase 1: b();\n\t\t}\n\t}\n}'
		);
		Assert.isTrue(out.indexOf('case 1: b()') == -1, 'dead arm should be gone, got: $out');
		Assert.isTrue(out.indexOf('case 1: a()') != -1, 'live arm should remain, got: $out');
	}

	public function testFixDeletesMidArmNoBlankLine(): Void {
		// The dead arm is NOT last; deleting it must not leave a blank line behind.
		final out: String = applyFix(
			'class C {\n\tfunction f():Void {\n\t\tswitch k {\n\t\t\tcase 1: a();\n\t\t\tcase 1: b();\n\t\t\tcase 2: c();\n\t\t}\n\t}\n}'
		);
		Assert.isTrue(out.indexOf('case 1: b()') == -1, 'dead arm gone, got: $out');
		Assert.isTrue(out.indexOf('case 2: c()') != -1, 'trailing arm remains, got: $out');
		Assert.isTrue(out.indexOf('\n\n') == -1, 'no blank line left behind, got: $out');
	}

	public function testFixDeletesAllDuplicates(): Void {
		final out: String = applyFix(
			'class C {\n\tfunction f():Void {\n\t\tswitch k {\n\t\t\tcase 1: a();\n\t\t\tcase 1: b();\n\t\t\tcase 1: d();\n'
			+ '\t\t\tcase 2: c();\n\t\t}\n\t}\n}'
		);
		Assert.isTrue(out.indexOf('b()') == -1 && out.indexOf('d()') == -1, 'both duplicates gone, got: $out');
		Assert.isTrue(out.indexOf('a()') != -1 && out.indexOf('c()') != -1, 'distinct arms remain, got: $out');
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('duplicate-case'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('duplicate-case'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new DuplicateCase(), src);
	}


	private function violations(src: String): Array<Violation> {
		return new DuplicateCase().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/**
	 * The same findings THROUGH THE LINTER — the altitude the central reification gate lives at
	 * (`Linter.run`), so a quoted finding is dropped here and not by the check itself.
	 */
	private function linted(src: String): Array<Violation> {
		return Linter.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin(), [new DuplicateCase()]);
	}

}
