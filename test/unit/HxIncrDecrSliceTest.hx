package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice ω-incr-decr — pre/post increment & decrement (`++a`, `--a`,
 * `a++`, `a--`).
 *
 * Four new `HxExpr` constructors: `PreIncr`/`PreDecr` as `@:prefix`
 * (declared before `@:prefix('-')` Neg — prefix branches dispatch in
 * declaration order with no longest-match sort, so `--` must precede
 * `-`), and `PostIncr`/`PostDecr` as bare single-literal `@:postfix`
 * (no close delimiter, no suffix child). The latter shape required
 * lifting the `Lowering` postfix fold's hard `fatalError` on
 * single-child branches without a close pair into a real
 * `left = Ctor(left)` body (`ω-postfix-single-literal`).
 *
 * Regression guards lock in that infix `+`/`-` and prefix `-` are not
 * cannibalised by the longer `++`/`--` literals — the postfix dispatch
 * already prepends `!peekLit(longerOp)` guards and the Pratt loop
 * longest-sorts, while prefix relies on declaration order.
 */
@:nullSafety(Strict)
class HxIncrDecrSliceTest extends HxTestHelpers {

	public function testPostIncrIdent(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a++; }');
		switch decl.init {
			case PostIncr(IdentExpr(v)):
				Assert.equals('a', (v: String));
			case null, _:
				Assert.fail('expected PostIncr(IdentExpr(a)), got ${decl.init}');
		}
	}

	public function testPostDecrIdent(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a--; }');
		switch decl.init {
			case PostDecr(IdentExpr(v)):
				Assert.equals('a', (v: String));
			case null, _:
				Assert.fail('expected PostDecr(IdentExpr(a)), got ${decl.init}');
		}
	}

	public function testPreIncrIdent(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = ++a; }');
		switch decl.init {
			case PreIncr(IdentExpr(v)):
				Assert.equals('a', (v: String));
			case null, _:
				Assert.fail('expected PreIncr(IdentExpr(a)), got ${decl.init}');
		}
	}

	public function testPreDecrIdent(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = --a; }');
		switch decl.init {
			case PreDecr(IdentExpr(v)):
				Assert.equals('a', (v: String));
			case null, _:
				Assert.fail('expected PreDecr(IdentExpr(a)), got ${decl.init}');
		}
	}

	public function testPostIncrOnFieldAccess(): Void {
		// Postfix `++` composes after the postfix `.field` chain:
		// `obj.count++` → PostIncr(FieldAccess(obj, count)).
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = obj.count++; }');
		switch decl.init {
			case PostIncr(FieldAccess(IdentExpr(o), f)):
				Assert.equals('obj', (o: String));
				Assert.equals('count', (f: String));
			case null, _:
				Assert.fail('expected PostIncr(FieldAccess(obj, count)), got ${decl.init}');
		}
	}

	public function testPostIncrInfixBinding(): Void {
		// `a++ + b` → Add(PostIncr(a), b): postfix binds tighter than
		// the infix `+`, and the infix `+` is not eaten by `++`.
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a++ + b; }');
		switch decl.init {
			case Add(PostIncr(IdentExpr(a)), IdentExpr(b)):
				Assert.equals('a', (a: String));
				Assert.equals('b', (b: String));
			case null, _:
				Assert.fail('expected Add(PostIncr(a), b), got ${decl.init}');
		}
	}

	public function testInfixPlusNotCannibalised(): Void {
		// Regression: bare infix `+` still parses as Add, not as a
		// stray `++` prefix/postfix.
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a + b; }');
		switch decl.init {
			case Add(IdentExpr(a), IdentExpr(b)):
				Assert.equals('a', (a: String));
				Assert.equals('b', (b: String));
			case null, _:
				Assert.fail('expected Add(a, b), got ${decl.init}');
		}
	}

	public function testPrefixMinusNotCannibalised(): Void {
		// Regression: prefix `-5` stays Neg — `--` is declared before
		// `-` but `expectLit('--')` fails on `-5` and rolls back to Neg.
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = -5; }');
		switch decl.init {
			case Neg(IntLit(v)):
				Assert.equals(5, (v: Int));
			case null, _:
				Assert.fail('expected Neg(IntLit(5)), got ${decl.init}');
		}
	}

	public function testInfixMinusNotCannibalised(): Void {
		// Regression: infix `i - 1` stays Sub, not eaten by `--`.
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = i - 1; }');
		switch decl.init {
			case Sub(IdentExpr(i), IntLit(one)):
				Assert.equals('i', (i: String));
				Assert.equals(1, (one: Int));
			case null, _:
				Assert.fail('expected Sub(i, 1), got ${decl.init}');
		}
	}

	public function testWriterEmitsPostfixForm(): Void {
		// Source form is preserved: `a++` writes as `a++`, not `++a`.
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('class Foo { function m():Void { a++; } }'));
		Assert.isTrue(out.indexOf('a++') != -1, 'expected `a++` in: <$out>');
	}

	public function testWriterEmitsPrefixForm(): Void {
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('class Foo { function m():Void { --a; } }'));
		Assert.isTrue(out.indexOf('--a') != -1, 'expected `--a` in: <$out>');
	}

	public function testRoundTrip(): Void {
		roundTrip('class Foo { function m():Void { a++; } }', 'post-incr');
		roundTrip('class Foo { function m():Void { a--; } }', 'post-decr');
		roundTrip('class Foo { function m():Void { ++a; } }', 'pre-incr');
		roundTrip('class Foo { function m():Void { --a; } }', 'pre-decr');
		roundTrip('class Foo { function m():Void { while (--i >= 0) trace(i); } }', 'pre-decr-cond');
		roundTrip('class Foo { function m():Void { var k:Int = j++ + 1; } }', 'post-incr-infix');
		roundTrip('class Foo { function m():Void { obj.count++; } }', 'post-incr-field');
		roundTrip('class Foo { function m():Void { var s:Int = a + b; } }', 'infix-plus-unaffected');
	}

}
