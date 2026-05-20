package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxTypeRef;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice apq-P5-L1: trailing separator before close in collection literals.
 *
 * Haxe accepts a trailing `,` in every collection-literal context
 * (`[1, 2,]`, `{a: 1,}`, `f(1, 2,)`, `Map<K, V,>`). The strict
 * plain-mode sep loops in `Lowering` consumed the sep then
 * unconditionally parsed the next element, so a trailing sep tried to
 * parse an element at the close literal and rolled the whole construct
 * back. Fix: after consuming a sep, peek the close — `if
 * (!($closeNotNextExpr)) break;` — in all four strict sep loops
 * (postfix-call args, Case-4 enum-Alt `ArrayExpr`, struct-field Star
 * `HxObjectLit.fields`, optional Star `HxTypeRef.params`). Mirrors the
 * break already present in the trivia-mode postfix loop.
 *
 * AST shape is unchanged — `_items` holds exactly the real elements.
 * Tests therefore assert element counts, plus regression guards that
 * the no-trailing-comma forms still parse and that round-trip is
 * idempotent.
 */
class HxTrailingSepSliceTest extends HxTestHelpers {

	// array literal (Case-4 enum-Alt ArrayExpr)

	public function testArrayTrailingComma():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x = [1, 2, 3,]; }');
		switch decl.init {
			case ArrayExpr(elems): Assert.equals(3, elems.length);
			case null, _: Assert.fail('expected ArrayExpr(3), got ${decl.init}');
		}
	}

	public function testArraySingleTrailingComma():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x = [1,]; }');
		switch decl.init {
			case ArrayExpr(elems): Assert.equals(1, elems.length);
			case null, _: Assert.fail('expected ArrayExpr(1), got ${decl.init}');
		}
	}

	// object literal (struct-field Star HxObjectLit.fields)

	public function testObjectTrailingComma():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {a: 1, b: 2,}; }');
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals(2, lit.fields.length);
				Assert.equals('a', (expectObjectFieldBody(lit.fields[0]).name : String));
				Assert.equals('b', (expectObjectFieldBody(lit.fields[1]).name : String));
			case null, _: Assert.fail('expected ObjectLit(2), got ${decl.init}');
		}
	}

	// call args (postfix-call args loop)

	public function testCallArgsTrailingComma():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x = g(1, 2,); }');
		switch decl.init {
			case Call(_, args): Assert.equals(2, args.length);
			case null, _: Assert.fail('expected Call(_, 2), got ${decl.init}');
		}
	}

	// type parameters (optional Star HxTypeRef.params)

	public function testTypeParamsTrailingComma():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Map<Int, String,>; }');
		final ref:HxTypeRef = switch decl.type {
			case Named(r): r;
			case null, _: throw 'expected Named type, got ${decl.type}';
		}
		Assert.equals(2, ref.params.length);
	}

	// regression: no-trailing-comma forms unaffected

	public function testNoTrailingCommaStillParses():Void {
		switch parseSingleVarDecl('class C { var x = [1, 2, 3]; }').init {
			case ArrayExpr(elems): Assert.equals(3, elems.length);
			case null, _: Assert.fail('array no-trail');
		}
		switch parseSingleVarDecl('class C { var x:Dynamic = {a: 1, b: 2}; }').init {
			case ObjectLit(lit): Assert.equals(2, lit.fields.length);
			case null, _: Assert.fail('object no-trail');
		}
		switch parseSingleVarDecl('class C { var x = g(1, 2); }').init {
			case Call(_, args): Assert.equals(2, args.length);
			case null, _: Assert.fail('call no-trail');
		}
	}

	// idempotency round-trip

	public function testTrailingCommaRoundTrip():Void {
		roundTrip('class C { var a = [1, 2, 3,]; var o:Dynamic = {p: 1, q: 2,}; function f() { g(1, 2,); } }', 'L1-trailing-sep');
	}
}
