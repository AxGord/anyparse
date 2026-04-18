package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HaxeModuleParser;

/**
 * Idempotency round-trip tests for the macro-generated writer.
 *
 * Invariant: `fastWrite(parse(fastWrite(parse(s)))) == fastWrite(parse(s))`.
 * The first write normalises formatting; the second write must produce
 * identical output, proving the generated writer emits parseable, stable text.
 */
class HaxeWriterRoundTripTest extends Test {

	private function roundTrip(source:String, ?label:String):Void {
		final written1:String = HxModuleWriter.write(HaxeModuleParser.parse(source));
		final written2:String = try {
			HxModuleWriter.write(HaxeModuleParser.parse(written1));
		} catch (e:Dynamic) {
			Assert.fail("reparse failed for " + (label ?? source) + ": written1=<" + written1 + ">, err=" + e);
			return;
		};
		Assert.equals(written1, written2, "idempotency failed for " + (label ?? source));
	}

	function testEmptyModule():Void {
		roundTrip('', 'empty');
	}

	function testEmptyClass():Void {
		roundTrip('class Foo {}');
	}

	function testClassWithVar():Void {
		roundTrip('class Foo { var x:Int; }');
	}

	function testClassWithVarInit():Void {
		roundTrip('class Foo { var x:Int = 42; }');
	}

	function testClassWithFunction():Void {
		roundTrip('class Foo { function bar():Void {} }');
	}

	function testFunctionWithParams():Void {
		roundTrip('class Foo { function bar(x:Int, y:Float):Void {} }');
	}

	function testFunctionWithBody():Void {
		roundTrip('class Foo { function f():Void { var x:Int = 1; return x; } }');
	}

	function testModifiers():Void {
		roundTrip('class Foo { public static var x:Int; }');
	}

	function testMultiDecl():Void {
		roundTrip('class A {} class B {}');
	}

	function testExprAtoms():Void {
		roundTrip('class F { var x:Int = 42; var y:Float = 3.14; var b:Bool = true; }');
	}

	function testExprArithmetic():Void {
		roundTrip('class F { var x:Int = 1 + 2 * 3; }');
	}

	function testExprPrefix():Void {
		roundTrip('class F { var x:Int = -1; var y:Bool = !true; }');
	}

	function testExprPostfix():Void {
		roundTrip('class F { function f():Void { var x:Int = a.b; var y:Int = a[0]; var z:Int = f(1, 2); } }');
	}

	function testExprAssignment():Void {
		roundTrip('class F { function f():Void { var x:Int = a = b = 1; } }');
	}

	function testExprComparison():Void {
		roundTrip('class F { var x:Bool = a == b; }');
	}

	function testExprLogical():Void {
		roundTrip('class F { var x:Bool = a && b || c; }');
	}

	function testExprBitwise():Void {
		roundTrip('class F { var x:Int = a | b & c; }');
	}

	function testExprShift():Void {
		roundTrip('class F { var x:Int = a << 2; }');
	}

	function testExprTernary():Void {
		roundTrip('class F { var x:Int = a ? b : c; }');
	}

	function testExprNullCoal():Void {
		roundTrip('class F { var x:Int = a ?? b; }');
	}

	function testExprParens():Void {
		roundTrip('class F { var x:Int = (a + b) * c; }');
	}

	function testExprNew():Void {
		roundTrip('class F { function f():Void { var x:Int = new Foo(1, 2); } }');
	}

	function testExprArray():Void {
		roundTrip('class F { function f():Void { var x:Int = [1, 2, 3]; } }');
	}

	function testExprArrow():Void {
		roundTrip('class F { var x:Int = a => b; }');
	}

	function testFnDeclNoReturnType():Void {
		roundTrip('class F { function main() {} }');
	}

	function testFnDeclNoReturnTypeWithBody():Void {
		roundTrip('class F { function main() { return 1; } }');
	}

