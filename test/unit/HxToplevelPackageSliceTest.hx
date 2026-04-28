package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Tests for slice ω-toplevel-package — adds `HxDecl.PackageDecl(path:HxTypeName)`
 * and the nullary `HxDecl.PackageEmpty` so a Haxe module's leading
 * `package foo.bar;` (or bare `package;`) directive parses as a top-
 * level decl. Both variants share `@:kw('package') @:trail(';')`;
 * `PackageDecl` is tried first to consume a dotted path, and the
 * `tryBranch` rollback in `lowerEnum` lets `PackageEmpty` catch the
 * no-name shape when `HxTypeName`'s regex fails on the bare `;`.
 *
 * Real Haxe accepts at most one `package` per module at the very
 * start. The parser does not enforce position or count — putting a
 * `package` after a class declaration, or two `package` directives in
 * a row, parses without complaint. Semantic policing belongs to a
 * later analysis pass; the grammar's job here is to recognise the
 * directive's surface shape so the AxGord/haxe-formatter corpus
 * fixtures whose first line is `package;` (`issue_115_*`,
 * `issue_38_whitespace_in_doc_comments`,
 * `issue_66_whitespace_at_end_of_comment`) parse-unblock for the
 * trivia harness.
 *
 * Out of scope: top-level `import` / `using` / `#if` / metadata.
 * Each is a separate slice — fixtures that combine package with
 * those (e.g. `issue_257_return_*` has `package … ;` followed by
 * `import …;`) remain skip-parse until those slices land.
 */
class HxToplevelPackageSliceTest extends HxTestHelpers {

	public function testPackageEmpty():Void {
		final ast:HxModule = HaxeModuleParser.parse('package;');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case PackageEmpty: Assert.pass();
			case _: Assert.fail('expected PackageEmpty, got ${ast.decls[0].decl}');
		}
	}

	public function testPackageSingleSegment():Void {
		final ast:HxModule = HaxeModuleParser.parse('package foo;');
		switch ast.decls[0].decl {
			case PackageDecl(path): Assert.equals('foo', (path : String));
			case _: Assert.fail('expected PackageDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testPackageDottedPath():Void {
		final ast:HxModule = HaxeModuleParser.parse('package foo.bar.baz;');
		switch ast.decls[0].decl {
			case PackageDecl(path): Assert.equals('foo.bar.baz', (path : String));
			case _: Assert.fail('expected PackageDecl');
		}
	}

	public function testPackageThenClass():Void {
		final ast:HxModule = HaxeModuleParser.parse('package foo.bar;\nclass C {}');
		Assert.equals(2, ast.decls.length);
		switch ast.decls[0].decl {
			case PackageDecl(path): Assert.equals('foo.bar', (path : String));
			case _: Assert.fail('expected PackageDecl first');
		}
		switch ast.decls[1].decl {
			case ClassDecl(_): Assert.pass();
			case _: Assert.fail('expected ClassDecl second');
		}
	}

	public function testPackageEmptyThenClass():Void {
		final ast:HxModule = HaxeModuleParser.parse('package;\nclass C {}');
		Assert.equals(2, ast.decls.length);
		switch ast.decls[0].decl {
			case PackageEmpty: Assert.pass();
			case _: Assert.fail('expected PackageEmpty first');
		}
		switch ast.decls[1].decl {
			case ClassDecl(_): Assert.pass();
			case _: Assert.fail('expected ClassDecl second');
		}
	}

	public function testPackageRequiresSemi():Void {
		// `@:trail(';')` is mandatory — both branches reject the bare
		// keyword. The outer-loop `expected HxDecl` fan still surfaces
		// the failure even though the branch-internal trail expectation
		// is what actually trips.
		Assert.raises(() -> HaxeModuleParser.parse('package foo'));
	}

	public function testWriterEmitsPackageEmpty():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('package;'));
		// Plain writer trims module-level newlines; the trail `;` plus
		// the trailing module newline is the canonical shape.
		Assert.equals('package;\n', out);
	}

	public function testWriterEmitsPackageDecl():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('package foo.bar;'));
		Assert.equals('package foo.bar;\n', out);
	}

	public function testRoundTripPackageEmpty():Void {
		roundTrip('package;');
	}

	public function testRoundTripPackageSingleSegment():Void {
		roundTrip('package foo;');
	}

	public function testRoundTripPackageDottedPath():Void {
		roundTrip('package haxe.io.bytes;');
	}

	public function testRoundTripPackageThenClass():Void {
		roundTrip('package foo.bar;\nclass C {}');
	}

}
