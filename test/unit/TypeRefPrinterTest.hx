package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeRefPrinter;
import anyparse.runtime.Span;

/**
 * The shared import-aware type-reference printer: how a fixer that MATERIALISES a type path
 * spells it inside one file. Covers the three routes — already visible (import, secondary
 * `import pack.Module.SubType` form, alias, same module, same package, builtin) → short name;
 * free short name → an inserted import; otherwise the CORRECT fully-qualified form, which for
 * a sub-type is module-qualified and never the `pack.SubType` hybrid — plus the import
 * insertion position (sorted block, unsorted block, package-only, bare file).
 */
class TypeRefPrinterTest extends Test {

	// --- route 1: already visible -> short name ---

	public function testImportedMainTypePrintsShort(): Void {
		final src: String = 'package pkg;\n\nimport pkg.deep.Foo;\n\nclass C {}\n';
		Assert.equals('Foo', printer(src).print('pkg.deep.Foo').text);
	}

	public function testImportedSecondaryTypePrintsShort(): Void {
		final src: String = 'package pkg;\n\nimport pkg.deep.Mod.Sub;\n\nclass C {}\n';
		Assert.equals('Sub', printer(src).print('pkg.deep.Mod.Sub').text);
	}

	public function testCompilerHybridRepairedThroughImport(): Void {
		// The compiler prints a secondary type as `pack.SubType` — the hybrid that resolves only
		// while a matching import exists. It must resolve back to the imported short name.
		final src: String = 'package pkg;\n\nimport pkg.deep.Mod.Sub;\n\nclass C {}\n';
		Assert.equals('Sub', printer(src).print('pkg.deep.Sub').text);
	}

	public function testAliasedImportPrintsTheAlias(): Void {
		final src: String = 'package pkg;\n\nimport pkg.deep.Foo as Renamed;\n\nclass C {}\n';
		Assert.equals('Renamed', printer(src).print('pkg.deep.Foo').text);
	}

	public function testSameModuleSecondaryTypePrintsShort(): Void {
		final src: String = 'package pkg;\n\nclass Host {}\n\ntypedef Sub = Int;\n';
		Assert.equals('Sub', printer(src).print('pkg.Host.Sub').text);
	}

	public function testSamePackageMainTypePrintsShort(): Void {
		final src: String = 'package pkg;\n\nclass C {}\n';
		Assert.equals('Sibling', printer(src).print('pkg.Sibling').text);
	}

	public function testBuiltinQualifiedPrintsShort(): Void {
		Assert.equals('Map', printer('class C {}\n').print('haxe.ds.Map').text);
	}

	public function testDotlessRunIsVerbatimAndNeverImports(): Void {
		final p: TypeRefPrinter = printer('class C {}\n');
		Assert.equals('Foo', p.print('Foo').text);
		Assert.isFalse(p.hasPendingImports());
	}

	// --- route 2: free short name -> import + short name ---

	public function testFreeNameGetsImportAndShortName(): Void {
		final src: String = 'package pkg;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		Assert.equals('Widget', p.print('pkg.deep.Widget').text);
		Assert.equals('import pkg.deep.Widget;', importText(p));
	}

	public function testRepeatedPrintImportsOnce(): Void {
		final src: String = 'package pkg;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('pkg.deep.Widget');
		p.print('pkg.deep.Widget');
		Assert.equals(1, p.pendingImportEdits().length);
		Assert.equals('import pkg.deep.Widget;', importText(p));
	}

	public function testTwoDistinctImportsMergeIntoOneSortedEdit(): Void {
		// Two zero-width edits at one offset would be an unorderable overlapping pair for the
		// batching splice, so they must arrive as ONE edit.
		final src: String = 'package pkg;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('z.deep.Zeta');
		p.print('a.deep.Alpha');
		Assert.equals(1, p.pendingImportEdits().length);
		Assert.equals('package pkg;\nimport a.deep.Alpha;\nimport z.deep.Zeta;\n\nclass C {}\n', applyImports(p, src));
	}

