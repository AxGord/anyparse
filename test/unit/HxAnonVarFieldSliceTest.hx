package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxAnonField;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice A + Slice 0 — class-notation `var` / `final` fields in
 * anonymous structure types, single AND multi.
 *
 * `HxType.Anon` opts into `@:sepAlt(';')`, so the non-trivia
 * build (`HaxeParser`, and the span parser `apq` uses) runs a
 * close-driven loop that consumes an OPTIONAL `,` OR `;` between
 * fields plus an optional trailing separator. The dominant
 * anyparse-schema shape `{ var a:T; var b:T; }` now parses, as do
 * `;`-separated short fields, mixed, classic `,`, and `{}`.
 *
 * Validation is a fresh in-suite compiled assertion (the suite
 * recompiles parser + writer), never a diff of the prebuilt
 * `bin/apq.n` against itself. `;`-form writer round-trip is
 * deliberately NOT asserted — the writer emits the canonical `,`
 * separator (per-element sep preservation is deferred to Phase 4
 * transforms); only the `,`-forms are round-tripped.
 */
class HxAnonVarFieldSliceTest extends HxTestHelpers {

	private function anonOf(source:String):Array<HxAnonField> {
		final ast:HxClassDecl = HaxeParser.parse(source);
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		return expectAnon(v.type);
	}

	public function testSingleVarField():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{ var x:Int; }; }');
		Assert.equals(1, fields.length);
		final decl:HxVarDecl = expectVarField(fields[0]);
		Assert.equals('x', (decl.name : String));
		Assert.equals('Int', (expectNamedType(decl.type).name : String));
	}

	public function testSingleFinalField():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{ final y:String; }; }');
		Assert.equals(1, fields.length);
		final decl:HxVarDecl = expectFinalField(fields[0]);
		Assert.equals('y', (decl.name : String));
		Assert.equals('String', (expectNamedType(decl.type).name : String));
	}

	public function testShortFieldsStillComma():Void {
		// Regression guard: the classic `,`-separated short form is
		// unaffected by the tolerant @:sepAlt loop.
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{x:Int, y:String}; }');
		Assert.equals(2, fields.length);
		switch fields[0] {
			case Required(body): Assert.equals('x', (body.name : String));
			case _: Assert.fail('expected Required short field at index 0');
		}
	}

	public function testMultiVarFieldsSemicolon():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{ var a:Int; var b:String; }; }');
		Assert.equals(2, fields.length);
		final a:HxVarDecl = expectVarField(fields[0]);
		final b:HxVarDecl = expectVarField(fields[1]);
		Assert.equals('a', (a.name : String));
		Assert.equals('Int', (expectNamedType(a.type).name : String));
		Assert.equals('b', (b.name : String));
		Assert.equals('String', (expectNamedType(b.type).name : String));
	}

	public function testMultiFinalFieldsSemicolon():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{ final x:Int; final y:Bool; }; }');
		Assert.equals(2, fields.length);
		Assert.equals('x', (expectFinalField(fields[0]).name : String));
		Assert.equals('y', (expectFinalField(fields[1]).name : String));
	}

	public function testMixedVarAndShortSemicolon():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{ var a:Int; b:Float }; }');
		Assert.equals(2, fields.length);
		Assert.equals('a', (expectVarField(fields[0]).name : String));
		switch fields[1] {
			case Required(body): Assert.equals('b', (body.name : String));
			case _: Assert.fail('expected Required short field at index 1');
		}
	}

	public function testRequiredSemicolonSeparated():Void {
		// `;` not field-eaten here (Required has no @:trail) — the loop
		// consumes it as the alt separator.
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{a:Int; b:Float}; }');
		Assert.equals(2, fields.length);
		switch fields[0] {
			case Required(body): Assert.equals('a', (body.name : String));
			case _: Assert.fail('expected Required short field at index 0');
		}
		switch fields[1] {
			case Required(body): Assert.equals('b', (body.name : String));
			case _: Assert.fail('expected Required short field at index 1');
		}
	}

	public function testTrailingCommaTolerated():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{x:Int, y:String,}; }');
		Assert.equals(2, fields.length);
	}

	public function testEmptyAnon():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{}; }');
		Assert.equals(0, fields.length);
	}

	public function testNestedSemicolonAnon():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{ var inner:{ var a:Int; var b:Int; }; }; }');
		Assert.equals(1, fields.length);
		final innerDecl:HxVarDecl = expectVarField(fields[0]);
		final inner:Array<HxAnonField> = expectAnon(innerDecl.type);
		Assert.equals(2, inner.length);
		Assert.equals('a', (expectVarField(inner[0]).name : String));
		Assert.equals('b', (expectVarField(inner[1]).name : String));
	}

	public function testSingleFnFieldNoBody():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{ function f():Void; }; }');
		Assert.equals(1, fields.length);
		final decl:HxFnDecl = expectFnField(fields[0]);
		Assert.equals('f', (decl.name : String));
		Assert.equals(0, decl.params.length);
		Assert.equals('Void', (expectNamedType(decl.returnType).name : String));
		Assert.isTrue(decl.body.match(NoBody));
	}

	public function testFnFieldWithParams():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{ function g(a:Int):Bool; }; }');
		Assert.equals(1, fields.length);
		final decl:HxFnDecl = expectFnField(fields[0]);
		Assert.equals('g', (decl.name : String));
		Assert.equals(1, decl.params.length);
		Assert.equals('Bool', (expectNamedType(decl.returnType).name : String));
	}

	public function testMultiFnFieldsSemicolon():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{ function a():Int; function b():String; }; }');
		Assert.equals(2, fields.length);
		Assert.equals('a', (expectFnField(fields[0]).name : String));
		Assert.equals('b', (expectFnField(fields[1]).name : String));
	}

	public function testMixedFnAndShortForm():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{ function f():Int; name:String }; }');
		Assert.equals(2, fields.length);
		Assert.equals('f', (expectFnField(fields[0]).name : String));
		switch fields[1] {
			case Required(body): Assert.equals('name', (body.name : String));
			case _: Assert.fail('expected Required short field at index 1');
		}
	}

	public function testMixedVarAndFnSemicolon():Void {
		final fields:Array<HxAnonField> = anonOf('class Foo { var s:{ var x:Int; function g(a:Int):Bool; }; }');
		Assert.equals(2, fields.length);
		Assert.equals('x', (expectVarField(fields[0]).name : String));
		Assert.equals('g', (expectFnField(fields[1]).name : String));
	}

	public function testCommaFormsRoundTrip():Void {
		roundTrip('class Foo { var s:{ var x:Int; }; }', 'single-var');
		roundTrip('class Foo { var s:{ final y:String; }; }', 'single-final');
		roundTrip('class Foo { var s:{x:Int, y:String}; }', 'short-comma');
	}
}
