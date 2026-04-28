package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Tests for slice ω-toplevel-import-using — adds
 * `HxDecl.ImportDecl(path:HxTypeName)` and
 * `HxDecl.UsingDecl(path:HxTypeName)` so a Haxe module's leading
 * `import foo.bar.Baz;` and `using foo.bar.Util;` directives parse as
 * top-level decls. Each ctor carries `@:kw('import') / @:kw('using')`
 * plus `@:trail(';')`; the dotted-ident `HxTypeName` regex covers the
 * single-segment (`import L;`), sub-module (`import Module.SubType;`),
 * and pack-qualified (`import haxe.io.Bytes;`) forms in one match.
 *
 * Real Haxe restricts `import`/`using` to the leading section of a
 * module — the parser does not police that, just like for `package`.
 *
 * Out of scope: wildcard form `import haxe.*;`, aliased form
 * `import Std.is as isOfType;`, and the conditional shape
 * `import #if … #end …;`. Each is a separate slice — corpus fixtures
 * combining import with those (`imports_mult`, `issue_634_is_as_import`,
 * `issue_504_conditional_import`) remain skip-parse until those slices
 * land. Capability-only target for THIS slice: pure dotted-path form,
 * which unblocks `issue_257_return_*`×4 (package + import +
 * class), `issue_73_return_switch_if_expression` (pure import), and
 * `issue_256_keep_anon_function` (mixed import + using).
 */
class HxToplevelImportUsingSliceTest extends HxTestHelpers {

	public function testImportSingleSegment():Void {
		final ast:HxModule = HaxeModuleParser.parse('import L;');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case ImportDecl(path): Assert.equals('L', (path : String));
			case _: Assert.fail('expected ImportDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testImportDottedPath():Void {
		final ast:HxModule = HaxeModuleParser.parse('import haxe.io.Bytes;');
		switch ast.decls[0].decl {
			case ImportDecl(path): Assert.equals('haxe.io.Bytes', (path : String));
			case _: Assert.fail('expected ImportDecl');
		}
	}

	public function testImportSubModule():Void {
		final ast:HxModule = HaxeModuleParser.parse('import languageprovider.LanguageTranslations.L;');
		switch ast.decls[0].decl {
			case ImportDecl(path): Assert.equals('languageprovider.LanguageTranslations.L', (path : String));
			case _: Assert.fail('expected ImportDecl');
		}
	}

	public function testUsingSingleSegment():Void {
		final ast:HxModule = HaxeModuleParser.parse('using StringTools;');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case UsingDecl(path): Assert.equals('StringTools', (path : String));
			case _: Assert.fail('expected UsingDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testUsingDottedPath():Void {
		final ast:HxModule = HaxeModuleParser.parse('using tink.CoreApi;');
		switch ast.decls[0].decl {
			case UsingDecl(path): Assert.equals('tink.CoreApi', (path : String));
			case _: Assert.fail('expected UsingDecl');
		}
	}

	public function testPackageImportClass():Void {
		final ast:HxModule = HaxeModuleParser.parse('package foo;\nimport bar.Baz;\nclass C {}');
		Assert.equals(3, ast.decls.length);
		switch ast.decls[0].decl {
			case PackageDecl(_): Assert.pass();
			case _: Assert.fail('expected PackageDecl first');
		}
		switch ast.decls[1].decl {
			case ImportDecl(path): Assert.equals('bar.Baz', (path : String));
			case _: Assert.fail('expected ImportDecl second');
		}
		switch ast.decls[2].decl {
			case ClassDecl(_): Assert.pass();
			case _: Assert.fail('expected ClassDecl third');
		}
	}

	public function testImportThenUsingSequence():Void {
		final ast:HxModule = HaxeModuleParser.parse('import tink.state.Observable;\nusing tink.CoreApi;');
		Assert.equals(2, ast.decls.length);
		switch ast.decls[0].decl {
			case ImportDecl(path): Assert.equals('tink.state.Observable', (path : String));
			case _: Assert.fail('expected ImportDecl first');
		}
		switch ast.decls[1].decl {
			case UsingDecl(path): Assert.equals('tink.CoreApi', (path : String));
			case _: Assert.fail('expected UsingDecl second');
		}
	}

	public function testImportRequiresSemi():Void {
		Assert.raises(() -> HaxeModuleParser.parse('import foo'));
	}

	public function testUsingRequiresSemi():Void {
		Assert.raises(() -> HaxeModuleParser.parse('using foo'));
	}

	public function testImportRequiresPath():Void {
		// No `ImportEmpty` ctor — bare `import;` is rejected.
		Assert.raises(() -> HaxeModuleParser.parse('import;'));
	}

	public function testUsingRequiresPath():Void {
		Assert.raises(() -> HaxeModuleParser.parse('using;'));
	}

	public function testWriterEmitsImport():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('import foo.bar.Baz;'));
		Assert.equals('import foo.bar.Baz;\n', out);
	}

	public function testWriterEmitsUsing():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('using StringTools;'));
		Assert.equals('using StringTools;\n', out);
	}

	public function testRoundTripImport():Void {
		roundTrip('import haxe.io.Bytes;');
	}

	public function testRoundTripUsing():Void {
		roundTrip('using tink.CoreApi;');
	}

	public function testRoundTripPackageImportClass():Void {
		roundTrip('package foo.bar;\nimport baz.Qux;\nclass C {}');
	}

	public function testRoundTripImportUsingSequence():Void {
		roundTrip('import tink.state.Observable;\nusing tink.CoreApi;');
	}

}
