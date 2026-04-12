package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeWriter;
import anyparse.grammar.haxe.HaxeWriter.HaxeWriteOptions;
import anyparse.grammar.haxe.HaxeModuleFastParser;

/**
 * Idempotency round-trip tests for HaxeWriter.
 *
 * The invariant: `write(parse(write(parse(source)))) == write(parse(source))`.
 * The first write normalises formatting; the second write must produce
 * identical output, proving the writer generates parseable, stable text.
 */
class HaxeRoundTripTest extends Test {

	private static final OPT:HaxeWriteOptions = {indent: '  ', lineWidth: 80};

	private function roundTrip(source:String, ?label:String):Void {
		final written1:String = HaxeWriter.write(HaxeModuleFastParser.parse(source), OPT);
		final written2:String = try {
			HaxeWriter.write(HaxeModuleFastParser.parse(written1), OPT);
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

	function testTypedef():Void {
		roundTrip('typedef Foo = Bar;');
	}

	function testEnum():Void {
		roundTrip('enum Foo { A; B; }');
	}

	function testEnumParamCtor():Void {
		roundTrip('enum Foo { Bar(x:Int); Baz; }');
	}

	function testInterface():Void {
		roundTrip('interface Foo { function bar():Void {} }');
	}

	function testAbstract():Void {
		roundTrip('abstract Foo(Int) from String to Float { var x:Int; }');
	}

	function testMultiDecl():Void {
		roundTrip('class A {} class B {} typedef C = Int;');
	}

	function testExprAtoms():Void {
		roundTrip('class F { var a:Int = 42; var b:Float = 3.14; var c:Bool = true; var d:Bool = false; var e:Int = null; var f:Int = other; }');
	}

	function testExprArithmetic():Void {
		roundTrip('class F { function f():Void { var x:Int = a + b * c - d / e % f; } }');
	}

	function testExprComparison():Void {
		roundTrip('class F { function f():Void { var x:Int = a == b; } }');
	}

	function testExprLogical():Void {
		roundTrip('class F { function f():Void { var x:Int = a && b || c; } }');
	}

	function testExprAssignment():Void {
		roundTrip('class F { function f():Void { a = b = c; } }');
	}

	function testExprBitwise():Void {
		roundTrip('class F { function f():Void { var x:Int = a | b & c ^ d; } }');
	}

	function testExprShift():Void {
		roundTrip('class F { function f():Void { var x:Int = a << b >> c >>> d; } }');
	}

	function testExprTernary():Void {
		roundTrip('class F { function f():Void { var x:Int = a ? b : c; } }');
	}

	function testExprNullCoal():Void {
		roundTrip('class F { function f():Void { var x:Int = a ?? b ?? c; } }');
	}

	function testExprPrefix():Void {
		roundTrip('class F { function f():Void { var x:Int = -a; var y:Int = !b; var z:Int = ~c; } }');
	}

	function testExprPostfix():Void {
		roundTrip('class F { function f():Void { a.b.c; a[0]; foo(1, 2); } }');
	}

	function testExprNew():Void {
		roundTrip('class F { function f():Void { new Foo(1, 2); } }');
	}

	function testExprParens():Void {
		roundTrip('class F { function f():Void { var x:Int = (a + b) * c; } }');
	}

	function testExprArray():Void {
		roundTrip('class F { function f():Void { var x:Int = [1, 2, 3]; } }');
	}

	function testExprArrow():Void {
		roundTrip('class F { function f():Void { var x:Int = a => b; } }');
	}

	function testExprParenLambda():Void {
		roundTrip('class F { function f():Void { var x:Int = (a:Int) => a; } }');
	}

	function testExprCompoundAssign():Void {
		roundTrip('class F { function f():Void { a += 1; b -= 2; c *= 3; d /= 4; e %= 5; } }');
	}

	function testIfStmt():Void {
		roundTrip('class F { function f():Void { if (x) return; } }');
	}

	function testIfElseStmt():Void {
		roundTrip('class F { function f():Void { if (x) return 1; else return 2; } }');
	}

	function testWhileStmt():Void {
		roundTrip('class F { function f():Void { while (x) return; } }');
	}

	function testForStmt():Void {
		roundTrip('class F { function f():Void { for (i in items) return; } }');
	}

	function testDoWhileStmt():Void {
		roundTrip('class F { function f():Void { do return; while (x); } }');
	}

	function testThrowStmt():Void {
		roundTrip('class F { function f():Void { throw x; } }');
	}

	function testBlockStmt():Void {
		roundTrip('class F { function f():Void { { return; } } }');
	}

	function testSwitchStmt():Void {
		roundTrip('class F { function f():Void { switch (x) { case 1: return; default: return; } } }');
	}

	function testTryCatch():Void {
		roundTrip('class F { function f():Void { try return; catch (e:Error) return; } }');
	}

	function testVoidReturn():Void {
		roundTrip('class F { function f():Void { return; } }');
	}

	function testDoubleString():Void {
		roundTrip('class F { var x:String = "hello"; }');
	}

	function testDoubleStringEscape():Void {
		roundTrip('class F { var x:String = "a\\nb"; }');
	}

	function testSingleString():Void {
		roundTrip("class F { var x:String = 'hello'; }");
	}

	function testSingleStringInterp():Void {
		roundTrip("class F { var x:String = 'hi $name'; }");
	}

	function testSingleStringBlock():Void {
		roundTrip("class F { var x:String = 'val=${1 + 2}'; }");
	}

	function testSingleStringDollar():Void {
		roundTrip("class F { var x:String = '$$'; }");
	}

	function testParamDefault():Void {
		roundTrip('class F { function f(x:Int = 0, y:Bool = true):Void {} }');
	}

	function testIfBlock():Void {
		roundTrip('class F { function f():Void { if (x) { return 1; return 2; } } }');
	}

	function testNestedExpr():Void {
		roundTrip('class F { function f():Void { var x:Int = a.b(c + d)[e]; } }');
	}

	function testMixedDecls():Void {
		roundTrip('class A { var x:Int; } enum B { X; Y; } typedef C = Int; interface D {} abstract E(Int) {}');
	}
}