	function testObjectLitEmpty():Void {
		roundTrip('class F { var x:Dynamic = {}; }');
	}

	function testObjectLitSingle():Void {
		roundTrip('class F { var x:Dynamic = {a: 1}; }');
	}

	function testObjectLitMultiple():Void {
		roundTrip('class F { var x:Dynamic = {a: 1, b: 2}; }');
	}

	function testObjectLitNested():Void {
		roundTrip('class F { var x:Dynamic = {outer: {inner: 1}}; }');
	}

	function testExprParenLambda():Void {
		roundTrip('class F { function f():Void { var x:Int = (a:Int) => a + 1; } }');
	}

	function testIfStmt():Void {
		roundTrip('class F { function f():Void { if (x) return 1; } }');
	}

	function testIfElseStmt():Void {
		roundTrip('class F { function f():Void { if (x) return 1; else return 2; } }');
	}

	function testWhileStmt():Void {
		roundTrip('class F { function f():Void { while (x) return 1; } }');
	}

	function testForStmt():Void {
		roundTrip('class F { function f():Void { for (i in items) return i; } }');
	}

	function testBlockStmt():Void {
		roundTrip('class F { function f():Void { { var x:Int = 1; } } }');
	}

	function testVoidReturn():Void {
		roundTrip('class F { function f():Void { return; } }');
	}

	function testThrowStmt():Void {
		roundTrip('class F { function f():Void { throw x; } }');
	}

	function testDoWhileStmt():Void {
		roundTrip('class F { function f():Void { do return 1; while (x); } }');
	}

	function testTryCatch():Void {
		roundTrip('class F { function f():Void { try return 1; catch (e:Error) return 2; } }');
	}

	function testSwitchStmt():Void {
		roundTrip('class F { function f():Void { switch (x) { case 1: return 1; default: return 2; } } }');
	}

	function testTypedef():Void {
		roundTrip('typedef Foo = Bar;');
	}

	function testEnum():Void {
		roundTrip('enum Foo { A; B; }');
	}

	function testEnumParamCtor():Void {
		roundTrip('enum Foo { A(x:Int, y:Float); B; }');
	}

	function testInterface():Void {
		roundTrip('interface Foo { function bar():Void {} }');
	}

	function testAbstract():Void {
		roundTrip('abstract Foo(Int) from Int to Int { function bar():Void {} }');
	}

	function testDoubleString():Void {
		roundTrip('class F { var x:String = "hello"; }');
	}

	function testSingleString():Void {
		roundTrip("class F { var x:String = 'hello'; }");
	}

	function testSingleStringInterp():Void {
		roundTrip("class F { var x:String = 'hello $name'; }");
	}

	function testSingleStringBlock():Void {
		roundTrip("class F { var x:String = 'val=${a + b}'; }");
	}

	function testSingleStringDollar():Void {
		roundTrip("class F { var x:String = 'costs " + "$$" + "5'; }");
	}

	function testMixedDecls():Void {
		roundTrip('class A {} typedef B = C; enum D { X; } interface E {} abstract F(Int) {}');
	}

	function testParamDefault():Void {
		roundTrip('class F { function f(x:Int = 0):Void {} }');
	}

	function testNestedExpr():Void {
		roundTrip('class F { var x:Int = (a + b) * (c - d); }');
	}

	function testCompoundAssign():Void {
		roundTrip('class F { function f():Void { var x:Int = a += b *= 2; } }');
	}

	function testIfBlock():Void {
		roundTrip('class F { function f():Void { if (x) { return 1; } } }');
	}