	// --- route 3: taken short name -> correct fully-qualified form ---

	public function testImportedOtherPathStaysQualified(): Void {
		final src: String = 'package pkg;\n\nimport other.Widget;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		Assert.equals('pkg.deep.Widget', p.print('pkg.deep.Widget').text);
		Assert.isFalse(p.hasPendingImports());
	}

	public function testAliasBoundNameStaysQualified(): Void {
		// The alias BINDS `Widget` to something else — importing our `Widget` would collide.
		final src: String = 'package pkg;\n\nimport other.Thing as Widget;\n\nclass C {}\n';
		Assert.equals('pkg.deep.Widget', printer(src).print('pkg.deep.Widget').text);
	}

	public function testImportShadowsTheSamePackageRoute(): Void {
		// Haxe resolves an import ahead of the package, so a bare `Widget` here means
		// `other.Widget`. The same-package route must NOT claim the short name.
		final src: String = 'package pkg;\n\nimport other.Widget;\n\nclass C {}\n';
		Assert.equals('pkg.Widget', printer(src).print('pkg.Widget').text);
	}

	public function testAliasShadowsTheSamePackageRoute(): Void {
		final src: String = 'package pkg;\n\nimport other.Thing as Widget;\n\nclass C {}\n';
		Assert.equals('pkg.Widget', printer(src).print('pkg.Widget').text);
	}

	public function testModuleTypeShadowsTheSamePackageRoute(): Void {
		// A module-local `Widget` outranks everything — the same-package `pkg.Widget` is a
		// different type and must stay qualified.
		final src: String = 'package pkg;\n\nclass Host {}\n\nclass Widget {}\n';
		Assert.equals('pkg.Widget', printer(src).print('pkg.Widget').text);
	}

	public function testAliasedCommentedImportDecodesItsRealTarget(): Void {
		// A comment between `import` and the path must not be read AS the path — decoding
		// `pkg.deep.Foo` there would print the alias for a type it does not name.
		final src: String = 'package pkg;\n\nimport /* pkg.deep.Foo */ other.Bar as Renamed;\n\nclass C {}\n';
		Assert.equals('pkg.deep.Foo', printer(src).print('pkg.deep.Foo').text);
	}

	public function testSecondSameNamedPathDoesNotGetASecondImport(): Void {
		// Haxe accepts two imports of one simple name and silently lets the LAST win, so the
		// first short form would bind the wrong type. The second path must stay qualified.
		final src: String = 'package pkg;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		Assert.equals('Widget', p.print('a.deep.Widget').text);
		Assert.equals('b.deep.Widget', p.print('b.deep.Widget').text);
		Assert.equals(1, p.pendingImportEdits().length);
		Assert.equals('import a.deep.Widget;', importText(p));
	}

	public function testBuiltinNameOnAnotherPathIsNeverTakenForTheBuiltin(): Void {
		// `haxe.macro.Type` is NOT the top-level `Type`. Matching the builtin by NAME would print
		// a bare `Type` with no import, silently rebinding it — and for `foo.Any` that wrong
		// annotation even typechecks, so no verification pass would catch it. The short form is
		// only legal here because an import comes with it.
		final p: TypeRefPrinter = printer('class C {}\n');
		Assert.equals('Type', p.print('haxe.macro.Type').text);
		Assert.equals('import haxe.macro.Type;', importText(p));
	}

	public function testBuiltinNameOnAnotherPathStaysQualifiedWithNoImportRoute(): Void {
		// Same input where no import can be added: the ONLY sound answer is the full path.
		final p: TypeRefPrinter = TypeRefPrinter.importsOnly([]);
		Assert.equals('haxe.macro.Type', p.print('haxe.macro.Type').text);
		Assert.equals('foo.Any', p.print('foo.Any').text);
		Assert.equals(0, p.pendingImportEdits().length);
	}

