package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxImportAliasIn;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Tests for slice ω-import-in-alias — adds
 * `HxDecl.ImportAliasInDecl(decl:HxImportAliasIn)`, the legacy pre-
 * Haxe-4 spelling of the import-alias clause: `import Std.is in
 * isOfType;` instead of the modern `import Std.is as isOfType;`
 * (`HxImportAliasSliceTest` / `HxDecl.ImportAliasDecl`). Placed BEFORE
 * the plain `ImportDecl` ctor so `tryBranch` attempts the longer match
 * first; a missing `in` rolls back to the plain ctor (twin of
 * `ImportAliasDecl` → `ImportDecl` rollback, itself a twin of
 * `ImportWildDecl` → `ImportDecl`).
 *
 * The `in` keyword is hard (not `@:optional`) on
 * `HxImportAliasIn.name`, same tryBranch-rollback reason as
 * `HxImportAlias.name`'s `@:kw('as')`. Both spellings are semantically
 * identical and equally valid Haxe today, so this is a byte-fidelity
 * slice, not a correctness one — the writer MUST re-emit whichever
 * keyword the source used and must NEVER normalise `in` to `as` (or
 * vice versa). That is why `as`/`in` are two struct shapes with their
 * own hard-coded keyword rather than one struct with a keyword choice.
 *
 * Capability target: unblocks `python.net.SslSocket` (real Haxe
 * std-lib file), which mixes both spellings in adjacent import lines —
 * `import python.lib.socket.Socket as PSocket;` immediately followed
 * by `import python.lib.Socket in PSocketModule;` — and `js.lib.Date`
 * / `cs._std.sys.net.Socket`, which use the legacy `in` form
 * exclusively.
 */
class HxImportAliasInSliceTest extends HxTestHelpers {

	public function testImportAliasInSimple(): Void {
		final ast: HxModule = HaxeModuleParser.parse('import Std.is in isOfType;');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case ImportAliasInDecl(decl):
				Assert.equals('Std.is', (decl.path: String));
				Assert.equals('isOfType', (decl.name: String));
			case _:
				Assert.fail('expected ImportAliasInDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testImportAliasInDottedPath(): Void {
		final ast: HxModule = HaxeModuleParser.parse('import python.lib.Socket in PSocketModule;');
		switch ast.decls[0].decl {
			case ImportAliasInDecl(decl):
				Assert.equals('python.lib.Socket', (decl.path: String));
				Assert.equals('PSocketModule', (decl.name: String));
			case _:
				Assert.fail('expected ImportAliasInDecl');
		}
	}

	public function testPlainImportStillFallsThrough(): Void {
		// Regression: without `in <ident>`, dispatcher must roll back from
		// ImportAliasInDecl (and ImportAliasDecl) to plain ImportDecl.
		final ast: HxModule = HaxeModuleParser.parse('import Std.is;');
		switch ast.decls[0].decl {
			case ImportDecl(path):
				Assert.equals('Std.is', (path: String));
			case _:
				Assert.fail('expected ImportDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testAsSpellingUnaffected(): Void {
		// Regression: the modern `as` spelling still dispatches to
		// ImportAliasDecl, not ImportAliasInDecl — the two keywords are
		// mutually exclusive, not interchangeable.
		final ast: HxModule = HaxeModuleParser.parse('import Std.is as isOfType;');
		switch ast.decls[0].decl {
			case ImportAliasDecl(decl):
				Assert.equals('isOfType', (decl.name: String));
			case _:
				Assert.fail('expected ImportAliasDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testImportAliasInRequiresAliasName(): Void {
		// `import Foo in ;` — `in` is consumed by ImportAliasInDecl but the
		// alias ident regex fails; rollback to plain ImportDecl is also
		// rejected because the path-only branch can't terminate on the
		// stray `in` text either.
		Assert.raises(HaxeModuleParser.parse.bind('import Foo in ;'));
	}

	public function testImportAliasInRequiresSemi(): Void {
		Assert.raises(HaxeModuleParser.parse.bind('import Foo in Bar'));
	}

	public function testWriterEmitsImportAliasIn(): Void {
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('import Std.is in isOfType;'));
		Assert.equals('import Std.is in isOfType;\n', out);
	}

	public function testWriterDoesNotRewriteInToAs(): Void {
		// The core byte-fidelity guarantee: an `in` import must round-trip
		// as `in`, never get silently normalised to `as`.
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('import Std.is in isOfType;'));
		Assert.isTrue(out.indexOf(' in isOfType;') >= 0);
		Assert.isFalse(out.indexOf(' as isOfType;') >= 0);
	}

	public function testRoundTripImportAliasInSimple(): Void {
		roundTrip('import Std.is in isOfType;');
	}

	public function testRoundTripImportAliasInCondComp(): Void {
		roundTrip('import Std.is in isOfType;\n#if (haxe_ver >= 4.2)\nimport Std.isOfType;\n#else\nimport Std.is in isOfType;\n#end\n');
	}

	// -- The real motivating shape: `as` and `in` mixed in one file --

	public function testMixedAsAndInAdjacent(): Void {
		// Matches python.net.SslSocket: `as` immediately followed by `in`.
		final src: String = 'import python.lib.socket.Socket as PSocket;\nimport python.lib.Socket in PSocketModule;\n';
		final ast: HxModule = HaxeModuleParser.parse(src);
		Assert.equals(2, ast.decls.length);
		switch ast.decls[0].decl {
			case ImportAliasDecl(decl):
				Assert.equals('PSocket', (decl.name: String));
			case _:
				Assert.fail('expected ImportAliasDecl first, got ${ast.decls[0].decl}');
		}
		switch ast.decls[1].decl {
			case ImportAliasInDecl(decl):
				Assert.equals('PSocketModule', (decl.name: String));
			case _:
				Assert.fail('expected ImportAliasInDecl second, got ${ast.decls[1].decl}');
		}
	}

	public function testMixedAsAndInRoundTrip(): Void {
		roundTrip('import python.lib.socket.Socket as PSocket;\nimport python.lib.Socket in PSocketModule;\n');
	}

	public function testMixedAsAndInKeywordsNotCrossRewritten(): Void {
		// The core byte-fidelity guarantee, adjacent-mix variant: neither
		// spelling gets normalised to the other when both appear in the
		// same file (the plain writer pipeline's default blank-line
		// insertion between different-ctor same-family imports is an
		// orthogonal formatting concern, not part of this invariant).
		final src: String = 'import python.lib.socket.Socket as PSocket;\nimport python.lib.Socket in PSocketModule;\n';
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(out.indexOf(' as PSocket;') >= 0);
		Assert.isTrue(out.indexOf(' in PSocketModule;') >= 0);
		Assert.isFalse(out.indexOf(' in PSocket;') >= 0);
		Assert.isFalse(out.indexOf(' as PSocketModule;') >= 0);
	}

}
