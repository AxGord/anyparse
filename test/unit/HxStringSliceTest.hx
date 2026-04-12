package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFastParser;
import anyparse.grammar.haxe.HaxeModuleFastParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxInterpString;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxStringSegment;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 string literal tests for the macro-generated Haxe parser.
 *
 * Validates double-quoted and single-quoted string literal atoms wired
 * into `HxExpr`. Double-quoted strings use `HxDoubleStringLit` (flat
 * String via `@:decode`). Single-quoted strings use `HxInterpString`
 * (declarative grammar: `HxStringSegment` enum with `Literal`, `Dollar`,
 * `Block`, `Ident` branches, parsed between `'` delimiters by the macro
 * pipeline with `@:raw` whitespace suppression).
 *
 * Test source strings use double-quoted Haxe strings so that `$` is
 * literal (no interpolation by the Haxe compiler). The inner
 * single-quoted strings are what the anyparse parser sees.
 */
class HxStringSliceTest extends HxTestHelpers {

	// ======== double-quoted (unchanged from v1 — flat String) ========

	/** Empty double-quoted string `""` -> decoded to `""`. */
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

	// ======== single-quoted — structured Array<HxStringSegment> ========

	/** Empty single-quoted string `''` -> empty parts array. */
	public function testSingleEmpty():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = ''; }").init);
		Assert.equals(0, parts.length);
	}

	/** Simple single-quoted string `'hello'` -> one Literal part. */
	public function testSingleSimple():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = 'hello'; }").init);
		Assert.equals(1, parts.length);
		assertLiteral(parts[0], 'hello');
	}

	/** Escape sequences in single-quoted string: `\n`, `\'`, `\\`. */
	public function testSingleEscapes():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = 'a\\nb\\'c\\\\d'; }").init);
		Assert.equals(1, parts.length);
		assertLiteral(parts[0], "a\nb'c\\d");
	}

	/** `$$` in single-quoted string -> Dollar segment. */
	public function testSingleEscapedDollar():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = 'cost: $$5'; }").init);
		Assert.equals(3, parts.length);
		assertLiteral(parts[0], 'cost: ');
		assertDollar(parts[1]);
		assertLiteral(parts[2], '5');
	}

	// ======== interpolation — $ident ========

	/** `'hello $name'` -> [Literal("hello "), Ident("name")]. */
	public function testInterpIdent():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = 'hello $name'; }").init);
		Assert.equals(2, parts.length);
		assertLiteral(parts[0], 'hello ');
		assertIdent(parts[1], 'name');
	}

	/** `'$x world'` -> [Ident("x"), Literal(" world")]. */
	public function testInterpIdentAtStart():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = '$x world'; }").init);
		Assert.equals(2, parts.length);
		assertIdent(parts[0], 'x');
		assertLiteral(parts[1], ' world');
	}

	/** `'$name'` -> [Ident("name")]. */
	public function testInterpIdentAlone():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = '$name'; }").init);
		Assert.equals(1, parts.length);
		assertIdent(parts[0], 'name');
	}

	/** `'$_foo'` -> [Ident("_foo")] — underscore-prefixed identifier. */
	public function testInterpIdentUnderscore():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = '$_foo'; }").init);
		Assert.equals(1, parts.length);
		assertIdent(parts[0], '_foo');
	}

	/** `'$a and $b'` -> [Ident("a"), Literal(" and "), Ident("b")]. */
	public function testInterpMultipleIdents():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = '$a and $b'; }").init);
		Assert.equals(3, parts.length);
		assertIdent(parts[0], 'a');
		assertLiteral(parts[1], ' and ');
		assertIdent(parts[2], 'b');
	}

	// ======== interpolation — ${expr} ========

	/** `'${x + 1}'` -> [Block(Add(IdentExpr, IntLit))]. */
	public function testInterpBlock():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = '${x + 1}'; }").init);
		Assert.equals(1, parts.length);
		switch parts[0] {
			case Block(expr):
				switch expr {
					case Add(left, right):
						Assert.isTrue(left.match(IdentExpr(_)));
						Assert.isTrue(right.match(IntLit(_)));
					case null, _:
						Assert.fail('expected Add, got $expr');
				}
			case _:
				Assert.fail('expected Block, got ${parts[0]}');
		}
	}

	/** `'${}'` -> empty block: expression parse inside `${}`. */
	public function testInterpBlockIdent():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = '${name}'; }").init);
		Assert.equals(1, parts.length);
		switch parts[0] {
			case Block(expr):
				Assert.isTrue(expr.match(IdentExpr(_)));
			case _:
				Assert.fail('expected Block, got ${parts[0]}');
		}
	}

	// ======== interpolation — mixed ========

	/** `'hello $name, age ${x + 1}!'` -> 5 parts. */
	public function testInterpMixed():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(
			parseSingleVarDecl("class Foo { var x:String = 'hello $name, age ${x + 1}!'; }").init
		);
		Assert.equals(5, parts.length);
		assertLiteral(parts[0], 'hello ');
		assertIdent(parts[1], 'name');
		assertLiteral(parts[2], ', age ');
		Assert.isTrue(parts[3].match(Block(_)));
		assertLiteral(parts[4], '!');
	}

	/** `'$$$name'` -> [Dollar, Ident("name")] — escaped dollar then ident. */
	public function testInterpDollarBeforeIdent():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = '$$$name'; }").init);
		Assert.equals(2, parts.length);
		assertDollar(parts[0]);
		assertIdent(parts[1], 'name');
	}

	/** Whitespace preserved inside string — spaces are literal. */
	public function testPreservesInternalWhitespace():Void {
		final parts:Array<HxStringSegment> = expectSingleParts(parseSingleVarDecl("class Foo { var x:String = '  hello  '; }").init);
		Assert.equals(1, parts.length);
		assertLiteral(parts[0], '  hello  ');
	}

	// ======== cross-cutting ========

	/** String concatenation: `"a" + 'b'` -> `Add(DoubleStringExpr, SingleStringExpr)`. */
	public function testStringConcat():Void {
		final decl:HxVarDecl = parseSingleVarDecl("class Foo { var x:String = \"hello\" + 'world'; }");
		switch decl.init {
			case Add(left, right):
				assertDoubleString(left, 'hello');
				final parts:Array<HxStringSegment> = expectSingleParts(right);
				Assert.equals(1, parts.length);
				assertLiteral(parts[0], 'world');
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

	/** Whitespace around string literal (outside the string). */
	public function testWhitespace():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:String =   "hi"  ; }');
		assertDoubleString(decl.init, 'hi');
	}

	/** Module-root integration with interpolated single-quoted string. */
	public function testModuleIntegration():Void {
		final source:String = "class A { var s:String = \"hello\"; } class B { var t:String = '$name'; }";
		final mod:HxModule = HaxeModuleFastParser.parse(source);
		Assert.equals(2, mod.decls.length);
		final a:HxClassDecl = expectClassDecl(mod.decls[0]);
		final b:HxClassDecl = expectClassDecl(mod.decls[1]);
		final va:HxVarDecl = expectVarMember(a.members[0].member);
		final vb:HxVarDecl = expectVarMember(b.members[0].member);
		assertDoubleString(va.init, 'hello');
		final parts:Array<HxStringSegment> = expectSingleParts(vb.init);
		Assert.equals(1, parts.length);
		assertIdent(parts[0], 'name');
	}

	/** Unterminated double-quoted string -> rejection. */
	public function testRejectsUnterminatedDouble():Void {
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:String = "hello; }'), ParseError);
	}

	/** Unterminated single-quoted string -> rejection. */
	public function testRejectsUnterminatedSingle():Void {
		Assert.raises(() -> HaxeFastParser.parse("class Foo { var x:String = 'hello; }"), ParseError);
	}

	// -------- assertion helpers --------

	private function assertDoubleString(expr:Null<HxExpr>, expected:String):Void {
		final s:String = expectDoubleString(expr);
		Assert.equals(expected, s);
	}

	private function expectDoubleString(expr:Null<HxExpr>):String {
		return switch expr {
			case DoubleStringExpr(v): (v : String);
			case null, _: throw 'expected DoubleStringExpr, got $expr';
		};
	}

	private function expectSingleParts(expr:Null<HxExpr>):Array<HxStringSegment> {
		return switch expr {
			case SingleStringExpr(v): v.parts;
			case null, _: throw 'expected SingleStringExpr, got $expr';
		};
	}

	private function assertLiteral(part:HxStringSegment, expected:String):Void {
		switch part {
			case Literal(s): Assert.equals(expected, (s : String));
			case _: Assert.fail('expected Literal, got $part');
		}
	}

	private function assertIdent(part:HxStringSegment, expected:String):Void {
		switch part {
			case Ident(name): Assert.equals(expected, (name : String));
			case _: Assert.fail('expected Ident, got $part');
		}
	}

	private function assertDollar(part:HxStringSegment):Void {
		switch part {
			case Dollar:
			case _: Assert.fail('expected Dollar, got $part');
		}
	}
}
