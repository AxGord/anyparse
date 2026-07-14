package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ExplicitType;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

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

	private function violations(src: String): Array<Violation> {
		return new ExplicitType().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}


	public function testFixNewWithTypeParamsCarried(): Void {
		final out: String = applyFix('class C { public var a = new Map<Int, String>(); }');
		Assert.isTrue(out.indexOf('a:Map<Int, String> =') != -1, 'expected carried type params, got: $out');
	}

	public function testFixBareNewSkipped(): Void {
		// A bare `new Foo()` could be a generic used without params — annotating `:Foo` risks a broken build.
		Assert.equals(0, fixCount('class C { public var a = new Foo(); }'));
	}

	public function testFixNewWithArgsButNoParamsSkipped(): Void {
		Assert.equals(0, fixCount('class C { public var a = new Foo(1, 2); }'));
	}

	public function testFixStringLiteral(): Void {
		final out: String = applyFix('class C { var a = "hi"; }');
		Assert.isTrue(out.indexOf('a:String =') != -1, 'got: $out');
	}

	public function testFixSingleQuoteString(): Void {
		final out: String = applyFix("class C { var a = 'hi'; }");
		Assert.isTrue(out.indexOf('a:String =') != -1, 'got: $out');
	}

	public function testFixBoolLiteral(): Void {
		final out: String = applyFix('class C { var a = true; }');
		Assert.isTrue(out.indexOf('a:Bool =') != -1, 'got: $out');
	}

	public function testFixIntLiteral(): Void {
		final out: String = applyFix('class C { var a = 42; }');
		Assert.isTrue(out.indexOf('a:Int =') != -1, 'got: $out');
	}

	public function testFixHexLiteral(): Void {
		final out: String = applyFix('class C { var a = 0xFF; }');
		Assert.isTrue(out.indexOf('a:Int =') != -1, 'got: $out');
	}

	public function testFixFloatLiteral(): Void {
		final out: String = applyFix('class C { var a = 3.14; }');
		Assert.isTrue(out.indexOf('a:Float =') != -1, 'got: $out');
	}

	public function testFixNegativeInt(): Void {
		final out: String = applyFix('class C { var a = -5; }');
		Assert.isTrue(out.indexOf('a:Int =') != -1, 'got: $out');
	}

	public function testFixNegativeFloat(): Void {
		final out: String = applyFix('class C { var a = -3.5; }');
		Assert.isTrue(out.indexOf('a:Float =') != -1, 'got: $out');
	}

	public function testFixTypedCast(): Void {
		final out: String = applyFix('class C { function f(x:Int) { } var a = cast(x, Foo); }');
		Assert.isTrue(out.indexOf('a:Foo =') != -1, 'got: $out');
	}

	public function testFixCheckType(): Void {
		final out: String = applyFix('class C { var a = (x : Bar); }');
		Assert.isTrue(out.indexOf('a:Bar =') != -1, 'got: $out');
	}

	public function testFixParamDefault(): Void {
		final out: String = applyFix('class C { public function f(p = 5):Void {} }');
		Assert.isTrue(out.indexOf('p:Int =') != -1, 'got: $out');
	}

	public function testFixSkipsCall(): Void {
		Assert.equals(0, fixCount('class C { var a = foo(); }'));
	}

	public function testFixSkipsArrayLiteral(): Void {
		Assert.equals(0, fixCount('class C { var a = [1, 2]; }'));
	}

	public function testFixSkipsTernary(): Void {
		Assert.equals(0, fixCount('class C { var a = c ? 1 : 2; }'));
	}

	public function testFixVoidMethodAnnotated(): Void {
		// A block-bodied method with no return at all returns Void.
		final out: String = applyFix('class C { public function f() {} }');
		Assert.isTrue(out.indexOf('f():Void') != -1, 'got: $out');
	}

	public function testFixVoidMethodWithBareReturn(): Void {
		// A bare `return;` is not a value-return — the method is still Void.
		final out: String = applyFix('class C { public function f() { if (a) return; } }');
		Assert.isTrue(out.indexOf('f():Void') != -1, 'got: $out');
	}

	public function testFixSkipsValueReturn(): Void {
		// `return 5;` is a value-return — its type is unknown without inference, so skip.
		Assert.equals(0, fixCount('class C { public function f() { return 5; } }'));
	}

	public function testFixSkipsValueReturnInExpression(): Void {
		// A `return <expr>` in expression position (`ReturnExpr`, inside a ternary) is still
		// a value-return in the function's own scope — must not be annotated Void.
		Assert.equals(0, fixCount('class C { public function f() { var y = c ? return 5 : 3; } }'));
	}

	public function testFixVoidDespiteLambdaValueReturn(): Void {
		// The lambda's `return x` belongs to the lambda, not to `f` — `f`'s own scope has no
		// value-return, so it is Void. The critical do-not-descend-into-lambdas case.
		final src: String = 'class C { public function f() { arr.map(x -> { return x; }); } }';
		Assert.equals(1, fixCount(src));
		Assert.isTrue(applyFix(src).indexOf('f():Void') != -1, 'got: ${applyFix(src)}');
	}

	public function testFixVoidDespiteNestedLocalFnValueReturn(): Void {
		// The nested local function's `return 7` is its own; `f` is Void. Only `f` is fixed.
		final src: String = 'class C { public function f() { function g() { return 7; } g(); } }';
		Assert.equals(1, fixCount(src));
		Assert.isTrue(applyFix(src).indexOf('f():Void') != -1, 'got: ${applyFix(src)}');
	}

	public function testFixSkipsMacroFunction(): Void {
		// A macro function returns `Expr` implicitly — annotating Void would break it.
		Assert.equals(0, fixCount('class C { macro static function f() {} }'));
	}

	public function testFixSkipsExpressionBodyReturn(): Void {
		// An expression-bodied `function f() return 5;` is a value-return — report-only.
		Assert.equals(0, fixCount('class C { public function f() return 5; }'));
	}

	public function testFixSkipsExpressionBodyBareCall(): Void {
		// An expression-bodied `function f() expr;` has an unknown return type — skip; only a
		// `{ … }` block body is annotated. Guards the block-body restriction.
		Assert.equals(0, fixCount('class C { public function f() trace("x"); }'));
	}

	public function testFixSkipsUntypedParamNoDefault(): Void {
		Assert.equals(0, fixCount('class C { public function f(a):Void {} }'));
	}

	public function testFixSkipsFieldNoInit(): Void {
		Assert.equals(0, fixCount('class C { public var b; }'));
	}

	private function applyFix(src: String): String {
		final check: ExplicitType = new ExplicitType();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		edits.sort((a, b) -> b.span.from - a.span.from);
		var result: String = src;
		for (e in edits) result = result.substring(0, e.span.from) + e.text + result.substring(e.span.to);
		return result;
	}

	private function fixCount(src: String): Int {
		final check: ExplicitType = new ExplicitType();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		return check.fix(src, vs, new HaxeQueryPlugin()).length;
	}

}
