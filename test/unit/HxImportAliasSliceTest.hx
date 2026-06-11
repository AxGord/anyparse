package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxImportAlias;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Tests for slice ω-import-as-alias — adds
 * `HxDecl.ImportAliasDecl(decl:HxImportAlias)` so single-symbol aliased
 * imports `import Std.is as isOfType;` parse as top-level decls. Placed
 * BEFORE the plain `ImportDecl` ctor so `tryBranch` attempts the longer
 * match first; a missing `as` rolls back to the plain ctor (twin of
 * `ImportWildDecl` → `ImportDecl` rollback).
 *
 * The `as` keyword is hard (not `@:optional`) on `HxImportAlias.alias`
 * so an absent `as` triggers tryBranch rollback rather than producing a
 * partially-filled `ImportAliasDecl`. `using ... as ...` is not legal
 * Haxe and has no twin ctor; wildcard `import foo.*` never carries
 * `as`, so there is no `ImportWildAliasDecl` either.
 *
 * Capability target: unblocks `issue_634_is_as_import.hxtest`. The
 * `issue_504_conditional_import.hxtest` fixture also uses `as`, but
 * fails earlier on cond-comp INSIDE the import path (`#if … #end`),
 * which is a separate slice.
 */
class HxImportAliasSliceTest extends HxTestHelpers {

	public function testImportAliasSimple(): Void {
		final ast: HxModule = HaxeModuleParser.parse('import Std.is as isOfType;');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case ImportAliasDecl(decl):
				Assert.equals('Std.is', (decl.path: String));
				Assert.equals('isOfType', (decl.name: String));
			case _:
				Assert.fail('expected ImportAliasDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testImportAliasDottedPath(): Void {
		final ast: HxModule = HaxeModuleParser.parse('import haxe.io.Bytes as B;');
		switch ast.decls[0].decl {
			case ImportAliasDecl(decl):
				Assert.equals('haxe.io.Bytes', (decl.path: String));
				Assert.equals('B', (decl.name: String));
			case _:
				Assert.fail('expected ImportAliasDecl');
		}
	}

	public function testPlainImportStillFallsThrough(): Void {
		// Regression: without `as <ident>`, dispatcher must roll back from
		// ImportAliasDecl to plain ImportDecl.
		final ast: HxModule = HaxeModuleParser.parse('import Std.is;');
		switch ast.decls[0].decl {
			case ImportDecl(path):
				Assert.equals('Std.is', (path: String));
			case _:
				Assert.fail('expected ImportDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testImportAliasRequiresAliasName(): Void {
		// `import Foo as ;` — `as` is consumed by ImportAliasDecl but the
		// alias ident regex fails; rollback to plain ImportDecl is also
		// rejected because the path-only branch can't terminate on the
		// stray `as` text either.
		Assert.raises(() -> HaxeModuleParser.parse('import Foo as ;'));
	}

	public function testImportAliasRequiresSemi(): Void {
		Assert.raises(() -> HaxeModuleParser.parse('import Foo as Bar'));
	}

	public function testWriterEmitsImportAlias(): Void {
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('import Std.is as isOfType;'));
		Assert.equals('import Std.is as isOfType;\n', out);
	}

	public function testRoundTripImportAliasSimple(): Void {
		roundTrip('import Std.is as isOfType;');
	}

	public function testRoundTripImportAliasMixedWithPlain(): Void {
		roundTrip('import Std.is as isOfType;\nimport haxe.io.Bytes;\n');
	}

	public function testRoundTripImportAliasInCondComp(): Void {
		// Matches issue_634 — the alias form inside a `#if … #else … #end`
		// guard. The cond-comp body re-enters `HxDecl` so the new
		// ImportAliasDecl ctor is reachable here too.
		roundTrip('import Std.is as isOfType;\n#if (haxe_ver >= 4.2)\nimport Std.isOfType;\n#else\nimport Std.is as isOfType;\n#end\n');
	}

}
