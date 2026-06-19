package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ExplicitType;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `explicit-type` check: a member field with no `:Type`, a function parameter
 * with no `:Type`, or a function with no return type is flagged `Warning`. A
 * constructor (`new`) is exempt from the return-type rule, and enum-abstract values
 * are exempt from the field rule; interface members are checked like any other.
 */
class ExplicitTypeCheckTest extends Test {

	public function testTypedFieldNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var a:Int; }').length);
	}

	public function testUntypedFieldWithInitFlagged(): Void {
		final vs: Array<Violation> = violations('class C { public var a = 0; }');
		Assert.equals(1, vs.length);
		Assert.equals('explicit-type', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testUntypedFieldNoInitFlagged(): Void {
		Assert.equals(1, violations('class C { public var b; }').length);
	}

	public function testTypedParamsAndReturnNotFlagged(): Void {
		Assert.equals(0, violations('class C { public function f(a:Int, b:String):Void {} }').length);
	}

	public function testUntypedParamFlagged(): Void {
		Assert.equals(1, violations('class C { public function f(a):Void {} }').length);
	}

	public function testMissingReturnTypeFlagged(): Void {
		Assert.equals(1, violations('class C { public function f() {} }').length);
	}

	public function testParamAndReturnBothFlagged(): Void {
		Assert.equals(2, violations('class C { public function g(a) {} }').length);
	}

	public function testConstructorReturnExempt(): Void {
		Assert.equals(0, violations('class C { public function new() {} }').length);
	}

	public function testConstructorParamStillChecked(): Void {
		Assert.equals(1, violations('class C { public function new(a) {} }').length);
	}

	public function testEnumAbstractValuesExempt(): Void {
		Assert.equals(0, violations('enum abstract E(Int) { final X = 0; final Y = 1; }').length);
	}

	public function testEnumAbstractMethodChecked(): Void {
		// The value is exempt, but the method's missing return type is flagged.
		Assert.equals(1, violations('enum abstract E(Int) { final X = 0; public function f() {} }').length);
	}

	public function testInterfaceTypedMembersNotFlagged(): Void {
		Assert.equals(0, violations('interface I { var a:Int; function f():Void; }').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('explicit-type'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('explicit-type'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new ExplicitType().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/**
	 * A generic constraint (`<T:C>`) projects like a return type but sits before the
	 * parameters; a constrained-generic method with no return type must still be
	 * flagged. Regression for the position-aware return detection.
	 */
	public function testConstrainedGenericMissingReturnFlagged(): Void {
		Assert.equals(1, violations('class C { public function k<T:Iterator<Int>>(x:T) {} }').length);
	}

	public function testCheckstyleIgnoreEnumAbstractFalseFlags(): Void {
		// checkstyle Type.ignoreEnumAbstractValues=false turns off the exemption,
		// so an untyped enum-abstract value is flagged.
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = (tmp != null && tmp.length > 0) ? tmp : '/tmp';
		final dir: String = '$base/anyparse_et_cs_${Sys.time()}';
		sys.FileSystem.createDirectory(dir);
		sys.io.File.saveContent('$dir/checkstyle.json', '{"checks":[{"type":"Type","props":{"ignoreEnumAbstractValues":false}}]}');
		final path: String = '$dir/EA.hx';
		final src: String = 'enum abstract E(Int) {\n\tvar A = 1;\n}';
		sys.io.File.saveContent(path, src);
		Assert.isTrue(new ExplicitType().run([{ file: path, source: src }], new HaxeQueryPlugin()).length >= 1);
		sys.FileSystem.deleteFile(path);
		sys.FileSystem.deleteFile('$dir/checkstyle.json');
		sys.FileSystem.deleteDirectory(dir);
	}

}
