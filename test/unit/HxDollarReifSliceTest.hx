package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice apq-P5-L (tail): macro `$`-reification expression escapes.
 *
 * Three new `HxExpr` ctors, an expression-position mirror of the
 * `HxStringSegment` interpolation grammar plus the named-reification
 * middle form:
 *
 *  - `DollarBlockExpr` — `${expr}` (`@:lead("${") @:trail("}")`).
 *  - `DollarReifExpr` — `$name{expr}` (`$i{}`/`$v{}`/`$p{}`/`$a{}`/
 *    `$b{}`/`$e{}`), `@:lead("$") @:trail("}")` with the field
 *    `expr` carrying `@:lead("{")`.
 *  - `DollarIdentExpr` — `$ident` (`@:lead("$")`).
 *
 * Purely syntactic — no reification semantics. Asserts each shape,
 * `tryBranch` disambiguation (`$x` vs `$i{…}` vs `${…}`), that postfix
 * still applies (`$type(e)`), that `macro` nesting is unaffected, and
 * round-trip idempotency. Source strings holding a literal `$` are
 * double-quoted so Haxe does not interpolate them.
 */
class HxDollarReifSliceTest extends HxTestHelpers {

	private function initOf(source:String):HxExpr {
		final decl:HxVarDecl = parseSingleVarDecl(source);
		return switch decl.init {
			case null: throw 'expected init expr, got null';
			case e: e;
		}
	}

	private function identOf(e:HxExpr):String {
		return switch e {
			case IdentExpr(v): (v : String);
			case null, _: throw 'expected IdentExpr, got $e';
		}
	}

	public function testDollarIdent():Void {
		switch initOf("class C { var x = $foo; }") {
			case DollarIdentExpr(name): Assert.equals('foo', (name : String));
			case e: Assert.fail('expected DollarIdentExpr, got $e');
		}
	}

	public function testDollarBlock():Void {
		switch initOf("class C { var x = ${expr}; }") {
			case DollarBlockExpr(inner): Assert.equals('expr', identOf(inner));
			case e: Assert.fail('expected DollarBlockExpr, got $e');
		}
	}

	public function testDollarBlockComplexExpr():Void {
		switch initOf("class C { var x = ${a + b}; }") {
			case DollarBlockExpr(Add(l, r)):
				Assert.equals('a', identOf(l));
				Assert.equals('b', identOf(r));
			case e: Assert.fail('expected DollarBlockExpr(Add), got $e');
		}
	}

	public function testDollarReifAllNames():Void {
		// Single-quoted: `$$` -> literal `$`, `$n` -> the loop variable.
		for (n in ['i', 'v', 'p', 'a', 'b', 'e']) {
			switch initOf('class C { var x = $$$n{body}; }') {
				case DollarReifExpr({name: name, expr: inner}):
					Assert.equals(n, (name : String));
					Assert.equals('body', identOf(inner));
				case e: Assert.fail('expected DollarReifExpr for $$$n{...}, got $e');
			}
		}
	}

	public function testDollarReifArrayBody():Void {
		// `$a{args}` is the array-splice reification; body is any expr.
		switch initOf("class C { var x = $a{[p, q]}; }") {
			case DollarReifExpr({name: name, expr: ArrayExpr(elems)}):
				Assert.equals('a', (name : String));
				Assert.equals(2, elems.length);
			case e: Assert.fail('expected DollarReifExpr(a, ArrayExpr), got $e');
		}
	}

	public function testDollarIdentPostfixCall():Void {
		// `$type(e)` — the bare `$ident` form, then a postfix Call.
		switch initOf("class C { var x = $type(e); }") {
			case Call(DollarIdentExpr(name), args):
				Assert.equals('type', (name : String));
				Assert.equals(1, args.length);
				Assert.equals('e', identOf(args[0]));
			case e: Assert.fail('expected Call(DollarIdentExpr(type), [e]), got $e');
		}
	}

	public function testMacroNesting():Void {
		// `macro $foo` must wrap the dollar atom, not break it.
		switch initOf("class C { var x = macro $foo; }") {
			case MacroExpr(DollarIdentExpr(name)): Assert.equals('foo', (name : String));
			case e: Assert.fail('expected MacroExpr(DollarIdentExpr(foo)), got $e');
		}
	}

	public function testPlainIdentRegressionUnaffected():Void {
		// No `$` — must still be a plain IdentExpr, not a dollar form.
		switch initOf('class C { var x = foo; }') {
			case IdentExpr(v): Assert.equals('foo', (v : String));
			case e: Assert.fail('expected IdentExpr(foo), got $e');
		}
	}

	public function testDollarReifRoundTrip():Void {
		roundTrip(
			"class C { static function f() { var a = macro $i{name}; var b = macro ${x + 1}; var c = macro $foo; } }",
			'L-dollar-reif'
		);
	}
}
