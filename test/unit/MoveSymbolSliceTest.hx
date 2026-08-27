package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.ImportOrder.ImportAnchor;
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
		// blank line the cut also removed does not arrive as a stray blank run — and the
		// destination ends in the ONE newline it arrived with. Until 2026-08-27 this
		// assertion read `}\n\n`: the cut span reaches over the decl's line terminator, so
		// `declText` carried one newline and the destination's own was re-added on top of
		// it, leaving every move's destination one blank line past canonical.
		Assert.equals('package pkg;\n\nclass B {}\n\ntypedef Foo = {\n\tfinal x:Int;\n}\n', newB);
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
		// The source loses the blank line that separated the decl from the import block as well:
		// with nothing following the cut it is a trailing blank, which `fmt --list` rejects.
		Assert.equals('package pkg;\n', changeFor(changes, 'pkg/A.hx').newSource);
		// The destination arrived with no EOF newline; the appended declaration's last line still
		// gets the one terminator it needs, which the untrimmed `declText` used to supply.
		Assert.equals('package pkg;\n\nclass B {}\n\ntypedef Foo = {\n\tfinal x:Int;\n}\n', changeFor(changes, 'pkg/B.hx').newSource);
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
		Assert.equals('package pkg;\n', changeFor(changes, 'pkg/A.hx').newSource);
		Assert.equals('package pkg;\n\nclass B {}\n\ntypedef Foo = {\n\tfinal x:Int;\n}\n', changeFor(changes, 'pkg/B.hx').newSource);
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
			'package pkg;\n\nclass B {}\n\n@:keep\nprivate final class Hidden {\n\tpublic function new() {}\n}\n',
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
	 * An importer that reaches the moved type ONLY through `import pkg.A.Foo as F;` is repointed
	 * like any other, and keeps its binding. It used to be invisible twice over: an alias
	 * statement's `raw` is the ALIAS, so `filesImportingModule` did not list the file and the
	 * per-statement match did not fire either, and `importStatementText` had no alias suffix to
	 * emit even if it had. Compile-proved on Haxe 4.3.7 — the file was left on
	 * `import p.Thing as T;` after `Thing` moved into `p/Host.hx`, and the tree failed with
	 * `Module p.Thing does not define type Thing` / `Type not found : T`.
	 *
	 * The `in` spelling is asserted beside `as` because the two share one `ImportKind` and the
	 * re-emit therefore has to read the statement's own text to tell them apart; re-emitting an
	 * `in` importer as `as` would be a restyle of a file the caller only asked to repoint. The
	 * plain importer in the same scope is the control: it must still repoint the way it always
	 * did, so a pass cannot come from the alias arm and the plain arm both going silent.
	 */
	public function testAliasImporterRepointedKeepingItsBinding(): Void {
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 3, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: 'package pkg;\n\nclass Foo {}' },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' },
			{ file: 'pkg/Plain.hx', source: 'package pkg;\n\nimport pkg.A.Foo;\n\nclass Plain {\n\tvar f:Foo;\n}' },
			{ file: 'pkg/AsUser.hx', source: 'package pkg;\n\nimport pkg.A.Foo as F;\n\nclass AsUser {\n\tvar f:F;\n}' },
			{ file: 'pkg/InUser.hx', source: 'package pkg;\n\nimport pkg.A.Foo in G;\n\nclass InUser {\n\tvar f:G;\n}' }
		]);
		Assert.equals('package pkg;\n\nimport pkg.B.Foo;\n\nclass Plain {\n\tvar f:Foo;\n}', changeFor(changes, 'pkg/Plain.hx').newSource);
		Assert.equals(
			'package pkg;\n\nimport pkg.B.Foo as F;\n\nclass AsUser {\n\tvar f:F;\n}', changeFor(changes, 'pkg/AsUser.hx').newSource
		);
		Assert.equals(
			'package pkg;\n\nimport pkg.B.Foo in G;\n\nclass InUser {\n\tvar f:G;\n}', changeFor(changes, 'pkg/InUser.hx').newSource
		);
	}

	/**
	 * The DESTINATION's own alias import of the moved type is REPOINTED, not removed. A plain
	 * import of it becomes redundant once the type is local and is deleted; an alias import does
	 * not, because the destination's code names the type through the ALIAS and nothing else binds
	 * it. Deleting it left `p/Host.hx` compiling against a module that no longer defines the type
	 * (`Module p.Thing does not define type Thing` / `Type not found : T`, Haxe 4.3.7), and
	 * `import p.Host.Thing as T;` inside `p/Host.hx` — a module aliasing its own sub-type — was
	 * compiled to confirm the repointed form is legal.
	 */
	public function testDestinationAliasImportRepointedNotRemoved(): Void {
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 3, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: 'package pkg;\n\nclass Foo {}' },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nimport pkg.A.Foo as F;\n\nclass B {\n\tvar f:F;\n}' }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('import pkg.B.Foo as F;'), 'the destination alias is repointed at the new path');
		Assert.isFalse(newB.contains('import pkg.A.Foo as F;'), 'the old path is gone');
		Assert.isTrue(newB.contains('var f:F;'), 'the destination still names the type through its alias');
	}

	/**
	 * A cross-package move is NOT refused by the alias importer's own statement. The refusal scans
	 * for the old dotted path outside any import statement, and recognised an import by
	 * `imp.raw == path` — which for an alias is the ALIAS, so the `pkg.A.Foo` inside
	 * `import pkg.A.Foo as F;` read as a fully-qualified CODE reference. The move was refused with
	 * a message telling the file's author to convert it to a bare name "with an import", which is
	 * exactly what they had written. The genuine fully-qualified reference is the control and must
	 * still refuse.
	 */
	public function testCrossPackageAliasImporterNotMistakenForAnFqnReference(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/A.hx', source: 'package pkg;\n\nclass Foo {}' },
			{ file: 'other/B.hx', source: 'package other;\n\nclass B {}' },
			{ file: 'pkg/AsUser.hx', source: 'package pkg;\n\nimport pkg.A.Foo as F;\n\nclass AsUser {\n\tvar f:F;\n}' }
		];
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 3, 7, 'other/B.hx', files);
		Assert.isTrue(
			changeFor(changes, 'pkg/AsUser.hx').newSource.contains('import other.B.Foo as F;'), 'the alias importer is repointed'
		);
		assertErr(MoveSymbol.moveType('pkg/A.hx', 3, 7, 'other/B.hx', files.concat([
			{ file: 'pkg/Fqn.hx', source: 'package pkg;\n\nclass Fqn {\n\tvar f:pkg.A.Foo;\n}' }
		]), plugin(), typeRefShape()));
	}

	/**
	 * The destination's alias import is repointed only while the ALIAS still buys something. Two
	 * shapes decide it, and both were compiled on 4.3.7 before being pinned:
	 *
	 *  - a SELF-alias (`import pkg.A.Foo as Foo;`) binds the very name the moved declaration now
	 *    binds, so after the move it is redundant exactly as a plain import is. Repointing it
	 *    leaves `pkg/B.hx` importing its own type under its own name — which compiles, and which
	 *    no lint rule reports (`unused-import` and `redundant-import` both ask about the BOUND
	 *    NAME, and that name IS used), so nothing downstream would ever have caught it. It is
	 *    deleted.
	 *  - the moved type becoming the destination's MAIN type makes the repointed statement
	 *    `import pkg.B as F;` inside `pkg/B.hx` — a module importing ITSELF rather than a
	 *    sub-type of itself. That is the shape the other destination pin does not reach, and it
	 *    compiles; the alias is still the only binding for `F`, so it is kept.
	 */
	public function testDestinationSelfAliasRemovedAndMainTypeAliasKept(): Void {
		final self: Array<MoveChange> = okChanges('pkg/A.hx', 3, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: 'package pkg;\n\nclass Foo {}' },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nimport pkg.A.Foo as Foo;\n\nclass B {\n\tvar f:Foo;\n}' }
		]);
		final newSelf: String = changeFor(self, 'pkg/B.hx').newSource;
		Assert.isFalse(newSelf.contains('import'), 'a self-alias of the moved type is redundant once it is local');
		Assert.isTrue(newSelf.contains('var f:Foo;'), 'the reference resolves against the moved declaration');

		// `B` moving into `pkg/B.hx` becomes that module's MAIN type, so the new path is `pkg.B`.
		final main: Array<MoveChange> = okChanges('pkg/A.hx', 5, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: 'package pkg;\n\nclass A {}\n\nclass B {}' },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nimport pkg.A.B as F;\n\nclass B2 {\n\tvar f:F;\n}' }
		]);
		final newMain: String = changeFor(main, 'pkg/B.hx').newSource;
		Assert.isTrue(newMain.contains('import pkg.B as F;'), 'a main-type destination repoints at the module path');
		Assert.isTrue(newMain.contains('var f:F;'), 'the alias is still the only binding for F');
	}

	/**
	 * A dependency the moved declaration reaches ONLY through `import p.Dep as D;` is CARRIED into
	 * the destination, spelled as the statement that bound it. The carry filter kept `Import` /
	 * `Using` and dropped `Alias`, so the declaration arrived at a file with no binding for `D`;
	 * letting the kind through alone would have emitted `import D;`, since `raw` is the ALIAS.
	 * Compile-proved on Haxe 4.3.7: before, the moved tree stopped at
	 * `q/Host.hx:11: characters 21-22 : Type not found : D`; after, it compiles.
	 *
	 * The `in` spelling is asserted beside `as` — one `ImportKind`, told apart only by the
	 * statement's own text — and the plain-import dependency is the control that must keep being
	 * carried exactly as it always was, so a green run cannot come from the carry going silent.
	 */
	public function testAliasDependencyIsCarriedIntoTheDestination(): Void {
		inline function destAfterMove(binding: String, denotes: String): String {
			return changeFor(okChanges('q/Mover.hx', 5, 7, 'q/Host.hx', [
				{ file: 'p/Dep.hx', source: 'package p;\n\nclass Dep {}' },
				{ file: 'q/Mover.hx', source: 'package q;\n\n$binding\n\nclass Mover {\n\tvar d:$denotes;\n}' },
				{ file: 'q/Host.hx', source: 'package q;\n\nclass Host {}' }
			]), 'q/Host.hx').newSource;
		}
		Assert.isTrue(destAfterMove('import p.Dep as D;', 'D').contains('import p.Dep as D;'), 'the `as` binding is carried whole');
		Assert.isTrue(destAfterMove('import p.Dep in D;', 'D').contains('import p.Dep in D;'), 'and the `in` spelling is preserved');
		Assert.isTrue(destAfterMove('import p.Dep;', 'Dep').contains('import p.Dep;'), 'the plain control is carried as before');
		// The destination already binding the SAME name to the SAME module is the whole effect of
		// keeping the path in the `already` identity: nothing is carried, so `D` is bound once.
		final held: String = changeFor(okChanges('q/Mover.hx', 5, 7, 'q/Host.hx', [
			{ file: 'p/Dep.hx', source: 'package p;\n\nclass Dep {}' },
			{ file: 'q/Mover.hx', source: 'package q;\n\nimport p.Dep as D;\n\nclass Mover {\n\tvar d:D;\n}' },
			{ file: 'q/Host.hx', source: 'package q;\n\nimport p.Dep as D;\n\nclass Host {\n\tvar h:D;\n}' }
		]), 'q/Host.hx').newSource;
		Assert.equals(1, held.split('import p.Dep as D;').length - 1, 'an identical binding already there is not carried again');
	}

	/**
	 * A dependency import is REFUSED, not carried, when the destination already binds that simple
	 * name to a different module — the shape that made `move` a silent miscompile. Measured on
	 * 11f22a25 and compile-run on Haxe 4.3.7: with `p/Host.hx` holding `import r.Dep;` and the
	 * moved decl reaching `q.Dep`, the op wrote both files, the tree compiled with rc 0 and no
	 * diagnostic, and `Host`'s own `new Dep()` traced `q.Dep` where it had traced `r.Dep`.
	 *
	 * Three arms, one gate, because Haxe's resolution order decides which SIDE silently moves: an
	 * import the destination already has (it wins over the carried one only until the carried one
	 * is written below it, so the DESTINATION rebinds), a sibling module of the destination's own
	 * package (an import beats same-package visibility, same direction), and a type the destination
	 * MODULE declares (that one beats every import, so the MOVED code rebinds instead — which is
	 * why it refuses without asking whether the destination names it). The alias spelling is the
	 * same defect in different clothes and takes the same gate.
	 */
	public function testCarriedImportCollidingWithADestinationBindingRefused(): Void {
		inline function move(mover: String, host: String, extra: Array<{ file: String, source: String }>): MoveResult {
			final files: Array<{ file: String, source: String }> = [
				{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' },
				{ file: 'p/Mover.hx', source: mover },
				{ file: 'p/Host.hx', source: host }
			];
			return MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', files.concat(extra), plugin(), typeRefShape());
		}
		final plainMover: String = 'package p;\n\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n}';
		final plainHost: String = 'package p;\n\nclass Host {\n\tvar h:Dep;\n}';
		// The destination imports the same simple name from another module.
		assertErrContains(
			move(
				plainMover, 'package p;\n\nimport r.Dep;\n\nclass Host {\n\tvar h:Dep;\n}',
				[{ file: 'r/Dep.hx', source: 'package r;\n\nclass Dep {}' }]
			),
			'already binds "Dep" to r.Dep'
		);
		// A sibling module of the destination's own package declares it as its MAIN type.
		assertErrContains(
			move(plainMover, plainHost, [{ file: 'p/Dep.hx', source: 'package p;\n\nclass Dep {}' }]), 'already binds "Dep" to p.Dep'
		);
		// The destination MODULE declares it — the arm where the carried import would lose and the
		// MOVED code is what silently rebinds, so it refuses without asking whether the destination
		// names `Dep` at all.
		assertErrContains(move(plainMover, 'package p;\n\nclass Host {}\n\nclass Dep {}', []), 'declares "Dep" itself (p.Host.Dep)');
		// The alias spelling of the first arm: one bound name, two targets.
		assertErrContains(
			move(
				'package p;\n\nimport q.Dep as D;\n\nclass Mover {\n\tvar d:D;\n}',
				'package p;\n\nimport r.Dep as D;\n\nclass Host {\n\tvar h:D;\n}',
				[{ file: 'r/Dep.hx', source: 'package r;\n\nclass Dep {}' }]
			),
			'already binds "D" to r.Dep'
		);
		// The control: nothing at the destination binds `Dep`, so the carry happens as before.
		switch move(plainMover, plainHost, []) {
			case Ok(changes, _):
				Assert.isTrue(changeFor(changes, 'p/Host.hx').newSource.contains('import q.Dep;'), 'the uncontested carry still happens');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * The collision gate runs on EVERY dependency name, not only on the ones with an import statement
	 * to carry. A dependency the source reaches by same-package visibility has no provider, so the
	 * first draft of the gate skipped it entirely — and it is the route with the fewest moving parts:
	 * nothing is carried, so at the destination the moved code simply takes the DESTINATION's ladder.
	 * Compile-proved on 4.3.7: `Moved.make()` returned `p.Dep` before and `r.Dep` after, rc 0 and no
	 * diagnostic, with `p/Host.hx` holding `import r.Dep;` and no import anywhere in `p/Mover.hx`.
	 *
	 * The second arm is the control the gate must NOT refuse, and it is the one that made the
	 * sibling-package walk read `isMain`: a SUB-module type of a sibling module is not visible by
	 * simple name (`Type not found : Dep` on 4.3.7), so it binds nothing and the move proceeds.
	 */
	public function testBareSamePackageDependencyIsPricedToo(): Void {
		inline function move(extra: Array<{ file: String, source: String }>, host: String): MoveResult {
			return MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', [
				{ file: 'p/Mover.hx', source: 'package p;\n\nclass Keep {}\n\nclass Mover {\n\tvar d:Dep;\n}' },
				{ file: 'p/Host.hx', source: host },
				{ file: 'r/Dep.hx', source: 'package r;\n\nclass Dep {}' }
			].concat(extra), plugin(), typeRefShape());
		}
		assertErrContains(
			move([{ file: 'p/Dep.hx', source: 'package p;\n\nclass Dep {}' }], 'package p;\n\nimport r.Dep;\n\nclass Host {}'),
			'no import to carry'
		);
		switch move(
			[{ file: 'p/Other.hx', source: 'package p;\n\nclass Other {}\n\nclass Dep {}' }], 'package p;\n\nclass Host {\n\tvar h:Dep;\n}'
		) {
			case Ok(_, _):
				Assert.pass();
			case Err(message):
				Assert.fail('a sibling module\'s SUB-module type binds nothing here, got Err: $message');
		}
	}

	/**
	 * The destination a move writes is CANONICAL — the property `fmt --list` decides, and the one a
	 * span-splicing op has to hold by construction, since it never re-emits through the writer.
	 *
	 * Two things used to break it, both invisible to every gate the project runs (no gate formats a
	 * move's output): a carried import written directly under `package …;` with no blank line
	 * between them, and the destination's own trailing newline re-added on top of the one the cut
	 * span already carried, which left EVERY move's destination one blank line long. The second arm is the offset-0 anchor of a module with no package declaration, where the blank
	 * line the fresh import owes is the one BELOW it.
	 */
	public function testDestinationIsCanonicalAfterAMove(): Void {
		final carried: Array<MoveChange> = okChanges('p/Mover.hx', 5, 7, 'p/Host.hx', [
			{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n}\n' },
			{ file: 'p/Host.hx', source: 'package p;\n\nclass Host {}\n' }
		]);
		Assert.equals(
			'package p;\n\nimport q.Dep;\n\nclass Host {}\n\nclass Mover {\n\tvar d:Dep;\n}\n', changeFor(carried, 'p/Host.hx').newSource
		);
		// A file with no package declaration anchors the carried line at offset 0 instead, where the
		// blank line it owes is the one AFTER it.
		final rootPkg: Array<MoveChange> = okChanges('Mover.hx', 5, 7, 'Host.hx', [
			{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' },
			{ file: 'Mover.hx', source: 'import q.Dep;\n\nclass Keep {}\n\nclass Mover {\n\tvar d:Dep;\n}\n' },
			{ file: 'Host.hx', source: 'class Host {}\n' }
		]);
		Assert.equals('import q.Dep;\n\nclass Host {}\n\nclass Mover {\n\tvar d:Dep;\n}\n', changeFor(rootPkg, 'Host.hx').newSource);
	}

	/**
	 * A destination whose whole body sits inside one `#if` region carries its import run there, so
	 * `ImportOrder.insertionFor` anchors INSIDE the guard — the third of the three anchors a file with
	 * no top-level import offers, and the one the first draft of this slice left without a `trail`.
	 * `fmt --list` rejected the result: the carried line landed welded to the first declaration.
	 */
	public function testCarriedImportInsideAWholeBodyGuardKeepsItsBlankLine(): Void {
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 5, 7, 'p/Host.hx', [
			{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n}\n' },
			{ file: 'p/Host.hx', source: 'package p;\n\n#if js\nclass Host {}\n#end\n' }
		]);
		Assert.equals(
			'package p;\n\n#if js\nimport q.Dep;\n\nclass Host {}\n#end\n\nclass Mover {\n\tvar d:Dep;\n}\n',
			changeFor(changes, 'p/Host.hx').newSource
		);
	}

	/**
	 * A destination whose only imports are `#if`-guarded still anchors on the PACKAGE declaration —
	 * `lastHeaderEnd` reads direct children and a guarded import is not one. The fresh line then goes
	 * UNDER the blank that already separates the package from the header, not above it: inserting
	 * above pushed that blank down between the fresh import and the `#if` region, and canonical Haxe
	 * writes a guarded import run flush under the import above it. The destination here is canonical
	 * before the move, which is what makes the result a regression rather than a pre-existing mess.
	 */
	public function testCarriedImportKeepsAGuardedRunAdjacent(): Void {
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 5, 7, 'p/Host.hx', [
			{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' },
			{ file: 'c/D.hx', source: 'package c;\n\nclass D {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n}\n' },
			{ file: 'p/Host.hx', source: 'package p;\n\n#if js\nimport c.D;\n#end\n\nclass Host {}\n' }
		]);
		Assert.equals(
			'package p;\n\nimport q.Dep;\n#if js\nimport c.D;\n#end\n\nclass Host {}\n\nclass Mover {\n\tvar d:Dep;\n}\n',
			changeFor(changes, 'p/Host.hx').newSource
		);
	}

	/**
	 * A declaration's own type PARAMETER stands in a type position and is collected as a dependency,
	 * but it shadows every module-level binding of that name inside the declaration — so pricing it
	 * asks about a type the moved code never means. `class Mover<Key>` moved beside a `p/Key.hx` and
	 * into a destination holding `import r.Key;` refused a move whose every `Key` is the parameter.
	 */
	public function testTypeParameterIsNotPricedAsADependency(): Void {
		switch MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', [
			{ file: 'p/Key.hx', source: 'package p;\n\nclass Key {}' },
			{ file: 'r/Key.hx', source: 'package r;\n\nclass Key {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nclass Keep {}\n\nclass Mover<Key> {\n\tvar k:Key;\n}' },
			{ file: 'p/Host.hx', source: 'package p;\n\nimport r.Key;\n\nclass Host {\n\tvar h:Key;\n}' }
		], plugin(), typeRefShape()) {
			case Ok(_, _):
				Assert.pass();
			case Err(message):
				Assert.fail('a type parameter shadows the name it spells, got Err: $message');
		}
	}

	/**
	 * A module that is only `package pkg;` with NO terminating newline is due BOTH reasons to lead
	 * with one: the newline that terminates the header's last line, and the blank line canonical Haxe
	 * puts between the package and the import block. The first draft spelled them as one ternary,
	 * which can only ever answer with one.
	 */
	public function testImportAnchorOwesBothLeadingNewlines(): Void {
		final anchor: ImportAnchor = MoveSymbol.importAnchor('package pkg;', plugin(), 'a.Bee');
		Assert.equals('\n\n', anchor.lead);
		Assert.equals(12, anchor.offset);
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

	/**
	 * `assertErr` with the refusal's own sentence pinned. `move` refuses for a dozen reasons — a
	 * cross-package fully-qualified reference, an ambiguous or missing type, a decl sharing a line, a
	 * scope file that does not parse, a module-private type still referenced — so a bare `Err` says
	 * only that SOMETHING objected, and a future guard can keep a collision test green while the
	 * collision gate itself is gone.
	 */
	private function assertErrContains(result: MoveResult, needle: String): Void {
		switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
			case Err(message):
				Assert.isTrue(message.contains(needle), 'Err "$message" should mention "$needle"');
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