	function testFunctionNameAdjacentToParen():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('class F { function main():Void {} }'));
		Assert.isTrue(out.indexOf('main()') != -1, 'expected `main()` (no space) in: <$out>');
		Assert.isTrue(out.indexOf('main ()') == -1, 'did not expect space before `()` in: <$out>');
	}

	function testFunctionWithParamsAdjacentToParen():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('class F { function bar(x:Int):Void {} }'));
		Assert.isTrue(out.indexOf('bar(x') != -1, 'expected `bar(x` (no space) in: <$out>');
		Assert.isTrue(out.indexOf('bar (') == -1, 'did not expect space before `(` in: <$out>');
	}

	function testFunctionReturnTypeTightColon():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('class F { function f():Int { return 1; } }'));
		Assert.isTrue(out.indexOf('f():Int') != -1, 'expected `f():Int` (tight colon) in: <$out>');
		Assert.isTrue(out.indexOf(' : Int') == -1, 'did not expect spaced ` : Int` in: <$out>');
	}

	function testLambdaParamTypeTightColon():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('class F { function f():Void { var x:Int = (a:Int) => a + 1; } }'));
		Assert.isTrue(out.indexOf('(a:Int)') != -1, 'expected `(a:Int)` (tight colon) in: <$out>');
		Assert.isTrue(out.indexOf('(a : Int)') == -1, 'did not expect spaced `(a : Int)` in: <$out>');
	}

	function testNoLeadingSpaceBeforeMemberWithoutModifiers():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('class F { function test() {} }'));
		Assert.isTrue(out.indexOf('\tfunction') != -1, 'expected `\\tfunction` (no leading space after indent) in: <$out>');
		Assert.isTrue(out.indexOf('\t function') == -1, 'did not expect `\\t function` (extra space) in: <$out>');
	}

	function testNoLeadingSpaceBeforeVarWithoutModifiers():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('class F { var x:Int; }'));
		Assert.isTrue(out.indexOf('\tvar') != -1, 'expected `\\tvar` (no leading space after indent) in: <$out>');
		Assert.isTrue(out.indexOf('\t var') == -1, 'did not expect `\\t var` (extra space) in: <$out>');
	}

	function testIfBodyPolicySame():Void {
		final out:String = writeWithIfBody('class F { function f() { if (x) doA(); } }', BodyPolicy.Same, 120);
		Assert.isTrue(out.indexOf('if (x) doA();') != -1, 'expected `if (x) doA();` (same line) in: <$out>');
	}

	function testIfBodyPolicyNextAlwaysBreaks():Void {
		final out:String = writeWithIfBody('class F { function f() { if (x) doA(); } }', BodyPolicy.Next, 120);
		Assert.isTrue(out.indexOf('if (x)\n\t\t\tdoA();') != -1, 'expected `if (x)\\n\\t\\t\\tdoA();` (next line + indent) in: <$out>');
	}

	function testIfBodyPolicyFitLineStaysFlatWhenFits():Void {
		final out:String = writeWithIfBody('class F { function f() { if (x) doA(); } }', BodyPolicy.FitLine, 120);
		Assert.isTrue(out.indexOf('if (x) doA();') != -1, 'expected `if (x) doA();` (fits flat) in: <$out>');
	}

	function testIfBodyPolicyFitLineBreaksWhenTooLong():Void {
		final out:String = writeWithIfBody('class F { function f() { if (x) doSomethingVeryLong(); } }', BodyPolicy.FitLine, 20);
		Assert.isTrue(out.indexOf('if (x)\n\t\t\tdoSomethingVeryLong();') != -1, 'expected broken body in: <$out>');
	}

	function testForBodyPolicyNextAlwaysBreaks():Void {
		final out:String = writeWithForBody('class F { function f() { for (i in xs) doA(); } }', BodyPolicy.Next, 120);
		Assert.isTrue(out.indexOf('for (i in xs)\n\t\t\tdoA();') != -1, 'expected for-body next line in: <$out>');
	}

	function testWhileBodyPolicyFitLineBreaksWhenTooLong():Void {
		final out:String = writeWithWhileBody('class F { function f() { while (x) doSomethingVeryLong(); } }', BodyPolicy.FitLine, 20);
		Assert.isTrue(out.indexOf('while (x)\n\t\t\tdoSomethingVeryLong();') != -1, 'expected while-body break in: <$out>');
	}

	function testElseBodyPolicyNextBreaksOnlyElseBody():Void {
		final out:String = writeWithOpts('class F { function f() { if (x) doA(); else doB(); } }', BodyPolicy.Same, BodyPolicy.Next, BodyPolicy.Same, BodyPolicy.Same, BodyPolicy.Same, 120);
		Assert.isTrue(out.indexOf('if (x) doA();') != -1, 'expected then-body flat in: <$out>');
		Assert.isTrue(out.indexOf('else\n\t\t\tdoB();') != -1, 'expected else-body next line in: <$out>');
	}

	function testDoBodyPolicySame():Void {
		final out:String = writeWithDoBody('class F { function f() { do doA(); while (x); } }', BodyPolicy.Same, 120);
		Assert.isTrue(out.indexOf('do doA(); while (x);') != -1, 'expected `do doA(); while (x);` (same line) in: <$out>');
	}

	function testDoBodyPolicyNextAlwaysBreaks():Void {
		final out:String = writeWithDoBody('class F { function f() { do doA(); while (x); } }', BodyPolicy.Next, 120);
		Assert.isTrue(out.indexOf('do\n\t\t\tdoA(); while (x);') != -1, 'expected `do\\n\\t\\t\\tdoA(); while (x);` (next line + indent) in: <$out>');
	}

	function testDoBodyPolicyFitLineBreaksWhenTooLong():Void {
		final out:String = writeWithDoBody('class F { function f() { do doSomethingVeryLong(); while (x); } }', BodyPolicy.FitLine, 20);
		Assert.isTrue(out.indexOf('do\n\t\t\tdoSomethingVeryLong(); while (x);') != -1, 'expected broken do-body in: <$out>');
	}

	private inline function writeWithIfBody(src:String, policy:BodyPolicy, lineWidth:Int):String {
		return writeWithOpts(src, policy, BodyPolicy.Same, BodyPolicy.Same, BodyPolicy.Same, BodyPolicy.Same, lineWidth);
	}

	private inline function writeWithForBody(src:String, policy:BodyPolicy, lineWidth:Int):String {
		return writeWithOpts(src, BodyPolicy.Same, BodyPolicy.Same, policy, BodyPolicy.Same, BodyPolicy.Same, lineWidth);
	}

	private inline function writeWithWhileBody(src:String, policy:BodyPolicy, lineWidth:Int):String {
		return writeWithOpts(src, BodyPolicy.Same, BodyPolicy.Same, BodyPolicy.Same, policy, BodyPolicy.Same, lineWidth);
	}

	private inline function writeWithDoBody(src:String, policy:BodyPolicy, lineWidth:Int):String {
		return writeWithOpts(src, BodyPolicy.Same, BodyPolicy.Same, BodyPolicy.Same, BodyPolicy.Same, policy, lineWidth);
	}

	private function writeWithOpts(
		src:String, ifBody:BodyPolicy, elseBody:BodyPolicy, forBody:BodyPolicy, whileBody:BodyPolicy, doBody:BodyPolicy,
		lineWidth:Int
	):String {
		final base:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		final opts:HxModuleWriteOptions = {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			sameLineElse: base.sameLineElse,
			sameLineCatch: base.sameLineCatch,
			sameLineDoWhile: base.sameLineDoWhile,
			trailingCommaArrays: base.trailingCommaArrays,
			trailingCommaArgs: base.trailingCommaArgs,
			trailingCommaParams: base.trailingCommaParams,
			ifBody: ifBody,
			elseBody: elseBody,
			forBody: forBody,
			whileBody: whileBody,
			doBody: doBody,
			leftCurly: base.leftCurly,
			objectFieldColon: base.objectFieldColon,
		};
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}
}
