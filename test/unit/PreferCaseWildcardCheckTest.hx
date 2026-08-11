package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferCaseWildcard;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `prefer-case-wildcard` check: a `default:` switch branch is flagged `Info`
 * and rewritten to `case _:` — the `default` keyword token swapped for `case _`,
 * the trailing `:` and body left intact. A branch already written `case _:` and
 * a switch with no default are safe misses. Works in statement and
 * expression-position switches and reaches nested switches.
 */
class PreferCaseWildcardCheckTest extends Test {

	/** The trigger shape written INSIDE a `macro …` quotation, where it is AST the macro builds. */
	private static inline final QUOTED: String =
		'class C {\n\tfunction f(k:Int):Void {\n\t\tfinal e = macro switch m {\n\t\t\tcase 1: a();\n\t\t\tdefault: b();\n\t\t};\n\t}\n}\n';

	/** The same shape quoted AND then written as real code — exactly one of the two is a finding. */
	private static inline final QUOTED_THEN_RUNTIME: String = 'class C {\n\tfunction f(k:Int):Void {\n\t\tfinal e = macro switch m {\n'
		+ '\t\t\tcase 1: a();\n\t\t\tdefault: b();\n\t\t};\n\t\tswitch k {\n\t\t\tcase 1: a();\n\t\t\tdefault: b();\n\t\t}\n\t}\n}\n';

	/** A `default:` inside a REIFICATION subtree is DATA: it reifies as `ESwitch.edef`, where `case _:` becomes another entry of `cases`. */
	public function testMacroQuotationNotFlagged(): Void {
		Assert.equals(0, linted(QUOTED).length);
	}

	/** …and the skip is the quotation's SUBTREE, not everything that follows it. */
	public function testSwitchAfterMacroQuotationStillFlagged(): Void {
		CheckFixture.assertOnlyAfterQuotation(linted(QUOTED_THEN_RUNTIME), QUOTED_THEN_RUNTIME, 'switch');
	}

	public function testDefaultFlagged(): Void {
		final source: String = stmtSwitch('default: b();');
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-case-wildcard', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('use case _: instead of default:', vs[0].message);
		Assert.equals('default', source.substring(vs[0].span.from, vs[0].span.to));
	}

	public function testDefaultFixed(): Void {
		Assert.equals(stmtSwitch('case _: b();'), applyFix(stmtSwitch('default: b();')));
	}

	public function testCaseWildcardNotFlagged(): Void {
		Assert.equals(0, violations(stmtSwitch('case _: b();')).length);
	}

	public function testSwitchWithoutDefaultNotFlagged(): Void {
		Assert.equals(0, violations(stmtSwitch('case 2: b();')).length);
	}

	public function testExpressionPositionSwitchFlagged(): Void {
		final source: String =
			'class C {\n\tfunction f(x:Int):String {\n\t\treturn switch x {\n\t\t\tcase 1: "a";\n\t\t\tdefault: "b";\n\t\t};\n\t}\n}';
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-case-wildcard', vs[0].rule);
		Assert.isTrue(applyFix(source).indexOf('case _: "b";') != -1);
	}

	public function testMultiStatementBodyFixed(): Void {
		final fixed: String = applyFix(stmtSwitch('default: a(); b();'));
		Assert.isTrue(fixed.indexOf('case _: a(); b();') != -1);
		Assert.equals(-1, fixed.indexOf('default'));
	}

	public function testNestedSwitchFlagged(): Void {
		final source: String = 'class C {\n\tfunction f(x:Int, y:Int):Void {\n\t\tswitch x {\n\t\t\tcase 1: switch y {\n'
			+ '\t\t\t\tcase 2: a();\n\t\t\t\tdefault: b();\n\t\t\t}\n\t\t\tdefault: c();\n\t\t}\n\t}\n}';
		final vs: Array<Violation> = violations(source);
		Assert.equals(2, vs.length);
		Assert.equals(-1, applyFix(source).indexOf('default'));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-case-wildcard'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-case-wildcard'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { switch (').length);
	}

	private function stmtSwitch(lastBranch: String): String {
		return 'class C {\n\tfunction f(x:Int):Void {\n\t\tswitch x {\n\t\t\tcase 1: a();\n\t\t\t$lastBranch\n\t\t}\n\t}\n}';
	}


	private function violations(source: String): Array<Violation> {
		return new PreferCaseWildcard().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	/**
	 * The same findings THROUGH THE LINTER — the altitude the central reification gate lives at
	 * (`Linter.run`), so a quoted finding is dropped here and not by the check itself.
	 */
	private function linted(src: String): Array<Violation> {
		return Linter.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin(), [new PreferCaseWildcard()]);
	}

	private function applyFix(source: String): String {
		return CheckFixture.fixedSource(new PreferCaseWildcard(), source);
	}

}
