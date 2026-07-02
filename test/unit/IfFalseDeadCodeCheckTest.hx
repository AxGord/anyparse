package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.IfFalseDeadCode;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `if-false` check: every `#if false … #end` conditional region —
 * dead on all compilation targets — is flagged `Warning` at any scope
 * (member run, statement, case group, expression, list element). `fix`
 * deletes the region, or replaces it with the `#else` branch when one
 * exists; `#elseif` chains are report-only.
 */
class IfFalseDeadCodeCheckTest extends Test {

	public function testStmtRegionFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f() {\n\t\t#if false\n\t\tdead();\n\t\t#end\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('if-false', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testMemberRegionFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t#if false\n\tfunction dead():Void {}\n\t#end\n}').length);
	}

	public function testCaseGroupFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f() {\n\t\tswitch v {\n\t\t\tcase 1: a();\n\t\t#if false\n\t\t\tcase 2: b();\n\t\t#end\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testExprRegionFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tvar x = #if false 1 #else 2 #end;\n}').length);
	}

	public function testParensFormFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f() {\n\t\t#if (false)\n\t\tdead();\n\t\t#end\n\t}\n}').length);
	}

	public function testRealFlagNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\t#if mobile\n\t\tlive();\n\t\t#end\n\t}\n}').length);
	}

	public function testFalsePrefixedFlagNotFlagged(): Void {
		// `falsePositive` starts with the word `false` — the word-boundary
		// check must not flag it.
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\t#if falsePositive\n\t\tlive();\n\t\t#end\n\t}\n}').length);
	}

	public function testFixDeletesElselessRegion(): Void {
		final out: String = applyFix('class C {\n\tfunction f() {\n\t\ta();\n\t\t#if false\n\t\tdead();\n\t\t#end\n\t\tb();\n\t}\n}');
		Assert.isTrue(out.indexOf('dead()') == -1, 'dead body removed, got: <$out>');
		Assert.isTrue(out.indexOf('#if') == -1, 'markers removed, got: <$out>');
		Assert.isTrue(out.indexOf('a();') != -1 && out.indexOf('b();') != -1, 'live code kept, got: <$out>');
	}

	public function testFixKeepsElseBranch(): Void {
		final out: String = applyFix('class C {\n\tfunction f() {\n\t\t#if false\n\t\tx();\n\t\t#else\n\t\ty();\n\t\t#end\n\t}\n}');
		Assert.isTrue(out.indexOf('x()') == -1, 'dead branch removed, got: <$out>');
		Assert.isTrue(out.indexOf('y();') != -1, 'else branch kept, got: <$out>');
		Assert.isTrue(out.indexOf('#else') == -1, 'markers removed, got: <$out>');
	}

	public function testFixExprElse(): Void {
		final out: String = applyFix('class C {\n\tvar v = #if false 1 #else 2 #end;\n}');
		Assert.isTrue(out.indexOf('var v = 2;') != -1, 'else value kept inline, got: <$out>');
	}

	public function testElseifChainReportOnly(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t#if false\n\t\tx();\n\t\t#elseif mobile\n\t\ty();\n\t\t#end\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	public function testNestedIfInsideDeadRegionSingleFlag(): Void {
		// The nested `#if mobile` lives inside the dead region — one flag
		// for the OUTER region only, and the elseless delete removes the
		// nested markers with it.
		final src: String = 'class C {\n\tfunction f() {\n\t\t#if false\n\t\t#if mobile\n\t\tm();\n\t\t#end\n\t\t#end\n\t\tb();\n\t}\n}';
		Assert.equals(1, violations(src).length);
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('m()') == -1 && out.indexOf('#if') == -1, 'whole region removed, got: <$out>');
	}

	private function violations(src: String): Array<Violation> {
		return new IfFalseDeadCode().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: IfFalseDeadCode = new IfFalseDeadCode();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
