package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxAnonField;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice A — class-notation `var` / `final` fields in anonymous
 * structure types: `{ var name:T; }`, `{ final name:T; }`.
 *
 * SCOPE LIMIT (deliberate): only the SINGLE-field case is exercised.
 * The `HxType.Anon` Star is strictly `,`-separated in plain/fast mode
 * (`Lowering.hx:1376` hard-requires the `@:sep` char), so a
 * `;`-terminated class-notation field followed by another field with
 * no comma — the dominant anyparse-schema shape `{ var a:T; var b:T; }`
 * — does NOT yet parse. Multi `;`-separated fields require a core
 * separator change tracked as a separate slice; asserting them here
 * would test behavior that is correctly out of this slice's scope.
 *
 * Validation is a fresh in-suite compiled assertion (the suite
 * recompiles parser + writer), never a diff of the prebuilt
 * `bin/apq.n` against itself.
 */
class HxAnonVarFieldSliceTest extends HxTestHelpers {

	private function expectVarField(field:HxAnonField):HxVarDecl {
		return switch field {
			case VarField(decl): decl;
			case _: throw 'expected HxAnonField.VarField, got $field';
		};
	}

	private function expectFinalField(field:HxAnonField):HxVarDecl {
		return switch field {
			case FinalField(decl): decl;
			case _: throw 'expected HxAnonField.FinalField, got $field';
		};
	}

	public function testSingleVarField():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{ var x:Int; }; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields:Array<HxAnonField> = expectAnon(v.type);
		Assert.equals(1, fields.length);
		final decl:HxVarDecl = expectVarField(fields[0]);
		Assert.equals('x', (decl.name : String));
		Assert.equals('Int', (expectNamedType(decl.type).name : String));
	}

	public function testSingleFinalField():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{ final y:String; }; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields:Array<HxAnonField> = expectAnon(v.type);
		Assert.equals(1, fields.length);
		final decl:HxVarDecl = expectFinalField(fields[0]);
		Assert.equals('y', (decl.name : String));
		Assert.equals('String', (expectNamedType(decl.type).name : String));
	}

	public function testShortFieldsStillComma():Void {
		// Regression guard: the original `,`-separated short form is
		// unaffected by the new branches.
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{x:Int, y:String}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields:Array<HxAnonField> = expectAnon(v.type);
		Assert.equals(2, fields.length);
		switch fields[0] {
			case Required(body): Assert.equals('x', (body.name : String));
			case _: Assert.fail('expected Required short field at index 0');
		}
	}

	public function testSingleVarFieldRoundTrip():Void {
		roundTrip('class Foo { var s:{ var x:Int; }; }', 'single-var');
		roundTrip('class Foo { var s:{ final y:String; }; }', 'single-final');
	}
}
