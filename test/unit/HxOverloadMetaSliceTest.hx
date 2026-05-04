package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxMetadata;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Tests for the structural `@:overload(function...)` metadata branch
 * (`HxMetadata.OverloadMeta`). Routes the metadata arg through
 * `HxOverloadFn` so format-driven knobs (`typeHintColon`, etc.) apply
 * — pre-slice the entire metadata was captured verbatim via a regex
 * abstract, leaving source spaces inside `(key : String)` un-normalized.
 *
 * Companion fixture: `whitespace/issue_184_type_hint_in_overload.hxtest`
 * in the haxe-formatter fork — flips from byte-diff @ 40 to PASS once
 * the structural branch tightens the type-hint colons.
 *
 * The fallback `PlainMeta` path is exercised by `HxToplevelMetaSliceTest`
 * (and `HxMetaExprSliceTest.testTriviaRoundTripByteExact` which uses
 * the malformed `@:overload(function())` body-less form that rolls
 * back through `tryBranch` to the regex catch-all).
 */
class HxOverloadMetaSliceTest extends HxTestHelpers {

	public function testParsesOverloadAsStructuralVariant():Void {
		final src:String = 'class M {\n\t@:overload(function<T>(key:String):T {})\n\tfunction get<T>(key:String):Null<T>;\n}';
		final ast:HxModule = HaxeModuleParser.parse(src);
		final m:HxMetadata = expectClassMembers(ast)[0].meta[0];
		switch m {
			case OverloadMeta(_): Assert.pass();
			case _: Assert.fail('expected OverloadMeta, got $m');
		}
	}

	public function testParsesNonOverloadAsPlainVariant():Void {
		final ast:HxModule = HaxeModuleParser.parse('@:keep class M {}');
		final m:HxMetadata = ast.decls[0].meta[0];
		switch m {
			case PlainMeta(_): Assert.pass();
			case _: Assert.fail('expected PlainMeta, got $m');
		}
	}

	public function testWriterTightensTypeHintColons():Void {
		final src:String = 'class M {\n\t@:overload(function<T>(key : String, defaultValue : T):T {})\n\tfunction get<T>(key:String):Null<T>;\n}';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(out.indexOf('key:String') >= 0);
		Assert.isTrue(out.indexOf('defaultValue:T') >= 0);
		Assert.isFalse(out.indexOf('key : String') >= 0);
		Assert.isFalse(out.indexOf('defaultValue : T') >= 0);
	}

	public function testWriterEmitsNoSpaceBetweenFunctionAndTypeParams():Void {
		final src:String = 'class M {\n\t@:overload(function<T>(key:String):T {})\n\tfunction get<T>(key:String):Null<T>;\n}';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(out.indexOf('function<T>') >= 0);
	}

	public function testWriterEmitsNoSpaceBetweenFunctionAndOpenParen():Void {
		final src:String = 'class M {\n\t@:overload(function(key:String):T {})\n\tfunction get(key:String):Null<T>;\n}';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(out.indexOf('function(') >= 0);
	}

	public function testRoundTripStructuralOverload():Void {
		final src:String = 'class M {\n\t@:overload(function<T>(key:String):T {})\n\tfunction get<T>(key:String):Null<T>;\n}';
		roundTrip(src);
	}

	public function testRoundTripMalformedOverloadFallsBackToPlain():Void {
		final src:String = 'class M {\n\t@:overload(function())\n\tfunction get():Void;\n}';
		roundTrip(src);
	}

	private function expectClassMembers(ast:HxModule) {
		return switch ast.decls[0].decl {
			case ClassDecl(c): c.members;
			case _: throw 'expected ClassDecl, got ${ast.decls[0].decl}';
		};
	}

}
