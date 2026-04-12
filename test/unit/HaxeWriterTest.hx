package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeWriter;
import anyparse.grammar.haxe.HaxeWriter.HaxeWriteOptions;
import anyparse.grammar.haxe.HaxeModuleFastParser;
import anyparse.grammar.haxe.HxModule;

/**
 * Golden-file unit tests for HaxeWriter.
 *
 * Each test parses a source string, writes it back, and asserts
 * the output matches the expected formatted form.
 */
class HaxeWriterTest extends Test {

	private static final OPT:HaxeWriteOptions = {indent: '  ', lineWidth: 80};

	private function fmt(source:String):String {
		final module:HxModule = HaxeModuleFastParser.parse(source);
		return HaxeWriter.write(module, OPT);
	}

	// --- Declarations ---

	function testEmptyClass():Void {
		Assert.equals('class Foo {}', fmt('class Foo {}'));
	}

	function testClassWithVar():Void {
		final result:String = fmt('class Foo { var x:Int; }');
		Assert.equals('class Foo {\n  var x:Int;\n}', result);
	}

	function testClassWithFunction():Void {
		final result:String = fmt('class Foo { function bar():Void {} }');
		Assert.equals('class Foo {\n  function bar():Void {}\n}', result);
	}

	function testClassWithModifiers():Void {
		final result:String = fmt('class Foo { public static var x:Int; }');
		Assert.equals('class Foo {\n  public static var x:Int;\n}', result);
	}

	function testClassWithMixedMembers():Void {
		final result:String = fmt('class Foo { var x:Int; function bar():Void {} }');
		Assert.equals('class Foo {\n  var x:Int;\n  function bar():Void {}\n}', result);
	}

	function testTypedef():Void {
		Assert.equals('typedef Foo = Bar;', fmt('typedef Foo = Bar;'));
	}

	function testEmptyEnum():Void {
		Assert.equals('enum Foo {}', fmt('enum Foo {}'));
	}

	function testEnumWithCtors():Void {
		final result:String = fmt('enum Foo { A; B; }');
		Assert.equals('enum Foo {\n  A;\n  B;\n}', result);
	}

	function testEnumParamCtor():Void {
		final result:String = fmt('enum Foo { Bar(x:Int, y:Float); }');
		Assert.equals('enum Foo {\n  Bar(x:Int, y:Float);\n}', result);
	}

	function testEmptyInterface():Void {
		Assert.equals('interface Foo {}', fmt('interface Foo {}'));
	}

	function testInterfaceWithMembers():Void {
		final result:String = fmt('interface Foo { function bar():Void {} }');
		Assert.equals('interface Foo {\n  function bar():Void {}\n}', result);
	}

	function testAbstractSimple():Void {
		Assert.equals('abstract Foo(Int) {}', fmt('abstract Foo(Int) {}'));
	}

	function testAbstractWithClauses():Void {
		final result:String = fmt('abstract Foo(Int) from String to Float {}');
		Assert.equals('abstract Foo(Int) from String to Float {}', result);
	}

	function testAbstractWithMembers():Void {
		final result:String = fmt('abstract Foo(Int) { var x:Int; }');
		Assert.equals('abstract Foo(Int) {\n  var x:Int;\n}', result);
	}

	function testTwoDecls():Void {
		final result:String = fmt('class Foo {} class Bar {}');
		Assert.equals('class Foo {}\n\nclass Bar {}', result);
	}

	function testEmptyModule():Void {
		Assert.equals('', fmt(''));
	}

	// --- Function details ---

	function testFunctionWithParams():Void {
		final result:String = fmt('class Foo { function bar(x:Int, y:Float):Void {} }');
		Assert.equals('class Foo {\n  function bar(x:Int, y:Float):Void {}\n}', result);
	}

	function testFunctionWithBody():Void {
		final result:String = fmt('class Foo { function bar():Void { return; } }');
		Assert.equals('class Foo {\n  function bar():Void {\n    return;\n  }\n}', result);
	}

	function testParamWithDefault():Void {
		final result:String = fmt('class Foo { function bar(x:Int = 0):Void {} }');
		Assert.equals('class Foo {\n  function bar(x:Int = 0):Void {}\n}', result);
	}

	function testVarWithInit():Void {
		final result:String = fmt('class Foo { var x:Int = 42; }');
		Assert.equals('class Foo {\n  var x:Int = 42;\n}', result);
	}

	// --- Expressions: atoms ---

	function testExprInt():Void {
		final result:String = fmt('class F { var x:Int = 42; }');
		Assert.stringContains('= 42;', result);
	}

	function testExprFloat():Void {
		final result:String = fmt('class F { var x:Float = 3.14; }');
		Assert.stringContains('= 3.14;', result);
	}

	function testExprBool():Void {
		final result:String = fmt('class F { var x:Bool = true; }');
		Assert.stringContains('= true;', result);
	}

	function testExprNull():Void {
		final result:String = fmt('class F { var x:Int = null; }');
		Assert.stringContains('= null;', result);
	}

