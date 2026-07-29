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
 * exists — but ONLY when the ELIMINATED branch is trivial (empty, or a
 * bare `;`); a non-trivial eliminated branch (real code) is left
 * report-only, with a human-review note appended to the message.
 * `#elseif` chains are always report-only.
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

	public function testFixDeletesTrivialElselessRegion(): Void {
		// The dead body is a bare `;` — trivial, so the whole region still
		// auto-deletes.
		final out: String = applyFix('class C {\n\tfunction f() {\n\t\ta();\n\t\t#if false\n\t\t;\n\t\t#end\n\t\tb();\n\t}\n}');
		Assert.isTrue(out.indexOf('#if') == -1, 'markers removed, got: <$out>');
		Assert.isTrue(out.indexOf('a();') != -1 && out.indexOf('b();') != -1, 'live code kept, got: <$out>');
	}

	public function testFixDeletesTrivialEmptyBlockElselessRegion(): Void {
		// The dead body is an empty block `{}` — the other trivial form
		// besides a bare `;` — so the whole region still auto-deletes.
		final out: String = applyFix('class C {\n\tfunction f() {\n\t\ta();\n\t\t#if false\n\t\t{}\n\t\t#end\n\t\tb();\n\t}\n}');
		Assert.isTrue(out.indexOf('#if') == -1, 'markers removed, got: <$out>');
		Assert.isTrue(out.indexOf('a();') != -1 && out.indexOf('b();') != -1, 'live code kept, got: <$out>');
	}

	public function testFixElselessRegionNonTrivialLeftUntouched(): Void {
		// The dead body `dead();` is a real statement: the site is still
		// reported (see testStmtRegionFlagged) but collects no edit.
		final src: String = 'class C {\n\tfunction f() {\n\t\ta();\n\t\t#if false\n\t\tdead();\n\t\t#end\n\t\tb();\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixTrivialThenKeepsElseBranch(): Void {
		// The eliminated `#if false` body is a bare `;` — trivial, so the
		// autofix still replaces the whole region with the `#else` branch.
		final out: String = applyFix('class C {\n\tfunction f() {\n\t\t#if false\n\t\t;\n\t\t#else\n\t\ty();\n\t\t#end\n\t}\n}');
		Assert.isTrue(out.indexOf('y();') != -1, 'else branch kept, got: <$out>');
		Assert.isTrue(out.indexOf('#else') == -1 && out.indexOf('#if') == -1, 'markers removed, got: <$out>');
	}

	public function testFixKeepsElseBranchNonTrivialLeftUntouched(): Void {
		// The eliminated `#if false` body `x();` is a real statement.
		final src: String = 'class C {\n\tfunction f() {\n\t\t#if false\n\t\tx();\n\t\t#else\n\t\ty();\n\t\t#end\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixExprElseNonTrivialLeftUntouched(): Void {
		// The eliminated value `1` is real (non-empty) content.
		final src: String = 'class C {\n\tvar v = #if false 1 #else 2 #end;\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testElseifChainReportOnly(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t#if false\n\t\tx();\n\t\t#elseif mobile\n\t\ty();\n\t\t#end\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		// Report-only for an unrelated reason (semantic rewrite), so the
		// message stays the base text — no human-review note appended.
		Assert.isFalse(vs[0].message.indexOf('dead branch - verify intent before deleting') != -1);
		Assert.equals(src, applyFix(src));
	}

	public function testNestedIfInsideDeadRegionSingleFlag(): Void {
		// The nested `#if mobile` lives inside the dead region — one flag
		// for the OUTER region only. Its body holds the real statement
		// `m();`, so it is non-trivial and left untouched by `fix`.
		final src: String = 'class C {\n\tfunction f() {\n\t\t#if false\n\t\t#if mobile\n\t\tm();\n\t\t#end\n\t\t#end\n\t\tb();\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	public function testFixMixedTrivialAndNonTrivialSites(): Void {
		// Two regions in one file: an elseless region whose body is a bare
		// `;` (trivial) auto-deletes; one whose body is the real statement
		// `c();` (non-trivial) is reported but left untouched — the
		// fix-count must reflect exactly the one edit actually produced,
		// not the two violations reported.
		final src: String =
			'class C {\n\tfunction f() {\n\t\ta();\n\t\t#if false\n\t\t;\n\t\t#end\n\t\tb();\n\t\t#if false\n\t\tc();\n\t\t#end\n\t\td();\n\t}\n}';
		final check: IfFalseDeadCode = new IfFalseDeadCode();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(2, vs.length);
		Assert.isFalse(vs[0].message.indexOf('dead branch - verify intent before deleting') != -1);
		Assert.isTrue(vs[1].message.indexOf('dead branch - verify intent before deleting') != -1);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(1, edits.length);
		final out: String = applyEdits(src, edits);
		// Not `'#if false'` — a standalone string literal spelling it out would
		// itself trip this very check when linting this test file.
		Assert.isTrue(out.indexOf('c();') != -1 && out.indexOf('#if') != -1, 'non-trivial region kept, got: <$out>');
		Assert.isTrue(out.indexOf('a();') != -1 && out.indexOf('b();') != -1 && out.indexOf('d();') != -1, 'live code kept, got: <$out>');
	}

	private function violations(src: String): Array<Violation> {
		return new IfFalseDeadCode().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: IfFalseDeadCode = new IfFalseDeadCode();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return applyEdits(src, edits);
	}

	private function applyEdits(src: String, edits: Array<{ span: Span, text: String }>): String {
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
