package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxMetadata;
import anyparse.grammar.haxe.HxMetadataUtil;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Tests for slice ω-toplevel-meta — extends `HxTopLevelDecl` with a
 * leading `@:trivia @:tryparse var meta:Array<HxMetadata>` Star, so
 * top-level `@:enum`, `@:allow(pack.Cls)`, `@test("foo")` etc. parse
 * before the `class`/`typedef`/`enum`/`interface`/`abstract` dispatch.
 * Mirror of the meta Star already on `HxMemberDecl`. Captures stay as
 * verbatim regex matches via `HxMetadata.PlainMeta(raw:HxMetaRaw)` —
 * the regex catch-all branch of the `HxMetadata` enum (structural
 * branches like `OverloadMeta` exist for compiler metas with
 * function-decl arguments).
 *
 * Capability-only target: corpus fixtures `popen_in_metadata.hxtest`
 * (`@:allow(pack.Base) @test("foo") class Main {}`) and
 * `try_catch_with_curly_next.hxtest` (`@:enum class Main {}`)
 * parse-unblock. They sit in the fail bucket waiting for orthogonal
 * writer-side policy slices (`metadataType: "after"`, `leftCurly: "both"`,
 * etc.) — out of scope for this slice.
 */
class HxToplevelMetaSliceTest extends HxTestHelpers {

	public function testSingleMetaOnClass():Void {
		final ast:HxModule = HaxeModuleParser.parse('@:enum class M {}');
		Assert.equals(1, ast.decls.length);
		Assert.equals(1, ast.decls[0].meta.length);
		Assert.equals('@:enum', HxMetadataUtil.source(ast.decls[0].meta[0]));
		switch ast.decls[0].decl {
			case ClassDecl(_): Assert.pass();
			case _: Assert.fail('expected ClassDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testMultipleMetasOnClass():Void {
		final ast:HxModule = HaxeModuleParser.parse('@:allow(pack.Base) @test("foo") class Main {}');
		Assert.equals(1, ast.decls.length);
		Assert.equals(2, ast.decls[0].meta.length);
		Assert.equals('@:allow(pack.Base)', HxMetadataUtil.source(ast.decls[0].meta[0]));
		Assert.equals('@test("foo")', HxMetadataUtil.source(ast.decls[0].meta[1]));
	}

	public function testMetaThenModifierOnClass():Void {
		final ast:HxModule = HaxeModuleParser.parse('@:keep private class M {}');
		Assert.equals(1, ast.decls[0].meta.length);
		Assert.equals('@:keep', HxMetadataUtil.source(ast.decls[0].meta[0]));
		Assert.equals(1, ast.decls[0].modifiers.length);
	}

	public function testMetaOnTypedef():Void {
		final ast:HxModule = HaxeModuleParser.parse('@:keep typedef T = Int;');
		Assert.equals(1, ast.decls[0].meta.length);
		switch ast.decls[0].decl {
			case TypedefDecl(_): Assert.pass();
			case _: Assert.fail('expected TypedefDecl');
		}
	}

	public function testMetaOnEnum():Void {
		final ast:HxModule = HaxeModuleParser.parse('@:enum enum E {A;B;}');
		Assert.equals(1, ast.decls[0].meta.length);
		switch ast.decls[0].decl {
			case EnumDecl(_): Assert.pass();
			case _: Assert.fail('expected EnumDecl');
		}
	}

	public function testMetaOnAbstract():Void {
		final ast:HxModule = HaxeModuleParser.parse('@:keep abstract A(Int) {}');
		Assert.equals(1, ast.decls[0].meta.length);
		switch ast.decls[0].decl {
			case AbstractDecl(_): Assert.pass();
			case _: Assert.fail('expected AbstractDecl');
		}
	}

	public function testMetaOnInterface():Void {
		final ast:HxModule = HaxeModuleParser.parse('@:keep interface I {}');
		Assert.equals(1, ast.decls[0].meta.length);
		switch ast.decls[0].decl {
			case InterfaceDecl(_): Assert.pass();
			case _: Assert.fail('expected InterfaceDecl');
		}
	}

	public function testNoMetaRegression():Void {
		final ast:HxModule = HaxeModuleParser.parse('class M {}');
		Assert.equals(0, ast.decls[0].meta.length);
		Assert.equals(0, ast.decls[0].modifiers.length);
	}

	public function testPackageImportThenMetaClass():Void {
		final ast:HxModule = HaxeModuleParser.parse('package foo;\nimport bar.Baz;\n@:enum class M {}');
		Assert.equals(3, ast.decls.length);
		Assert.equals(1, ast.decls[2].meta.length);
		Assert.equals('@:enum', HxMetadataUtil.source(ast.decls[2].meta[0]));
	}

	public function testWriterEmitsSingleMeta():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('@:enum class M {}'));
		Assert.equals('@:enum class M {}\n', out);
	}

	public function testWriterEmitsTwoMetas():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('@:allow(pack.Base) @test("foo") class Main {}'));
		Assert.equals('@:allow(pack.Base) @test("foo") class Main {}\n', out);
	}

	public function testWriterEmitsMetaWithModifier():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('@:keep private class M {}'));
		Assert.equals('@:keep private class M {}\n', out);
	}

	public function testRoundTripMetaClass():Void {
		roundTrip('@:enum class M {}');
	}

	public function testRoundTripMetaTypedef():Void {
		roundTrip('@:keep typedef T = Int;');
	}

	public function testRoundTripMetasOnClass():Void {
		roundTrip('@:allow(pack.Base) @test("foo") class Main {}');
	}

	public function testRoundTripMetaWithModifier():Void {
		roundTrip('@:keep private class M {}');
	}

	public function testRoundTripPackageImportMetaClass():Void {
		roundTrip('package foo;\nimport bar.Baz;\n@:enum class M {}');
	}

}
