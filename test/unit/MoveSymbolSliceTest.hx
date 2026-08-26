package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.MoveSymbol;
import utest.Assert;
import utest.Test;

using StringTools;

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
 * column in the same 1-based convention as `rename`);
 * cursors point at the type NAME so the identifier-token tier applies.
 */
class MoveSymbolSliceTest extends Test {

	/**
	 * Move `class Foo` from `pkg/A.hx` to `pkg/B.hx` (same package), with
	 * a third file `pkg/User.hx` that imports and uses it. After the move:
	 * Foo's decl appears in B, is gone from A, and User's import is
	 * repointed `pkg.A.Foo` -> `pkg.B.Foo`. Every changed file re-parses.
	 */
	public function testMoveAcrossSamePackage(): Void {
		final a: String = 'package pkg;\n\nclass Foo {\n\tpublic var x:Int = 1;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package pkg;\n\nimport pkg.A.Foo;\n\nclass User {\n\tvar f:Foo;\n}';
		// `class Foo` on line 3; `Foo` at col 7.
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 3, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user }
		]);
		// All three files change.
		Assert.equals(3, changes.length);

		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		final newUser: String = changeFor(changes, 'pkg/User.hx').newSource;

		// Foo gone from A, present in B.
		Assert.isFalse(newA.contains('class Foo'), 'Foo should be gone from A');
		Assert.isTrue(newB.contains('class Foo'), 'Foo should land in B');
		Assert.isTrue(newB.contains('public var x:Int = 1;'), 'Foo body should land in B');

		// User's import repointed to the new module path.
		Assert.isTrue(newUser.contains('import pkg.B.Foo;'), 'User import should repoint to pkg.B.Foo');
		Assert.isFalse(newUser.contains('import pkg.A.Foo;'), 'old import should be gone from User');
		// User's type position is untouched (still `:Foo`).
		Assert.isTrue(newUser.contains('var f:Foo;'), 'User type position stays');
	}

	/**
	 * Move a `final class Foo` (the dominant style) from `pkg/A.hx` to
	 * `pkg/B.hx`. The cut span is the OUTER `FinalDecl` span, so the WHOLE
	 * `final class Foo {…}` relocates WITH its `final ` keyword — A is left
	 * with no orphaned `final`, and B gains `final class Foo`. The importer
	 * is repointed exactly as for a plain class.
	 */
	public function testMoveFinalClass(): Void {
		final a: String = 'package pkg;\n\nfinal class Foo {\n\tpublic var x:Int = 1;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package pkg;\n\nimport pkg.A.Foo;\n\nclass User {\n\tvar f:Foo;\n}';
		// `final class Foo` on line 3; `Foo` at col 13.
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 3, 13, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user }
		]);
		Assert.equals(3, changes.length);

		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		final newUser: String = changeFor(changes, 'pkg/User.hx').newSource;

		// The whole final class — keyword included — left A and landed in B.
		Assert.isFalse(newA.contains('final class Foo'), 'final class gone from A');
		Assert.isFalse(newA.contains('final'), 'no orphaned final keyword in A');
		Assert.isTrue(newB.contains('final class Foo'), 'final class Foo lands in B');
		Assert.isTrue(newB.contains('public var x:Int = 1;'), 'final class body lands in B');

		// Importer repointed exactly as for a plain class.
		Assert.isTrue(newUser.contains('import pkg.B.Foo;'), 'User import repointed');
		Assert.isFalse(newUser.contains('import pkg.A.Foo;'), 'old import gone from User');
	}

	/**
	 * Dependency import carried: Foo's body references a cross-package
	 * type `Ext` that A imports (`import ext.Ext;`). Moving Foo to B
	 * carries that import into B so the relocated body still resolves.
	 */
	public function testDependencyImportCarried(): Void {
		final a: String = 'package pkg;\n\nimport ext.Ext;\n\nclass Foo {\n\tvar e:Ext;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 5, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('import ext.Ext;'), 'B should gain the carried dependency import');
		Assert.isTrue(newB.contains('class Foo'), 'Foo should land in B');
		Assert.isTrue(newB.contains('var e:Ext;'), 'Foo body should land in B');
	}

	/**
	 * The same carry when the dependency is named ONLY inside an anonymous
	 * structure. `dependencyImportsToCarry` walks the type-refs projection,
	 * which dropped the whole struct, so the import stayed behind and the
	 * relocated body failed to resolve — a build break, not a loud refusal.
	 */
	public function testDependencyImportInsideAnAnonymousStructureCarried(): Void {
		final a: String = 'package pkg;\n\nimport ext.Ext;\n\nclass Foo {\n\tvar e:Array<{node:Ext}>;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 5, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('import ext.Ext;'), 'B should gain the import the anon field type needs');
		Assert.isTrue(newB.contains('var e:Array<{node:Ext}>;'), 'Foo body should land in B');
	}

	/**
	 * A leading doc-comment moves WITH the type. `parseFile` drops the
	 * doc-comment from the decl span, so the cut must scan backward over
	 * it; the destination should carry the doc-comment line immediately
	 * above the relocated decl.
	 */
	public function testDocCommentMovesWithType(): Void {
		final a: String = 'package pkg;\n\n/** the foo */\nclass Foo {}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 4, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('/** the foo */'), 'doc-comment should move to B');
		Assert.isTrue(newB.contains('class Foo'), 'Foo should land in B');
		// The doc-comment is gone from A too.
		Assert.isFalse(newA.contains('/** the foo */'), 'doc-comment should be gone from A');
	}

	/**
	 * A leading `@:meta` line moves WITH the type (the meta is a separate
	 * preceding sibling node in the `parseFile` tree; the backward cut
	 * scan picks it up from the raw source).
	 */
	public function testMetaMovesWithType(): Void {
		final a: String = 'package pkg;\n\n@:keep\nclass Foo {}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 4, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('@:keep'), 'meta should move to B');
		Assert.isFalse(newA.contains('@:keep'), 'meta should be gone from A');
	}

	/** Refusal: the cursor is not on a type declaration (a field). */
	public function testCursorNotOnTypeDeclRefused(): Void {
		final a: String = 'package pkg;\n\nclass Foo {\n\tvar field:Int;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		// Line 4: the field name `field` at col 6 — a value decl, not a type.
		final result: MoveResult = MoveSymbol.moveType('pkg/A.hx', 4, 6, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		], plugin(), typeRefShape());
		assertErr(result);
	}

	/**
	 * Refusal: a cross-package destination. Moving the type to a file in a
	 * different package would break its same-package auto-visible
	 * dependencies, so the op refuses.
	 */
	public function testCrossPackageMoves(): Void {
		final a: String = 'package pkg;\n\nclass Foo {\n\tpublic var x:Int = 1;\n}';
		final b: String = 'package other;\n\nclass B {}';
		final user: String = 'package pkg;\n\nimport pkg.A.Foo;\n\nclass User {\n\tvar f:Foo;\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 3, 7, 'other/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'other/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user }
		]);
		Assert.isFalse(StringTools.contains(changeFor(changes, 'pkg/A.hx').newSource, 'class Foo'), 'Foo left A');
		Assert.isTrue(StringTools.contains(changeFor(changes, 'other/B.hx').newSource, 'class Foo'), 'Foo landed in B');
		final newUser: String = changeFor(changes, 'pkg/User.hx').newSource;
		Assert.isTrue(newUser.contains('import other.B.Foo;'), 'importer repointed cross-package');
		Assert.isTrue(newUser.contains('var f:Foo;'), 'bare type position stays');
	}

	public function testCrossPackageFqnRefused(): Void {
		final a: String = 'package pkg;\n\nclass Foo {}';
		final b: String = 'package other;\n\nclass B {}';
		final user: String = 'package pkg;\n\nclass User {\n\tvar f:pkg.A.Foo;\n}';
		final result: MoveResult = MoveSymbol.moveType('pkg/A.hx', 3, 7, 'other/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'other/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user }
		], plugin(), typeRefShape());
		assertErr(result);
	}

	/**
	 * Refusal: a scope file that does not parse — completeness cannot be
	 * proven over an unparseable file, so the whole move is refused.
	 */
	public function testSkipParseScopeFileRefused(): Void {
		final a: String = 'package pkg;\n\nclass Foo {}';
		final b: String = 'package pkg;\n\nclass B {}';
		final broken: String = 'class @@@ not valid haxe @@@';
		final result: MoveResult = MoveSymbol.moveType('pkg/A.hx', 3, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/Broken.hx', source: broken }
		], plugin(), typeRefShape());
		assertErr(result);
	}

	/**
	 * Refusal: `Foo` is declared in TWO scope files — the move refuses
	 * rather than guess which declaration the user meant.
	 */
	public function testAmbiguousDeclRefused(): Void {
		final a: String = 'package pkg;\n\nclass Foo {}';
		final dup: String = 'package pkg;\n\nclass Foo {}';
		final b: String = 'package pkg;\n\nclass B {}';
		final result: MoveResult = MoveSymbol.moveType('pkg/A.hx', 3, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/Dup.hx', source: dup },
			{ file: 'pkg/B.hx', source: b }
		], plugin(), typeRefShape());
		assertErr(result);
	}

	/** Refusal: source and destination are the same file. */
	public function testSameFileRefused(): Void {
		final a: String = 'package pkg;\n\nclass Foo {}';
		final result: MoveResult = MoveSymbol.moveType(
			'pkg/A.hx', 3, 7, 'pkg/A.hx', [{ file: 'pkg/A.hx', source: a }], plugin(), typeRefShape()
		);
		assertErr(result);
	}

	/** Refusal: the destination file is not in the scope set. */
	public function testDestNotInScopeRefused(): Void {
		final a: String = 'package pkg;\n\nclass Foo {}';
		final result: MoveResult = MoveSymbol.moveType(
			'pkg/A.hx', 3, 7, 'pkg/Missing.hx', [{ file: 'pkg/A.hx', source: a }], plugin(), typeRefShape()
		);
		assertErr(result);
	}

	/**
	 * A fresh import is anchored after the last TOP-LEVEL import, never after a
	 * `#if`-guarded one written lower in the file: anchoring on the guarded
	 * import would drop the new line inside the conditional region. The offset
	 * is the start of the `#if js` line (right after `import a.Top;`), NOT the
	 * `#end` line (which is where an unfiltered anchor would land).
	 */
	public function testImportAnchorSkipsGuardedImport(): Void {
		final source: String = 'package pkg;\nimport a.Top;\n#if js\nimport b.Guarded;\n#end\nclass C {}\n';
		Assert.equals(source.indexOf('#if js'), MoveSymbol.importAnchor(source, plugin()).offset);
	}

	/**
	 * A module whose WHOLE body is `#if`-guarded carries its import run INSIDE the region, so the
	 * anchor lands there — the same header the `add-import` op and the `import-order` rule read.
	 * Anchoring at the top level would strand the line above the `#if`, in scope for nothing the
	 * module declares.
	 */
	public function testImportAnchorEntersAWholeBodyGuard(): Void {
		final source: String = 'package pkg;\n\n#if js\nimport a.Top;\n\nclass C {}\n#end\n';
		Assert.equals(source.indexOf('import a.Top;'), MoveSymbol.importAnchor(source, plugin(), 'a.Bee').offset);
	}

	/** A ROOT-package `package;` anchors BELOW itself — an import above `package` does not compile. */
	public function testImportAnchorClearsAnEmptyPackage(): Void {
		final source: String = 'package;\n\nclass C {}\n';
		final at: Int = MoveSymbol.importAnchor(source, plugin(), 'a.Bee').offset;
		Assert.isTrue(at > source.indexOf('package;'), 'anchor $at must sit below the package statement');
	}

	/**
	 * A module-level `typedef` carries `@:trailOpt(';')`: written WITHOUT the
	 * `;` its parse span runs past the closing `}` to the next declaration —
	 * over the blank line AND that declaration's doc comment, which the parser
	 * hands back to the neighbour as leading trivia. The cut must stop at the
	 * bytes the typedef owns, else the neighbour's documentation travels to the
	 * destination as an orphan documenting nothing while the neighbour is left
	 * bare — silently, since both files still parse.
	 */
	public function testMoveKeepsNextDeclDoc(): Void {
		final a: String = 'package pkg;\n\ntypedef Foo = {\n\tfinal x:Int;\n}\n\n/** the bar */\ntypedef Bar = {\n\tfinal y:Int;\n}\n';
		final b: String = 'package pkg;\n\nclass B {}\n';
		// `typedef Foo` on line 3; `Foo` at col 9.
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 3, 9, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		// Byte-exact: Bar keeps its own doc, and the blank line the typedef sat
		// above is consumed with it (no double blank left behind).
		Assert.equals('package pkg;\n\n/** the bar */\ntypedef Bar = {\n\tfinal y:Int;\n}\n', newA);
		// Byte-exact on the destination too: only the decl's OWN text moves, so the
		// blank line the cut also removed does not arrive as a stray blank run.
		Assert.equals('package pkg;\n\nclass B {}\n\ntypedef Foo = {\n\tfinal x:Int;\n}\n\n', newB);
		Assert.isFalse(newB.contains('the bar'), 'the neighbour doc must not travel to B');
	}

	/**
	 * A module-level `private` type moves. `private` projects as a SEPARATE
	 * sibling node BEFORE the declaration, so the "shares a source line with
	 * other code" guard — which requires the text between the line start and
	 * the decl span to be blank — used to read the modifier as other code and
	 * refuse an ordinary `private typedef` sitting alone on its own lines. The
	 * cut is computed from the modifier-folded declaration group, so the
	 * modifier travels to the destination with the type.
	 */
	public function testMovePrivateModuleType(): Void {
		final a: String = 'package pkg;\n\nprivate typedef Priv = {\n\tfinal x:Int;\n}\n\nclass A {}\n';
		final b: String = 'package pkg;\n\nclass B {}\n';
		// `private typedef Priv` on line 3; `Priv` at col 17.
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 3, 17, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.equals('package pkg;\n\nclass A {}\n', newA);
		Assert.isTrue(newB.contains('private typedef Priv = {'), 'the private modifier should move with the type');
	}

	/**
	 * Guard for the `;`-TERMINATED form: the trail token is present, so the
	 * parse span already ends at the `;` and the trailing trim has nothing to
	 * cut. The cut stays exactly what it was — the decl's own lines plus one
	 * newline — including the blank run it leaves behind, which is
	 * pre-existing behaviour and NOT what the trim changes.
	 */
	public function testMoveSemicolonTerminatedTypedefUnchanged(): Void {
		final a: String = 'package pkg;\n\ntypedef Foo = {\n\tfinal x:Int;\n};\n\n/** the bar */\ntypedef Bar = {\n\tfinal y:Int;\n};';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 3, 9, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.equals('package pkg;\n\n\n/** the bar */\ntypedef Bar = {\n\tfinal y:Int;\n};', newA);
		Assert.equals('package pkg;\n\nclass B {}\n\ntypedef Foo = {\n\tfinal x:Int;\n};\n', newB);
	}

	/**
	 * Guard for a decl with NO following declaration to borrow trivia from:
	 * the trailing trim and the blank-run extension are both no-ops, so the
	 * cut and the inserted text are byte-identical to what they always were.
	 */
	public function testMoveTypedefWithNoNeighbourUnchanged(): Void {
		final a: String = 'package pkg;\n\ntypedef Foo = {\n\tfinal x:Int;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 3, 9, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		Assert.equals('package pkg;\n\n', changeFor(changes, 'pkg/A.hx').newSource);
		Assert.equals('package pkg;\n\nclass B {}\n\ntypedef Foo = {\n\tfinal x:Int;\n}', changeFor(changes, 'pkg/B.hx').newSource);
	}

	/**
	 * A `;`-less typedef that is the LAST declaration in the file: its parse span
	 * claims the whole trailing blank run, so the cut runs the blank-line
	 * extension all the way to EOF while only the decl's own text — one line
	 * terminator, no blank run — moves to the destination.
	 */
	public function testMoveTrailingBlankRunAtEofCollapses(): Void {
		final a: String = 'package pkg;\n\ntypedef Foo = {\n\tfinal x:Int;\n}\n\n\n';
		final b: String = 'package pkg;\n\nclass B {}\n';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 3, 9, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		Assert.equals('package pkg;\n\n', changeFor(changes, 'pkg/A.hx').newSource);
		Assert.equals('package pkg;\n\nclass B {}\n\ntypedef Foo = {\n\tfinal x:Int;\n}\n\n', changeFor(changes, 'pkg/B.hx').newSource);
	}

	/**
	 * The full modifier group of a `final class` travels with it: `@:meta` and
	 * `private` are separate sibling nodes BEFORE the declaration and `final `
	 * lives in the OUTER `FinalDecl` span, so the cut must start at the first
	 * sibling — which is what pins `declNode` to the `FinalDecl` rather than to
	 * the inner `ClassForm`. The `FinalDecl` span runs on past its own `}` exactly
	 * like a `;`-less typedef, so the neighbour's doc must survive here too.
	 */
	public function testMoveMetaPrivateFinalClass(): Void {
		final a: String = 'package pkg;\n\n@:keep\nprivate final class Hidden {\n\tpublic function new() {}\n}\n\n'
			+ '/** the keeper */\nfinal class Keeper {\n\tpublic function new() {}\n}\n';
		final b: String = 'package pkg;\n\nclass B {}\n';
		// `private final class Hidden` on line 4; `Hidden` at col 21.
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 4, 21, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		Assert.equals(
			'package pkg;\n\n/** the keeper */\nfinal class Keeper {\n\tpublic function new() {}\n}\n',
			changeFor(changes, 'pkg/A.hx').newSource
		);
		Assert.equals(
			'package pkg;\n\nclass B {}\n\n@:keep\nprivate final class Hidden {\n\tpublic function new() {}\n}\n\n',
			changeFor(changes, 'pkg/B.hx').newSource
		);
	}

	/**
	 * A module-`private` type the source STILL references is refused. Moving it
	 * leaves the source needing an import, and Haxe has no way to import a
	 * module-private type from another module — the op would otherwise write an
	 * `import` that cannot compile, which no re-parse gate would catch.
	 */
	public function testMovePrivateTypeStillUsedRefused(): Void {
		final a: String = 'package pkg;\n\nprivate typedef Priv = {\n\tfinal a:Int;\n}\n\nclass A {\n\tvar p:Priv;\n}\n';
		final b: String = 'package pkg;\n\nclass B {}\n';
		final result: MoveResult = MoveSymbol.moveType('pkg/A.hx', 3, 17, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		], plugin(), typeRefShape());
		switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
			case Err(message):
				Assert.isTrue(message.contains('module-private'), 'the refusal must name the private-type cause: $message');
		}
	}

	/**
	 * Drive a successful move and return the changes, asserting the result
	 * is `Ok`, the advisory is present, and every rewrite re-parses (the
	 * op already validates this; the test makes it explicit by re-parsing
	 * each `newSource`).
	 */
	private function okChanges(
		cursorFile: String, line: Int, col: Int, destFile: String, scopeFiles: Array<{ file: String, source: String }>
	): Array<MoveChange> {
		final result: MoveResult = MoveSymbol.moveType(cursorFile, line, col, destFile, scopeFiles, plugin(), typeRefShape());
		switch result {
			case Ok(changes, advisory):
				Assert.notNull(advisory);
				for (c in changes) {
					var parsed: Bool = true;
					try
						plugin().parseFile(c.newSource)
					catch (_: haxe.Exception)
						parsed = false;
					Assert.isTrue(parsed, 'rewritten ${c.file} should re-parse');
				}
				return changes;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return [];
		}
	}

	private function assertErr(result: MoveResult): Void {
		switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
			case Err(_):
				Assert.pass();
		}
	}

	private function changeFor(changes: Array<MoveChange>, file: String): MoveChange {
		for (c in changes) if (c.file == file) return c;
		Assert.fail('no change for file $file');
		return { file: file, newSource: '' };
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	private static function typeRefShape(): TypeRefShape {
		return new HaxeQueryPlugin().typeRefShape();
	}

}
