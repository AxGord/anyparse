package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice apq-P5-L (tail): macro `: Type` type-reification expression.
 *
 * One new `HxExpr` atom ctor, declared before `MacroExpr`:
 *
 *  - `MacroTypeExpr` — `macro : Type` (`@:kw('macro') @:lead(':')`),
 *    a single cross-type Ref to `HxType`.
 *
 * The asymmetric cross-type Ref (right operand is `HxType`, not
 * `HxExpr`) flows through the generic single-Ref atom path the same
 * way `MacroExpr(operand:HxExpr)` and `HxArrowParamBody.type:HxType`
 * do — no Lowering/writer/synth change. `is`-operator's asymmetric
 * special-casing is INFIX-recursion-only, not needed for an atom.
 *
 * Asserts the type shape (`Named` / parametrized / function /
 * anon), `tryBranch` disambiguation (`macro x + 1` stays `MacroExpr`,
 * `macro {…}` stays a block, `macro macro : Int` nests), and
 * round-trip idempotency.
 */
class HxMacroTypeExprSliceTest extends HxTestHelpers {

	public function testMacroTypeSimple(): Void {
		switch initOf('class C { var x = macro : Int; }') {
			case MacroTypeExpr(t):
				Assert.equals('Int', namedOf(t));
			case e:
				Assert.fail('expected MacroTypeExpr(Int), got $e');
		}
	}

	public function testMacroTypeParametrized(): Void {
		switch initOf('class C { var x = macro : Array<String>; }') {
			case MacroTypeExpr(Named(ref)):
				Assert.equals('Array', (ref.name: String));
				Assert.equals(1, ref.params == null ? 0 : ref.params.length);
			case e:
				Assert.fail('expected MacroTypeExpr(Named(Array<String>)), got $e');
		}
	}

	public function testMacroTypeMap(): Void {
		switch initOf('class C { var x = macro : Map<String, Int>; }') {
			case MacroTypeExpr(Named(ref)):
				Assert.equals('Map', (ref.name: String));
				Assert.equals(2, ref.params == null ? 0 : ref.params.length);
			case e:
				Assert.fail('expected MacroTypeExpr(Named(Map<String,Int>)), got $e');
		}
	}

	public function testMacroTypeFunction(): Void {
		switch initOf('class C { var x = macro : Int -> Void; }') {
			case MacroTypeExpr(Arrow(l, r)):
				Assert.equals('Int', namedOf(l));
				Assert.equals('Void', namedOf(r));
			case e:
				Assert.fail('expected MacroTypeExpr(Arrow(Int, Void)), got $e');
		}
	}

	public function testMacroTypeAnon(): Void {
		switch initOf('class C { var x = macro : {y:Int}; }') {
			case MacroTypeExpr(Anon(fields)):
				Assert.equals(1, fields.length);
			case e:
				Assert.fail('expected MacroTypeExpr(Anon), got $e');
		}
	}

	public function testMacroExprStillExpr(): Void {
		// `macro` not followed by `:` rolls back to MacroExpr.
		switch initOf('class C { var x = macro a + 1; }') {
			case MacroExpr(Add(_, _)):
				Assert.pass();
			case e:
				Assert.fail('expected MacroExpr(Add), got $e');
		}
	}

	public function testMacroBlockStillBlock(): Void {
		switch initOf('class C { var x = macro { a; }; }') {
			case MacroExpr(BlockExpr(_)):
				Assert.pass();
			case e:
				Assert.fail('expected MacroExpr(BlockExpr), got $e');
		}
	}

	public function testMacroTypeNestedInMacro(): Void {
		// Outer `macro` -> `:` lead fails (sees `macro`) -> MacroExpr;
		// its operand `macro : Int` then parses as MacroTypeExpr.
		switch initOf('class C { var x = macro macro : Int; }') {
			case MacroExpr(MacroTypeExpr(t)):
				Assert.equals('Int', namedOf(t));
			case e:
				Assert.fail('expected MacroExpr(MacroTypeExpr(Int)), got $e');
		}
	}

	public function testMacroTypeRoundTrip(): Void {
		roundTrip(
			'class C { static function f() { var a = macro : Int; var b = macro : Array<String>; var c = macro : Int -> Void; var d = macro foo; } }',
			'L-macro-type'
		);
	}

	private function initOf(source: String): HxExpr {
		final decl: HxVarDecl = parseSingleVarDecl(source);
		return switch decl.init {
			case null: throw 'expected init expr, got null';
			case e: e;
		}
	}

	private function namedOf(t: HxType): String {
		return switch t {
			case Named(ref): (ref.name: String);
			case e: throw 'expected Named type, got $e';
		}
	}

}