	public function testRealMainTypeIsNotRepairedIntoASubType(): Void {
		// `pkg.Entity` is a real main type that merely LOOKS like a hybrid of the imported
		// `pkg.Mod.Entity`. Repairing it would rewrite one type into another.
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/Entity.hx', source: 'package pkg;\n\nclass Entity {}\n' },
			{ file: 'pkg/Mod.hx', source: 'package pkg;\n\nclass Mod {}\n\ntypedef Entity = Int;\n' }
		]);
		final src: String = 'package app;\n\nimport pkg.Mod.Entity;\n\nclass C {}\n';
		Assert.equals('pkg.Entity', printerWith(src, index).print('pkg.Entity').text);
	}

	public function testSamePackageSubModuleTypeStillGetsAnImport(): Void {
		// A sub-module type of one's OWN package is declared in that package yet still needs an
		// import — its own declaration must not veto route 2.
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/Mod.hx', source: 'package pkg;\n\nclass Mod {}\n\ntypedef Sub = Int;\n' }
		]);
		final src: String = 'package pkg;\n\nclass C {}\n';
		final p: TypeRefPrinter = printerWith(src, index);
		Assert.equals('Sub', p.print('pkg.Mod.Sub').text);
		Assert.equals('import pkg.Mod.Sub;', importText(p));
	}

	public function testAppendLandsBeforeTheUsingGroup(): Void {
		final src: String = 'package pkg;\n\nimport a.Alpha;\nusing StringTools;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('z.Zeta');
		Assert.equals('package pkg;\n\nimport a.Alpha;\nimport z.Zeta;\nusing StringTools;\n\nclass C {}\n', applyImports(p, src));
	}

	public function testWordBoundaryOccurrenceStaysQualified(): Void {
		// `Widget` occurs with no import binding it — it resolves elsewhere (a wildcard import,
		// a type parameter, a qualified use), so a fresh import would retarget it.
		final src: String = 'package pkg;\n\nclass C {\n\n\tprivate var w:Widget;\n\n}\n';
		Assert.equals('pkg.deep.Widget', printer(src).print('pkg.deep.Widget').text);
	}

	public function testModuleLocalTypeNameStaysQualified(): Void {
		final src: String = 'package pkg;\n\nclass Widget {}\n';
		Assert.equals('other.Widget', printer(src).print('other.Widget').text);
	}

	public function testCollidingSecondaryTypeIsModuleQualifiedNotHybrid(): Void {
		// The trap: with `import other.Entity;` present, a bare `pkg.Entity` for the OTHER
		// (sub-module) `Entity` compiles only by accident. The index repairs it to the
		// module-qualified path, which resolves unconditionally.
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/Mod.hx', source: 'package pkg;\n\nclass Mod {}\n\ntypedef Entity = Int;\n' }
		]);
		final src: String = 'package app;\n\nimport other.Entity;\n\nclass C {}\n';
		final p: TypeRefPrinter = printerWith(src, index);
		Assert.equals('pkg.Mod.Entity', p.print('pkg.Entity').text);
		Assert.isFalse(p.hasPendingImports());
	}

	public function testSamePackageTypeVetoesBuiltinShortening(): Void {
		// A same-package `pkg.Map` shadows the bare `Map` inside `package pkg;` — the builtin
		// short-circuit must not fire, and no import can rescue it.
		final index: SymbolIndex = indexOf([{ file: 'pkg/Map.hx', source: 'package pkg;\n\nclass Map {}\n' }]);
		final p: TypeRefPrinter = printerWith('package pkg;\n\nclass C {}\n', index);
		Assert.equals('haxe.ds.Map', p.print('haxe.ds.Map').text);
		Assert.isFalse(p.hasPendingImports());
	}

	public function testSameNamedTypeOutsideScopeDoesNotVetoBuiltin(): Void {
		// A `pkg.Map` is invisible from a root-package file — the bare `Map` still means the
		// builtin, and no import is needed for it.
		final index: SymbolIndex = indexOf([{ file: 'pkg/Map.hx', source: 'package pkg;\n\nclass Map {}\n' }]);
		final p: TypeRefPrinter = printerWith('class C {}\n', index);
		Assert.equals('Map', p.print('haxe.ds.Map').text);
		Assert.isFalse(p.hasPendingImports());
	}

	public function testSamePackageTypeBlocksImport(): Void {
		final index: SymbolIndex = indexOf([{ file: 'pkg/Widget.hx', source: 'package pkg;\n\nclass Widget {}\n' }]);
		final src: String = 'package pkg;\n\nclass C {}\n';
		Assert.equals('other.Widget', printerWith(src, index).print('other.Widget').text);
	}

	// --- import insertion position ---

	public function testSortedImportBlockKeepsItsSort(): Void {
		final src: String = 'package pkg;\n\nimport a.Alpha;\nimport z.Zeta;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('m.Middle');
		Assert.equals('package pkg;\n\nimport a.Alpha;\nimport m.Middle;\nimport z.Zeta;\n\nclass C {}\n', applyImports(p, src));
	}

	public function testUnsortedImportBlockAppendsAfterLast(): Void {
		final src: String = 'package pkg;\n\nimport z.Zeta;\nimport a.Alpha;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('m.Middle');
		Assert.equals('package pkg;\n\nimport z.Zeta;\nimport a.Alpha;\nimport m.Middle;\n\nclass C {}\n', applyImports(p, src));
	}

	public function testPackageOnlyFileInsertsAfterPackage(): Void {
		final src: String = 'package pkg;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('m.Middle');
		Assert.equals('package pkg;\nimport m.Middle;\n\nclass C {}\n', applyImports(p, src));
	}

	public function testBareFileInsertsAtStart(): Void {
		final src: String = 'class C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('m.Middle');
		Assert.equals('import m.Middle;\nclass C {}\n', applyImports(p, src));
	}

	// --- type EXPRESSION walk ---

	public function testPrintTypeExprRewritesComponentsOnly(): Void {
		final src: String = 'package pkg;\n\nimport pkg.deep.Foo;\n\nclass C {}\n';
		Assert.equals('Array<Foo>', printer(src).printTypeExpr('Array<pkg.deep.Foo>'));
	}

	public function testPrintTypeExprLeavesAnonFieldNamesAlone(): Void {
		final p: TypeRefPrinter = printer('class C {}\n');
		Assert.equals('{ name : String }', p.printTypeExpr('{ name : String }'));
		Assert.isFalse(p.hasPendingImports(), 'a structural field name must never trigger an import');
	}

	// --- the imports-only degenerate form ---

	public function testImportsOnlyShortensButNeverImports(): Void {
		final p: TypeRefPrinter = TypeRefPrinter.importsOnly(['Foo' => 'pkg.Foo']);
		Assert.equals('Foo', p.print('pkg.Foo').text);
		Assert.equals('other.Bar', p.print('other.Bar').text);
		Assert.equals(0, p.pendingImportEdits().length);
	}

	// --- helpers -------------------------------------------------------------------

	private function printer(source: String): TypeRefPrinter {
		return printerWith(source, null);
	}

	private function printerWith(source: String, index: Null<SymbolIndex>): TypeRefPrinter {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final root: QueryNode = plugin.parseFile(source);
		return TypeRefPrinter.forFile(source, root, plugin.importMap(source), index);
	}

	private function indexOf(files: Array<{ file: String, source: String }>): SymbolIndex {
		return SymbolIndex.build(files, new HaxeQueryPlugin());
	}

	/** The pending import statement text, trimmed of the newline the anchor carries. */
	private function importText(p: TypeRefPrinter): String {
		final edits: Array<{ span: Span, text: String }> = p.pendingImportEdits();
		return edits.length == 0 ? '' : StringTools.trim(edits[0].text);
	}

	/** `source` with the pending import edits spliced in — through the SAME batching path a fixer's edits take. */
	private function applyImports(p: TypeRefPrinter, source: String): String {
		return RefactorSupport.applyEdits(source, p.pendingImportEdits());
	}

}
