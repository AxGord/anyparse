package unit.check.common.members;

import anyparse.check.Severity;
import anyparse.check.common.members.RedundantMetaParens;

/**
 * The `redundant-meta-parens` check: metadata written with an empty argument list is the same
 * entry as the bare tag, so the `()` is flagged `Info` and deleted. Every metadata position is
 * covered; a comment between the parentheses and a `(` right after them keep the tag as written.
 */
class RedundantMetaParensCheckTest extends Test {

	public function testTypeMeta(): Void {
		final source: String = '@:forward() abstract Table(CTable) {}';
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('redundant-meta-parens', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('()', source.substring(vs[0].span.from, vs[0].span.to));
		Assert.equals('redundant parentheses on @:forward: an empty argument list is the same metadata as none', vs[0].message);
		Assert.equals('@:forward abstract Table(CTable) {}', applyFix(source));
	}

	public function testFieldMeta(): Void {
		Assert.equals('class C {\n\t@:keep var a: Int;\n}', applyFix('class C {\n\t@:keep() var a: Int;\n}'));
	}

	public function testFunctionMetaUserTag(): Void {
		Assert.equals('class C {\n\t@meta function f() {}\n}', applyFix('class C {\n\t@meta() function f() {}\n}'));
	}

	public function testLocalMeta(): Void {
		final source: String = 'class C {\n\tfunction f() {\n\t\t@:keep() var x = 1;\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.equals('class C {\n\tfunction f() {\n\t\t@:keep var x = 1;\n\t}\n}', applyFix(source));
	}

	public function testExpressionMeta(): Void {
		final source: String = 'class C {\n\tfunction f() {\n\t\tvar y = @:keep() 2;\n\t\treturn @foo() y;\n\t}\n}';
		Assert.equals(2, violations(source).length);
		Assert.equals('class C {\n\tfunction f() {\n\t\tvar y = @:keep 2;\n\t\treturn @foo y;\n\t}\n}', applyFix(source));
	}

	public function testEnumConstructorMeta(): Void {
		Assert.equals('enum E {\n\t@:keep A;\n\tB;\n}', applyFix('enum E {\n\t@:keep() A;\n\tB;\n}'));
	}

	public function testWhitespaceInsideParens(): Void {
		Assert.equals('@:keep class C {}', applyFix('@:keep( ) class C {}'));
		Assert.equals('@:keep class C {}', applyFix('@:keep(\n) class C {}'));
	}

	public function testOnlyTheEmptyOneOfStackedMetas(): Void {
		Assert.equals(1, violations('@:keep() @:native("x") @:final class C {}').length);
		Assert.equals('@:keep @:native("x") @:final class C {}', applyFix('@:keep() @:native("x") @:final class C {}'));
	}

	public function testBareMetaNotFlagged(): Void {
		Assert.equals(0, violations('@:forward abstract A(Int) {}').length);
	}

	public function testMetaWithArgumentsNotFlagged(): Void {
		Assert.equals(0, violations('@:native("x") class C {}').length);
	}

	public function testCommentInsideParensNotFlagged(): Void {
		Assert.equals(0, violations('@:keep(/* why */) class C {}').length);
	}

	public function testParenDirectlyAfterNotFlagged(): Void {
		// Deleting the pair would hand `(1)` to the metadata as its argument list.
		Assert.equals(0, violations('class C {\n\tfunction f() return @:keep()(1);\n}').length);
	}

	public function testRegisteredInBuiltins(): Void {
		CheckFixture.assertRegistered('redundant-meta-parens');
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(').length);
	}

	private function violations(source: String): Array<Violation> {
		return CheckFixture.violations(new RedundantMetaParens(), source);
	}

	private function applyFix(source: String): String {
		return CheckFixture.fixedSource(new RedundantMetaParens(), source);
	}

}
