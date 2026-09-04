package unit.query;

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
	 * cut. The cut stays exactly what the trim leaves — the decl's own
	 * lines plus one newline. The blank run it used to leave BEHIND was
	 * frozen here as "pre-existing behaviour"; `cutEditSpan` now absorbs it,
	 * so the two blanks that used to end up adjacent are one.
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
		Assert.equals('package pkg;\n\n/** the bar */\ntypedef Bar = {\n\tfinal y:Int;\n};', newA);
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
		// The control: the destination neither binds NOR names `Dep`, so the carry happens as before.
		// It used to reuse `plainHost`, which names `Dep` while nothing in the scope binds it — source
		// that does not compile (`Type not found : Dep`, 4.3.7), and the ambient-shadowing arm now
		// refuses it correctly. A control has to be a file Haxe would accept.
		switch move(plainMover, 'package p;\n\nclass Host {\n\tvar h:Int;\n}', []) {
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
	 * A STRING literal is the other half of the same question, and nothing masks one: the reference
	 * scans see a string's bytes exactly as they see code.
	 *
	 * The comment spelling of both arms is already pinned — `testACommentOnlyMentionStillCountsAsAReference`
	 * for the import and `testACommentOnlyMentionDoesNotRefuseAPrivateType` for the private refusal. What
	 * is new here is the STRING mention, and the two arms in one fixture: the TEXT scan (`namesAnyOf`)
	 * counts it, which is the conservative direction wherever the answer WRITES an import (a redundant
	 * import costs a lint advisory, a missing one costs the build), while the PROVEN scan
	 * (`namesAnyNodeOf`) does not — and that arm REFUSES rather than imports, because a module-`private`
	 * type cannot be imported from another module at all. Same file, same single mention, opposite
	 * answers.
	 */
	public function testAStringOnlyMentionBuysTheImportAndDoesNotRefuseThePrivateMove(): Void {
		inline function moveWith(modifier: String): MoveResult {
			final mover: String = 'package p;\n\nclass Keep {\n\n\tpublic function new() {}\n\n\tpublic function label(): String return '
				+ '"Moved by hand";\n\n}\n\n${modifier}class Moved {\n\n\tpublic static function tag(): Int return 1;\n\n}\n';
			return MoveSymbol.moveType('p/Mover.hx', 11, 7 + modifier.length, 'p/Host.hx', [
				{ file: 'p/Mover.hx', source: mover },
				{ file: 'p/Host.hx', source: 'package p;\n\nclass Host {\n\n\tpublic function new() {}\n\n}\n' }
			], plugin(), typeRefShape());
		}
		switch moveWith('') {
			case Ok(changes, _):
				Assert.isTrue(
					changeFor(changes, 'p/Mover.hx').newSource.contains('package p;\n\nimport p.Host.Moved;\n\nclass Keep {'),
					'a string-literal-only mention still buys the repair import'
				);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
		switch moveWith('private ') {
			case Ok(changes, _):
				Assert.isFalse(
					changeFor(changes, 'p/Mover.hx').newSource.contains('import'), 'a module-private type is never imported back'
				);
			case Err(message):
				Assert.fail('the proven scan must not read a string literal as a reference: $message');
		}
	}

	/**
	 * A comment ending in a PERIOD, directly above a line that starts with the moved type's name.
	 *
	 * `namesAnyOf`'s comment regions are NOT a mask that drops mentions written inside comments — the
	 * scan counts those deliberately, which is the conservative direction when the answer WRITES an
	 * import. What the regions decide is the QUALIFICATION test: a name a `.` precedes is spelled
	 * fully qualified and owes no import, and `qualifiedBefore` only believes that `.` when it is not
	 * itself inside a comment. Hand the scan no regions and a comment's own full stop becomes that
	 * `.` — the last real reference in the file goes uncounted, the repair import is never written,
	 * and the source file stops compiling with `Type not found`. Measured: with the regions dropped
	 * this fixture loses `import p.Host.Moved;` and nothing else changes.
	 *
	 * The second arm is the control — the same file with the period removed answers identically,
	 * which is what makes the first arm a statement about the regions rather than about the fixture.
	 */
	public function testACommentsTrailingPeriodDoesNotHideTheReferenceOwedARepairImport(): Void {
		inline function repairedSourceFor(note: String): String {
			final mover: String = 'package p;\n\nclass Keep {\n\n\tpublic function new() {}\n\n\tpublic function use(): Int {\n\t\t// $note'
				+ '\n\t\tMoved.tag();\n\t\treturn 1;\n\t}\n\n}\n\nclass Moved {\n\n\tpublic static function tag(): Int return 1;\n\n}\n';
			return changeFor(okChanges('p/Mover.hx', 15, 7, 'p/Host.hx', [
				{ file: 'p/Mover.hx', source: mover },
				{ file: 'p/Host.hx', source: 'package p;\n\nclass Host {\n\n\tpublic function new() {}\n\n}\n' }
			]), 'p/Mover.hx').newSource;
		}
		Assert.isTrue(
			repairedSourceFor('A note that ends in a period.').contains('package p;\n\nimport p.Host.Moved;\n\nclass Keep {'),
			'the comment\'s full stop must not read as a qualification of the `Moved` on the next line'
		);
		Assert.isTrue(
			repairedSourceFor('A note that ends in a word').contains('import p.Host.Moved;'),
			'the control arm must carry the same repair import'
		);
	}

	/**
	 * The carry-collision scan of the DESTINATION reads the DESTINATION's own comment regions.
	 *
	 * `referencedInDest` is handed a region array, and the file it scans is `destSource` — two things
	 * a single-array hop can silently disagree about. It did: a seam refactor across 109 files passed
	 * the CURSOR file's regions into this scan, and every gate the campaign runs stayed green, because
	 * no capture drives a move op at all. Here the cursor file's comment is a doc block near its top
	 * and the destination's is deep inside a method, so the two region sets cannot stand in for each
	 * other: with the destination's, the `.` closing its comment is not a qualification and the
	 * reference is seen, which is the refusal; with the cursor's, that same `.` reads as a
	 * qualification and the import is carried — silently rebinding the destination's own `Dep`.
	 *
	 * The control is the shape the qualification test is FOR: a genuinely qualified `q.Dep.tag()` in
	 * the destination is not an unqualified reference and does not contest the carry.
	 */
	public function testTheDestinationCollisionScanReadsTheDestinationsOwnComments(): Void {
		inline function moveInto(destBody: String): MoveResult {
			final cursor: String = 'package p;\n\nimport q.Dep;\n\n/**\n * A doc block only the CURSOR file has.\n */\n'
				+ 'class Mover {\n\n\tpublic function new() {}\n\n\tpublic function m(): Int return Dep.tag();\n\n}\n';
			final host: String = 'package p;\n\nclass Host {\n\n\tpublic function new() {}\n\n\tpublic function h(): Int {\n$destBody'
				+ '\t\treturn 1;\n\t}\n\n}\n';
			return MoveSymbol.moveType('p/Mover.hx', 8, 7, 'p/Host.hx', [
				{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {\n\n\tpublic static function tag(): Int return 1;\n\n}\n' },
				{ file: 'p/Mover.hx', source: cursor },
				{ file: 'p/Host.hx', source: host }
			], plugin(), typeRefShape());
		}
		assertErrContains(
			moveInto('\t\t// A note that ends in a period.\n\t\tDep.tag();\n'),
			'references "Dep" while nothing in the indexed scope binds it there'
		);
		switch moveInto('\t\tq.Dep.tag();\n') {
			case Ok(changes, _):
				Assert.isTrue(
					changeFor(changes, 'p/Host.hx').newSource.contains('import q.Dep;'), 'a qualified mention does not contest the carry'
				);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A dependency the DESTINATION resolves through a binding the scope index cannot name. Two
	 * spellings, both compile-run to a CHANGED runtime class on the base engine with rc 0 and no
	 * output: a ROOT-PACKAGE module (`Dep.hx` at the top level, which the index CAN name once the
	 * ladder has a top-level rung — `Dep` -> `q.Dep`) and the standard library's own top-level scope
	 * (`Date`, which it never can — `Date` -> `q.Date`). A carried import outranks both.
	 */
	public function testCarryOverAnAmbientDestinationBindingRefused(): Void {
		inline function move(host: String, extra: Array<{ file: String, source: String }>): MoveResult {
			final files: Array<{ file: String, source: String }> = [
				{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' },
				{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n}' },
				{ file: 'p/Host.hx', source: host }
			];
			return MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', files.concat(extra), plugin(), typeRefShape());
		}
		final namingHost: String = 'package p;\n\nclass Host {\n\tvar h:Dep;\n}';
		assertErrContains(move(namingHost, [{ file: 'Dep.hx', source: 'class Dep {}' }]), 'already binds "Dep" to Dep');
		assertErrContains(move(namingHost, []), 'references "Dep" while nothing in the indexed scope binds it');
		// The control is a destination that neither binds NOR names `Dep` — the only shape of the
		// three that is valid Haxe on its own, and the carry still happens for it.
		switch move('package p;\n\nclass Host {\n\tvar h:Int;\n}', []) {
			case Ok(changes, _):
				Assert.isTrue(changeFor(changes, 'p/Host.hx').newSource.contains('import q.Dep;'), 'the uncontested carry still happens');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * The mirror: the SOURCE's binding is the one the index cannot name, and the destination names
	 * something for the same simple name. Nothing is carried for any of the three spellings, so the
	 * moved code takes the destination's ladder — compile-run to a changed class with rc 0 for the
	 * stdlib one (`Date` -> `q.Date`) and the guarded one (`q.Dep` -> `r.Dep`).
	 */
	public function testUnnameableSourceBindingAgainstANamedDestinationRefused(): Void {
		inline function move(dep: String, mover: String, line: Int, extra: Array<{ file: String, source: String }>): MoveResult {
			final files: Array<{ file: String, source: String }> = [
				{ file: 'p/Mover.hx', source: mover },
				{ file: 'r/$dep.hx', source: 'package r;\n\nclass $dep {}' },
				{ file: 'p/Host.hx', source: 'package p;\n\nimport r.$dep;\n\nclass Host {\n\tvar h:$dep;\n}' }
			];
			return MoveSymbol.moveType('p/Mover.hx', line, 7, 'p/Host.hx', files.concat(extra), plugin(), typeRefShape());
		}
		// The stdlib spelling. `Date` rather than a made-up name so the fixture is a program Haxe would
		// accept: nothing in the scope binds it, and the source still resolves it — to the STDLIB type,
		// which is precisely the binding the index cannot name.
		assertErrContains(
			move('Date', 'package p;\n\nclass Mover {\n\tvar d:Date;\n}', 3, []), 'the source reaches it outside the indexed scope'
		);
		// The `#if`-guarded provider: a guarded import is never carried, so the moved code arrives bare.
		assertErrContains(
			move(
				'Dep', 'package p;\n\n#if neko\nimport q.Dep;\n#end\n\nclass Mover {\n\tvar d:Dep;\n}', 7,
				[{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' }]
			),
			'the source binds it to q.Dep inside a `#if` guard'
		);
		// A package WILDCARD at the source IS nameable once the ladder has a wildcard rung, so this one
		// reports the resolved path rather than the unknown-binding arm.
		assertErrContains(
			move(
				'Dep', 'package p;\n\nimport q.*;\n\nclass Mover {\n\tvar d:Dep;\n}', 5,
				[{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' }]
			),
			'reaches "Dep" as q.Dep'
		);
	}

	/**
	 * The destination's binding comes from a package WILDCARD or a `#if`-guarded import. Both were
	 * invisible to the ladder and both were compile-run to a changed class with rc 0: `import r.*`
	 * lost to the carried `import q.Dep;` (`r.Dep` -> `q.Dep`), and with a guarded `import r.Dep;`
	 * the loser depends only on which line the anchor picked — under `-D neko` the MOVED code went
	 * `q.Dep` -> `r.Dep` with the carry above the guard, and the DESTINATION's went the other way
	 * with an unguarded import below it.
	 */
	public function testDestinationWildcardAndGuardedBindingsAreSeen(): Void {
		inline function move(host: String): MoveResult {
			final files: Array<{ file: String, source: String }> = [
				{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' },
				{ file: 'r/Dep.hx', source: 'package r;\n\nclass Dep {}' },
				{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n}' },
				{ file: 'p/Host.hx', source: host }
			];
			return MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', files, plugin(), typeRefShape());
		}
		assertErrContains(move('package p;\n\nimport r.*;\n\nclass Host {\n\tvar h:Dep;\n}'), 'already binds "Dep" to r.Dep');
		assertErrContains(
			move('package p;\n\n#if neko\nimport r.Dep;\n#end\n\nclass Host {\n\tvar h:Dep;\n}'),
			'binds "Dep" to r.Dep inside a `#if` guard'
		);
		// A wildcard of a package the index does not hold names nothing, so it leaves the destination
		// unbound — the ambient arm answers, not the wildcard rung.
		assertErrContains(
			move('package p;\n\nimport x.*;\n\nclass Host {\n\tvar h:Dep;\n}'),
			'references "Dep" while nothing in the indexed scope binds it'
		);
	}

	/**
	 * A dependency the source reaches with NO import statement, moved into a destination the index
	 * says nothing about. There is nothing to carry, so the moved code takes that file's own ladder —
	 * compile-run on the base engine, a same-package `p.Date` shadowing the stdlib came back as the
	 * STDLIB `Date` at a destination in another package, rc 0.
	 */
	public function testNoCarryIntoAnUnnameableDestinationBindingRefused(): Void {
		inline function move(destFile: String, destSource: String): MoveResult {
			final files: Array<{ file: String, source: String }> = [
				{ file: 'p/Dep.hx', source: 'package p;\n\nclass Dep {}' },
				{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {\n\tvar d:Dep;\n}' },
				{ file: destFile, source: destSource }
			];
			return MoveSymbol.moveType('p/Mover.hx', 3, 7, destFile, files, plugin(), typeRefShape());
		}
		assertErrContains(
			move('s/Host.hx', 'package s;\n\nclass Host {}'), 'with no import to carry, and nothing in the indexed scope binds'
		);
		// The control: a destination in the SAME package sees the same sibling module, so the binding
		// is reproduced and the move goes through with nothing carried.
		switch move('p/Host.hx', 'package p;\n\nclass Host {}') {
			case Ok(changes, _):
				final host: String = changeFor(changes, 'p/Host.hx').newSource;
				Assert.isTrue(host.contains('class Mover') && !host.contains('import'), 'the same-package move carries nothing');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * Two files spelling the SAME import statement for a dependency the index cannot name is not a
	 * collision — it is the commonest macro-module shape there is (`#if macro import haxe.macro.Expr;`
	 * on both sides), and four of eleven changed outcomes in a 60-case `move` census over the Pony tree
	 * were exactly that. Both halves of the reconciliation are exercised: the statement that binds the
	 * name directly, and the MODULE import that binds it as one of the module's other types.
	 */
	public function testTheSameUnnameableImportOnBothSidesIsNotACollision(): Void {
		inline function move(mover: String, host: String, dep: String): Void {
			final files: Array<{ file: String, source: String }> = [
				{ file: 'p/Mover.hx', source: mover },
				{ file: 'p/Host.hx', source: host }
			];
			switch MoveSymbol.moveType('p/Mover.hx', 7, 7, 'p/Host.hx', files, plugin(), typeRefShape()) {
				case Ok(changes, _):
					Assert.isTrue(changeFor(changes, 'p/Host.hx').newSource.contains('var d:$dep'), 'the decl moved');
				case Err(message):
					Assert.fail('expected Ok, got Err: $message');
			}
		}
		move(
			'package p;\n\n#if macro\nimport x.Ctx;\n#end\n\nclass Mover {\n\tvar d:Ctx;\n}',
			'package p;\n\n#if macro\nimport x.Ctx;\n#end\n\nclass Host {\n\tvar h:Ctx;\n}', 'Ctx'
		);
		move(
			'package p;\n\n#if macro\nimport x.Mod;\n#end\n\nclass Mover {\n\tvar d:Sub;\n}',
			'package p;\n\n#if macro\nimport x.Mod.Sub;\n#end\n\nclass Host {\n\tvar h:Sub;\n}', 'Sub'
		);
	}

	/**
	 * `import q.Mod;` binds every type MODULE `q.Mod` declares, not only the one sharing its name —
	 * compile-run on 4.3.7, `new Sub()` under that single import built a `q.Sub`. Reading only the
	 * import's last segment left `Sub` unbound, and an unbound source name is what the gate refuses on,
	 * so the rung is what turns a wrong-message refusal into the right one.
	 */
	public function testModuleImportBindsTheModulesOtherTypes(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'r/Sub.hx', source: 'package r;\n\nclass Sub {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Mod;\n\nclass Mover {\n\tvar d:Sub;\n}' },
			{ file: 'p/Host.hx', source: 'package p;\n\nimport r.Sub;\n\nclass Host {\n\tvar h:Sub;\n}' }
		];
		assertErrContains(
			MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', files, plugin(), typeRefShape()), 'reaches "Sub" as q.Mod.Sub'
		);
	}

	/**
	 * A METHOD's type parameters are not projected by the grammar at all, so they reach the dependency
	 * scan only through the annotations that spell them and look exactly like a dependency on a module
	 * of that name. `class Mover` beside a `p/Item.hx` was refused a move over a `pick<Item>` whose
	 * every `Item` was the parameter — RED on the base engine, which reported the sibling module.
	 */
	public function testMethodTypeParameterIsNotPricedAsADependency(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' },
			{ file: 'p/Item.hx', source: 'package p;\n\nclass Item {}' },
			{ file: 'r/Item.hx', source: 'package r;\n\nclass Item {}' },
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n\n'
					+ '\tpublic function pick<Item>(x:Item):Item return x;\n}'
			},
			{ file: 'p/Host.hx', source: 'package p;\n\nimport r.Item;\n\nclass Host {\n\tvar h:Item;\n}' }
		];
		switch MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', files, plugin(), typeRefShape()) {
			case Ok(changes, _):
				Assert.isTrue(changeFor(changes, 'p/Host.hx').newSource.contains('pick<Item>'), 'the generic method moved');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A module-`private` MAIN type is invisible by simple name outside its own module — compile-proved
	 * on 4.3.7, `private class Dep` in `p/Dep.hx` is `Type not found : Dep` from `p/Host.hx` — so
	 * counting one invents a binding, and the unnameable-source arm then refuses a move that was correct.
	 *
	 * The fixture is a program Haxe accepts: `s/Date.hx` keeps its private main type invisible, so BOTH
	 * files mean the stdlib `Date` and the move genuinely changes nothing. Green at base BY CONSTRUCTION
	 * (the base gate never reached the phantom — it skipped every name it could not name at the source),
	 * so the `isPrivate` filter is proved by MUTATION instead: drop `!t.isPrivate` from the same-package
	 * rung and this test alone flips.
	 */
	public function testPrivateSiblingMainTypeIsNotABinding(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 's/Date.hx', source: 'package s;\n\nprivate class Date {}\n\nclass DateHelper {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {\n\tvar d:Date;\n}' },
			{ file: 's/Host.hx', source: 'package s;\n\nclass Host {}' }
		];
		switch MoveSymbol.moveType('p/Mover.hx', 3, 7, 's/Host.hx', files, plugin(), typeRefShape()) {
			case Ok(changes, _):
				Assert.isTrue(changeFor(changes, 's/Host.hx').newSource.contains('class Mover'), 'the decl moved');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A destination holding no declaration of its own puts the import anchor at or past the point the
	 * declaration is appended at, so the carried line was spliced BELOW it — `import and using may not
	 * appear after a declaration`, compile-proved on both shapes. The assertions are whole-source so
	 * neither the order nor the blank lines can drift.
	 */
	public function testCarriedImportIntoAHeaderOnlyDestinationStaysAboveTheDeclaration(): Void {
		inline function move(host: String): String {
			final files: Array<{ file: String, source: String }> = [
				{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' },
				{ file: 'q/Other.hx', source: 'package q;\n\nclass Other {}' },
				{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n}' },
				{ file: 'p/Host.hx', source: host }
			];
			return switch MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', files, plugin(), typeRefShape()) {
				case Ok(changes, _): changeFor(changes, 'p/Host.hx').newSource;
				case Err(message): 'ERR: $message';
			}
		}
		Assert.equals('package p;\n\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n}\n', move('package p;\n'));
		Assert.equals(
			'package p;\n\nimport q.Other;\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n}\n', move('package p;\n\nimport q.Other;\n')
		);
		// The same two headers with NO trailing newline. That is the boundary: the anchor lands exactly
		// ON the append point rather than past it, and a `>` test sent both straight back down the
		// two-edit path whose output is `import and using may not appear after a declaration`.
		Assert.equals('package p;\n\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n}\n', move('package p;'));
		Assert.equals(
			'package p;\n\nimport q.Other;\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n}\n', move('package p;\n\nimport q.Other;')
		);
	}

	/**
	 * `import pkg.Module.*` binds NO TYPE — it imports that module's STATIC FIELDS, measured on 4.3.7
	 * (`trace(STATIC_FIELD)` prints; `new Mod()` and `new Sub()` are both `Type not found`). Modelling
	 * it as a rung invented a binding, and the invented binding EQUALLED `wanted`, which cancelled the
	 * ambient refusal one line later: the destination's `Sub` (the root-package module) came back as
	 * `q.Mod.Sub` with rc 0.
	 */
	public function testModuleWildcardBindsNoTypeSoItIsNotARung(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'Sub.hx', source: 'class Sub {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Mod.Sub;\n\nclass Mover {\n\tvar d:Sub;\n}' },
			{ file: 'p/Host.hx', source: 'package p;\n\nimport q.Mod.*;\n\nclass Host {\n\tvar h:Sub;\n}' }
		];
		assertErrContains(
			MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', files, plugin(), typeRefShape()), 'already binds "Sub" to Sub'
		);
	}

	/**
	 * A method's `<Dep>` shadows `Dep` INSIDE that method and nowhere else, so un-pricing the name over
	 * the whole moved declaration dropped a sibling `var d:Dep;` from the gate entirely — compile-run to
	 * a changed runtime class with rc 0, on a move the base engine refused. The shadow is subtracted per
	 * OCCURRENCE, which is why the same name can be a parameter at one position and a dependency at
	 * another.
	 */
	public function testMethodTypeParameterShadowsOnlyItsOwnFunction(): Void {
		inline function move(mover: String): MoveResult {
			final files: Array<{ file: String, source: String }> = [
				{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' },
				{ file: 'r/Dep.hx', source: 'package r;\n\nclass Dep {}' },
				{ file: 'p/Mover.hx', source: mover },
				{ file: 'p/Host.hx', source: 'package p;\n\nimport r.Dep;\n\nclass Host {\n\tvar h:Dep;\n}' }
			];
			return MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', files, plugin(), typeRefShape());
		}
		// The field's `Dep` is a real dependency; the method parameter of the same name must not cancel it.
		assertErrContains(
			move('package p;\n\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n\n\tpublic function pick<Dep>(x:Dep):Dep return x;\n}'),
			'already binds "Dep" to r.Dep'
		);
		// The control: the SAME declaration without the field is all parameter, and moves.
		switch move('package p;\n\nimport q.Dep;\n\nclass Mover {\n\n\tpublic function pick<Dep>(x:Dep):Dep return x;\n}') {
			case Ok(changes, _):
				Assert.isTrue(changeFor(changes, 'p/Host.hx').newSource.contains('pick<Dep>'), 'the generic method moved');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A destination type that declares the dependency's name as a HEADER type parameter spells it all
	 * over its OWN body, and the reference scan cannot tell that from a reference to a module of that
	 * name. The cancel is therefore by SPAN: `class Box<Date>` says nothing about a `Date` a SIBLING
	 * type in the same module writes, and cancelling the whole FILE on it left that sibling's carry
	 * unrefused — compile-run to a changed runtime class with rc 0.
	 */
	public function testDestinationTypeParameterCancelsOnlyItsOwnDeclaration(): Void {
		inline function move(host: String): MoveResult {
			final files: Array<{ file: String, source: String }> = [
				{ file: 'q/Date.hx', source: 'package q;\n\nclass Date {}' },
				{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Date;\n\nclass Mover {\n\tvar d:Date;\n}' },
				{ file: 'p/Host.hx', source: host }
			];
			return MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', files, plugin(), typeRefShape());
		}
		assertErrContains(
			move('package p;\n\nclass Box<Date> {\n\tvar b:Date;\n}\n\nclass Host {\n\tvar h:Date;\n}'),
			'references "Date" while nothing in the indexed scope binds it'
		);
		// A class type parameter is NOT in scope inside a STATIC member — `class Box<Date> { static
		// function tag() return Date.now(); }` compiles and answers the STDLIB `Date`, measured on
		// 4.3.7 — so excluding the whole declaration hid an ambient reference that a carried import
		// would outrank. A type declaring any static member gets no exclusion at all.
		assertErrContains(
			move('package p;\n\nclass Box<Date> {\n\tvar b:Date;\n\n\tpublic static function tag():String return Date.now();\n}'),
			'references "Date" while nothing in the indexed scope binds it'
		);
		// The control: every `Date` at the destination IS the parameter, so the carry changes nothing.
		switch move('package p;\n\nclass Box<Date> {\n\tvar b:Date;\n}') {
			case Ok(changes, _):
				Assert.isTrue(changeFor(changes, 'p/Host.hx').newSource.contains('import q.Date;'), 'the carry still happens');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A module-level `private` static (Haxe 4.2) projects as `(Private) (FnDecl helper)` — a visibility
	 * modifier with no type to attach to. Carrying it forward the way a meta or an `extern` is carried
	 * marked the NEXT declaration private, and that direction is the unsafe one: a private type is
	 * skipped by the binding walk, so a real binding disappears and the gate stops refusing. The pin is
	 * the MESSAGE — with the leak the arm that answers is the ambient one, not the named-binding one.
	 */
	public function testModuleLevelPrivateStaticDoesNotMarkTheNextTypePrivate(): Void {
		inline function move(dep: String): MoveResult {
			final files: Array<{ file: String, source: String }> = [
				{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' },
				{ file: 'p/Dep.hx', source: dep },
				{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Dep;\n\nclass Mover {\n\tvar d:Dep;\n}' },
				{ file: 'p/Host.hx', source: 'package p;\n\nclass Host {\n\tvar h:Dep;\n}' }
			];
			return MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', files, plugin(), typeRefShape());
		}
		assertErrContains(move('package p;\n\nclass Dep {}'), 'already binds "Dep" to p.Dep');
		assertErrContains(move('package p;\n\nprivate function helper():Int return 1;\n\nclass Dep {}'), 'already binds "Dep" to p.Dep');
		// And the modifier still reaches the type it DOES belong to. The dependency is `Date` here so
		// the fixture stays a program Haxe accepts: with `p/Date.hx`'s main type private, both files
		// mean the stdlib `Date`, which is exactly the ambient binding the arm names.
		final files: Array<{ file: String, source: String }> = [
			{ file: 'q/Date.hx', source: 'package q;\n\nclass Date {}' },
			{ file: 'p/Date.hx', source: 'package p;\n\nprivate class Date {}\n\nclass DateHelper {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Date;\n\nclass Mover {\n\tvar d:Date;\n}' },
			{ file: 'p/Host.hx', source: 'package p;\n\nclass Host {\n\tvar h:Date;\n}' }
		];
		assertErrContains(
			MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', files, plugin(), typeRefShape()),
			'references "Date" while nothing in the indexed scope binds it'
		);
	}

	public function testAGuardedStatementIsNeverTheOneCarried(): Void {
		// `bindingOf` skips a guarded statement, so the ladder's answer always comes from the unguarded
		// one — but both spell the same module path, and a `using` carried instead of an `import` would
		// give the destination static extensions it never had.
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 8, 7, 'p/Host.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nimport q.Mod;\n#if neko\nusing q.Mod;\n#end\n\nclass Mover {\n\tvar d:Sub;\n}'
			},
			{ file: 'p/Host.hx', source: 'package p;\n\nclass Host {}' }
		]);
		final host: String = changeFor(changes, 'p/Host.hx').newSource;
		Assert.isTrue(host.contains('import q.Mod;'), 'the unguarded import is the line carried');
		Assert.isFalse(host.contains('using q.Mod;'), 'the guarded using is not');
	}

	public function testARootModuleLeadingSegmentIsNamedInTheRefusal(): Void {
		// The refusal has to name what each side actually reaches; a root-package module is a real
		// answer and reads differently from "the top level".
		assertErrContains(MoveSymbol.moveType('p/Mover.hx', 3, 7, 's/Dest.hx', [
			{ file: 'Root.hx', source: 'class Root {}\n\nclass Sub {}' },
			{ file: 's/Root.hx', source: 'package s;\n\nclass Root {}\n\nclass Sub {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {\n\tvar d:Root.Sub;\n}' },
			{ file: 's/Dest.hx', source: 'package s;\n\nclass Dest {}' }
		], plugin(), typeRefShape()), 'reaches Root and');
	}

	public function testAnImporterSpellingTheOldPathIsNotAlsoGivenOne(): Void {
		// Both statements bind the moved type here, and the repoint of the explicit one already answers
		// for it — emitting from the module statement too wrote the new import twice (review found it).
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 5, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{
				file: 'r/Uses.hx',
				source: 'package r;\n\nimport q.Mod;\nimport q.Mod.Sub;\n\nclass Uses {\n\tvar a:Mod;\n\tvar b:Sub;\n}'
			}
		]);
		Assert.equals(
			'package r;\n\nimport q.Mod;\nimport q.Dest.Sub;\n\nclass Uses {\n\tvar a:Mod;\n\tvar b:Sub;\n}',
			changeFor(changes, 'r/Uses.hx').newSource
		);
	}

	public function testAnAliasSpellingTheOldPathDoesNotSuppressTheMirror(): Void {
		// `pathImportedBy` answers an ALIAS's TARGET, so an alias spells the old path — but it binds
		// `S`, not `Sub`, and the bare name came from the module statement. Suppressing the mirror on it
		// left `Type not found : Sub` (review found it).
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 5, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{
				file: 'r/Uses.hx',
				source: 'package r;\n\nimport q.Mod;\nimport q.Mod.Sub as S;\n\nclass Uses {\n\tvar a:Sub;\n\tvar b:S;\n}'
			}
		]);
		Assert.equals(
			'package r;\n\nimport q.Mod;\nimport q.Dest.Sub;\nimport q.Dest.Sub as S;\n\nclass Uses {\n\tvar a:Sub;\n\tvar b:S;\n}',
			changeFor(changes, 'r/Uses.hx').newSource
		);
	}

	public function testAGuardedStatementSpellingTheOldPathDoesNotSuppressTheMirror(): Void {
		// A `#if`-guarded statement binds the name under its own flag and under no other, so the
		// unconditional binding the module statement provided still has to be written — and the
		// configuration that loses it is the DEFAULT one, which no single-configuration oracle sees.
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 5, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{
				file: 'r/Uses.hx',
				source: 'package r;\n\nimport q.Mod;\n#if flagx\nimport q.Mod.Sub;\n#end\n\nclass Uses {\n\tvar a:Sub;\n}'
			}
		]);
		Assert.equals(
			'package r;\n\nimport q.Mod;\nimport q.Dest.Sub;\n#if flagx\nimport q.Dest.Sub;\n#end\n\nclass Uses {\n\tvar a:Sub;\n}',
			changeFor(changes, 'r/Uses.hx').newSource
		);
	}

	public function testDestinationUsingIsRepointedNotDeleted(): Void {
		// Static extension is granted by the STATEMENT, not by the declaration's module, and a module
		// may `using` its own sub-type (compile-proved) — so the type becoming local does not make the
		// statement redundant the way a plain import becomes redundant.
		final sole: Array<MoveChange> = okChanges('q/Ext.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Ext.hx', source: 'package q;\n\nclass Ext {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nusing q.Ext;\n\nclass Dest {}' }
		]);
		Assert.isTrue(changeFor(sole, 'q/Dest.hx').newSource.contains('using q.Dest.Ext;'), 'the sole-type using is repointed');
		Assert.isFalse(changeFor(sole, 'q/Dest.hx').newSource.contains('using q.Ext;'), 'and the old path does not stand beside it');
		final withOthers: Array<MoveChange> = okChanges('q/Mod.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nusing q.Mod;\n\nclass Dest {}' }
		]);
		final kept: String = changeFor(withOthers, 'q/Dest.hx').newSource;
		Assert.isTrue(kept.contains('using q.Mod;\nusing q.Dest.Mod;'), 'both statements stand when the module still has types');
	}

	public function testAPrivateSiblingIsNotAReasonToKeepAModuleImport(): Void {
		// The remaining-name scan reads TEXT, so what reaches it is a name COLLISION, not a reference:
		// the importer declares its own `Helper` while the source module holds a `private class Helper`,
		// which no other module can name. Counting the private one would keep an import for a binding
		// the language never granted.
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nprivate class Helper {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{
				file: 'r/Uses.hx',
				source: 'package r;\n\nimport q.Mod;\n\nclass Uses {\n\tvar a:Mod;\n\tvar h:Helper;\n}\n\nclass Helper {}'
			}
		]);
		Assert.equals(
			'package r;\n\nimport q.Dest.Mod;\n\nclass Uses {\n\tvar a:Mod;\n\tvar h:Helper;\n}\n\nclass Helper {}',
			changeFor(changes, 'r/Uses.hx').newSource
		);
	}

	public function testSoleTypeModuleUsingImporterIsPlainlyRepointed(): Void {
		// The `using` arm keeps the statement without asking whether the file names anything — so what
		// stops it is the module having nothing left to bind, and that has to be its own assertion.
		final changes: Array<MoveChange> = okChanges('q/Ext.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Ext.hx', source: 'package q;\n\nclass Ext {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{ file: 'r/Uses.hx', source: 'package r;\n\nusing q.Ext;\n\nclass Uses {}' }
		]);
		Assert.equals('package r;\n\nusing q.Dest.Ext;\n\nclass Uses {}', changeFor(changes, 'r/Uses.hx').newSource);
	}

	public function testSubTypeUsingImporterIsPlainlyRepointed(): Void {
		// `using q.Mod.Sub;` spells the SUB-TYPE path and binds only `Sub`, so keeping it beside the
		// repointed line would leave a statement naming a type its module no longer declares.
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 5, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{ file: 'r/Uses.hx', source: 'package r;\n\nusing q.Mod.Sub;\n\nclass Uses {}' }
		]);
		Assert.equals('package r;\n\nusing q.Dest.Sub;\n\nclass Uses {}', changeFor(changes, 'r/Uses.hx').newSource);
	}

	public function testDestinationModuleUsingIsKeptWithoutANameScan(): Void {
		// The destination reaches the module's other types through EXTENSION CALLS, which no name scan
		// sees — neither its own source nor the moved declaration mentions `Sub`.
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nusing q.Mod;\n\nclass Dest {\n\tvar n:Int = 1;\n}' }
		]);
		Assert.isTrue(
			changeFor(changes, 'q/Dest.hx').newSource.contains('using q.Mod;\nusing q.Dest.Mod;'),
			'the destination keeps its using AND gains the repointed one'
		);
	}

	public function testAnImportStatementsOwnTextIsNotAReference(): Void {
		// The remaining-name scan reads the whole file, and an import statement spells type names too —
		// so a file whose ONLY occurrence of `Other` is another import must still be plainly repointed.
		// The import has to be a ROOT-package one to make the point: a dotted path puts a `.` before the
		// name, and the scan already declines a qualified occurrence, so only `import Other;` puts the
		// bare name into the file's text.
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Other {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{ file: 'Other.hx', source: 'class Other {}' },
			{ file: 'r/Only.hx', source: 'package r;\n\nimport q.Mod;\nimport Other;\n\nclass Only {\n\tvar a:Mod;\n}' }
		]);
		Assert.equals(
			'package r;\n\nimport q.Dest.Mod;\nimport Other;\n\nclass Only {\n\tvar a:Mod;\n}', changeFor(changes, 'r/Only.hx').newSource
		);
	}

	public function testAnIndentedImportStatementKeepsItsIndentation(): Void {
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Other {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{
				file: 'r/Guarded.hx',
				source: 'package r;\n\n#if neko\n\timport q.Mod;\n#end\n\nclass Guarded {\n\tvar a:Mod;\n\tvar b:Other;\n}'
			}
		]);
		Assert.equals(
			'package r;\n\n#if neko\n\timport q.Mod;\n\timport q.Dest.Mod;\n#end\n\nclass Guarded {\n\tvar a:Mod;\n\tvar b:Other;\n}',
			changeFor(changes, 'r/Guarded.hx').newSource
		);
	}

	public function testASiblingThatNeverNamesTheTypeIsLeftAlone(): Void {
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 3, 7, 'p/Dest.hx', [
			{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {}' },
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' },
			{ file: 'p/Sibling.hx', source: 'package p;\n\nclass Sibling {\n\tvar m:Mover;\n}' },
			{ file: 'p/Quiet.hx', source: 'package p;\n\nclass Quiet {\n\tvar n:Int = 1;\n}' }
		]);
		Assert.equals(
			'package p;\n\nimport p.Dest.Mover;\n\nclass Sibling {\n\tvar m:Mover;\n}', changeFor(changes, 'p/Sibling.hx').newSource
		);
		assertUnchanged(changes, 'p/Quiet.hx');
	}

	public function testASiblingTheRepointWalkAlreadyEditedIsNotImportedTwice(): Void {
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 3, 7, 'p/Dest.hx', [
			{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {}' },
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' },
			{ file: 'p/Explicit.hx', source: 'package p;\n\nimport p.Mover;\n\nclass Explicit {\n\tvar m:Mover;\n}' }
		]);
		Assert.equals(
			'package p;\n\nimport p.Dest.Mover;\n\nclass Explicit {\n\tvar m:Mover;\n}', changeFor(changes, 'p/Explicit.hx').newSource
		);
	}

	public function testALowercaseLeadingSegmentIsAPackagePrefix(): Void {
		// A lowercase module file is legal to have and unreachable by path (`Type not found : p.q.QType`,
		// compile-proved), but the index still records its last segment — so without the lowercase
		// short-circuit the leading segment of a FULLY-QUALIFIED `q.Mod.Sub` would match the module
		// `p/q` on one side and nothing on the other, and a correct cross-package move would be refused.
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 3, 7, 's/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'p/q.hx', source: 'package p;\n\nclass QType {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {\n\tvar d:q.Mod.Sub;\n}' },
			{ file: 's/Dest.hx', source: 'package s;\n\nclass Dest {}' }
		]);
		Assert.isTrue(changeFor(changes, 's/Dest.hx').newSource.contains('var d:q.Mod.Sub;'), 'the qualified reference moves');
	}

	public function testModuleImporterKeepsTheStatementItsOtherTypesNeed(): Void {
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Other {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{ file: 'r/Uses.hx', source: 'package r;\n\nimport q.Mod;\n\nclass Uses {\n\tvar a:Mod;\n\tvar b:Other;\n}' },
			{ file: 'r/Only.hx', source: 'package r;\n\nimport q.Mod;\n\nclass Only {\n\tvar a:Mod;\n}' }
		]);
		Assert.equals(
			'package r;\n\nimport q.Mod;\nimport q.Dest.Mod;\n\nclass Uses {\n\tvar a:Mod;\n\tvar b:Other;\n}',
			changeFor(changes, 'r/Uses.hx').newSource
		);
		Assert.equals('package r;\n\nimport q.Dest.Mod;\n\nclass Only {\n\tvar a:Mod;\n}', changeFor(changes, 'r/Only.hx').newSource);
	}

	public function testModuleUsingImporterKeepsItsStatementUnconditionally(): Void {
		final changes: Array<MoveChange> = okChanges('q/Ext.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Ext.hx', source: 'package q;\n\nclass Ext {}\n\nclass More {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{ file: 'r/Uses.hx', source: 'package r;\n\nusing q.Ext;\n\nclass Uses {}' }
		]);
		Assert.equals('package r;\n\nusing q.Ext;\nusing q.Dest.Ext;\n\nclass Uses {}', changeFor(changes, 'r/Uses.hx').newSource);
	}

	public function testSoleTypeModuleImporterIsPlainlyRepointed(): Void {
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{ file: 'r/Uses.hx', source: 'package r;\n\nimport q.Mod;\n\nclass Uses {\n\tvar a:Mod;\n}' }
		]);
		Assert.equals('package r;\n\nimport q.Dest.Mod;\n\nclass Uses {\n\tvar a:Mod;\n}', changeFor(changes, 'r/Uses.hx').newSource);
	}

	public function testModuleImporterGainsAnImportForASecondaryTypeThatLeft(): Void {
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 5, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{ file: 'r/Uses.hx', source: 'package r;\n\nimport q.Mod;\n\nclass Uses {\n\tvar a:Mod;\n\tvar b:Sub;\n}' },
			{ file: 'r/Plain.hx', source: 'package r;\n\nimport q.Mod;\n\nclass Plain {\n\tvar a:Mod;\n}' }
		]);
		Assert.equals(
			'package r;\n\nimport q.Mod;\nimport q.Dest.Sub;\n\nclass Uses {\n\tvar a:Mod;\n\tvar b:Sub;\n}',
			changeFor(changes, 'r/Uses.hx').newSource
		);
		assertUnchanged(changes, 'r/Plain.hx');
	}

	public function testDestinationModuleImportKeptForTheModulesOtherTypes(): Void {
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {\n\tvar s:Sub;\n}\n\nclass Sub {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nimport q.Mod;\n\nclass Dest {}' }
		]);
		Assert.equals(
			'package q;\n\nimport q.Mod;\n\nclass Dest {}\n\nclass Mod {\n\tvar s:Sub;\n}\n', changeFor(changes, 'q/Dest.hx').newSource
		);
	}

	public function testDestinationModuleImportGoesWhenNothingElseNeedsIt(): Void {
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nimport q.Mod;\n\nclass Dest {\n\tvar m:Mod;\n}' }
		]);
		// Asserted by absence rather than by full text: removing the statement leaves the blank line
		// that stood above it, so the result is not writer-canonical — a pre-existing seam of the op
		// that pinning the exact bytes here would freeze.
		Assert.isFalse(changeFor(changes, 'q/Dest.hx').newSource.contains('import q.Mod;'), 'the redundant module import goes');
		Assert.isTrue(changeFor(changes, 'q/Dest.hx').newSource.contains('class Mod {}'), 'the type landed');
	}

	public function testModuleImportProvidingADependencyIsCarried(): Void {
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 5, 7, 'p/Host.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Mod;\n\nclass Mover {\n\tvar d:Sub;\n}' },
			{ file: 'p/Host.hx', source: 'package p;\n\nclass Host {}' }
		]);
		Assert.equals(
			'package p;\n\nimport q.Mod;\n\nclass Host {}\n\nclass Mover {\n\tvar d:Sub;\n}\n', changeFor(changes, 'p/Host.hx').newSource
		);
	}

	public function testAModuleImportTheLadderDoesNotAgreeWithIsNotCarried(): Void {
		// The source module declares `Sub` itself, and a module's own type beats every import — so the
		// module import that also declares one is NOT what the moved code means by the name, and
		// carrying it would rebind the moved code to `q.Mod.Sub` with nothing said.
		assertErrContains(MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Mod;\n\nclass Mover {\n\tvar d:Sub;\n}\n\nclass Sub {}' },
			{ file: 'p/Host.hx', source: 'package p;\n\nclass Host {}' }
		], plugin(), typeRefShape()), 'no import to carry');
	}

	public function testQualifiedTypeHeadRebindingAcrossPackagesRefused(): Void {
		assertErrContains(MoveSymbol.moveType('p/Mover.hx', 3, 7, 's/Dest.hx', [
			{ file: 'p/Mod.hx', source: 'package p;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 's/Mod.hx', source: 'package s;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {\n\tvar d:Mod.Sub;\n}' },
			{ file: 's/Dest.hx', source: 'package s;\n\nclass Dest {}' }
		], plugin(), typeRefShape()), 'whose head "Mod"');
	}

	public function testQualifiedTypeHeadWithinOnePackageIsNotPriced(): Void {
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 3, 7, 'p/Dest.hx', [
			{ file: 'p/Mod.hx', source: 'package p;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {\n\tvar d:Mod.Sub;\n}' },
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' }
		]);
		Assert.isTrue(changeFor(changes, 'p/Dest.hx').newSource.contains('var d:Mod.Sub;'), 'the qualified reference moves as written');
	}

	public function testFullyQualifiedAndTopLevelHeadsAreNotPriced(): Void {
		final qualified: Array<MoveChange> = okChanges('p/Mover.hx', 3, 7, 's/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {\n\tvar d:q.Mod.Sub;\n}' },
			{ file: 's/Dest.hx', source: 'package s;\n\nclass Dest {}' }
		]);
		Assert.isTrue(changeFor(qualified, 's/Dest.hx').newSource.contains('var d:q.Mod.Sub;'), 'a lowercase head is absolute');
		final ambient: Array<MoveChange> = okChanges('p/Mover.hx', 3, 7, 's/Dest.hx', [
			{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {\n\tvar d:Xml.XmlType;\n}' },
			{ file: 's/Dest.hx', source: 'package s;\n\nclass Dest {}' }
		]);
		Assert.isTrue(changeFor(ambient, 's/Dest.hx').newSource.contains('var d:Xml.XmlType;'), 'a head no file declares is ambient');
	}

	public function testSamePackageSiblingGainsAnImportWhenTheTypeBecomesASubType(): Void {
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 3, 7, 'p/Dest.hx', [
			{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {}' },
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' },
			{ file: 'p/Sibling.hx', source: 'package p;\n\nclass Sibling {\n\tvar m:Mover;\n}' },
			{ file: 'p/Other.hx', source: 'package p;\n\nimport z.Thing as Mover;\n\nclass Other {\n\tvar m:Mover;\n}' },
			{ file: 'z/Thing.hx', source: 'package z;\n\nclass Thing {}' }
		]);
		Assert.equals(
			'package p;\n\nimport p.Dest.Mover;\n\nclass Sibling {\n\tvar m:Mover;\n}', changeFor(changes, 'p/Sibling.hx').newSource
		);
		assertUnchanged(changes, 'p/Other.hx');
	}

	public function testSamePackageSiblingsFollowTheTypeOutOfThePackage(): Void {
		// Replaces a control this slice wrote and then found VACUOUS: it asserted a sibling keeps bare
		// visibility when the moved type "stays a main type", over a fixture where the type was a
		// SECONDARY type all along — `p/A.hx` declaring only `class Foo` makes `Foo` unreachable by its
		// bare name from `p/Sibling.hx` (`Type not found : Foo`, compile-proved), so the test passed for
		// a reason it did not name. The reachable half of that idea is this: the siblings follow the
		// type into another PACKAGE, where nothing else could bind it for them.
		final changes: Array<MoveChange> = okChanges('p/Foo.hx', 3, 7, 's/Foo.hx', [
			{ file: 'p/Foo.hx', source: 'package p;\n\nclass Foo {}' },
			{ file: 's/Foo.hx', source: 'package s;\n\nclass Helper {}' },
			{ file: 'p/Sibling.hx', source: 'package p;\n\nclass Sibling {\n\tvar m:Foo;\n}' }
		]);
		Assert.equals('package p;\n\nimport s.Foo;\n\nclass Sibling {\n\tvar m:Foo;\n}', changeFor(changes, 'p/Sibling.hx').newSource);
	}

	/**
	 * The fully-qualified-reference refusal is asked in BOTH directions. A SAME-package move takes
	 * `pkg.A.Foo` to `pkg.B.Foo` exactly as a cross-package one does, so a file spelling the path was
	 * left dangling while the move reported success — the Pony shape is
	 * `Module pony.net.rpc.IRPC does not define type RPCBuilder`, written at rc 0 by the base engine.
	 */
	public function testSamePackageFqnReferenceRefused(): Void {
		final result: MoveResult = MoveSymbol.moveType('pkg/A.hx', 5, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: 'package pkg;\n\nclass A {}\n\nclass Foo {}' },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' },
			{ file: 'pkg/User.hx', source: 'package pkg;\n\nclass User {\n\tvar f:pkg.A.Foo;\n}' }
		], plugin(), typeRefShape());
		assertErrContains(result, 'by its fully-qualified path');
	}

	/**
	 * Its one exemption, and the reason the guard could not simply be asked unconditionally: a
	 * ROOT-package type's own import path IS its bare name, so the path scan matches the declaration
	 * itself and every such move would be refused. Nothing is qualified there, so nothing can dangle.
	 */
	public function testRootPackageMoveIsNotAnFqnReference(): Void {
		final changes: Array<MoveChange> = okChanges('Mover.hx', 1, 7, 'Host.hx', [
			{ file: 'Mover.hx', source: 'class Mover {}\n' },
			{ file: 'Host.hx', source: 'class Host {}\n' }
		]);
		Assert.equals('class Host {}\n\nclass Mover {}\n', changeFor(changes, 'Host.hx').newSource);
		Assert.equals('', changeFor(changes, 'Mover.hx').newSource);
	}

	/**
	 * And the half that exemption may NOT cover, because there the scan's answer was never about the
	 * declaration: taking a root-package type INTO a package makes every bare `Mover` elsewhere stop
	 * resolving, and the repair walk reaches only its TYPE positions — a `Mover.make()` static call is
	 * left dangling (`Module Foo does not define type Foo`, compile-proved against both engines). The
	 * base engine refused this through the cross-package gate; exempting every dotless path turned that
	 * into a silent write of two files at rc 0.
	 */
	public function testRootPackageMoveIntoAPackageStillRefusesAnFqnReference(): Void {
		final result: MoveResult = MoveSymbol.moveType('Mover.hx', 1, 7, 's/Dest.hx', [
			{ file: 'Mover.hx', source: 'class Mover {\n\tpublic static function make(): Int return 1;\n}\n' },
			{ file: 's/Dest.hx', source: 'package s;\n\nclass Dest {}\n' },
			{ file: 'r/User.hx', source: 'package r;\n\nclass User {\n\tpublic function go(): Int return Mover.make();\n}\n' }
		], plugin(), typeRefShape());
		assertErrContains(result, 'by its fully-qualified path');
	}

	/**
	 * A `#if … enum #else @:enum #end` region is the declaration's own prefix — it carries the `enum`
	 * of `enum abstract` — and the grammar projects it as a SIBLING of the abstract, so a
	 * modifier-and-annotation-only prefix test read it as a declaration of its own and the cut left it
	 * standing in front of the NEXT declaration (`Unexpected @` at `pony/text/TextTools.hx:22` after
	 * `AnsiForeground` moved out, rc 1 against Pony's own oracle; rc 0 with the region folded in).
	 */
	public function testConditionalEnumPrefixMovesWithTheType(): Void {
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 4, 10, 'pkg/B.hx', [
			{
				file: 'pkg/A.hx',
				source: 'package pkg;\n\n#if (haxe_ver >= 4.2) enum #else @:enum #end\nabstract E(Int) {\n\tfinal X = 1;\n}\n\nclass A {}'
			},
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		]);
		Assert.equals('package pkg;\n\nclass A {}', changeFor(changes, 'pkg/A.hx').newSource);
		Assert.equals(
			'package pkg;\n\nclass B {}\n\n#if (haxe_ver >= 4.2) enum #else @:enum #end\nabstract E(Int) {\n\tfinal X = 1;\n}\n',
			changeFor(changes, 'pkg/B.hx').newSource
		);
	}

	/** The same for the `final` arm of the same grammar enum — `#if … final #else @:final #end class C`. */
	public function testConditionalFinalPrefixMovesWithTheType(): Void {
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 4, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: 'package pkg;\n\n#if (haxe_ver >= 4.2) final #else @:final #end\nclass C {}\n\nclass A {}' },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		]);
		Assert.equals('package pkg;\n\nclass A {}', changeFor(changes, 'pkg/A.hx').newSource);
		Assert.equals(
			'package pkg;\n\nclass B {}\n\n#if (haxe_ver >= 4.2) final #else @:final #end\nclass C {}\n',
			changeFor(changes, 'pkg/B.hx').newSource
		);
	}

	/** And for the `abstract` arm — `#if flag abstract #end class C`, the Haxe 4.2 abstract-class modifier. */
	public function testConditionalAbstractPrefixMovesWithTheType(): Void {
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 4, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: 'package pkg;\n\n#if (haxe_ver >= 4.2) abstract #end\nclass C {}\n\nclass A {}' },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		]);
		Assert.equals('package pkg;\n\nclass A {}', changeFor(changes, 'pkg/A.hx').newSource);
		Assert.equals(
			'package pkg;\n\nclass B {}\n\n#if (haxe_ver >= 4.2) abstract #end\nclass C {}\n', changeFor(changes, 'pkg/B.hx').newSource
		);
	}

	/**
	 * An importer that reaches a moved ENUM only through its CONSTRUCTORS. `case Alpha(n):` names
	 * the type nowhere, so the scan deciding whether the module statement still owes this file
	 * anything answered no and the type left its scope — `Unknown identifier : A` on
	 * `Pony/pony/ServiceProvider.hx` after `OrState` left `pony.Or`, rc 1 at base and rc 0 once the
	 * constructors join the scan (compile-proved on Pony's own oracle, both ways).
	 */
	public function testModuleImporterGainsAnImportForAnEnumOnlyItsConstructorsName(): Void {
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 5, 6, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nenum Sub {\n\tAlpha(v:Int);\n\tBeta;\n}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{
				file: 'r/Param.hx',
				source: 'package r;\n\nimport q.Mod;\n\nclass Param {\n\tvar a:Mod;\n'
				+ '\tfunction f(v:Dynamic) return switch v { case Alpha(n): n; case _: 2; }\n}'
			},
			{
				file: 'r/Simple.hx',
				source: 'package r;\n\nimport q.Mod;\n\nclass Simple {\n\tvar a:Mod;\n'
				+ '\tfunction f(v:Dynamic) return switch v { case Beta: 1; case _: 2; }\n}'
			},
			{ file: 'r/Plain.hx', source: 'package r;\n\nimport q.Mod;\n\nclass Plain {\n\tvar a:Mod;\n}' }
		]);
		// One importer per constructor SPELLING — `Alpha(v:Int)` projects as `ParamCtor` and `Beta` as
		// `SimpleCtor`, and a scan taught only one of the two kinds leaves the other file broken. The
		// Pony case is a ParamCtor (`OrState.A(v:T1)`); every fixture the tree already had was a
		// SimpleCtor, so the parameterised half had no killer at all until this one.
		Assert.isTrue(changeFor(changes, 'r/Param.hx').newSource.contains('import q.Mod;\nimport q.Dest.Sub;\n'));
		Assert.isTrue(changeFor(changes, 'r/Simple.hx').newSource.contains('import q.Mod;\nimport q.Dest.Sub;\n'));
		assertUnchanged(changes, 'r/Plain.hx');
	}

	/**
	 * The same names in the other direction: a MAIN-type move leaves the module statement standing for
	 * the types it still declares, and an importer that reaches a REMAINING enum only through its
	 * constructors was not counted as one of them — the statement was repointed away from under it.
	 */
	public function testModuleImporterKeepsTheStatementARemainingEnumsConstructorsNeed(): Void {
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 3, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nenum Kept {\n\tGamma(v:Int);\n}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nclass Dest {}' },
			{
				file: 'r/Uses.hx',
				source: 'package r;\n\nimport q.Mod;\n\nclass Uses {\n'
				+ '\tfunction f(v:Dynamic) return switch v { case Gamma(n): n; case _: 0; }\n}'
			}
		]);
		Assert.isTrue(changeFor(changes, 'r/Uses.hx').newSource.contains('import q.Mod;\nimport q.Dest.Mod;\n'));
	}

	/**
	 * A cut with content directly above it owns only the separator BELOW, so nothing may be collapsed —
	 * not even when the source file's own new import lands at the cut's own offset, which is what the
	 * forward branch keys on. Without the leading-run guard that shape ate the trailing blank and left
	 * the import region touching the next declaration.
	 */
	public function testACutWithNoLeadingBlankKeepsTheTrailingSeparator(): Void {
		final changes: Array<MoveChange> = okChanges('p/A.hx', 4, 6, 'p/Dest.hx', [
			{ file: 'p/A.hx', source: 'package p;\n\nimport p.C;\nenum Sub {\n\tAlpha;\n}\n\nclass A {\n\tvar s:Sub;\n}\n' },
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}\n' },
			{ file: 'p/C.hx', source: 'package p;\n\nclass C {}\n' }
		]);
		Assert.equals(
			'package p;\n\nimport p.C;\nimport p.Dest.Sub;\n\nclass A {\n\tvar s:Sub;\n}\n', changeFor(changes, 'p/A.hx').newSource
		);
	}

	/**
	 * The destination-side mirror of that arm, for a `using`: `using q.Mod;` spells the MODULE, not the
	 * moved type's path, so the destination walk never saw it — and a static extension is granted by
	 * the STATEMENT, not by the declaration's module, so the moved type stopped being an extension at
	 * the very file it moved into (`Int has no field twice`, compile-proved on 4.3.7; rc 0 with the
	 * statement written, which also proves a module may `using` its own sub-type).
	 */
	public function testDestinationUsingGainsTheMovedSecondaryTypesExtension(): Void {
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 5, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nusing q.Mod;\n\nclass Dest {}' }
		]);
		Assert.equals(
			'package q;\n\nusing q.Mod;\nusing q.Dest.Sub;\n\nclass Dest {}\n\nclass Sub {}\n', changeFor(changes, 'q/Dest.hx').newSource
		);
	}

	/**
	 * Its duplicate guard, the destination-side twin of `spellsOldPath`: a destination that ALSO
	 * `using`s the moved type's own path gets `using q.Dest.Sub;` from the repoint loop, and the mirror
	 * must not write a second copy of the same line beside it. Only a `using` of the old path suppresses
	 * it — a repointed ALIAS binds its alias rather than granting the extension, and a plain `import` of
	 * the old path is removed rather than repointed.
	 */
	public function testDestinationUsingOfTheOldPathSuppressesTheMirror(): Void {
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 5, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nusing q.Mod;\nusing q.Mod.Sub;\n\nclass Dest {}' }
		]);
		Assert.equals(
			'package q;\n\nusing q.Mod;\nusing q.Dest.Sub;\n\nclass Dest {}\n\nclass Sub {}\n', changeFor(changes, 'q/Dest.hx').newSource
		);
	}

	/**
	 * Its control: a plain `import q.Mod;` at the destination owes nothing for a secondary move — the
	 * type is declared in that module now, and a module's own declaration is what the file reads it
	 * off. Only a `using` loses something.
	 */
	public function testDestinationModuleImportGainsNothingForASecondaryMove(): Void {
		final changes: Array<MoveChange> = okChanges('q/Mod.hx', 5, 7, 'q/Dest.hx', [
			{ file: 'q/Mod.hx', source: 'package q;\n\nclass Mod {}\n\nclass Sub {}' },
			{ file: 'q/Dest.hx', source: 'package q;\n\nimport q.Mod;\n\nclass Dest {\n\tvar m:Mod;\n}' }
		]);
		Assert.equals(
			'package q;\n\nimport q.Mod;\n\nclass Dest {\n\tvar m:Mod;\n}\n\nclass Sub {}\n', changeFor(changes, 'q/Dest.hx').newSource
		);
	}

	/**
	 * A wildcard `import p.*;` binds a module's MAIN type from ANY package, and it spells no path the
	 * repoint walk can rewrite — so the repair walk that writes an import for such a file must not be
	 * filtered to the cursor's own package. Compile-proved: `Type not found : Foo` at base, rc 0 with
	 * the import written.
	 */
	public function testCrossPackageWildcardImporterFollowsTheType(): Void {
		final changes: Array<MoveChange> = okChanges('p/Foo.hx', 3, 7, 's/Dest.hx', [
			{ file: 'p/Foo.hx', source: 'package p;\n\nclass Foo {}\n\nclass FooHelper {}' },
			{ file: 'p/Kept.hx', source: 'package p;\n\nclass Kept {}' },
			{ file: 's/Dest.hx', source: 'package s;\n\nclass Dest {}' },
			{ file: 'r/Consumer.hx', source: 'package r;\n\nimport p.*;\n\nclass Consumer {\n\tvar v:Foo;\n}' },
			// The control names the OTHER main type the same wildcard binds, so it models a real
			// importer: a secondary type is not wildcard-visible at all and would not resolve even
			// before the move.
			{ file: 'r/Other.hx', source: 'package r;\n\nimport p.*;\n\nclass Other {\n\tvar h:Kept;\n}' }
		]);
		Assert.equals(
			'package r;\n\nimport p.*;\nimport s.Dest.Foo;\n\nclass Consumer {\n\tvar v:Foo;\n}',
			changeFor(changes, 'r/Consumer.hx').newSource
		);
		assertUnchanged(changes, 'r/Other.hx');
	}

	/**
	 * A declaration with a blank line on BOTH sides left the two of them adjacent — a double separator
	 * `fmt --list` rejects. It was reachable only at the end of a module until the conditional prefix
	 * above stopped being left behind to fill the gap, which is why the widening read as an
	 * end-of-file special case (and why the `;`-terminated typedef test froze the double blank as
	 * "pre-existing behaviour").
	 */
	public function testABlankLineOnBothSidesOfTheCutCollapsesToOne(): Void {
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 5, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: 'package pkg;\n\nimport pkg.C;\n\nclass Foo {}\n\nclass A {}\n' },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}\n' }
		]);
		Assert.equals('package pkg;\n\nimport pkg.C;\n\nclass A {}\n', changeFor(changes, 'pkg/A.hx').newSource);
	}

	/**
	 * And its counter-case, which is what makes the collapse conditional: when the source file still
	 * uses the type, its own new import lands in exactly that gap. Widening the cut over the run then
	 * overlaps the insert, and `applyEdits` — which sorts by start offset alone — spliced the two into
	 * a file that no longer parsed, so the move refused itself. An import written into the gap fills
	 * it, so there is nothing to collapse.
	 */
	public function testTheSourceFilesOwnImportLandsInTheCutGapWithoutOverlappingIt(): Void {
		final changes: Array<MoveChange> = okChanges('p/A.hx', 3, 6, 'p/Dest.hx', [
			{ file: 'p/A.hx', source: 'package p;\n\nenum Sub {\n\tAlpha;\n}\n\nclass A {\n\tvar s:Sub;\n}\n' },
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}\n' }
		]);
		Assert.equals('package p;\n\nimport p.Dest.Sub;\n\nclass A {\n\tvar s:Sub;\n}\n', changeFor(changes, 'p/A.hx').newSource);
	}

	/**
	 * A declaration at the END of a `#if … #end` region owns no blank against the `#end`, so the
	 * cut has to take the one in front of it. The old rule keyed on whether the line AFTER the cut
	 * was blank — true only between siblings — so it returned early and left `}` + blank + `#end`.
	 * Driven through the PURE op, so the canonical-in / canonical-out gate at the CLI seam (which
	 * repaired the OUTPUT for a file that happened to be canonical on disk) is not what is being
	 * measured.
	 */
	public function testCuttingTheLastDeclarationOutOfARegionTakesItsSeparator(): Void {
		final a: String =
			'package pkg;\n\n#if macro\nclass Keep {\n\tpublic var k:Int = 1;\n}\n\nclass Gone {\n\tpublic var g:Int = 1;\n}\n#end\n';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 8, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		]);
		Assert.equals(
			'package pkg;\n\n#if macro\nclass Keep {\n\tpublic var k:Int = 1;\n}\n#end\n', changeFor(changes, 'pkg/A.hx').newSource
		);
	}

	/**
	 * The mirror: a declaration at the START of the region owns no blank against the `#if`, and
	 * there the cut has to widen FORWARD — the leading run is empty, so the backward widening the
	 * old rule offered had nothing to take and left `#if macro` + blank.
	 */
	public function testCuttingTheFirstDeclarationOutOfARegionTakesItsSeparator(): Void {
		final a: String =
			'package pkg;\n\n#if macro\nclass Gone {\n\tpublic var g:Int = 1;\n}\n\nclass Keep {\n\tpublic var k:Int = 1;\n}\n#end\n';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 4, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		]);
		Assert.equals(
			'package pkg;\n\n#if macro\nclass Keep {\n\tpublic var k:Int = 1;\n}\n#end\n', changeFor(changes, 'pkg/A.hx').newSource
		);
	}

	/**
	 * CONTROL, green at base: a declaration BETWEEN two siblings owns exactly one separator, and
	 * exactly one must survive. With a blank on BOTH sides the "keep one" branch is taken whatever
	 * the container answer is, so this pins the OUTPUT and not that mechanism —
	 * `testAMiddleDeclarationWithOneBlankSideKeepsIt` is the one that pins the answer itself.
	 * Forcing the container answer to "needed" flips the two region pins above; a no-op forward
	 * blank-run scan flips this one.
	 */
	public function testCuttingAMiddleDeclarationLeavesExactlyOneSeparator(): Void {
		final a: String = 'package pkg;\n\n#if macro\nclass A {\n\tpublic var a:Int = 1;\n}\n\nclass Gone {\n\tpublic var g:Int = 1;\n}'
			+ '\n\nclass B {\n\tpublic var b:Int = 1;\n}\n#end\n';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 8, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B2 {}' }
		]);
		Assert.equals(
			'package pkg;\n\n#if macro\nclass A {\n\tpublic var a:Int = 1;\n}\n\nclass B {\n\tpublic var b:Int = 1;\n}\n#end\n',
			changeFor(changes, 'pkg/A.hx').newSource
		);
	}

	/**
	 * CONTROL, green at base: the end-of-MODULE shape the widening was first written for — the same
	 * question with no container directive, so the trailing blank goes with the declaration.
	 * Forcing the container answer to "separator needed" leaves it standing and flips this.
	 */
	public function testCuttingTheLastDeclarationOfAModuleTakesItsSeparator(): Void {
		final a: String = 'package pkg;\n\nclass Keep {\n\tpublic var k:Int = 1;\n}\n\nclass Gone {\n\tpublic var g:Int = 1;\n}\n';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 7, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		]);
		Assert.equals('package pkg;\n\nclass Keep {\n\tpublic var k:Int = 1;\n}\n', changeFor(changes, 'pkg/A.hx').newSource);
	}

	/**
	 * The SOURCE keeps every import it had, including the one the departed declaration was the
	 * last TYPE-POSITION user of. This is a decision, not an omission: the only reference
	 * machinery this layer has for the source file is `sourceStillUsesType`, which reads type
	 * positions only — measured, `apq uses Helper` returns 0 hits on a file whose only reference
	 * is `Helper.go()`. An arm that dropped the import on that evidence was built and run, and it
	 * deleted the import this fixture's remaining `Helper.go()` needs, at rc 0 with a file that
	 * still parses; `unused-import` answers the same question with the resolution index and is
	 * silent here. The advisory names the hand-off.
	 */
	public function testTheSourceKeepsAnImportTheMovedDeclarationLeftBehind(): Void {
		final a: String = 'package pkg;\n\nimport dep.Helper;\n\nclass Stay {\n\tpublic function s():Void {\n\t\tHelper.go();\n\t}\n}'
			+ '\n\nclass Movee {\n\tpublic var h:Helper;\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 11, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' },
			{ file: 'dep/Helper.hx', source: 'package dep;\n\nclass Helper {\n\tpublic static function go():Void {}\n}' }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		Assert.isFalse(newA.contains('class Movee'), 'the move did not actually cut the declaration');
		Assert.isTrue(newA.contains('import dep.Helper;'), 'the import a remaining Helper.go() needs was dropped');
		Assert.isTrue(newA.contains('Helper.go();'), 'the remaining value-position use was lost');
		Assert.isTrue(changeFor(changes, 'pkg/B.hx').newSource.contains('import dep.Helper;'), 'the dependency import was not carried');
	}

	/**
	 * CONTROL for the container-end rule: a container's end is not always a directive or EOF. A
	 * trailing COMMENT is trivia, so it is no sibling and the declaration still reads as the last
	 * in its container — but the blank in front of the comment is a real separator. Taking BOTH
	 * runs there, the obvious spelling of "a declaration at the end owns no blank", glued the
	 * comment onto the previous declaration's closing brace, and flips exactly this. Found by a
	 * review probe of this slice's own first cut, not by any pin it shipped with.
	 */
	public function testACutBeforeATrailingCommentKeepsOneSeparator(): Void {
		final a: String =
			'package pkg;\n\nclass Keep {\n\tpublic var k:Int = 1;\n}\n\nclass Gone {\n\tpublic var g:Int = 1;\n}\n\n// a trailing note\n';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 7, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		]);
		Assert.equals(
			'package pkg;\n\nclass Keep {\n\tpublic var k:Int = 1;\n}\n\n// a trailing note\n', changeFor(changes, 'pkg/A.hx').newSource
		);
	}

	/**
	 * A `#if … #else … #end` region flattens EVERY branch into ONE child list, so two declarations
	 * either side of an `#else` are adjacent children of one node and a child-INDEX test reads the
	 * last of the `#if` branch as mid-container — leaving `}` + blank + `#else`, the very shape the
	 * region pins above exist to remove. The neighbour test therefore asks the SOURCE as well:
	 * a sibling only counts when nothing but whitespace stands between it and the cut. Found by
	 * review, not by any pin the first cut shipped with.
	 */
	public function testCuttingTheLastDeclarationOfAConditionalBranchTakesItsSeparator(): Void {
		final a: String = 'package pkg;\n\n#if macro\nclass A {\n\tpublic var a:Int = 1;\n}\n\nclass Gone {\n\tpublic var g:Int = 1;\n}\n'
			+ '#else\nclass C {\n\tpublic var c:Int = 1;\n}\n#end\n';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 8, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		]);
		Assert.equals(
			'package pkg;\n\n#if macro\nclass A {\n\tpublic var a:Int = 1;\n}\n#else\nclass C {\n\tpublic var c:Int = 1;\n}\n#end\n',
			changeFor(changes, 'pkg/A.hx').newSource
		);
	}

	/**
	 * The mirror at the other branch edge: the FIRST declaration after an `#else` owes no blank
	 * against it either, and its trailing run is the one that has to go.
	 */
	public function testCuttingTheFirstDeclarationOfAConditionalBranchTakesItsSeparator(): Void {
		final a: String = 'package pkg;\n\n#if macro\nclass A {\n\tpublic var a:Int = 1;\n}\n#else\nclass Gone {\n'
			+ '\tpublic var g:Int = 1;\n}\n\nclass C {\n\tpublic var c:Int = 1;\n}\n#end\n';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 8, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		]);
		Assert.equals(
			'package pkg;\n\n#if macro\nclass A {\n\tpublic var a:Int = 1;\n}\n#else\nclass C {\n\tpublic var c:Int = 1;\n}\n#end\n',
			changeFor(changes, 'pkg/A.hx').newSource
		);
	}

	/**
	 * CONTROL, and the one shape the `needsSeparator` answer alone decides: a MIDDLE declaration
	 * with a blank on exactly ONE side. With both sides blank the "keep one" branch is taken
	 * whatever the answer is, which is why the four-fixture controls above cannot see it. Here
	 * `needsSeparator` is the whole decision — forcing it false takes the leading blank and glues
	 * `class B` onto `class A`'s brace.
	 */
	public function testAMiddleDeclarationWithOneBlankSideKeepsIt(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic var a:Int = 1;\n}\n\nclass Gone {\n\tpublic var g:Int = 1;\n}\nclass B {\n'
			+ '\tpublic var b:Int = 1;\n}\n';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 7, 7, 'pkg/B.hx', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B2 {}' }
		]);
		Assert.equals(
			'package pkg;\n\nclass A {\n\tpublic var a:Int = 1;\n}\n\nclass B {\n\tpublic var b:Int = 1;\n}\n',
			changeFor(changes, 'pkg/A.hx').newSource
		);
	}

	/**
	 * Haxe resolves an unqualified type name through the file's own package and then through every
	 * ANCESTOR package, so `p/sub/deep/C.hx` reaches `p.Moved` with no import at all — and when the
	 * type leaves `p`, that file owes an import exactly as a same-package sibling does. Compile-proved
	 * on 4.3.7 in both directions: the descendant sees it, a sibling package (`q`) reads
	 * `Type not found : Moved`.
	 */
	public function testADescendantPackageFileFollowsTheTypeThroughAnAncestorPackage(): Void {
		final changes: Array<MoveChange> = okChanges('p/Moved.hx', 3, 7, 'p/Dest.hx', [
			{ file: 'p/Moved.hx', source: 'package p;\n\nclass Moved {}' },
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' },
			{ file: 'p/sub/deep/C.hx', source: 'package p.sub.deep;\n\nclass C {\n\tvar m:Moved;\n}' }
		]);
		Assert.equals(
			'package p.sub.deep;\n\nimport p.Dest.Moved;\n\nclass C {\n\tvar m:Moved;\n}', changeFor(changes, 'p/sub/deep/C.hx').newSource
		);
	}

	/**
	 * The chain is the file's OWN ancestors, not every package in the index: a file of package `q`
	 * never reached `p.Moved` by a simple name, so it is owed nothing and writing it an import would
	 * be a statement for a reference that does not exist. The control is discriminating because `q/D.hx`
	 * DOES spell `Moved` — the walk's other two gates (the ladder answer and the name scan) cannot tell
	 * this case from the one above.
	 */
	public function testASiblingPackageIsNotAnAncestorSoItIsLeftAlone(): Void {
		final changes: Array<MoveChange> = okChanges('p/Moved.hx', 3, 7, 'p/Dest.hx', [
			{ file: 'p/Moved.hx', source: 'package p;\n\nclass Moved {}' },
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' },
			{ file: 'q/D.hx', source: 'package q;\n\nclass D {\n\tvar m:Moved;\n}' }
		]);
		assertUnchanged(changes, 'q/D.hx');
	}

	/**
	 * The NEAREST ancestor wins, measured rather than assumed: with both `p.Dep` and `p.sub.Dep`
	 * present, a `p.sub.deep` file prints `p.sub.Dep` on 4.3.7. The refusal has to name THAT one — a
	 * chain walked root-first answers `p.Dep`, which is what the destination already binds, and the
	 * gate then finds no collision at all and lets the rebind through.
	 */
	public function testTheNearestAncestorOwnsTheNameSoTheRefusalNamesIt(): Void {
		assertErrContains(MoveSymbol.moveType('p/sub/deep/Mover.hx', 3, 7, 'q/Host.hx', [
			{ file: 'p/sub/deep/Mover.hx', source: 'package p.sub.deep;\n\nclass Mover {\n\tvar d:Dep;\n}' },
			{ file: 'q/Host.hx', source: 'package q;\n\nimport p.Dep;\n\nclass Host {\n\tvar d:Dep;\n}' },
			{ file: 'p/Dep.hx', source: 'package p;\n\nclass Dep {}' },
			{ file: 'p/sub/Dep.hx', source: 'package p.sub;\n\nclass Dep {}' }
		], plugin(), typeRefShape()), 'reaches "Dep" as p.sub.Dep');
	}

	/**
	 * A QUALIFIED path's head is a module resolved through the same chain — compile-proved on its own
	 * account: `p/sub/deep/C.hx` resolves `Mod.Sub` against `p.Mod` while a sibling `q/D.hx` reads
	 * `Type not found : Mod`. Modelling only the same package and the root made both sides answer "the
	 * top level", the two nulls agreed, and a cross-package move rebound the reference in silence.
	 */
	public function testAQualifiedHeadReachedThroughAnAncestorPackageIsPriced(): Void {
		assertErrContains(MoveSymbol.moveType('p/sub/deep/Mover.hx', 3, 7, 'q/Host.hx', [
			{ file: 'p/sub/deep/Mover.hx', source: 'package p.sub.deep;\n\nclass Mover {\n\tvar s:Mod.Sub;\n}' },
			{ file: 'q/Host.hx', source: 'package q;\n\nclass Host {}' },
			{ file: 'p/Mod.hx', source: 'package p;\n\nclass Mod {}\n\nclass Sub {}' }
		], plugin(), typeRefShape()), 'whose head "Mod" is a module resolved through');
	}

	/**
	 * A dependency reached through a STATIC RECEIVER is a dependency, and the layer that used to answer
	 * this question sees type POSITIONS only — `apq uses Helper` returns 0 hits on a file whose one
	 * reference is `Helper.go()`. The op's own doc called the residue LOUD ("never a silent semantic
	 * change") and that is false: run through the base engine, a `Moved` reaching `r.Helper` through
	 * the source file's import, moved into a destination whose own package declares `p.Helper`, came
	 * back bound to `p.Helper` and `Moved.use()` went from 42 to 7 at rc 0.
	 */
	public function testAStaticReceiverDependencyIsCarried(): Void {
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 5, 7, 'p/Host.hx', [
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nimport r.Helper;\n\nclass Mover {\n\tpublic static function use():Int return Helper.go();\n}'
			},
			{ file: 'p/Host.hx', source: 'package p;\n\nclass Host {}' },
			{ file: 'p/Helper.hx', source: 'package p;\n\nclass Helper {}' },
			{ file: 'r/Helper.hx', source: 'package r;\n\nclass Helper {}' }
		]);
		Assert.isTrue(changeFor(changes, 'p/Host.hx').newSource.contains('import r.Helper;'));
	}

	/**
	 * The same widening turns a silent break into a refusal where carrying cannot help: a SECONDARY
	 * type of the module the declaration is leaving is `Type not found` from anywhere else, so there is
	 * no statement to write. Compile-proved on the shape — the base engine writes two files at rc 0 and
	 * the tree then reads `Type not found : Sib` — and it is the whole refusal cost this arm adds to the
	 * Pony census (2 of 133), both of them exactly this.
	 */
	public function testAStaticReceiverOnASiblingSubTypeIsRefused(): Void {
		assertErrContains(MoveSymbol.moveType('p/Mover.hx', 3, 7, 'p/Host.hx', [
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nclass Mover {\n\tpublic static function use():Int return Sib.go();\n}\n\nclass Sib {}'
			},
			{ file: 'p/Host.hx', source: 'package p;\n\nclass Host {}' }
		], plugin(), typeRefShape()), 'no import to carry');
	}

	/**
	 * Only the RECEIVER slot. A bare upper-initial identifier in a VALUE position is an enum
	 * CONSTRUCTOR far more often than a module, and nothing in the index can tell the two apart — so
	 * `Type.createInstance(Dep, [])` does not price `Dep`, and the destination's differing binding for
	 * `Dep` is not a refusal.
	 *
	 * Only the `Dep` half is observable here: `Type` resolves to nothing on either side and produces no
	 * refusal either way. The control is the boundary this slice deliberately did not cross; widening the
	 * scan to every upper-initial identifier flips it, and that arm was measured on the Pony census — 4
	 * more refusals of 131 accepted, every one of them compile-proved correct, and ZERO changed diffs.
	 */
	public function testAValuePositionIsStillNotPriced(): Void {
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 5, 7, 'p/Host.hx', [
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nimport r.Dep;\n\nclass Mover {\n'
				+ '\tpublic static function use():Dynamic return Type.createInstance(Dep, []);\n}'
			},
			{ file: 'p/Host.hx', source: 'package p;\n\nimport z.Dep;\n\nclass Host {\n\tvar d:Dep;\n}' },
			{ file: 'r/Dep.hx', source: 'package r;\n\nclass Dep {}' },
			{ file: 'z/Dep.hx', source: 'package z;\n\nclass Dep {}' }
		]);
		Assert.equals(
			'package p;\n\nimport z.Dep;\n\nclass Host {\n\tvar d:Dep;\n}\n\nclass Mover {\n'
			+ '\tpublic static function use():Dynamic return Type.createInstance(Dep, []);\n}\n',
			changeFor(changes, 'p/Host.hx').newSource
		);
	}

	/**
	 * A scope file that reaches the moved type ONLY through a static receiver is owed the same repair
	 * import a type-position reference gets. The repoint walk already answered with a text scan while
	 * the statementless walk answered with the type-position projection — two answers to one question,
	 * and this file's `Moved.use()` fell through the second: `Type not found : Moved` in a file the
	 * move never touched, at rc 0.
	 */
	public function testAStaticReceiverReferenceIsRepairedInAStatementlessFile(): Void {
		final changes: Array<MoveChange> = okChanges('p/Moved.hx', 3, 7, 'p/Dest.hx', [
			{ file: 'p/Moved.hx', source: 'package p;\n\nclass Moved {\n\tpublic static function use():Int return 5;\n}' },
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' },
			{ file: 'p/Main.hx', source: 'package p;\n\nclass Main {\n\tpublic static function go():Int return Moved.use();\n}' }
		]);
		Assert.equals(
			'package p;\n\nimport p.Dest.Moved;\n\nclass Main {\n\tpublic static function go():Int return Moved.use();\n}',
			changeFor(changes, 'p/Main.hx').newSource
		);
	}

	/**
	 * The SOURCE file's own re-import is the third reader of that one question, and it fell through the
	 * same way: a `Moved.use()` left standing after the cut got no `import p.Dest.Moved;` and the file
	 * the op had just rewritten did not compile.
	 */
	public function testTheSourceFileGainsAnImportForAStaticReceiverItKeeps(): Void {
		final changes: Array<MoveChange> = okChanges('p/Src.hx', 7, 7, 'p/Dest.hx', [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nclass Src {\n\tpublic static function ask():Int return Moved.use();\n}\n\nclass Moved {\n'
				+ '\tpublic static function use():Int return 5;\n}'
			},
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' }
		]);
		Assert.isTrue(changeFor(changes, 'p/Src.hx').newSource.contains('import p.Dest.Moved;'));
	}

	/**
	 * The source file's own re-import reads the same name set for the same reason: a `case Red:` it
	 * keeps is a reference to the enum that left, and the file may never spell `Colour` anywhere. A
	 * scan of the type name alone leaves the file the op has just rewritten without the import its own
	 * remaining code needs.
	 */
	public function testTheSourceFileGainsAnImportForAMovedEnumsConstructorItKeeps(): Void {
		final changes: Array<MoveChange> = okChanges('p/Src.hx', 10, 6, 'p/Dest.hx', [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nclass Src {\n\tpublic static function tag(b:Box):Int return switch b.v {\n\t\tcase Red: 1;\n'
				+ '\t\tcase _: 0;\n\t}\n}\n\nenum Colour {\n\tRed;\n\tGreen;\n}'
			},
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' },
			{ file: 'p/Box.hx', source: 'package p;\n\ntypedef Box = {\n\tvar v:Colour;\n}' }
		]);
		Assert.isTrue(changeFor(changes, 'p/Src.hx').newSource.contains('import p.Dest.Colour;'));
	}

	/**
	 * A mention that appears ONLY in a COMMENT is NOT the reference an import exists for.
	 *
	 * S62 pinned the opposite here, deliberately: `namesAnyOf` passed the comment spans on to the
	 * qualification test and never tested the occurrence itself against them, on the reasoning that
	 * keeping an import a file no longer needs costs a lint advisory while dropping one it does need
	 * costs the build. The second half is true and the first half is not the whole cost: a comment is
	 * never compiled, so an occurrence inside one cannot be the reference the import repairs, and
	 * writing it created the very coupling the move was removing — measured as T512, where a scope
	 * file whose only `Thing` was a doc line came back carrying `import b.Holder.Thing;` at rc 0 with
	 * nothing said about it.
	 *
	 * The second arm is the control and it is what makes this a statement about the SCAN rather than
	 * about the fixture: the same file, the same doc block, plus one real `Moved.tag()` — the import
	 * is written. STRING literals keep counting
	 * (`testAStringOnlyMentionBuysTheImportAndDoesNotRefuseThePrivateMove`), and so does a real code
	 * reference on the line below a comment ending in a period
	 * (`testACommentsTrailingPeriodDoesNotHideTheReferenceOwedARepairImport`) — comment-ADJACENT is
	 * counted, comment-INTERIOR is not.
	 */
	public function testACommentOnlyMentionIsNotAReference(): Void {
		inline function repaired(body: String): String {
			return changeFor(okChanges('p/Src.hx', 8, 7, 'p/Dest.hx', [
				{ file: 'p/Src.hx', source: 'package p;\n\n/**\n * Companion of Moved.\n */\nclass Src {$body}\n\nclass Moved {}' },
				{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' }
			]), 'p/Src.hx').newSource;
		}
		Assert.isFalse(repaired('').contains('import p.Dest.Moved;'), 'a doc block is not the reference an import exists for');
		// The control's member is written on ONE line so both arms have identical line numbering and
		// the shared cursor position keeps addressing `class Moved`.
		Assert.isTrue(
			repaired(' public static function t():Int return Moved.tag(); ').contains('import p.Dest.Moved;'),
			'the control arm: the SAME doc block plus one real code reference still buys the import'
		);
	}

	/**
	 * A carried `using` is declared FIRST inside the destination's own `using` run, so Haxe — which
	 * tries static extensions in reverse declaration order — ranks it LAST and the destination's own
	 * calls keep their meaning.
	 *
	 * The ordinary import anchor cannot decide this: it answers the last plain `import` when the file
	 * has one and the last statement of ANY import kind otherwise, so the same carried line landed on
	 * opposite sides of the run depending on a shape that has nothing to do with the question. Both
	 * halves were measured at rc 0 on 4.3.7 — `q.Ext -> q.Other` for the moved body with an import
	 * present, `q.Other -> q.Ext` for the DESTINATION's own call without one. Both fixtures are here
	 * because only the pair discriminates.
	 */
	public function testACarriedUsingIsDeclaredFirstSoItRanksLast(): Void {
		inline function move(destHeader: String): Array<MoveChange> {
			return okChanges('p/Src.hx', 7, 7, 'p/Dest.hx', [
				{
					file: 'p/Src.hx',
					source: 'package p;\n\nusing q.Ext;\n\nclass Src {}\n\nclass Moved {\n'
					+ '\tpublic static function use(s:String):String return s.go();\n}'
				},
				{ file: 'p/Dest.hx', source: '$destHeader\nclass Dest {\n\tpublic static function d(s:String):String return s.go();\n}' },
				{ file: 'q/Ext.hx', source: 'package q;\n\nclass Ext {}' },
				{ file: 'q/Other.hx', source: 'package q;\n\nclass Other {}' },
				{ file: 'q/Third.hx', source: 'package q;\n\nclass Third {}' }
			]);
		}
		Assert.isTrue(changeFor(move('package p;\n\nusing q.Other;\n\n'), 'p/Dest.hx').newSource.contains('using q.Ext;\nusing q.Other;'));
		Assert.isTrue(
			changeFor(move('package p;\n\nimport q.Other;\n\nusing q.Other;\n\n'), 'p/Dest.hx')
				.newSource.contains('using q.Ext;\nusing q.Other;')
		);
		// A run of TWO: the anchor is the FIRST of them, which one `using` cannot tell from the last.
		Assert.isTrue(
			changeFor(move('package p;\n\nusing q.Other;\nusing q.Third;\n\n'), 'p/Dest.hx')
				.newSource.contains('using q.Ext;\nusing q.Other;\nusing q.Third;')
		);
	}

	/**
	 * A destination whose own `using` run sits inside a `#if` region with a plain import BELOW it
	 * offers no seat: the region cannot be entered (the carried statement must be unconditional) and
	 * the ordinary anchor is under the import, hence under the region. Writing there was measured at
	 * rc 0 taking `Dest.d("x")` from `OTHER` to `EXT` — the destination's OWN call, which is the half
	 * the seat exists to protect — so the answer is a refusal naming the statement.
	 */
	public function testAGuardedDestinationUsingRunBelowTheAnchorIsRefused(): Void {
		assertErrContains(MoveSymbol.moveType('p/Src.hx', 7, 7, 'p/Dest.hx', [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nusing q.Ext;\n\nclass Src {}\n\nclass Moved {\n'
				+ '\tpublic static function use(s:String):String return s.go();\n}'
			},
			{ file: 'p/Dest.hx', source: 'package p;\n\n#if eval\nusing q.Other;\n#end\nimport a.B;\n\nclass Dest {}' },
			{ file: 'q/Ext.hx', source: 'package q;\n\nclass Ext {}' },
			{ file: 'q/Other.hx', source: 'package q;\n\nclass Other {}' },
			{ file: 'a/B.hx', source: 'package a;\n\nclass B {}' }
		], plugin(), typeRefShape()), 'offers no seat above it');
	}

	/**
	 * The same refusal for the other seatless shape: a `using` SHARING its line with the package
	 * declaration has no line start above it that is still below `package`, and the carried statement
	 * was written ABOVE `package` — which anyparse re-parses happily and Haxe rejects with
	 * `Unexpected keyword "package"`, at rc 0 with two files written.
	 */
	public function testADestinationUsingSharingItsLineIsRefused(): Void {
		assertErrContains(MoveSymbol.moveType('p/Src.hx', 7, 7, 'p/Dest.hx', [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nusing q.Ext;\n\nclass Src {}\n\nclass Moved {\n'
				+ '\tpublic static function use(s:String):String return s.go();\n}'
			},
			{ file: 'p/Dest.hx', source: 'package p; using q.Other;\n\nclass Dest {}' },
			{ file: 'q/Ext.hx', source: 'package q;\n\nclass Ext {}' },
			{ file: 'q/Other.hx', source: 'package q;\n\nclass Other {}' }
		], plugin(), typeRefShape()), 'offers no seat above it');
	}

	/**
	 * String interpolation is executable code, and the UNBRACED `'$Moved'` form projects as its own
	 * kind — `RefShape.stringInterpIdentKind`, which the shape names and ~20 checks already read. A
	 * proven scan that asked only for `identKind` caught the braced `'${Moved}'` and lost this one, so
	 * a module-private type whose last reference was `'v=$Moved'` moved at rc 0 and the source then
	 * read `Unknown identifier : Moved`.
	 */
	public function testAPrivateTypeReachedByUnbracedInterpolationIsRefused(): Void {
		assertErrContains(MoveSymbol.moveType('p/Src.hx', 7, 15, 'p/Dest.hx', [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nclass Src {\n\tpublic static function tag():String return \'v=$$Moved\';\n}\n\n'
				+ 'private class Moved {}'
			},
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' }
		], plugin(), typeRefShape()), 'is module-private and');
	}

	/**
	 * The SPLIT path: a carry holding both a plain import and a `using` puts each at its own seat — the
	 * import at the ordinary anchor, the `using` at the head of the destination's run. Nothing else in
	 * the suite carries both at once, so `carriedImportLines` and the two-edit branch had no coverage.
	 */
	public function testACarriedImportAndUsingTakeSeparateSeats(): Void {
		final changes: Array<MoveChange> = okChanges('p/Src.hx', 9, 7, 'p/Dest.hx', [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nimport a.Dep;\n\nusing q.Ext;\n\nclass Src {}\n\nclass Moved {\n\tvar d:Dep;\n\n'
				+ '\tpublic static function use(s:String):String return s.go();\n}'
			},
			{ file: 'p/Dest.hx', source: 'package p;\n\nusing q.Other;\n\nclass Dest {}' },
			{ file: 'a/Dep.hx', source: 'package a;\n\nclass Dep {}' },
			{ file: 'q/Ext.hx', source: 'package q;\n\nclass Ext {}' },
			{ file: 'q/Other.hx', source: 'package q;\n\nclass Other {}' }
		]);
		Assert.equals(
			'package p;\n\nusing q.Ext;\nusing q.Other;\nimport a.Dep;\n\nclass Dest {}\n\nclass Moved {\n\tvar d:Dep;\n\n'
			+ '\tpublic static function use(s:String):String return s.go();\n}\n',
			changeFor(changes, 'p/Dest.hx').newSource
		);
	}

	/**
	 * The module-private refusal asks the PROVEN scan, so a mention that lives only in a COMMENT is
	 * neither a reason to refuse nor something an import could repair — the base engine moved this
	 * cleanly and the text scan the import branch uses would have refused it. The sibling fixture
	 * `testACommentOnlyMentionStillCountsAsAReference` is the same shape with a PUBLIC type, where the
	 * loose answer is the safe one; the pair is what makes the split visible.
	 */
	public function testACommentOnlyMentionDoesNotRefuseAPrivateType(): Void {
		final changes: Array<MoveChange> = okChanges('p/Src.hx', 8, 15, 'p/Dest.hx', [
			{ file: 'p/Src.hx', source: 'package p;\n\n/**\n * Companion of Moved.\n */\nclass Src {}\n\nprivate class Moved {}' },
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' }
		]);
		Assert.equals('package p;\n\n/**\n * Companion of Moved.\n */\nclass Src {}\n', changeFor(changes, 'p/Src.hx').newSource);
	}

	/**
	 * …and a RECEIVER reference still refuses it, which is the half the proven scan must not lose: the
	 * base engine's type-position walk could not see `Moved.use()` either, so it wrote the source file
	 * back without the import it needs and without a refusal.
	 */
	public function testAPrivateTypeStillReachedByAStaticReceiverIsRefused(): Void {
		assertErrContains(MoveSymbol.moveType('p/Src.hx', 7, 15, 'p/Dest.hx', [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nclass Src {\n\tpublic static function ask():Int return Moved.use();\n}\n\nprivate class Moved {\n'
				+ '\tpublic static function use():Int return 5;\n}'
			},
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' }
		], plugin(), typeRefShape()), 'is module-private and');
	}

	/**
	 * A `using` grants STATIC EXTENSIONS and an extension call spells the method name and nothing else,
	 * so no name scan can see which module supplied it — the same evidence on which S40 keeps a
	 * DESTINATION `using` unconditionally. Without the mirror the moved body's `s.trim()` arrived at a
	 * destination with no `using StringTools;` and read `String has no field trim` at rc 0.
	 */
	public function testASourceUsingIsCarriedIntoTheDestination(): Void {
		final changes: Array<MoveChange> = okChanges('p/Src.hx', 7, 7, 'p/Dest.hx', [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nusing StringTools;\n\nclass Src {}\n\nclass Moved {\n'
				+ '\tpublic static function use(s:String):String return s.trim();\n}'
			},
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' }
		]);
		Assert.isTrue(changeFor(changes, 'p/Dest.hx').newSource.contains('using StringTools;'));
	}

	/**
	 * The one necessary condition the tree can answer: an extension is reached as `expr.method(...)`,
	 * so a declaration with no member access anywhere inside it needs no `using` and gets none. This is what keeps the
	 * statement off the pure-data moves rather than a guess about which extension a body uses, which
	 * nothing here could make. The fixture puts an extension call in the SIBLING declaration, so a gate
	 * that asked the whole file rather than the declaration's own span would carry the line anyway.
	 */
	public function testADeclarationWithNoMemberAccessCarriesNoUsing(): Void {
		final changes: Array<MoveChange> = okChanges('p/Src.hx', 9, 7, 'p/Dest.hx', [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nusing StringTools;\n\nclass Src {\n\tpublic static function s(v:String):String return v.trim();\n'
				+ '}\n\nclass Moved {\n\tvar n:Int;\n}'
			},
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' }
		]);
		Assert.equals('package p;\n\nclass Dest {}\n\nclass Moved {\n\tvar n:Int;\n}\n', changeFor(changes, 'p/Dest.hx').newSource);
	}

	/**
	 * A `using` the destination already holds is not written a second time, and a `#if`-guarded one is
	 * not carried at all — it binds under its own flag and under no other, which an unconditional line
	 * at the destination would not reproduce. Both halves in one fixture, because either alone leaves
	 * the other's arm free.
	 */
	public function testAnAlreadyPresentOrGuardedSourceUsingIsNotCarried(): Void {
		final changes: Array<MoveChange> = okChanges('p/Src.hx', 10, 7, 'p/Dest.hx', [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nusing StringTools;\n#if cpp\nusing Lambda;\n#end\n\nclass Src {}\n\nclass Moved {\n'
				+ '\tpublic static function use(s:String):String return s.trim();\n}'
			},
			{ file: 'p/Dest.hx', source: 'package p;\n\nusing StringTools;\n\nclass Dest {}' }
		]);
		Assert.equals(
			'package p;\n\nusing StringTools;\n\nclass Dest {}\n\nclass Moved {\n'
			+ '\tpublic static function use(s:String):String return s.trim();\n}\n',
			changeFor(changes, 'p/Dest.hx').newSource
		);
	}

	/**
	 * The moved type's OWN name is not a dependency on itself, in the receiver slot as in a type
	 * position. Without the filter every type that calls one of its own
	 * statics — `Mover.n` inside `Mover` — prices `Mover` against a destination that does not yet
	 * declare it. The move has to be CROSS-package for that to bite: the index is built BEFORE the cut,
	 * so a same-package destination answers `p.Mover` through the package rung and the two agree, and
	 * only a destination outside the chain reaches nothing and refuses with "no import to carry" for a
	 * name that travels with the declaration.
	 */
	public function testTheMovedTypesOwnStaticReceiverIsNotPriced(): Void {
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 3, 7, 'q/Host.hx', [
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nclass Mover {\n\tstatic var n:Int = 1;\n\n\tpublic static function use():Int return Mover.n;\n}'
			},
			{ file: 'q/Host.hx', source: 'package q;\n\nclass Host {}' }
		]);
		Assert.isTrue(changeFor(changes, 'q/Host.hx').newSource.contains('class Mover {'));
	}

	/**
	 * A carried `using` binds its module's own TYPE name beside the extensions, so it faces the same
	 * collision gate a carried import does — and a collision SKIPS the line rather than refusing the
	 * move.
	 *
	 * The asymmetry with the dependency carry is the point: there the moved code PROVABLY names the
	 * dependency, so an unrepairable binding must be refused; here the need is unproven, the gate fires
	 * for a `using` the declaration may never touch, and refusing would cost a correct refactor — review
	 * found the refusing version aborting whole moves on this shape. What skipping costs is bounded but
	 * not nothing: it cannot rebind a TYPE name, and its worst case is either a missing extension (loud,
	 * which is what this fixture produces) or the moved call landing on an extension the destination
	 * already supplies.
	 */
	public function testACarriedUsingCollidingWithADestinationBindingIsSkippedNotRefused(): Void {
		final changes: Array<MoveChange> = okChanges('p/Src.hx', 7, 7, 'p/Dest.hx', [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nusing q.Tools;\n\nclass Src {}\n\nclass Moved {\n'
				+ '\tpublic static function use(s:String):String return s.trim();\n}'
			},
			{ file: 'p/Dest.hx', source: 'package p;\n\nimport z.Tools;\n\nclass Dest {\n\tvar t:Tools;\n}' },
			{ file: 'q/Tools.hx', source: 'package q;\n\nclass Tools {}' },
			{ file: 'z/Tools.hx', source: 'package z;\n\nclass Tools {}' }
		]);
		Assert.equals(
			'package p;\n\nimport z.Tools;\n\nclass Dest {\n\tvar t:Tools;\n}\n\nclass Moved {\n'
			+ '\tpublic static function use(s:String):String return s.trim();\n}\n',
			changeFor(changes, 'p/Dest.hx').newSource
		);
	}

	/**
	 * A `#if`-guarded `using` at the DESTINATION satisfies nothing: it binds under its own flag and
	 * under no other, so a build without that flag still needs the unconditional line. Compile-proved —
	 * with a `#if js using StringTools; #end` at the destination and the guard absent from the
	 * `already` test, the move wrote two files at rc 0 and the tree read `String has no field trim` on
	 * neko. It is the filter `addImportEdit` has always applied for the same reason.
	 */
	public function testAGuardedDestinationUsingDoesNotSatisfyTheCarry(): Void {
		final changes: Array<MoveChange> = okChanges('p/Src.hx', 7, 7, 'p/Dest.hx', [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nusing StringTools;\n\nclass Src {}\n\nclass Moved {\n'
				+ '\tpublic static function use(s:String):String return s.trim();\n}'
			},
			{ file: 'p/Dest.hx', source: 'package p;\n\n#if js\nusing StringTools;\n#end\n\nclass Dest {}' }
		]);
		Assert.equals(
			'package p;\n\nusing StringTools;\n#if js\nusing StringTools;\n#end\n\nclass Dest {}\n\nclass Moved {\n'
			+ '\tpublic static function use(s:String):String return s.trim();\n}\n',
			changeFor(changes, 'p/Dest.hx').newSource
		);
	}

	/**
	 * A LOWERCASE receiver is not priced, and that is a trade rather than a truth: Haxe permits a
	 * lowercase type name (it only warns), so `tools.go()` COULD be a real dependency — but every local
	 * variable is lowercase too, and pricing them would put a `carryCollision` question against every
	 * `s.trim()` in the body. The guard buys that at the cost of the rare lowercase type, which the
	 * compiler itself discourages.
	 */
	public function testALowercaseReceiverIsNotPriced(): Void {
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 5, 7, 'p/Host.hx', [
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nimport r.tools;\n\nclass Mover {\n\tpublic static function use():Int return tools.go();\n}'
			},
			{ file: 'p/Host.hx', source: 'package p;\n\nimport z.tools;\n\nclass Host {\n\tvar t:tools;\n}' },
			{ file: 'r/tools.hx', source: 'package r;\n\nclass tools {}' },
			{ file: 'z/tools.hx', source: 'package z;\n\nclass tools {}' }
		]);
		Assert.equals(
			'package p;\n\nimport z.tools;\n\nclass Host {\n\tvar t:tools;\n}\n\nclass Mover {\n'
			+ '\tpublic static function use():Int return tools.go();\n}\n',
			changeFor(changes, 'p/Host.hx').newSource
		);
	}

	/**
	 * A DOTLESS path no module in the index spells is the AMBIENT TOP LEVEL, and both sides mean the
	 * same type by it — so a destination that merely WRITES `StringTools.lpad(...)` is not a collision.
	 * Green at base only because nothing priced a receiver there at all; once `StringTools.trim(s)` is
	 * a dependency the ambient arm of the collision gate fires on it, and 2 of 15 accepted Pony
	 * `move-member` cases were refused before this exemption existed.
	 */
	public function testAnAmbientTopLevelDependencyIsNotACollision(): Void {
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 5, 7, 'p/Host.hx', [
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nusing StringTools;\n\nclass Mover {\n'
				+ '\tpublic static function use(s:String):String return StringTools.trim(s);\n}'
			},
			{
				file: 'p/Host.hx',
				source: 'package p;\n\nclass Host {\n\tpublic static function pad(s:String):String return StringTools.lpad(s, " ", 3);\n}'
			}
		]);
		Assert.isTrue(changeFor(changes, 'p/Host.hx').newSource.contains('using StringTools;'));
	}

	/**
	 * The exemption is DOTLESS-and-UNKNOWN, not dotless: a root module the index DOES hold is a real
	 * binding the carried statement would outrank, and the gate still refuses it.
	 *
	 * The fixture is CONSTRUCTED rather than found in the corpus — a root module whose only type is not
	 * its own name is the one shape that reaches this arm, since a root module that DOES declare its own
	 * type is visible from every package and answers `standing` itself.
	 */
	public function testARootPackageModuleTheIndexHoldsIsStillACollision(): Void {
		assertErrContains(MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', [
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nimport Dep;\n\nclass Mover {\n\tpublic static function use():Int return Dep.go();\n}'
			},
			{ file: 'p/Host.hx', source: 'package p;\n\nclass Host {\n\tpublic static function ask():Int return Dep.go();\n}' },
			{ file: 'Dep.hx', source: 'class Other {}' }
		], plugin(), typeRefShape()), 'references "Dep" while nothing in the indexed scope binds it there');
	}

	/**
	 * A statementless file can reach a moved ENUM through its CONSTRUCTORS and never spell the type at
	 * all — S41's own Pony case was `pony/ServiceProvider.hx` reaching `pony.Or.OrState` only through
	 * `case A(cb)`. The repoint walk was taught the constructor names then; the repair walk scans the
	 * same set now, and a scan of the type name alone leaves this file unrepaired.
	 */
	public function testAStatementlessFileNamingOnlyAMovedEnumsConstructorIsRepaired(): Void {
		final changes: Array<MoveChange> = okChanges('p/Colour.hx', 3, 6, 'p/Dest.hx', [
			{ file: 'p/Colour.hx', source: 'package p;\n\nenum Colour {\n\tRed;\n\tGreen;\n}' },
			{ file: 'p/Dest.hx', source: 'package p;\n\nclass Dest {}' },
			{ file: 'p/Box.hx', source: 'package p;\n\ntypedef Box = {\n\tvar v:Colour;\n}' },
			{
				file: 'p/Reader.hx',
				source: 'package p;\n\nclass Reader {\n\tpublic static function tag(b:Box):Int return switch b.v {\n\t\tcase Red: 1;\n'
				+ '\t\tcase _: 0;\n\t}\n}'
			}
		]);
		Assert.isTrue(changeFor(changes, 'p/Reader.hx').newSource.contains('import p.Dest.Colour;'));
	}

	/**
	 * A doc comment whose continuation lines carry NO `*` gutter travels whole with the declaration.
	 *
	 * The backward trivia walk read one line at a time and accepted a line starting with `//`, `/*`,
	 * `*` or `@` — so a `/**\n\tText\n**\/` block matched only on its closing line, and the cut took
	 * the `**\/` and left the opener behind. The destination then began with a bare `**\/` and stopped
	 * parsing; the op refused with `parse failed` and no position, which is how the shape stayed
	 * invisible. Measured on a real 1127-line test module. The walk now asks the lexer where the
	 * comment starts before reading any line's text.
	 */
	public function testAGutterlessDocBlockTravelsWholeWithTheDeclaration(): Void {
		final doc: String = '/**\n\tThe kind of doc block that has no gutter.\n\tSecond line, still prose.\n**/\n';
		final changes: Array<MoveChange> = okChanges('p/Mover.hx', 11, 7, 'p/Host.hx', [
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nclass Keep {\n\tpublic function new() {}\n}\n\n${doc}class Gone {\n\tpublic function new() {}\n}\n'
			},
			{ file: 'p/Host.hx', source: 'package p;\n' }
		]);
		final dest: String = changeFor(changes, 'p/Host.hx').newSource;
		Assert.isTrue(dest.contains(doc), 'the whole doc block should have travelled, got:\n$dest');
		final source: String = changeFor(changes, 'p/Mover.hx').newSource;
		Assert.isFalse(source.contains('**/'), 'no half of the doc block should be left behind, got:\n$source');
	}

	/**
	 * A fully-qualified `a.Thing` that appears ONLY inside a COMMENT does not refuse the move.
	 *
	 * `qualifiedPathRefusal` is a raw `indexOf` over each scope file with only the import statements
	 * excluded, so a doc line naming the path read as a code reference and blocked a legitimate move
	 * at rc 1 — with advice ("convert it to a bare Thing, with an import") that means nothing for
	 * prose. Reproduced as T511 on the base engine over exactly this three-file scope.
	 *
	 * Two controls, because a refusal gate that stops refusing is worth nothing on its own. A REAL
	 * `a.Thing.go()` in the same slot still refuses — that is the reference the gate exists for. And
	 * a STRING literal spelling the path still refuses too, deliberately: `Type.resolveClass("a.Thing")`
	 * is a reference the move breaks and nothing in the repair walk rewrites, which is the whole
	 * reason the comment mask is comments-only and not `lexicalRegions` wholesale.
	 */
	public function testACommentOnlyFullyQualifiedMentionDoesNotRefuseTheMove(): Void {
		inline function moveWith(readerBody: String): MoveResult {
			return MoveSymbol.moveType('a/Thing.hx', 3, 7, 'b/Holder.hx', [
				{ file: 'a/Thing.hx', source: 'package a;\n\nclass Thing {\n\tpublic static function go():Int return 1;\n}\n' },
				{ file: 'b/Holder.hx', source: 'package b;\n\nclass Holder {\n\tpublic static function run():Int return 1;\n}\n' },
				{ file: 'b/Reader.hx', source: 'package b;\n\nclass Reader {\n$readerBody}\n' }
			], plugin(), typeRefShape());
		}
		switch moveWith('\t// The registry key is a.Thing here.\n\tpublic static function read():Int return 2;\n') {
			case Ok(changes, _):
				// The whole changed set, not just the absence of one file: an assertion that only says
				// "Reader is missing" also passes for a move that stopped writing anything at all.
				final touched: Array<String> = [for (c in changes) c.file];
				touched.sort(Reflect.compare);
				Assert.equals('a/Thing.hx,b/Holder.hx', touched.join(','), 'the file whose only mention is a comment is untouched');
			case Err(message):
				Assert.fail('a comment-only fully-qualified mention must not refuse the move: $message');
		}
		assertErrContains(moveWith('\tpublic static function read():Int return a.Thing.go();\n'), 'by its fully-qualified path');
		assertErrContains(moveWith('\tpublic static function read():String return "a.Thing";\n'), 'by its fully-qualified path');
	}

	private function assertUnchanged(changes: Array<MoveChange>, file: String): Void {
		for (c in changes) if (c.file == file) Assert.fail('$file should not have been rewritten');
		Assert.pass();
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
