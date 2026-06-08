package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.MoveSymbol;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.MoveSymbol.MoveChange;

/**
 * `MoveSymbol.moveType` — scope-correct, format-preserving move of a
 * TYPE declaration from one file to another within the SAME PACKAGE,
 * fixing imports across a scope. The largest cross-file refactoring op
 * in the query suite: it relocates a type's source verbatim, carries the
 * type-position imports its body depends on, and rewrites every importer
 * that named the type through its old module path.
 *
 * Each test drives the PURE operation with an IN-MEMORY `scopeFiles`
 * array (no disk; paths use a `pkg/` prefix so the module path / basename
 * machinery is exercised), points a cursor at a type declaration in one
 * file, and asserts structural facts about the rewritten files (the decl
 * landed in the destination, vanished from the source, importers were
 * repointed). The op re-parses every rewrite before returning, so an
 * `Ok` is guaranteed valid Haxe; the tests additionally re-parse each
 * `newSource` to make the guarantee explicit. Refusal cases assert `Err`
 * and that no rewrite is emitted.
 *
 * Coordinates are the positions `apq refs` prints (the op interprets the
 * column in the same `Span.lineCol().col - 1` convention as `rename`);
 * cursors point at the type NAME so the identifier-token tier applies.
 */
class MoveSymbolSliceTest extends Test {

	/**
	 * Move `class Foo` from `pkg/A.hx` to `pkg/B.hx` (same package), with
	 * a third file `pkg/User.hx` that imports and uses it. After the move:
	 * Foo's decl appears in B, is gone from A, and User's import is
	 * repointed `pkg.A.Foo` -> `pkg.B.Foo`. Every changed file re-parses.
	 */
	public function testMoveAcrossSamePackage():Void {
		final a:String =
			'package pkg;\n'
			+ '\n'
			+ 'class Foo {\n'
			+ '\tpublic var x:Int = 1;\n'
			+ '}';
		final b:String =
			'package pkg;\n'
			+ '\n'
			+ 'class B {}';
		final user:String =
			'package pkg;\n'
			+ '\n'
			+ 'import pkg.A.Foo;\n'
			+ '\n'
			+ 'class User {\n'
			+ '\tvar f:Foo;\n'
			+ '}';
		// `class Foo` on line 3; `Foo` at display col 6.
		final changes:Array<MoveChange> = okChanges('pkg/A.hx', 3, 6, 'pkg/B.hx', [
			{file: 'pkg/A.hx', source: a}, {file: 'pkg/B.hx', source: b}, {file: 'pkg/User.hx', source: user},
		]);
		// All three files change.
		Assert.equals(3, changes.length);

		final newA:String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB:String = changeFor(changes, 'pkg/B.hx').newSource;
		final newUser:String = changeFor(changes, 'pkg/User.hx').newSource;

		// Foo gone from A, present in B.
		Assert.isFalse(StringTools.contains(newA, 'class Foo'), 'Foo should be gone from A');
		Assert.isTrue(StringTools.contains(newB, 'class Foo'), 'Foo should land in B');
		Assert.isTrue(StringTools.contains(newB, 'public var x:Int = 1;'), 'Foo body should land in B');

		// User's import repointed to the new module path.
		Assert.isTrue(StringTools.contains(newUser, 'import pkg.B.Foo;'), 'User import should repoint to pkg.B.Foo');
		Assert.isFalse(StringTools.contains(newUser, 'import pkg.A.Foo;'), 'old import should be gone from User');
		// User's type position is untouched (still `:Foo`).
		Assert.isTrue(StringTools.contains(newUser, 'var f:Foo;'), 'User type position stays');
	}