	function testExprIdent():Void {
		final result:String = fmt('class F { var x:Int = other; }');
		Assert.stringContains('= other;', result);
	}

	function testExprDoubleString():Void {
		final result:String = fmt('class F { var x:String = "hello"; }');
		Assert.stringContains('= "hello";', result);
	}

	function testExprSingleString():Void {
		final result:String = fmt("class F { var x:String = 'world'; }");
		Assert.stringContains("'world'", result);
	}

	function testExprArray():Void {
		final result:String = fmt('class F { var x:Int = [1, 2, 3]; }');
		Assert.stringContains('= [1, 2, 3];', result);
	}

	function testExprEmptyArray():Void {
		final result:String = fmt('class F { var x:Int = []; }');
		Assert.stringContains('= [];', result);
	}

	// --- Expressions: precedence ---

	function testPrecedenceNoParens():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = a + b * c; } }');
		Assert.stringContains('a + b * c;', result);
	}

	function testPrecedenceNeedsParens():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = (a + b) * c; } }');
		Assert.stringContains('(a + b) * c;', result);
	}

	function testLeftAssocNoParens():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = a - b - c; } }');
		Assert.stringContains('a - b - c;', result);
	}

	function testRightAssocNoParens():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = a = b = c; } }');
		Assert.stringContains('a = b = c;', result);
	}

	function testPrefixNoParens():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = -a + b; } }');
		Assert.stringContains('-a + b;', result);
	}

	function testPostfixFieldAccess():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = a.b.c; } }');
		Assert.stringContains('a.b.c;', result);
	}

	function testPostfixCall():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = foo(1, 2); } }');
		Assert.stringContains('foo(1, 2);', result);
	}

	function testPostfixIndex():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = a[0]; } }');
		Assert.stringContains('a[0];', result);
	}

	function testTernary():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = a ? b : c; } }');
		Assert.stringContains('a ? b : c;', result);
	}

	function testNullCoal():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = a ?? b; } }');
		Assert.stringContains('a ?? b;', result);
	}

	function testArrowExpr():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = a => b; } }');
		Assert.stringContains('a => b;', result);
	}

	function testNewExpr():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = new Foo(1, 2); } }');
		Assert.stringContains('new Foo(1, 2);', result);
	}

	function testParenLambda():Void {
		final result:String = fmt('class F { function f():Void { var x:Int = (a:Int) => a; } }');
		Assert.stringContains('(a:Int) => a;', result);
	}

	// --- Statements ---

	function testReturnStmt():Void {
		final result:String = fmt('class F { function f():Void { return 1; } }');
		Assert.stringContains('return 1;', result);
	}

	function testVoidReturn():Void {
		final result:String = fmt('class F { function f():Void { return; } }');
		Assert.stringContains('return;', result);
	}

	function testIfStmt():Void {
		final result:String = fmt('class F { function f():Void { if (x) return; } }');
		Assert.stringContains('if (x) return;', result);
	}

	function testIfElse():Void {
		final result:String = fmt('class F { function f():Void { if (x) return; else return; } }');
		Assert.stringContains('if (x) return; else return;', result);
	}

	function testWhileStmt():Void {
		final result:String = fmt('class F { function f():Void { while (x) return; } }');
		Assert.stringContains('while (x) return;', result);
	}

	function testForStmt():Void {
		final result:String = fmt('class F { function f():Void { for (i in items) return; } }');
		Assert.stringContains('for (i in items) return;', result);
	}

	function testThrowStmt():Void {
		final result:String = fmt('class F { function f():Void { throw x; } }');
		Assert.stringContains('throw x;', result);
	}

	function testDoWhile():Void {
		final result:String = fmt('class F { function f():Void { do return; while (x); } }');
		Assert.stringContains('do return; while (x);', result);
	}

	function testBlockStmt():Void {
		final result:String = fmt('class F { function f():Void { { return; } } }');
		Assert.stringContains('{\n      return;\n    }', result);
	}

	function testSwitchStmt():Void {
		final result:String = fmt('class F { function f():Void { switch (x) { case 1: return; default: return; } } }');
		Assert.stringContains('switch (x)', result);
		Assert.stringContains('case 1:', result);
		Assert.stringContains('default:', result);
	}

	function testTryCatch():Void {
		final result:String = fmt('class F { function f():Void { try return; catch (e:Error) return; } }');
		Assert.stringContains('try return; catch (e:Error) return;', result);
	}

	// --- Strings ---

	function testDoubleStringEscapes():Void {
		final result:String = fmt('class F { var x:String = "a\\nb"; }');
		Assert.stringContains('"a\\nb"', result);
	}

	function testSingleStringInterp():Void {
		final result:String = fmt("class F { var x:String = 'hello ${1 + 2}'; }");
		Assert.stringContains("${1 + 2}", result);
	}

	function testInterpIdent():Void {
		final result:String = fmt("class F { var x:String = 'hi $name'; }");
		Assert.stringContains("$name", result);
	}

	function testInterpDollar():Void {
		final result:String = fmt("class F { var x:String = '$$'; }");
		Assert.stringContains("'$$'", result);
	}
}
