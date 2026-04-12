package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFastParser;
import anyparse.grammar.haxe.HaxeModuleFastParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 string literal tests for the macro-generated Haxe parser.
 *
 * Validates double-quoted and single-quoted string literal atoms
 * wired into `HxExpr` via `HxDoubleStringLit` and `HxSingleStringLit`
 * terminals. Both use `@:decode` metadata (the one new concept in
 * slice ν₁) to call `HxStringDecoder.decode` at runtime instead of
 * the JSON-specific decoder.
 *
 * **Not covered**: string interpolation, multi-line strings, raw
 * strings, `\0`, `\xNN`, `\uNNNN` hex/unicode escapes.
 */
class HxStringSliceTest extends HxTestHelpers {

	/** Empty double-quoted string `""` → decoded to `""`. */
	public function testDoubleEmpty():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:String = ""; }');
		assertDoubleString(decl.init, '');
	}

	/** Simple double-quoted string `"hello"`. */
	public function testDoubleSimple():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:String = "hello"; }');
		assertDoubleString(decl.init, 'hello');
	}

	/** Double-quoted string with spaces. */
	public function testDoubleWithSpaces():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:String = "hello world"; }');
		assertDoubleString(decl.init, 'hello world');
	}

	/** Escape sequences in double-quoted string: `\n`, `\t`, `\\`, `\"`. */
	public function testDoubleEscapes():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:String = "a\\nb\\tc\\\\d\\"e"; }');
		final s:String = expectDoubleString(decl.init);
		Assert.equals('a\nb\tc\\d"e', s);
	}

	/** Empty single-quoted string `''` → decoded to `""`. */
	public function testSingleEmpty():Void {
		final decl:HxVarDecl = parseSingleVarDecl("class Foo { var x:String = ''; }");
		assertSingleString(decl.init, '');
	}

	/** Simple single-quoted string `'hello'`. */
	public function testSingleSimple():Void {
		final decl:HxVarDecl = parseSingleVarDecl("class Foo { var x:String = 'hello'; }");
		assertSingleString(decl.init, 'hello');
	}

	/** Escape sequences in single-quoted string: `\n`, `\'`, `\\`. */
	public function testSingleEscapes():Void {
		final decl:HxVarDecl = parseSingleVarDecl("class Foo { var x:String = 'a\\nb\\'c\\\\d'; }");
		final s:String = expectSingleString(decl.init);
		Assert.equals("a\nb'c\\d", s);
	}

	/** Dollar sign in single-quoted string without interpolation → literal `$`. */
	public function testSingleDollarNoInterpolation():Void {
		final decl:HxVarDecl = parseSingleVarDecl("class Foo { var x:String = 'cost: $$5'; }");
		final s:String = expectSingleString(decl.init);
		Assert.equals("cost: $$5", s);
	}

	/** String concatenation: `"a" + 'b'` → `Add(DoubleStringExpr, SingleStringExpr)`. */
	public function testStringConcat():Void {
		final decl:HxVarDecl = parseSingleVarDecl("class Foo { var x:String = \"hello\" + 'world'; }");
		switch decl.init {
			case Add(left, right):
				assertDoubleString(left, 'hello');
				assertSingleString(right, 'world');
			case null, _:
				Assert.fail('expected Add, got ${decl.init}');
		}
	}

	/** Double-quoted string as function argument. */
	public function testStringInFunctionArg():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f("hello"); }');
		switch decl.init {
			case Call(operand, args):
				Assert.equals(1, args.length);
				assertDoubleString(args[0], 'hello');
			case null, _:
				Assert.fail('expected Call, got ${decl.init}');
		}
	}

	/** String in return statement. */
	public function testStringInReturn():Void {
		final ast:HxClassDecl = HaxeFastParser.parse('class Foo { function bar():String { return "ok"; } }');
		final fn:HxFnDecl = expectFnMember(ast.members[0].member);
		Assert.equals(1, fn.body.length);
		switch fn.body[0] {
			case ReturnStmt(value):
				assertDoubleString(value, 'ok');
			case null, _:
				Assert.fail('expected ReturnStmt');
		}
	}

	/** Whitespace around string literal. */
	public function testWhitespace():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:String =   "hi"  ; }');
		assertDoubleString(decl.init, 'hi');
	}

	/** Module-root integration. */
	public function testModuleIntegration():Void {
		final source:String = "class A { var s:String = \"hello\"; } class B { var t:String = 'world'; }";
		final mod:HxModule = HaxeModuleFastParser.parse(source);
		Assert.equals(2, mod.decls.length);
		final a:HxClassDecl = expectClassDecl(mod.decls[0]);
		final b:HxClassDecl = expectClassDecl(mod.decls[1]);
		final va:HxVarDecl = expectVarMember(a.members[0].member);
		final vb:HxVarDecl = expectVarMember(b.members[0].member);
		assertDoubleString(va.init, 'hello');
		assertSingleString(vb.init, 'world');
	}

	/** Unterminated double-quoted string → rejection. */
	public function testRejectsUnterminatedDouble():Void {
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:String = "hello; }'), ParseError);
	}

	/** Unterminated single-quoted string → rejection. */
	public function testRejectsUnterminatedSingle():Void {
		Assert.raises(() -> HaxeFastParser.parse("class Foo { var x:String = 'hello; }"), ParseError);
	}

	// -------- assertion helpers --------

	private function assertDoubleString(expr:Null<HxExpr>, expected:String):Void {
		final s:String = expectDoubleString(expr);
		Assert.equals(expected, s);
	}

	private function assertSingleString(expr:Null<HxExpr>, expected:String):Void {
		final s:String = expectSingleString(expr);
		Assert.equals(expected, s);
	}

	private function expectDoubleString(expr:Null<HxExpr>):String {
		return switch expr {
			case DoubleStringExpr(v): (v : String);
			case null, _: throw 'expected DoubleStringExpr, got $expr';
		};
	}

	private function expectSingleString(expr:Null<HxExpr>):String {
		return switch expr {
			case SingleStringExpr(v): (v : String);
			case null, _: throw 'expected SingleStringExpr, got $expr';
		};
	}
}