	/**
	 * Dependency import carried: Foo's body references a cross-package
	 * type `Ext` that A imports (`import ext.Ext;`). Moving Foo to B
	 * carries that import into B so the relocated body still resolves.
	 */
	public function testDependencyImportCarried():Void {
		final a:String =
			'package pkg;\n'
			+ '\n'
			+ 'import ext.Ext;\n'
			+ '\n'
			+ 'class Foo {\n'
			+ '\tvar e:Ext;\n'
			+ '}';
		final b:String =
			'package pkg;\n'
			+ '\n'
			+ 'class B {}';
		final changes:Array<MoveChange> = okChanges('pkg/A.hx', 5, 6, 'pkg/B.hx', [
			{file: 'pkg/A.hx', source: a}, {file: 'pkg/B.hx', source: b},
		]);
		final newB:String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(StringTools.contains(newB, 'import ext.Ext;'), 'B should gain the carried dependency import');
		Assert.isTrue(StringTools.contains(newB, 'class Foo'), 'Foo should land in B');
		Assert.isTrue(StringTools.contains(newB, 'var e:Ext;'), 'Foo body should land in B');
	}

	/**
	 * A leading doc-comment moves WITH the type. `parseFile` drops the
	 * doc-comment from the decl span, so the cut must scan backward over
	 * it; the destination should carry the doc-comment line immediately
	 * above the relocated decl.
	 */
	public function testDocCommentMovesWithType():Void {
		final a:String =
			'package pkg;\n'
			+ '\n'
			+ '/** the foo */\n'
			+ 'class Foo {}';
		final b:String =
			'package pkg;\n'
			+ '\n'
			+ 'class B {}';
		final changes:Array<MoveChange> = okChanges('pkg/A.hx', 4, 6, 'pkg/B.hx', [
			{file: 'pkg/A.hx', source: a}, {file: 'pkg/B.hx', source: b},
		]);
		final newA:String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB:String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(StringTools.contains(newB, '/** the foo */'), 'doc-comment should move to B');
		Assert.isTrue(StringTools.contains(newB, 'class Foo'), 'Foo should land in B');
		// The doc-comment is gone from A too.
		Assert.isFalse(StringTools.contains(newA, '/** the foo */'), 'doc-comment should be gone from A');
	}

	/**
	 * A leading `@:meta` line moves WITH the type (the meta is a separate
	 * preceding sibling node in the `parseFile` tree; the backward cut
	 * scan picks it up from the raw source).
	 */
	public function testMetaMovesWithType():Void {
		final a:String =
			'package pkg;\n'
			+ '\n'
			+ '@:keep\n'
			+ 'class Foo {}';
		final b:String =
			'package pkg;\n'
			+ '\n'
			+ 'class B {}';
		final changes:Array<MoveChange> = okChanges('pkg/A.hx', 4, 6, 'pkg/B.hx', [
			{file: 'pkg/A.hx', source: a}, {file: 'pkg/B.hx', source: b},
		]);
		final newA:String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB:String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(StringTools.contains(newB, '@:keep'), 'meta should move to B');
		Assert.isFalse(StringTools.contains(newA, '@:keep'), 'meta should be gone from A');
	}

	/** Refusal: the cursor is not on a type declaration (a field). */
	public function testCursorNotOnTypeDeclRefused():Void {
		final a:String =
			'package pkg;\n'
			+ '\n'
			+ 'class Foo {\n'
			+ '\tvar field:Int;\n'
			+ '}';
		final b:String = 'package pkg;\n\nclass B {}';
		// Line 4: the field name `field` at col 5 — a value decl, not a type.
		final result:MoveResult = MoveSymbol.moveType('pkg/A.hx', 4, 5, 'pkg/B.hx', [
			{file: 'pkg/A.hx', source: a}, {file: 'pkg/B.hx', source: b},
		], plugin(), typeRefShape());
		assertErr(result);
	}

	/**
	 * Refusal: a cross-package destination. Moving the type to a file in a
	 * different package would break its same-package auto-visible
	 * dependencies, so the op refuses.
	 */
	public function testCrossPackageRefused():Void {
		final a:String =
			'package pkg;\n'
			+ '\n'
			+ 'class Foo {}';
		final b:String =
			'package other;\n'
			+ '\n'
			+ 'class B {}';
		final result:MoveResult = MoveSymbol.moveType('pkg/A.hx', 3, 6, 'other/B.hx', [
			{file: 'pkg/A.hx', source: a}, {file: 'other/B.hx', source: b},
		], plugin(), typeRefShape());
		assertErr(result);
	}

