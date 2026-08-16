package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.CrossRename;

using StringTools;
using Lambda;

/**
 * `CrossRename.crossRenameType` — scope-correct, format-preserving
 * cross-file TYPE rename. Hardens the single-file ceiling of the
 * refactoring quartet: `Rename` renames one binding in one file, this
 * renames one type declaration across a whole scope.
 *
 * Each test drives the PURE operation with an IN-MEMORY `scopeFiles`
 * array (no disk), points a cursor at a type declaration in one file,
 * and asserts the EXACT rewritten text of every changed file. The op
 * re-parses every rewrite before returning, so an `Ok` result is
 * guaranteed valid Haxe; the tests additionally re-parse each
 * `newSource` to make the guarantee explicit. Refusal cases assert
 * `Err` and that no rewrite is emitted.
 *
 * Coordinates are the positions `apq refs` / `apq uses` print (the op
 * interprets the column in the same 1-based
 * convention as `rename`). Cursors point at the type NAME so the
 * identifier-token tier of the resolver applies.
 */
class CrossRenameSliceTest extends Test {

	/**
	 * Two-file rename: file A declares `class Foo`, file B uses it as a
	 * field type, a constructor argument type, a return type, and a `new`
	 * expression. Renaming `Foo` -> `Bar` rewrites BOTH files — the decl
	 * name in A and every type position + `new` in B — and nothing else.
	 */
	public function testTwoFileRename(): Void {
		final a: String = 'class Foo {\n\tpublic function new() {}\n}';
		final b: String = 'class Use {\n\tvar f:Foo;\n\tfunction g(a:Foo):Foo {\n\t\treturn new Foo();\n\t}\n}';
		final expectedA: String = 'class Bar {\n\tpublic function new() {}\n}';
		final expectedB: String = 'class Use {\n\tvar f:Bar;\n\tfunction g(a:Bar):Bar {\n\t\treturn new Bar();\n\t}\n}';
		// `class Foo` — `Foo` starts at col 7.
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 7, 'Bar', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedA, changeFor(changes, 'a.hx').newSource);
		Assert.equals(1, changeFor(changes, 'a.hx').count);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(4, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A type position INSIDE an anonymous structure. The one nested in a type
	 * PARAMETER (`Array<{node:Foo}>`) was the documented residual: the projection
	 * dropped the whole struct, so `Uses.find` reported nothing there and the op
	 * left a dangling name that only the compiler caught. The one whose struct IS
	 * the annotation (`p:{cb:Foo -> Void}`) always worked — asserting the file as
	 * ONE string keeps the fixture from passing on unchanged input.
	 */
	public function testTypePositionInsideAnAnonymousStructureRenames(): Void {
		final a: String = 'class Foo {\n\tpublic function new() {}\n}';
		final b: String = 'class Use {\n\tvar f:Array<{node:Foo}>;\n\tfunction g(p:{cb:Foo -> Void}):Void {}\n}';
		final expectedB: String = 'class Use {\n\tvar f:Array<{node:Bar}>;\n\tfunction g(p:{cb:Bar -> Void}):Void {}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 7, 'Bar', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(2, changeFor(changes, 'b.hx').count);
	}

	/**
	 * An arrow-type PARAMETER LABEL that happens to spell the renamed type. A label
	 * binds nothing, so rewriting it is a silent unintended edit — it compiles either
	 * way. The fixture holds the label and a real reference in ONE file, and the
	 * expected text asserts both halves together.
	 */
	public function testArrowFnParameterLabelIsNotRenamed(): Void {
		final a: String = 'class Foo {\n\tpublic function new() {}\n}';
		final b: String = 'class Use {\n\tfunction g():(Foo:Int) -> Void {\n\t\treturn null;\n\t}\n\n\tvar f:Foo;\n}';
		final expectedB: String = 'class Use {\n\tfunction g():(Foo:Int) -> Void {\n\t\treturn null;\n\t}\n\n\tvar f:Bar;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 7, 'Bar', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * `final class` rename — the dominant style. File A declares
	 * `final class Foo`; the named node is the inner `ClassForm` so the
	 * decl-name occurrence is collected through the final-aware
	 * `typeDeclOf` path. After the rename the `final ` keyword is
	 * PRESERVED and the decl token becomes `Bar`; file B's type positions
	 * (field, arg, return, `new`) all rename, and an import segment too.
	 */
	public function testFinalClassRename(): Void {
		final a: String = 'final class Foo {\n\tpublic function new() {}\n}';
		final b: String = 'import pkg.Foo;\nclass Use {\n\tvar f:Foo;\n\tfunction g(a:Foo):Foo {\n\t\treturn new Foo();\n\t}\n}';
		final expectedA: String = 'final class Bar {\n\tpublic function new() {}\n}';
		final expectedB: String = 'import pkg.Bar;\nclass Use {\n\tvar f:Bar;\n\tfunction g(a:Bar):Bar {\n\t\treturn new Bar();\n\t}\n}';
		// `final class Foo` — `Foo` starts at col 13 (after
		// `final class `).
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 13, 'Bar', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		final newA: String = changeFor(changes, 'a.hx').newSource;
		Assert.equals(expectedA, newA);
		// The `final ` keyword survives and the decl token is renamed.
		Assert.isTrue(newA.startsWith('final class Bar'), 'final keyword preserved, decl renamed');
		Assert.equals(1, changeFor(changes, 'a.hx').count);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		// import segment + field + arg + return + new = 5 occurrences.
		Assert.equals(5, changeFor(changes, 'b.hx').count);
	}

	/**
	 * Import rename: file B has `import pkg.Foo;` plus a `var f:Foo;`
	 * type position. Both the import's LAST dotted segment and the type
	 * position are renamed; the lower-case package segment is untouched.
	 */
	public function testImportSegmentRename(): Void {
		final a: String = 'class Foo {}';
		final b: String = 'import pkg.Foo;\nclass Use {\n\tvar f:Foo;\n}';
		final expectedB: String = 'import pkg.Bar;\nclass Use {\n\tvar f:Bar;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 7, 'Bar', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals('class Bar {}', changeFor(changes, 'a.hx').newSource);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		// import segment + type position = 2 occurrences in b.hx.
		Assert.equals(2, changeFor(changes, 'b.hx').count);
	}

	/**
	 * `using pkg.Foo;` LAST segment is renamed exactly like `import`.
	 */
	public function testUsingSegmentRename(): Void {
		final a: String = 'class Foo {}';
		final b: String = 'using pkg.Foo;\nclass Use {}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 7, 'Bar', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals('using pkg.Bar;\nclass Use {}', changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * `extends` / `implements` and the type-param `Array<Foo>` position
	 * are all covered (they ride on `Uses.find`).
	 */
	public function testExtendsImplementsAndTypeParam(): Void {
		final a: String = 'class Foo {}';
		final b: String = 'class Use extends Foo {\n\tvar xs:Array<Foo>;\n}';
		final expectedB: String = 'class Use extends Bar {\n\tvar xs:Array<Bar>;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 7, 'Bar', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(2, changeFor(changes, 'b.hx').count);
	}

	/**
	 * Uniqueness refusal: `Foo` is declared in TWO scope files — the
	 * rename refuses rather than guess which declaration the user meant.
	 */
	public function testAmbiguousDeclRefused(): Void {
		final a: String = 'class Foo {}';
		final dup: String = 'class Foo {}';
		final result: CrossRenameResult = CrossRename.crossRenameType('a.hx', a, 1, 7, 'Bar', [
			{ file: 'a.hx', source: a },
			{ file: 'dup.hx', source: dup },
		], plugin(), typeRefShape(), refShape());
		assertErr(result);
	}

	/**
	 * Refusal: the cursor is not on a type declaration (it lands on a
	 * field, a value position).
	 */
	public function testCursorNotOnTypeDeclRefused(): Void {
		final a: String = 'class Foo {\n\tvar field:Int;\n}';
		// Line 2: the field name `field` at col 6 — a value decl, not a type.
		final result: CrossRenameResult = CrossRename.crossRenameType(
			'a.hx', a, 2, 6, 'renamed', [{ file: 'a.hx', source: a },], plugin(), typeRefShape(), refShape()
		);
		assertErr(result);
	}

	/**
	 * Refusal: a scope file that does not parse — completeness cannot be
	 * proven over an unparseable file, so the whole rename is refused.
	 */
	public function testSkipParseScopeFileRefused(): Void {
		final a: String = 'class Foo {}';
		final broken: String = 'class @@@ not valid haxe @@@';
		final result: CrossRenameResult = CrossRename.crossRenameType('a.hx', a, 1, 7, 'Bar', [
			{ file: 'a.hx', source: a },
			{ file: 'broken.hx', source: broken },
		], plugin(), typeRefShape(), refShape());
		assertErr(result);
	}

	/** No-op `Foo` -> `Foo` is refused. */
	public function testNoOpRefused(): Void {
		final a: String = 'class Foo {}';
		final result: CrossRenameResult = CrossRename.crossRenameType(
			'a.hx', a, 1, 7, 'Foo', [{ file: 'a.hx', source: a },], plugin(), typeRefShape(), refShape()
		);
		assertErr(result);
	}

	/** An invalid new name is rejected without touching any source. */
	public function testInvalidNewNameRefused(): Void {
		final a: String = 'class Foo {}';
		final result: CrossRenameResult = CrossRename.crossRenameType(
			'a.hx', a, 1, 7, '1bad', [{ file: 'a.hx', source: a },], plugin(), typeRefShape(), refShape()
		);
		assertErr(result);
	}

	/** An enum declaration renames just like a class. */
	public function testEnumDeclKind(): Void {
		final a: String = 'enum Color {\n\tRed;\n}';
		final b: String = 'class Use {\n\tvar c:Color;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 6, 'Hue', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals('enum Hue {\n\tRed;\n}', changeFor(changes, 'a.hx').newSource);
		Assert.equals('class Use {\n\tvar c:Hue;\n}', changeFor(changes, 'b.hx').newSource);
	}

	/** An interface declaration renames across its `implements` use. */
	public function testInterfaceDeclKind(): Void {
		final a: String = 'interface Drawable {}';
		final b: String = 'class Use implements Drawable {}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 11, 'Paintable', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals('interface Paintable {}', changeFor(changes, 'a.hx').newSource);
		Assert.equals('class Use implements Paintable {}', changeFor(changes, 'b.hx').newSource);
	}

	/** A typedef declaration renames across a field-type use. */
	public function testTypedefDeclKind(): Void {
		final a: String = 'typedef Id = Int;';
		final b: String = 'class Use {\n\tvar id:Id;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 9, 'Key', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals('typedef Key = Int;', changeFor(changes, 'a.hx').newSource);
		Assert.equals('class Use {\n\tvar id:Key;\n}', changeFor(changes, 'b.hx').newSource);
	}

	/** An abstract declaration renames across a `new`-style use. */
	public function testAbstractDeclKind(): Void {
		final a: String = 'abstract Meters(Int) {}';
		final b: String = 'class Use {\n\tvar m:Meters;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 10, 'Feet', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals('abstract Feet(Int) {}', changeFor(changes, 'a.hx').newSource);
		Assert.equals('class Use {\n\tvar m:Feet;\n}', changeFor(changes, 'b.hx').newSource);
	}

	/**
	 * Static-receiver coverage: file A declares `class Foo` with a static
	 * method and a static var; file B accesses them as `Foo.create()` and
	 * `Foo.CONST`. Each receiver is a `FieldAccess` whose `IdentExpr Foo`
	 * does NOT resolve to a value binding (no in-file value named `Foo`),
	 * so it is the type used as a static namespace and IS renamed —
	 * alongside the import segment and the `:Foo` return-type position.
	 */
	public function testStaticReceiverRenamed(): Void {
		final a: String = 'class Foo {\n\tpublic static function create():Foo return null;\n\tpublic static var CONST = 1;\n}';
		final b: String = 'import pkg.Foo;\nclass C {\n\tfunction m() {\n\t\tFoo.create();\n\t\tvar v = Foo.CONST;\n\t}\n}';
		final expectedA: String = 'class Bar {\n\tpublic static function create():Bar return null;\n\tpublic static var CONST = 1;\n}';
		final expectedB: String = 'import pkg.Bar;\nclass C {\n\tfunction m() {\n\t\tBar.create();\n\t\tvar v = Bar.CONST;\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 7, 'Bar', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedA, changeFor(changes, 'a.hx').newSource);
		// decl name + `:Foo` return type.
		Assert.equals(2, changeFor(changes, 'a.hx').count);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		// import segment + `Foo.create()` + `Foo.CONST`.
		Assert.equals(3, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A static-receiver occurrence SHADOWED by a local value of the same
	 * name is NOT renamed. File B's `var Foo = makeThing(); Foo.run();`
	 * binds `Foo` to a local value, so its `Foo.run()` receiver resolves
	 * to that binding (`bindingSpan != null`) and is excluded — even
	 * though file A declares a type `Foo`. Only file A's decl name
	 * changes; file B is left byte-for-byte untouched (no `FileChange`).
	 */
	public function testShadowingLocalValueNotRenamed(): Void {
		final a: String = 'class Foo {\n\tpublic static function create():Void {}\n}';
		final b: String = 'class C {\n\tfunction m() {\n\t\tvar Foo = makeThing();\n\t\tFoo.run();\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 7, 'Widget', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		// Only the type declaration in a.hx is renamed.
		Assert.equals(1, changes.length);
		Assert.equals('class Widget {\n\tpublic static function create():Void {}\n}', changeFor(changes, 'a.hx').newSource);
		// b.hx emitted no change: the local-value receiver is untouched.
		Assert.isNull(changeOrNull(changes, 'b.hx'));
	}

	/**
	 * A bare value-position `IdentExpr Foo` (a `Class<Foo>` value and a
	 * `case Foo:` pattern) is NOT a `FieldAccess` receiver, so it is left
	 * untouched — the documented residual. Only file A's decl name is
	 * renamed; file B's `var c = Foo;` and `case Foo:` survive verbatim.
	 */
	public function testBareValuePositionNotRenamed(): Void {
		final a: String = 'class Foo {\n\tpublic static function create():Void {}\n}';
		final b: String =
			'class C {\n\tfunction m(e) {\n\t\tvar c = Foo;\n\t\tvar r = switch e {\n\t\t\tcase Foo: 1;\n\t\t\tcase _: 0;\n\t\t};\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 1, 7, 'Widget', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		// Only the type declaration in a.hx is renamed.
		Assert.equals(1, changes.length);
		Assert.equals('class Widget {\n\tpublic static function create():Void {}\n}', changeFor(changes, 'a.hx').newSource);
		// b.hx emitted no change: bare `Foo` value / case-pattern untouched.
		Assert.isNull(changeOrNull(changes, 'b.hx'));
	}

	/**
	 * A sub-module type named through its module — `pkg.Boxes.Rim` — is ONE node in the type-ref
	 * tree whose name is the whole dotted path, so the plain name match never saw it and the
	 * declaration was renamed with every such reference left behind. The same file also names
	 * `ext.Other.Rim`, a same-simple-name type from a module OUTSIDE the scope: matching the FULL
	 * path is what leaves it alone, and one expected source carries both halves.
	 */
	public function testQualifiedSubModuleReferenceRenamesAcrossScope(): Void {
		final a: String = 'package pkg;\n\nclass Boxes {\n\tpublic function new() {}\n}\n\nclass Rim {\n\tpublic function new() {}\n}';
		final b: String = 'package zone;\n\nclass Z {\n\tvar near:pkg.Boxes.Rim = new pkg.Boxes.Rim();\n\tvar far:ext.Other.Rim = null;\n}';
		final expectedB: String =
			'package zone;\n\nclass Z {\n\tvar near:pkg.Boxes.Edge = new pkg.Boxes.Edge();\n\tvar far:ext.Other.Rim = null;\n}';
		final changes: Array<FileChange> = okChanges('pkg/Boxes.hx', a, 7, 7, 'Edge', [
			{ file: 'pkg/Boxes.hx', source: a },
			{ file: 'zone/Z.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'zone/Z.hx').newSource);
		Assert.equals(2, changeFor(changes, 'zone/Z.hx').count);
	}

	/**
	 * The short `Boxes.Rim` spelling is legal ONLY from a file in the module's own package —
	 * compiler-checked: an `import pkg.Boxes;` elsewhere still gives `Type not found : Boxes`,
	 * while a ROOT-package module of the same base name IS reachable that way from anywhere. So
	 * the same three characters mean a different type in the two files here, and only the
	 * same-package one may be rewritten. Without the package gate the foreign file's reference to
	 * an out-of-scope root module would be rewritten into a type that does not exist.
	 */
	public function testShortModulePathRenamesOnlyInsideTheModulesOwnPackage(): Void {
		final a: String = 'package pkg;\n\nclass Boxes {\n\tpublic function new() {}\n}\n\nclass Rim {\n\tpublic function new() {}\n}';
		final near: String = 'package pkg;\n\nclass Near {\n\tvar r:Boxes.Rim = new Boxes.Rim();\n}';
		final far: String = 'package zone;\n\nclass Far {\n\tvar r:Boxes.Rim = null;\n}';
		final expectedNear: String = 'package pkg;\n\nclass Near {\n\tvar r:Boxes.Edge = new Boxes.Edge();\n}';
		final changes: Array<FileChange> = okChanges('pkg/Boxes.hx', a, 7, 7, 'Edge', [
			{ file: 'pkg/Boxes.hx', source: a },
			{ file: 'pkg/Near.hx', source: near },
			{ file: 'zone/Far.hx', source: far },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedNear, changeFor(changes, 'pkg/Near.hx').newSource);
		Assert.isFalse(changes.exists(c -> c.file == 'zone/Far.hx'), 'the foreign-package short form must be left alone');
	}

	/**
	 * A module's MAIN type is named through the module path itself — `pkg.Boxes`, with no segment
	 * of its own — so the same qualified pass covers it, and the rewrite now agrees with the
	 * import segment the op has always rewritten. Both still point at a module whose FILE the op
	 * does not rename; that is the residual the advisory names.
	 */
	public function testFullyQualifiedMainTypeReferenceRenames(): Void {
		final a: String = 'package pkg;\n\nclass Boxes {\n\tpublic function new() {}\n}';
		final b: String = 'import pkg.Boxes;\n\nclass Z {\n\tvar b:pkg.Boxes = new pkg.Boxes();\n}';
		final expectedB: String = 'import pkg.Crates;\n\nclass Z {\n\tvar b:pkg.Crates = new pkg.Crates();\n}';
		final changes: Array<FileChange> = okChanges('pkg/Boxes.hx', a, 3, 7, 'Crates', [
			{ file: 'pkg/Boxes.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(3, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A static access reached through the module path — `pkg.Boxes.M`, and every
	 * `macro pkg.Mod.Ctor(…)` reification — carries the type on a `FieldAccess` CHAIN, not on the
	 * bare identifier the static-receiver arm recognised, so it was left behind. The same expression also reads `other.Boxes.M` — the SAME simple name, from a
	 * different module outside the scope: the chain is matched WHOLE, so only the first receiver
	 * moves.
	 */
	public function testQualifiedNamespaceReceiverRenames(): Void {
		final a: String = 'package pkg;\n\nclass Boxes {\n\tpublic static final M:Int = 5;\n}';
		final b: String = 'class Z {\n\tvar n:Int = pkg.Boxes.M + other.Boxes.M;\n}';
		final expectedB: String = 'class Z {\n\tvar n:Int = pkg.Crates.M + other.Boxes.M;\n}';
		final changes: Array<FileChange> = okChanges('pkg/Boxes.hx', a, 3, 7, 'Crates', [
			{ file: 'pkg/Boxes.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * The same dotted-receiver form for a SUB-MODULE type: `pkg.Boxes.Rim.K` names `Rim` through
	 * its module, one segment deeper than the main-type case, and the flattened chain must match
	 * the sub-module candidate rather than the module path.
	 */
	public function testQualifiedNamespaceReceiverRenamesSubModuleType(): Void {
		final a: String =
			'package pkg;\n\nclass Boxes {\n\tpublic function new() {}\n}\n\nclass Rim {\n\tpublic static final K:Int = 1;\n}';
		final b: String = 'class Z {\n\tvar n:Int = pkg.Boxes.Rim.K;\n}';
		final expectedB: String = 'class Z {\n\tvar n:Int = pkg.Boxes.Edge.K;\n}';
		final changes: Array<FileChange> = okChanges('pkg/Boxes.hx', a, 7, 7, 'Edge', [
			{ file: 'pkg/Boxes.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
	}

	/**
	 * Drive a successful rename and return the changes, asserting the
	 * result is `Ok`, the advisory is present, and every rewrite
	 * re-parses (the op already validates this; the test makes it
	 * explicit by re-parsing each `newSource`).
	 */
	private function okChanges(
		cursorFile: String, cursorSource: String, line: Int, col: Int, newName: String, scopeFiles: Array<{ file: String, source: String }>
	): Array<FileChange> {
		final result: CrossRenameResult = CrossRename.crossRenameType(
			cursorFile, cursorSource, line, col, newName, scopeFiles, plugin(), typeRefShape(), refShape()
		);
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

	private function assertErr(result: CrossRenameResult): Void {
		switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
			case Err(_):
				Assert.pass();
		}
	}

	private function changeFor(changes: Array<FileChange>, file: String): FileChange {
		for (c in changes) if (c.file == file) return c;
		Assert.fail('no change for file $file');
		return { file: file, newSource: '', count: 0 };
	}

	private function changeOrNull(changes: Array<FileChange>, file: String): Null<FileChange> {
		return changes.find(c -> c.file == file);
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	private static function typeRefShape(): TypeRefShape {
		return new HaxeQueryPlugin().typeRefShape();
	}

	private static function refShape(): RefShape {
		return new HaxeQueryPlugin().refShape();
	}

}
