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

	/** Two runs split by a `using`, each sorted, their CONCATENATION not — the shape a whole-list reading called unordered. */
	private static inline final SPLIT_RUNS: String = 'package app;\n\nimport a.Alpha;\nimport m.Mid;\nimport z.Zeta;\n'
		+ '\nusing ext.Tools;\n\nimport b.Bee;\nimport c.Cee;\n\nclass C {}\n';

	// --- route 1: already visible -> short name ---

	public function testImportedMainTypePrintsShort(): Void {
		final src: String = 'package pkg;\n\nimport pkg.deep.Foo;\n\nclass C {}\n';
		Assert.equals('Foo', printer(src).print('pkg.deep.Foo').text);
	}

	public function testImportedSecondaryTypePrintsShort(): Void {
		final src: String = 'package pkg;\n\nimport pkg.deep.Mod.Sub;\n\nclass C {}\n';
		Assert.equals('Sub', printer(src).print('pkg.deep.Mod.Sub').text);
	}

	/**
	 * A plain `import pkg.deep.Mod;` binds every TOP-LEVEL type the module declares, not only its
	 * main one — so a secondary type of that module is already visible and must print short with
	 * NO fresh import. Route 2 firing here is what put `import fs.FileSystemInterface.FileSystemCloudAction;`
	 * into a file already carrying `import fs.FileSystemInterface;`.
	 */
	public function testModuleImportMakesItsSecondaryTypeVisible(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/deep/Mod.hx', source: 'package pkg.deep;\n\nclass Mod {}\n\ntypedef Sub = Int;\n' }
		]);
		final p: TypeRefPrinter = printerWith('package app;\n\nimport pkg.deep.Mod;\n\nclass C {}\n', index);
		Assert.equals('Sub', p.print('pkg.deep.Mod.Sub').text);
		Assert.isFalse(p.hasPendingImports());
	}

	/**
	 * With NO index the module import is still proof enough: only a MODULE may be plainly imported,
	 * so `pkg.deep.Mod.Sub` beside `import pkg.deep.Mod;` can only be that module's sub-type.
	 */
	public function testModuleImportSecondaryVisibleWithoutAnIndex(): Void {
		final p: TypeRefPrinter = printer('package app;\n\nimport pkg.deep.Mod;\n\nclass C {}\n');
		Assert.equals('Sub', p.print('pkg.deep.Mod.Sub').text);
		Assert.isFalse(p.hasPendingImports());
	}

	/** No module import, no visibility — the sub-type takes route 2 and gets its own import. */
	public function testSecondaryTypeWithoutTheModuleImportStillImports(): Void {
		final p: TypeRefPrinter = printer('package app;\n\nclass C {}\n');
		Assert.equals('Sub', p.print('pkg.deep.Mod.Sub').text);
		Assert.equals('import pkg.deep.Mod.Sub;', importText(p));
	}

	/** An ALIASED module import binds only the alias, so it brings no secondary type into scope. */
	public function testAliasedModuleImportDoesNotMakeItsSecondaryTypeVisible(): Void {
		final p: TypeRefPrinter = printer('package app;\n\nimport pkg.deep.Mod as M;\n\nclass C {}\n');
		Assert.equals('Sub', p.print('pkg.deep.Mod.Sub').text);
		Assert.equals('import pkg.deep.Mod.Sub;', importText(p));
	}

	/** The index CONTRADICTING the path — `Sub` declared by another module — refuses the module-import route. */
	public function testModuleImportRouteRefusedWhenIndexDeclaresTheNameElsewhere(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/deep/Mod.hx', source: 'package pkg.deep;\n\nclass Mod {}\n' },
			{ file: 'other/Other.hx', source: 'package other;\n\nclass Other {}\n\ntypedef Sub = Int;\n' }
		]);
		final p: TypeRefPrinter = printerWith('package app;\n\nimport pkg.deep.Mod;\n\nclass C {}\n', index);
		Assert.equals('Sub', p.print('pkg.deep.Mod.Sub').text);
		Assert.equals('import pkg.deep.Mod.Sub;', importText(p));
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
		assertImported('package pkg;\n\nclass C {}\n');
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

	// --- route 2: what a LITERAL's text is allowed to veto ---

	/**
	 * A double-quoted Haxe string NEVER interpolates, so its whole content is inert text. The
	 * pre-mask reading refused the import on the strength of an assertion message.
	 */
	public function testDoubleQuotedStringMentionDoesNotVetoTheImport(): Void {
		assertImported(withBody('"Widget should exist"'));
	}

	/** The plain-text fragments of a single-quoted string are inert too — nothing there binds. */
	public function testPlainSingleQuotedStringMentionDoesNotVetoTheImport(): Void {
		assertImported(withBody("'Widget should exist'"));
	}

	/** A regex body is pattern syntax, not Haxe — no identifier of the file's scope lives in it. */
	public function testRegexLiteralMentionDoesNotVetoTheImport(): Void {
		assertImported(withBody('~/Widget[0-9]/g'));
	}

	/**
	 * `$$` is the ESCAPED dollar, so what follows it is text, not the `$name` shorthand — the
	 * segment split has to survive one trigger to read the next fragment correctly.
	 */
	public function testEscapedDollarBeforeTheNameDoesNotVetoTheImport(): Void {
		assertImported(withBody("'cost $$Widget'"));
	}

	/**
	 * The hole of an interpolation is CODE, and a literal nested inside it is text again — so
	 * masking has to recurse through the hole rather than stop at the outer literal.
	 */
	public function testNestedLiteralInsideAnInterpolationHoleDoesNotVetoTheImport(): Void {
		assertImported(withBody("'a ${g(\"Widget\")} b'"));
	}

	/** A double-quoted literal decodes escapes but never interpolates — `\x24Widget` is text. */
	public function testEscapeSpelledDollarInADoubleQuotedStringDoesNotVetoTheImport(): Void {
		assertImported(withBody('"a \\x24Widget b"'));
	}

	/** `${ … }` in a single-quoted string IS a reference — the whole reason a literal is not masked whole. */
	public function testInterpolationHoleMentionStillVetoesTheImport(): Void {
		assertNotImported(withBody("'a ${Widget.x} b'"));
	}

	/** The `$name` shorthand is a read of `Widget` exactly as a bare identifier would be. */
	public function testInterpolationShorthandMentionStillVetoesTheImport(): Void {
		assertNotImported(withBody("'a $Widget b'"));
	}

	/**
	 * Haxe decodes escapes BEFORE it scans a single-quoted literal for interpolation, so
	 * `'\x24Widget'` is a read of `Widget`. Only the tree knows — the raw bytes spell a plain
	 * fragment — which is why the mask is taken off the projection and not off a lexer.
	 */
	public function testEscapeSpelledInterpolationStillVetoesTheImport(): Void {
		assertNotImported(withBody("'a \\x24Widget b'"));
	}

	/**
	 * A `${ … }` whose trigger was escape-spelled is a hole the rescan DISCOVERS, and it carries
	 * no parsed child expression — so nothing inside it can be recognised as text and the whole
	 * hole stays unmasked. Fail-closed by construction, and the fixture is here because the
	 * opposite is one list entry away: adding `Block` to the text segments would drop this veto
	 * with the rest of the suite still green.
	 */
	public function testDiscoveredInterpolationHoleStillVetoesTheImport(): Void {
		assertNotImported(withBody("'a \\x24{Widget.x} b'"));
	}

	// --- route 3: taken short name -> correct fully-qualified form ---

	public function testImportedOtherPathStaysQualified(): Void {
		assertNotImported('package pkg;\n\nimport other.Widget;\n\nclass C {}\n');
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
		// A comment between `import` and the path must not be read AS the path: a decoder that
		// read `pkg.deep.Foo` there would bind it to the alias and print `Renamed` for a type the
		// statement does not name. That — not the qualified form — is what this discriminates.
		// The alias claims only `Renamed`, so the simple name is genuinely free and route 2 takes
		// it; the comment's own mention is masked, since a comment binds nothing.
		final src: String = 'package pkg;\n\nimport /* pkg.deep.Foo */ other.Bar as Renamed;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		Assert.equals('Foo', p.print('pkg.deep.Foo').text);
		Assert.equals('import pkg.deep.Foo;', importText(p));
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

	public function testCaseFoldedSortedBlockKeepsItsSort(): Void {
		// The reported incident. A block an IDE sorted CASE-INSENSITIVELY is NOT ASCII-sorted:
		// `pkg.mid.events.Alpha` precedes `pkg.mid.SetBeta` only with case folded ('e' > 'S' in
		// ASCII). Reading the block as unsorted appended the fresh import LAST, past every
		// existing one, which is what put a `components.editor.*` import at the bottom of an
		// otherwise ordered block in the wild.
		final src: String =
			'package app;\n\nimport app.base.Host;\nimport pkg.mid.events.Alpha;\nimport pkg.mid.SetBeta;\nimport util.Valid;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('app.deep.Mod.Widget');
		Assert.equals(
			'package app;\n\nimport app.base.Host;\nimport app.deep.Mod.Widget;\nimport pkg.mid.events.Alpha;\nimport pkg.mid.SetBeta;\nimport util.Valid;\n\nclass C {}\n',
			applyImports(p, src)
		);
	}

	public function testSecondaryTypeImportSortsByItsWholePath(): Void {
		// A `Module.SubType` import sorts as the WHOLE string it is written as — `a.Mod.Sub`
		// belongs between `a.Mid` and `a.Other`. The module is deliberately NOT imported here:
		// a file that already imports `a.Mod` never gets a fresh `a.Mod.Sub` at all, since the
		// module import already binds the name (`moduleImportBinds`).
		final src: String = 'package app;\n\nimport a.Mid;\nimport a.Other;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('a.Mod.Sub');
		Assert.equals('package app;\n\nimport a.Mid;\nimport a.Mod.Sub;\nimport a.Other;\n\nclass C {}\n', applyImports(p, src));
	}

	public function testBlankSeparatedGroupsKeepTheirSort(): Void {
		// Blank lines split an import block into visual groups. The order across the whole block
		// still holds, so the insert lands in the group it sorts into and the blank lines survive.
		final src: String =
			'package app;\n\nimport app.base.Host;\nimport app.mid.events.Alpha;\nimport app.mid.SetBeta;\n\nimport z.Zeta;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('app.deep.Mod.Widget');
		Assert.equals(
			'package app;\n\nimport app.base.Host;\nimport app.deep.Mod.Widget;\nimport app.mid.events.Alpha;\nimport app.mid.SetBeta;\n\nimport z.Zeta;\n\nclass C {}\n',
			applyImports(p, src)
		);
	}

	public function testInsertBetweenTwoGroupsOpensTheLaterGroup(): Void {
		// A path sorting past every member of the first group and before the second's opens THAT
		// group: the anchor is the first later import's own start, which sits after the blank line.
		final src: String = 'package app;\n\nimport app.mid.events.Alpha;\nimport app.mid.SetBeta;\n\nimport z.Zeta;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('m.Mod.Middle');
		Assert.equals(
			'package app;\n\nimport app.mid.events.Alpha;\nimport app.mid.SetBeta;\n\nimport m.Mod.Middle;\nimport z.Zeta;\n\nclass C {}\n',
			applyImports(p, src)
		);
	}

	public function testAsciiSortedBlockIsNotResortedByCaseFolding(): Void {
		// `a.Zeta` before `a.alpha.Beta` is ASCII-sorted and case-folded UNsorted. The ASCII
		// reading must win, so the insert keeps that order rather than the folded one.
		final src: String = 'package app;\n\nimport a.Zeta;\nimport a.alpha.Beta;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('a.Mid');
		Assert.equals('package app;\n\nimport a.Mid;\nimport a.Zeta;\nimport a.alpha.Beta;\n\nclass C {}\n', applyImports(p, src));
	}

	public function testCoAnchoredImportsAreSortedUnderTheBlockOwnOrder(): Void {
		// Two fresh imports merged into ONE edit at the same anchor must be written in the order the
		// FILE carries, not a fixed codepoint one: `pkg.Widget` before `pkg.data.Model` would leave
		// the block explained by NEITHER order, and every later insert would fall back to appending.
		final src: String = 'package app;\n\nimport a.events.A;\nimport a.SetB;\nimport zz.Z;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('pkg.Widget');
		p.print('pkg.data.Model');
		Assert.equals(1, p.pendingImportEdits().length, 'both anchor at the same slot');
		Assert.equals(
			'package app;\n\nimport a.events.A;\nimport a.SetB;\nimport pkg.data.Model;\nimport pkg.Widget;\nimport zz.Z;\n\nclass C {}\n',
			applyImports(p, src)
		);
	}

	public function testOneImportBlockStillPlacesInOrder(): Void {
		// A one-import block counts as ordered, so a second import lands in a defensible slot
		// instead of being appended by definition.
		final src: String = 'package pkg;\n\nimport z.Zeta;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('a.Alpha');
		Assert.equals('package pkg;\n\nimport a.Alpha;\nimport z.Zeta;\n\nclass C {}\n', applyImports(p, src));
	}

	public function testBlockUnsortedUnderEveryOrderStillAppends(): Void {
		// The documented fallback: a block no supported order explains is appended to, never
		// resorted — the printer's insert must not rewrite import lines it did not add.
		final src: String = 'package app;\n\nimport m.Mid;\nimport z.Zeta;\nimport a.Alpha;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('b.Beta');
		Assert.equals(
			'package app;\n\nimport m.Mid;\nimport z.Zeta;\nimport a.Alpha;\nimport b.Beta;\n\nclass C {}\n', applyImports(p, src)
		);
	}

	// --- contiguous RUNS: a `using` / `#if` splits the list, and each run is placed into on its own ---

	public function testPathSortingIntoTheEarlierRunLandsThere(): Void {
		// A whole-list reading sees `z.Zeta` before `b.Bee` and calls the file unordered, so the
		// fresh import was appended past the LAST import — into the run after the `using`,
		// whichever run it actually sorts into. Each run carries its own order instead.
		final p: TypeRefPrinter = printer(SPLIT_RUNS);
		p.print('h.Host');
		Assert.equals(
			'package app;\n\nimport a.Alpha;\nimport h.Host;\nimport m.Mid;\nimport z.Zeta;\n'
			+ '\nusing ext.Tools;\n\nimport b.Bee;\nimport c.Cee;\n\nclass C {}\n',
			applyImports(p, SPLIT_RUNS)
		);
	}

	public function testInsertNeverInvertsTheRunItLandsIn(): Void {
		// The two-wave incident: appended past the last import, `a.Aaa` inverted the post-`using`
		// run, which the `import-order` rule then flagged and re-sorted. It sorts into the FIRST
		// run's head, and no run is left out of order.
		final p: TypeRefPrinter = printer(SPLIT_RUNS);
		p.print('a.Aaa');
		Assert.equals(
			'package app;\n\nimport a.Aaa;\nimport a.Alpha;\nimport m.Mid;\nimport z.Zeta;\n'
			+ '\nusing ext.Tools;\n\nimport b.Bee;\nimport c.Cee;\n\nclass C {}\n',
			applyImports(p, SPLIT_RUNS)
		);
	}

	public function testSamePrefixRunWinsOverALaterRunThatWouldAlsoTakeIt(): Void {
		// `app.core.Mid` sorts past its own group and before the next one, so a whole-list reading
		// opened that next group with it. The run its package prefix names is where it belongs.
		final src: String =
			'package app;\n\nimport app.core.Alpha;\nimport app.core.Beta;\n\nimport zz.Yankee;\nimport zz.Zulu;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('app.core.Mid');
		Assert.equals(
			'package app;\n\nimport app.core.Alpha;\nimport app.core.Beta;\nimport app.core.Mid;\n'
			+ '\nimport zz.Yankee;\nimport zz.Zulu;\n\nclass C {}\n',
			applyImports(p, src)
		);
	}

	public function testGuardedRegionIsNeverInsertedInto(): Void {
		// A `#if` region is its own run and no anchor can fall inside it: the run it ends is
		// appended to at the offset just BEFORE the `#if` line, never after it.
		final src: String = 'package app;\n\nimport a.Alpha;\n#if js\nimport js.Browser;\n#end\nimport z.Zeta;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('a.Zulu');
		Assert.equals(
			'package app;\n\nimport a.Alpha;\nimport a.Zulu;\n#if js\nimport js.Browser;\n#end\nimport z.Zeta;\n\nclass C {}\n',
			applyImports(p, src)
		);
	}

	public function testTiedRunsGrowTheEARLIESTOne(): Void {
		// Both runs are ordered, share nothing with `x.Xray`, and would both merely APPEND it — the
		// rank the other three criteria leave undecided. Growing the file's FAR end is exactly the
		// last-run-blind append the run model exists to stop, so the earliest run wins.
		final src: String =
			'package app;\n\nimport a.Alpha;\nimport b.Beta;\n\nusing ext.Tools;\n\nimport c.Cee;\nimport d.Dee;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('x.Xray');
		Assert.equals(
			'package app;\n\nimport a.Alpha;\nimport b.Beta;\nimport x.Xray;\n'
			+ '\nusing ext.Tools;\n\nimport c.Cee;\nimport d.Dee;\n\nclass C {}\n',
			applyImports(p, src)
		);
	}

	public function testAnOrderedRunOutranksACloserUnorderedOne(): Void {
		// Rank 1 beats rank 2: the first run SHARES `b.Bravo`'s package but no order explains it, so
		// appending there would say nothing about where the line belongs; the lone import past the
		// `using` is ordered (`orderOf` calls a one-import run ordered) and takes it in order. Note
		// what that is not: joining a run the file already had, never opening one past the `using`.
		final src: String = 'package app;\n\nimport b.Zulu;\nimport b.Alpha;\n\nusing ext.Tools;\n\nimport q.Quebec;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		p.print('b.Bravo');
		Assert.equals(
			'package app;\n\nimport b.Zulu;\nimport b.Alpha;\n\nusing ext.Tools;\n\nimport b.Bravo;\nimport q.Quebec;\n\nclass C {}\n',
			applyImports(p, src)
		);
	}

	public function testSecondInsertIntoAFreshlyPlacedRunIsStable(): Void {
		// Idempotence across waves: the file produced by one insert must place the NEXT one the
		// same way, or the two-wave loop reopens with different lines.
		final p: TypeRefPrinter = printer(SPLIT_RUNS);
		p.print('h.Host');
		final once: String = applyImports(p, SPLIT_RUNS);
		final second: TypeRefPrinter = printer(once);
		second.print('c.Car');
		Assert.equals(
			'package app;\n\nimport a.Alpha;\nimport h.Host;\nimport m.Mid;\nimport z.Zeta;\n'
			+ '\nusing ext.Tools;\n\nimport b.Bee;\nimport c.Car;\nimport c.Cee;\n\nclass C {}\n',
			applyImports(second, once)
		);
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

	// --- bulk imports: a name source neither the import map nor the package routes model ---

	public function testWildcardImportShadowsASameNamedType(): Void {
		// `import other.*;` binds `Foo` to `other.Foo`; a bare `Foo` here would rebind the
		// reference, and the wildcard names nothing the import map can see.
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/deep/Foo.hx', source: 'package pkg.deep;\n\nclass Foo {}\n' },
			{ file: 'other/Foo.hx', source: 'package other;\n\nclass Foo {}\n' }
		]);
		final src: String = 'package app;\n\nimport other.*;\n\nclass C {}\n';
		final p: TypeRefPrinter = printerWith(src, index);
		Assert.equals('pkg.deep.Foo', p.print('pkg.deep.Foo').text);
		Assert.isFalse(p.hasPendingImports());
	}

	public function testWildcardImportOfAnUnrelatedPackageDoesNotShadow(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/deep/Foo.hx', source: 'package pkg.deep;\n\nclass Foo {}\n' },
			{ file: 'other/Bar.hx', source: 'package other;\n\nclass Bar {}\n' }
		]);
		final src: String = 'package app;\n\nimport other.*;\n\nclass C {}\n';
		final p: TypeRefPrinter = printerWith(src, index);
		Assert.equals('Foo', p.print('pkg.deep.Foo').text);
		Assert.equals('import pkg.deep.Foo;', importText(p));
	}

	/**
	 * The `using` arm must be aimed at a route it actually overrides. A fixture printing an
	 * OUT-of-package path never reaches it: the freeness scan in `canAddImport` sees the `Foo`
	 * token inside the fixture's own `using other.Foo;` and refuses the import anyway, so the
	 * assertion passes with the whole arm deleted. The SAME-PACKAGE route is what a `using`
	 * genuinely outranks, so that is what these two fixtures print.
	 */
	public function testUsingShadowsTheSamePackageRoute(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'app/Foo.hx', source: 'package app;\n\nclass Foo {}\n' },
			{ file: 'other/Foo.hx', source: 'package other;\n\nclass Foo {}\n' }
		]);
		final src: String = 'package app;\n\nusing other.Foo;\n\nclass C {}\n';
		Assert.equals('app.Foo', printerWith(src, index).print('app.Foo').text, 'using other.Foo outranks the same-package app.Foo');
	}

	public function testUsingWithNoIndexShadowsTheSamePackageRoute(): Void {
		final src: String = 'package app;\n\nusing other.Foo;\n\nclass C {}\n';
		Assert.equals('app.Foo', printer(src).print('app.Foo').text, 'the textual main-type heuristic still vetoes the bare name');
	}

	public function testUnrelatedUsingWithNoIndexDoesNotShadow(): Void {
		final src: String = 'package app;\n\nusing Lambda;\n\nclass C {}\n';
		Assert.equals('Foo', printer(src).print('app.Foo').text, 'using Lambda binds no Foo');
	}

	public function testWildcardImportWithNoIndexShadowsUnconditionally(): Void {
		// Nothing can enumerate what `other.*` brings in without an index, so the short name is
		// refused rather than guessed — the conservative direction for every caller.
		final src: String = 'package app;\n\nimport other.*;\n\nclass C {}\n';
		final p: TypeRefPrinter = printer(src);
		Assert.equals('pkg.deep.Foo', p.print('pkg.deep.Foo').text);
		Assert.isFalse(p.hasPendingImports());
	}

	public function testPackageWildcardBindsMainTypesOnly(): Void {
		// `import other.*;` binds the MAIN type of each module in `other` and nothing else — a
		// SECONDARY `other.Mod.Foo` stays unreachable, so it cannot shadow the bare name.
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/deep/Foo.hx', source: 'package pkg.deep;\n\nclass Foo {}\n' },
			{ file: 'other/Mod.hx', source: 'package other;\n\nclass Mod {}\n\ntypedef Foo = Int;\n' }
		]);
		final src: String = 'package app;\n\nimport other.*;\n\nclass C {}\n';
		final p: TypeRefPrinter = printerWith(src, index);
		Assert.equals('Foo', p.print('pkg.deep.Foo').text, 'a secondary type is not bound by a package wildcard');
		Assert.equals('import pkg.deep.Foo;', importText(p));
	}

	public function testGuardedWildcardImportStillShadows(): Void {
		// A `#if`-guarded bulk import is nested under a `Conditional`, not left at the top level.
		// Missing it is the FALSE-NEGATIVE direction: the short name would bind another type in
		// the build where the guard holds.
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/deep/Foo.hx', source: 'package pkg.deep;\n\nclass Foo {}\n' },
			{ file: 'other/Foo.hx', source: 'package other;\n\nclass Foo {}\n' }
		]);
		final src: String = 'package app;\n\n#if js\nimport other.*;\n#end\n\nclass C {}\n';
		final p: TypeRefPrinter = printerWith(src, index);
		Assert.equals('pkg.deep.Foo', p.print('pkg.deep.Foo').text, 'a guarded wildcard binds under its guard');
		Assert.isFalse(p.hasPendingImports());
	}

	// --- bulk imports rank BELOW an explicit import and a module-local type ---

	public function testExplicitImportOutranksAWildcard(): Void {
		// Verified against the compiler: with both `import q.*;` and `import p.Foo;` in scope, a
		// bare `Foo` is `p.Foo`. Vetoing the short name here would refuse what Haxe resolves.
		final index: SymbolIndex = indexOf([
			{ file: 'p/Foo.hx', source: 'package p;\n\nclass Foo {}\n' },
			{ file: 'q/Foo.hx', source: 'package q;\n\nclass Foo {}\n' }
		]);
		final src: String = 'package app;\n\nimport q.*;\nimport p.Foo;\n\nclass C {}\n';
		Assert.equals('Foo', printerWith(src, index).print('p.Foo').text, 'the explicit import wins');
	}

	public function testExplicitImportOutranksAUsing(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'p/Foo.hx', source: 'package p;\n\nclass Foo {}\n' },
			{ file: 'q/Foo.hx', source: 'package q;\n\nclass Foo {}\n' }
		]);
		final src: String = 'package app;\n\nimport p.Foo;\nusing q.Foo;\n\nclass C {}\n';
		Assert.equals('Foo', printerWith(src, index).print('p.Foo').text, 'the explicit import wins');
	}

	public function testModuleLocalTypeOutranksAWildcard(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'q/Foo.hx', source: 'package q;\n\nclass Foo {}\n' },
			{ file: 'app/Main.hx', source: 'package app;\n\nclass Main {}\n\ntypedef Foo = Int;\n' }
		]);
		final src: String = 'package app;\n\nimport q.*;\n\nclass Main {}\n\ntypedef Foo = Int;\n';
		Assert.equals('Foo', printerWith(src, index).print('app.Main.Foo').text, 'the module-local type wins');
	}

	// --- resolvePath: which DECLARATION a written reference names ---

	public function testResolvePathAnswersTheSamePathForBothSpellings(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/deep/Mod.hx', source: 'package pkg.deep;\n\nclass Mod {}\n\ntypedef Sub = Int;\n' }
		]);
		final p: TypeRefPrinter = printerWith('package app;\n\nclass C {}\n', index);
		Assert.equals('pkg.deep.Mod.Sub', p.resolvePath('pkg.deep.Mod.Sub'));
		Assert.equals('pkg.deep.Mod.Sub', p.resolvePath('pkg.deep.Sub'), 'the hybrid canonicalises onto the same declaration');
	}

	public function testResolvePathIsNullWithoutAnIndex(): Void {
		Assert.isNull(printer('package app;\n\nclass C {}\n').resolvePath('pkg.deep.Foo'));
	}

	public function testResolvePathIsNullForADotlessName(): Void {
		final index: SymbolIndex = indexOf([{ file: 'pkg/deep/Foo.hx', source: 'package pkg.deep;\n\nclass Foo {}\n' }]);
		Assert.isNull(printerWith('package app;\n\nimport pkg.deep.Foo;\n\nclass C {}\n', index).resolvePath('Foo'));
	}

	public function testResolvePathIsNullForAnUndeclaredPath(): Void {
		final index: SymbolIndex = indexOf([{ file: 'pkg/deep/Foo.hx', source: 'package pkg.deep;\n\nclass Foo {}\n' }]);
		Assert.isNull(printerWith('package app;\n\nclass C {}\n', index).resolvePath('pkg.deep.Missing'));
	}

	// --- helpers -------------------------------------------------------------------

	private function printer(source: String): TypeRefPrinter {
		return printerWith(source, null);
	}

	/** A one-class file whose only mention of `Widget` outside the printed path is the literal `body`. */
	private function withBody(body: String): String {
		return 'package pkg;\n\nclass C {\n\n\tfunction f() {\n\t\tfinal s = $body;\n\t}\n\n}\n';
	}

	/** `pkg.deep.Widget` printed into `src` takes route 2: the short name plus a fresh import. */
	private function assertImported(src: String): Void {
		final p: TypeRefPrinter = printer(src);
		Assert.equals('Widget', p.print('pkg.deep.Widget').text);
		Assert.equals('import pkg.deep.Widget;', importText(p));
	}

	/** `pkg.deep.Widget` printed into `src` falls to route 3: the name is taken, so no import is promised. */
	private function assertNotImported(src: String): Void {
		final p: TypeRefPrinter = printer(src);
		Assert.equals('pkg.deep.Widget', p.print('pkg.deep.Widget').text);
		Assert.isFalse(p.hasPendingImports());
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
