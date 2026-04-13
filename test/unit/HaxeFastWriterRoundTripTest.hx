package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HxModuleFastWriter;
import anyparse.grammar.haxe.HaxeModuleFastParser;

/**
 * Idempotency round-trip tests for the macro-generated writer.
 *
 * Invariant: `fastWrite(parse(fastWrite(parse(s)))) == fastWrite(parse(s))`.
 * The first write normalises formatting; the second write must produce
 * identical output, proving the generated writer emits parseable, stable text.
 */
class HaxeFastWriterRoundTripTest extends Test {

	private function roundTrip(source:String, ?label:String):Void {
		final written1:String = HxModuleFastWriter.write(HaxeModuleFastParser.parse(source));
		final written2:String = try {
			HxModuleFastWriter.write(HaxeModuleFastParser.parse(written1));
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
}
