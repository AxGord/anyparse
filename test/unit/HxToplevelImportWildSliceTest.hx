package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Tests for slice ω-toplevel-import-wild — adds
 * `HxDecl.ImportWildDecl(path:HxWildPath)` and
 * `HxDecl.UsingWildDecl(path:HxWildPath)` so a Haxe module's leading
 * `import haxe.*;` and `using foo.bar.*;` directives parse as
 * top-level decls.
 *
 * Branch dispatch puts the wildcard ctors BEFORE the plain
 * `ImportDecl` / `UsingDecl` ctors so the `HxWildPath` regex (which
 * requires a literal `.*` suffix) is tried first; when the suffix
 * isn't present, `tryBranch` rolls back and the plain `HxTypeName`
 * ctor matches the dotted-ident sequence. Mirrors the
 * `PackageDecl` → `PackageEmpty` rollback shape.
 *
 * Out of scope: aliased form `import Std.is as isOfType;` and the
 * conditional shape `import #if … #end …;`. Capability-only target
 * for THIS slice: pure wildcard form, which unblocks
 * `imports_mult.hxtest` (whitespace) end-to-end. The other two
 * wildcard-using fixtures (`conditionals_fixed_zero_increase_blocks`,
 * `issue_519_nested_conditional`) also need top-level `#if … #end`
 * and remain skip-parse until that slice lands.
 */
class HxToplevelImportWildSliceTest extends HxTestHelpers {

	public function testImportWildSingleSegment():Void {
		final ast:HxModule = HaxeModuleParser.parse('import haxe.*;');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case ImportWildDecl(path): Assert.equals('haxe.*', (path : String));
			case _: Assert.fail('expected ImportWildDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testImportWildDottedPath():Void {
		final ast:HxModule = HaxeModuleParser.parse('import foo.bar.*;');
		switch ast.decls[0].decl {
			case ImportWildDecl(path): Assert.equals('foo.bar.*', (path : String));
			case _: Assert.fail('expected ImportWildDecl');
		}
	}

	public function testUsingWildSingleSegment():Void {
		final ast:HxModule = HaxeModuleParser.parse('using haxe.*;');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case UsingWildDecl(path): Assert.equals('haxe.*', (path : String));
			case _: Assert.fail('expected UsingWildDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testUsingWildDottedPath():Void {
		final ast:HxModule = HaxeModuleParser.parse('using tink.core.*;');
		switch ast.decls[0].decl {
			case UsingWildDecl(path): Assert.equals('tink.core.*', (path : String));
			case _: Assert.fail('expected UsingWildDecl');
		}
	}

	public function testPlainImportStillRoutesToPlainCtor():Void {
		// Regression: without `.*` suffix, dispatcher must roll back to plain ImportDecl.
		final ast:HxModule = HaxeModuleParser.parse('import foo.bar.Baz;');
		switch ast.decls[0].decl {
			case ImportDecl(path): Assert.equals('foo.bar.Baz', (path : String));
			case _: Assert.fail('expected ImportDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testPlainUsingStillRoutesToPlainCtor():Void {
		final ast:HxModule = HaxeModuleParser.parse('using StringTools;');
		switch ast.decls[0].decl {
			case UsingDecl(path): Assert.equals('StringTools', (path : String));
			case _: Assert.fail('expected UsingDecl');
		}
	}

	public function testWildAndPlainSequence():Void {
		final ast:HxModule = HaxeModuleParser.parse('import haxe.*;\nimport foo.Bar;');
		Assert.equals(2, ast.decls.length);
		switch ast.decls[0].decl {
			case ImportWildDecl(path): Assert.equals('haxe.*', (path : String));
			case _: Assert.fail('expected ImportWildDecl first');
		}
		switch ast.decls[1].decl {
			case ImportDecl(path): Assert.equals('foo.Bar', (path : String));
			case _: Assert.fail('expected ImportDecl second');
		}
	}

	public function testImportWildThenUsingWild():Void {
		final ast:HxModule = HaxeModuleParser.parse('import haxe.*;\nusing haxe.*;');
		Assert.equals(2, ast.decls.length);
		switch ast.decls[0].decl {
			case ImportWildDecl(path): Assert.equals('haxe.*', (path : String));
			case _: Assert.fail('expected ImportWildDecl first');
		}
		switch ast.decls[1].decl {
			case UsingWildDecl(path): Assert.equals('haxe.*', (path : String));
			case _: Assert.fail('expected UsingWildDecl second');
		}
	}

	public function testImportWildRequiresSemi():Void {
		Assert.raises(() -> HaxeModuleParser.parse('import haxe.*'));
	}

	public function testUsingWildRequiresSemi():Void {
		Assert.raises(() -> HaxeModuleParser.parse('using haxe.*'));
	}

	public function testWriterEmitsImportWild():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('import haxe.*;'));
		Assert.equals('import haxe.*;\n', out);
	}

	public function testWriterEmitsUsingWild():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('using foo.bar.*;'));
		Assert.equals('using foo.bar.*;\n', out);
	}

	public function testRoundTripImportWild():Void {
		roundTrip('import haxe.*;');
	}

	public function testRoundTripUsingWild():Void {
		roundTrip('using tink.core.*;');
	}

	public function testRoundTripImportWildThenUsingWild():Void {
		roundTrip('import haxe.*;\nusing haxe.*;');
	}

	public function testRoundTripWildAndPlainMix():Void {
		roundTrip('import haxe.*;\nimport foo.Bar;');
	}

}
