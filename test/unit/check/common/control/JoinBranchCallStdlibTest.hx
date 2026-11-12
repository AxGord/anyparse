package unit.check.common.control;

import anyparse.check.common.control.JoinBranchCall;
import anyparse.query.GrammarPlugin;

/**
 * `join-branch-call` over a shared argument that is a stdlib call the `StdlibPurity` table proves transparent, run in a
 * scope that holds the std (a bare test index holds none, and would pass what a real run refuses): a `Math` static, a
 * `StringTools` static whose result is read, a `String` method on a typed field. A project type of the same name as the
 * std one is no longer the std's, so its call stays unjoined.
 */
class JoinBranchCallStdlibTest extends Test {

	/** `String` as the std declares it, beside the `StdScope` stubs, so a read of `length` is a known plain field. */
	private static final STRING_STUB: String = 'extern class String {\n\tvar length(default, null):Int;\n'
		+ '\tfunction toUpperCase():String;\n\tfunction charCodeAt(index:Int):Null<Int>;\n}';

	@:pin('control')
	@:killer('M-STDLIB-STATIC-SHADOW-COUNTS-STD')
	public function testStdStaticArgumentJoins(): Void {
		Assert.equals(
			1,
			findings(
				'class C {\n\tstatic function h(a:Float, b:Int) {}\n\tstatic function f(c:Bool, n:Float) {\n'
				+ '\t\tif (c) h(Math.abs(n), 1); else h(Math.abs(n), 2);\n\t}\n}\n'
			).length
		);
	}

	@:pin('control')
	@:killer('M-STDLIB-STATIC-SHADOW-COUNTS-STD', 'M-PURITY-CALL-RECEIVER-UNTYPED')
	public function testStdStaticResultLengthJoins(): Void {
		Assert.equals(
			1,
			findings(
				'class C {\n\tstatic function h(a:Int, b:Int) {}\n\tstatic function f(c:Bool, s:String) {\n'
				+ '\t\tif (c) h(StringTools.trim(s).length, 1); else h(StringTools.trim(s).length, 2);\n\t}\n}\n'
			).length
		);
	}

	@:pin('control')
	@:killer('M-STDLIB-STRING-RECEIVER-IDENT-ONLY', 'M-PURITY-STRING-FIELD-RECEIVER-UNVOUCHED')
	public function testStringMethodOnTypedFieldJoins(): Void {
		Assert.equals(
			1,
			findings(
				'typedef S = {\n\tt:String\n}\n\nclass C {\n\tstatic function h(a:String, b:Int) {}\n'
				+ '\tstatic function f(c:Bool, u:S) {\n\t\tif (c) h(u.t.toUpperCase(), 1); else h(u.t.toUpperCase(), 2);\n\t}\n}\n'
			).length
		);
	}

	@:pin('control')
	@:killer('M-STDLIB-STRING-RECEIVER-IDENT-ONLY', 'M-PURITY-STRING-FIELD-RECEIVER-UNVOUCHED')
	public function testStringMethodOnClassFieldJoins(): Void {
		Assert.equals(
			1,
			findings(
				'class S {\n\tpublic var t:String;\n}\n\nclass C {\n\tstatic function h(a:String, b:Int) {}\n'
				+ '\tstatic function f(c:Bool, u:S) {\n\t\tif (c) h(u.t.toUpperCase(), 1); else h(u.t.toUpperCase(), 2);\n\t}\n}\n'
			).length
		);
	}

	@:pin('control')
	@:killer('M-STDLIB-ANSWERS-STRING-STATIC-ONLY')
	public function testStringMethodOnStaticFieldResultLengthJoins(): Void {
		Assert.equals(
			1,
			findings(
				'class K {\n\tpublic static var name:String;\n}\n\nclass C {\n\tstatic function h(a:Int, b:Int) {}\n\tstatic function '
				+ 'f(c:Bool) {\n\t\tif (c) h(K.name.toUpperCase().length, 1); else h(K.name.toUpperCase().length, 2);\n\t}\n}\n'
			).length
		);
	}

	@:pin('control')
	@:killer('M-STDLIB-STATIC-SHADOW-IGNORED')
	public function testProjectMathShadowStaysUnjoined(): Void {
		Assert.equals(
			0,
			findings(
				'class Math {\n\tpublic static function abs(n:Float):Float return n;\n}\n\nclass C {\n\tstatic function h(a:Float, '
				+ 'b:Int) {}\n\tstatic function f(c:Bool, n:Float) {\n\t\tif (c) h(Math.abs(n), 1); else h(Math.abs(n), 2);\n\t}\n}\n'
			).length
		);
	}

	@:pin('control')
	@:killer('M-STDLIB-STATIC-SHADOW-IGNORED')
	public function testProjectStringToolsShadowStaysUnjoined(): Void {
		Assert.equals(
			0,
			findings(
				'class StringTools {\n\tpublic static function trim(s:String):String return s;\n}\n\nclass C {\n'
				+ '\tstatic function h(a:String, b:Int) {}\n\tstatic function f(c:Bool, s:String) {\n'
				+ '\t\tif (c) h(StringTools.trim(s), 1); else h(StringTools.trim(s), 2);\n\t}\n}\n'
			).length
		);
	}

	@:pin('control')
	@:killer('M-PURITY-CALLEE-RECEIVER-UNASKED')
	public function testGetterFieldReceiverStaysUnjoined(): Void {
		Assert.equals(
			0,
			findings(
				'class S {\n\tpublic var t(get, never):String;\n\n\tfunction get_t():String return \'\';\n}\n\n'
				+ 'class C {\n\tstatic function h(a:String, b:Int) {}\n\tstatic function f(c:Bool, u:S) {\n'
				+ '\t\tif (c) h(u.t.toUpperCase(), 1); else h(u.t.toUpperCase(), 2);\n\t}\n}\n'
			).length
		);
	}

	private static function findings(src: String): Array<Violation> {
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final scoped: GrammarPlugin = StdScope.plugin(files, [{ file: QueryTestHelpers.stdPath('String.hx'), source: STRING_STUB }]);
		return CheckFixture.violationsIn(new JoinBranchCall(), files, scoped);
	}

}