	/**
	 * Refusal: a scope file that does not parse — completeness cannot be
	 * proven over an unparseable file, so the whole move is refused.
	 */
	public function testSkipParseScopeFileRefused():Void {
		final a:String = 'package pkg;\n\nclass Foo {}';
		final b:String = 'package pkg;\n\nclass B {}';
		final broken:String = 'class @@@ not valid haxe @@@';
		final result:MoveResult = MoveSymbol.moveType('pkg/A.hx', 3, 6, 'pkg/B.hx', [
			{file: 'pkg/A.hx', source: a}, {file: 'pkg/B.hx', source: b}, {file: 'pkg/Broken.hx', source: broken},
		], plugin(), typeRefShape());
		assertErr(result);
	}

	/**
	 * Refusal: `Foo` is declared in TWO scope files — the move refuses
	 * rather than guess which declaration the user meant.
	 */
	public function testAmbiguousDeclRefused():Void {
		final a:String = 'package pkg;\n\nclass Foo {}';
		final dup:String = 'package pkg;\n\nclass Foo {}';
		final b:String = 'package pkg;\n\nclass B {}';
		final result:MoveResult = MoveSymbol.moveType('pkg/A.hx', 3, 6, 'pkg/B.hx', [
			{file: 'pkg/A.hx', source: a}, {file: 'pkg/Dup.hx', source: dup}, {file: 'pkg/B.hx', source: b},
		], plugin(), typeRefShape());
		assertErr(result);
	}

	/** Refusal: source and destination are the same file. */
	public function testSameFileRefused():Void {
		final a:String = 'package pkg;\n\nclass Foo {}';
		final result:MoveResult = MoveSymbol.moveType('pkg/A.hx', 3, 6, 'pkg/A.hx', [
			{file: 'pkg/A.hx', source: a},
		], plugin(), typeRefShape());
		assertErr(result);
	}

	/** Refusal: the destination file is not in the scope set. */
	public function testDestNotInScopeRefused():Void {
		final a:String = 'package pkg;\n\nclass Foo {}';
		final result:MoveResult = MoveSymbol.moveType('pkg/A.hx', 3, 6, 'pkg/Missing.hx', [
			{file: 'pkg/A.hx', source: a},
		], plugin(), typeRefShape());
		assertErr(result);
	}

	/**
	 * Drive a successful move and return the changes, asserting the result
	 * is `Ok`, the advisory is present, and every rewrite re-parses (the
	 * op already validates this; the test makes it explicit by re-parsing
	 * each `newSource`).
	 */
	private function okChanges(cursorFile:String, line:Int, col:Int, destFile:String,
			scopeFiles:Array<{file:String, source:String}>):Array<MoveChange> {
		final result:MoveResult = MoveSymbol.moveType(cursorFile, line, col, destFile, scopeFiles, plugin(), typeRefShape());
		switch result {
			case Ok(changes, advisory):
				Assert.notNull(advisory);
				for (c in changes) {
					var parsed:Bool = true;
					try plugin().parseFile(c.newSource) catch (_:haxe.Exception) parsed = false;
					Assert.isTrue(parsed, 'rewritten ${c.file} should re-parse');
				}
				return changes;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return [];
		}
	}

	private function assertErr(result:MoveResult):Void {
		switch result {
			case Ok(changes, _): Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
			case Err(_): Assert.pass();
		}
	}

	private function changeFor(changes:Array<MoveChange>, file:String):MoveChange {
		for (c in changes) if (c.file == file) return c;
		Assert.fail('no change for file $file');
		return {file: file, newSource: ''};
	}

	private static function plugin():HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	private static function typeRefShape():TypeRefShape {
		return new HaxeQueryPlugin().typeRefShape();
	}
}
