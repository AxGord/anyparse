package unit.query;

import anyparse.query.CachingGrammarPlugin;
import anyparse.query.ImportBindings;
import anyparse.query.IndexScope;
import anyparse.query.StdResolver;
import anyparse.query.StdTypes;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeNameBinding;
import haxe.Exception;
import unit.CheckFixture;
import unit.QueryTestHelpers;

/**
 * The ONE reading of a simple type name (`TypeNameBinding`, which `TypeRefIndex.resolveTypeRefAll` answers a simple
 * reference through). Every precedence a fixture asserts was compiled first on Haxe 4.3.7, in type position — the
 * probe programs are recorded with the `docs/decisions.md` entry: the module's own types; the explicit imports, the
 * LAST winning; the ambient chain; `StdTypes`; the package wildcards, last first, main types only; the package and
 * its parents, then the toplevel, main types only, a private one never.
 */
@:nullSafety(Strict)
class TypeNameBindingTest extends Test {

	@:pin('control')
	@:killer('M-BINDING-OWN-TIER-CUT')
	public function testTheModulesOwnTypeOutranksAnImport(): Void {
		final index: SymbolIndex = indexOf([
			'a/X.hx' => 'package a;\n\nclass X {}\n',
			'Main.hx' => 'import a.X;\n\nclass Main {}\n\nclass X {}\n'
		]);
		Assert.equals('Main.hx#X', tierText(index, 'X', 'Main.hx'), 'the compiler picks the module own `X` over `import a.X`');
		Assert.equals('Main.hx', pinned(index, 'X', 'Main.hx'), 'the type reference layer answers the same declaration');
	}

	@:pin('control')
	@:killer('M-BINDING-FIRST-STATEMENT-WINS')
	public function testTheLastExplicitImportWins(): Void {
		final index: SymbolIndex = indexOf([
			'a/X.hx' => 'package a;\n\nclass X {}\n',
			'b/X.hx' => 'package b;\n\nclass X {}\n',
			'a/Mod.hx' => 'package a;\n\nclass Mod {}\n\nclass Y {}\n',
			'b/Y.hx' => 'package b;\n\nclass Y {}\n',
			'One.hx' => 'import a.X;\nimport b.X;\n\nclass One {}\n',
			'Two.hx' => 'import b.X;\nimport a.X;\n\nclass Two {}\n',
			'Three.hx' => 'import b.Y;\nimport a.Mod;\n\nclass Three {}\n'
		]);
		Assert.equals('b/X.hx#X', tierText(index, 'X', 'One.hx'), 'the later `import b.X` wins');
		Assert.equals('a/X.hx#X', tierText(index, 'X', 'Two.hx'), 'in the other order the later `import a.X` wins');
		Assert.equals(
			'a/Mod.hx#Y', tierText(index, 'Y', 'Three.hx'), 'a later module import binds its sub-type over an earlier type import'
		);
		Assert.equals('b/X.hx', pinned(index, 'X', 'One.hx'), 'the type reference layer pins the same declaration');
	}

	@:pin('control')
	@:killer('M-BINDING-PRIVATE-VISIBLE')
	public function testAPrivateTypeIsNeverImportedOrSeenFromItsPackage(): Void {
		final index: SymbolIndex = indexOf([
			'a/Mod.hx' => 'package a;\n\nclass Mod {}\n\nprivate class X {}\n',
			'b/X.hx' => 'package b;\n\nclass X {}\n',
			'Main.hx' => 'import b.X;\nimport a.Mod;\n\nclass Main {}\n',
			'p/Y.hx' => 'package p;\n\nprivate class Y {}\n',
			'p/Main.hx' => 'package p;\n\nclass Main {}\n'
		]);
		Assert.equals('b/X.hx#X', tierText(index, 'X', 'Main.hx'), 'a module import does not bring its private sub-type in');
		Assert.equals('Free', tierText(index, 'Y', 'p/Main.hx'), 'a private main type is invisible to the rest of its package');
	}

	@:pin('control')
	@:killer('M-BINDING-FIRST-STATEMENT-WINS')
	public function testWildcardsAreAskedLastFirst(): Void {
		final index: SymbolIndex = indexOf([
			'a/X.hx' => 'package a;\n\nclass X {}\n',
			'b/X.hx' => 'package b;\n\nclass X {}\n',
			'Main.hx' => 'import a.*;\nimport b.*;\n\nclass Main {}\n'
		]);
		Assert.equals('b/X.hx#X', tierText(index, 'X', 'Main.hx'), 'the later wildcard is asked first and binds');
		Assert.equals('b/X.hx', pinned(index, 'X', 'Main.hx'), 'so the reference is not ambiguous');
	}

	@:pin('control')
	@:killer('M-BINDING-SUBTYPES-VISIBLE')
	public function testAWildcardBindsMainTypesOnly(): Void {
		final index: SymbolIndex = indexOf([
			'a/Mod.hx' => 'package a;\n\nclass Mod {}\n\nclass X {}\n',
			'p/X.hx' => 'package p;\n\nclass X {}\n',
			'p/Main.hx' => 'package p;\n\nimport a.*;\n\nclass Main {}\n'
		]);
		Assert.equals('p/X.hx#X', tierText(index, 'X', 'p/Main.hx'), '`import a.*` does not bring the sub-type `a.Mod.X` in');
		Assert.equals('p/X.hx', pinned(index, 'X', 'p/Main.hx'), 'the same-package class is the one answer');
	}

	@:pin('control')
	@:killer('M-BINDING-STDTYPES-CUT')
	public function testStdTypesOutrankThePackage(): Void {
		final index: SymbolIndex = indexOf([
			'p/Iterable.hx' => 'package p;\n\nclass Iterable {}\n',
			'p/Main.hx' => 'package p;\n\nclass Main {}\n'
		]);
		Assert.equals('Free', tierText(index, 'Iterable', 'p/Main.hx'), 'the compiler binds `StdTypes.Iterable`, a built-in here');
		Assert.equals('unresolved', pinned(index, 'Iterable', 'p/Main.hx'), 'no indexed declaration is what the name means');
	}

	@:pin('control')
	@:killer('M-BINDING-ROOT-SUBTYPES')
	public function testASubTypeIsInvisibleOutsideItsModule(): Void {
		final index: SymbolIndex = indexOf([
			'Foo.hx' => 'class Foo {}\n\nclass X {}\n',
			'p/Mod.hx' => 'package p;\n\nclass Mod {}\n\nclass Y {}\n',
			'p/Main.hx' => 'package p;\n\nclass Main {}\n'
		]);
		Assert.equals('Free', tierText(index, 'X', 'p/Main.hx'), 'a root module sub-type is not a toplevel type');
		Assert.equals('Free', tierText(index, 'Y', 'p/Main.hx'), 'a sibling module sub-type is not a package type');
	}

	@:pin('control')
	@:killer('M-BINDING-PACKAGE-TIER-CUT')
	public function testAParentPackageMainTypeBinds(): Void {
		final index: SymbolIndex = indexOf([
			'p/X.hx' => 'package p;\n\nclass X {}\n',
			'X.hx' => 'class X {}\n',
			'p/q/Main.hx' => 'package p.q;\n\nclass Main {}\n'
		]);
		Assert.equals('p/X.hx#X', tierText(index, 'X', 'p/q/Main.hx'), 'the parent package outranks the toplevel');
		Assert.equals('p/X.hx', pinned(index, 'X', 'p/q/Main.hx'), 'the type reference layer reaches the parent package too');
	}

	@:pin('control')
	@:killer('M-BINDING-FIELD-IMPORT-UNKNOWN')
	public function testAStaticFieldImportBindsNoType(): Void {
		final index: SymbolIndex = indexOf([
			'p/X.hx' => 'package p;\n\nclass X {}\n',
			'p/Main.hx' => 'package p;\n\nimport ext.Mod.helper;\nimport ext.Mod.Inner.LIMIT;\nimport ext.Other.Sub;\n\nclass Main {}\n'
		]);
		Assert.equals('p/X.hx#X', tierText(index, 'X', 'p/Main.hx'), 'a field import, and a sub-type import of another name, bind no `X`');
	}

	@:pin('control')
	@:killer('M-BINDING-UNINDEXED-MODULE-FREE')
	public function testAnUnreadableModuleImportIsUnknown(): Void {
		final index: SymbolIndex = indexOf([
			'p/X.hx' => 'package p;\n\nclass X {}\n',
			'p/Main.hx' => 'package p;\n\nimport ext.Mod;\n\nclass Main {}\n'
		]);
		Assert.equals('Unknown', tierText(index, 'X', 'p/Main.hx'), 'a module nothing can read may declare `X` as a sub-type');
		Assert.equals('unresolved', pinned(index, 'X', 'p/Main.hx'), 'so the same-package class is not pinned');
	}

	@:pin('control')
	@:killer('M-BINDING-OUTSIDE-UNREAD')
	public function testAStdModuleIsReadByTheStdListing(): Void {
		if (StdResolver.stdDir() == null) {
			Assert.pass('no std discovered');
			return;
		}
		final index: SymbolIndex = indexOf([
			'p/X.hx' => 'package p;\n\nclass X {}\n',
			'p/Main.hx' => 'package p;\n\nimport haxe.ds.StringMap;\n\nclass Main {}\n'
		]);
		Assert.equals('p/X.hx#X', tierText(index, 'X', 'p/Main.hx'), 'the std `haxe.ds.StringMap` declares no `X`');
		Assert.equals('Free', tierText(index, 'StringMap', 'p/Main.hx'), 'and binds its own name outside the index');
	}

	@:pin('control')
	@:killer('M-BINDING-STD-WILDCARD-BLIND')
	public function testAStdWildcardWithoutTheModuleBindsNothing(): Void {
		if (StdResolver.stdDir() == null) {
			Assert.pass('no std discovered');
			return;
		}
		final index: SymbolIndex = indexOf([
			'p/X.hx' => 'package p;\n\nclass X {}\n',
			'p/Main.hx' => 'package p;\n\nimport haxe.ds.*;\n\nclass Main {}\n'
		]);
		Assert.equals('p/X.hx#X', tierText(index, 'X', 'p/Main.hx'), 'the std package `haxe.ds` holds no module `X`');
	}

	@:pin('control')
	@:killer('M-SCOPE-MODULE-TYPES-NONE')
	public function testALibraryModuleIsReadFromTheResolutionScope(): Void {
		final project: Array<{ file: String, source: String }> = [
			{ file: 'p/X.hx', source: 'package p;\n\nclass X {}\n' },
			{ file: 'p/Main.hx', source: 'package p;\n\nimport lib.Thing;\n\nclass Main {}\n' },
			{ file: 'p/Other.hx', source: 'package p;\n\nimport lib.Pair;\n\nclass Other {}\n' }
		];
		final library: Array<{ file: String, source: String }> = [
			{ file: 'lib/Thing.hx', source: 'package lib;\n\nclass Thing {}\n' },
			{ file: 'lib/Pair.hx', source: 'package lib;\n\nclass Pair {}\n\nclass X {}\n' }
		];
		final plugin: CachingGrammarPlugin = QueryTestHelpers.projectPlugin(project, library);
		final index: SymbolIndex = IndexScope.report(project, plugin);
		Assert.equals('p/X.hx#X', tierText(index, 'X', 'p/Main.hx'), 'the report index reads `lib.Thing` from the scope: no `X` there');
		Assert.equals('Free', tierText(index, 'X', 'p/Other.hx'), '`lib.Pair` declares an `X`, which outranks the package one');
	}

	@:pin('control')
	@:killer('M-SCOPE-ROOT-MODULE-ANYWHERE')
	public function testARootModuleIsNotAFileOfItsNameInAnotherPackage(): Void {
		// `import Thing;` names the ROOT module `Thing`; the scope holds only `lib/Thing.hx`, the module `lib.Thing`, which
		// does declare an `X` — but it is not the module imported, so what `Thing` brings in is unknown.
		final project: Array<{ file: String, source: String }> = [
			{ file: 'p/X.hx', source: 'package p;\n\nclass X {}\n' },
			{ file: 'p/Main.hx', source: 'package p;\n\nimport Thing;\n\nclass Main {}\n' }
		];
		final library: Array<{ file: String, source: String }> = [
			{ file: 'lib/Thing.hx', source: 'package lib;\n\nclass Thing {}\n\nclass X {}\n' }
		];
		final index: SymbolIndex = IndexScope.report(project, QueryTestHelpers.projectPlugin(project, library));
		Assert.equals('Unknown', tierText(index, 'X', 'p/Main.hx'), 'no root module `Thing` is in the scope');
	}

	@:pin('control')
	@:killer('M-SKIM-NEVER')
	public function testALibraryModuleWhoseBodyDoesNotParseStillDeclaresItsTypes(): Void {
		// The scope's module is read declarations-only: a body the grammar cannot read is never read, so the sub-type `X`
		// it declares outranks the package's own, as the compiler has it.
		final project: Array<{ file: String, source: String }> = [
			{ file: 'p/X.hx', source: 'package p;\n\nclass X {}\n' },
			{ file: 'p/Main.hx', source: 'package p;\n\nimport lib.Pair;\n\nclass Main {}\n' }
		];
		final library: Array<{ file: String, source: String }> = [
			{ file: 'lib/Pair.hx', source: 'package lib;\n\nclass Pair {\n\tfunction f() {\n\t\treturn 1 +;\n\t}\n}\n\nclass X {}\n' }
		];
		final index: SymbolIndex = IndexScope.report(project, QueryTestHelpers.projectPlugin(project, library));
		Assert.equals('Free', tierText(index, 'X', 'p/Main.hx'), '`lib.Pair` declares an `X` past a body nothing reads');
	}

	@:pin('control')
	@:killer('M-SCOPE-UNPARSED-UNSPELLED')
	public function testALibraryModuleThatDoesNotParseDeclaresNoTypeItNeverSpells(): Void {
		final project: Array<{ file: String, source: String }> = [
			{ file: 'p/X.hx', source: 'package p;\n\nclass X {}\n' },
			{ file: 'p/Main.hx', source: 'package p;\n\nimport lib.Pair;\nimport lib.Odd;\n\nclass Main {}\n' }
		];
		final library: Array<{ file: String, source: String }> = [
			{ file: 'lib/Pair.hx', source: 'package lib;\n\nclass Pair {\n\tvar ;\n}\n' },
			{ file: 'lib/Odd.hx', source: 'package lib;\n\nclass Odd {\n\tvar ;\n}\n' }
		];
		final index: SymbolIndex = IndexScope.report(project, QueryTestHelpers.projectPlugin(project, library));
		Assert.equals('p/X.hx#X', tierText(index, 'X', 'p/Main.hx'), 'neither unparsed module spells `X`, so neither declares it');
	}

	@:pin('control')
	@:killer('M-BINDING-GUARDED-OTHER-BUILD')
	public function testAGuardedImportBindsWhereTheOtherBuildProvablyBindsNothing(): Void {
		// The scope READS the toplevel module `T` and finds no type `T` in it, so a build without the import binds nothing.
		final project: Array<{ file: String, source: String }> = [
			{ file: 'Main.hx', source: '#if useA\nimport a.T;\n#end\n\nclass Main {\n\tvar t:T;\n}\n' }
		];
		final library: Array<{ file: String, source: String }> = [
			{ file: 'a/T.hx', source: 'package a;\n\nclass T {}\n' },
			{ file: 'T.hx', source: 'class Unrelated {}\n' }
		];
		final index: SymbolIndex = IndexScope.resolution(project, QueryTestHelpers.projectPlugin(project, library));
		Assert.equals('a/T.hx#T', tierAt(index, 'T', 'Main.hx', 'var t:T'), 'the other build binds no `T`, so it compiles no use of it');
	}

	@:pin('control')
	@:killer('M-BINDING-COGUARD-IGNORED')
	public function testAUseInsideTheGuardedImportsBranchBindsIt(): Void {
		// Compiled on 4.3.7 (b2-scratch/hx/g2): the build without the import has no `class M extends T` at all.
		final index: SymbolIndex = indexOf([
			'a/T.hx' => 'package a;\n\nclass T {}\n',
			'b/Other.hx' => 'package b;\n\nclass Other {}\n',
			'M.hx' => '#if !useB\nimport a.T;\n\nclass M extends T {}\n#else\ntypedef M = b.Other;\n#end\n'
		]);
		Assert.equals('a/T.hx#T', tierAt(index, 'T', 'M.hx', 'extends T'), 'the use sits in the import\'s own branch');
		Assert.equals('Unknown', tierText(index, 'T', 'M.hx'), 'with no use site, the other build\'s toplevel `T` is unread');
	}

	@:pin('control')
	@:killer('M-BINDING-STRICT-UNREAD-PASS')
	public function testAUseOutsideTheGuardedRegionIsUnknown(): Void {
		// A build without `useA` compiles `var t:T` too, and what `T` names there is a toplevel module nothing here reads.
		final index: SymbolIndex = indexOf([
			'a/T.hx' => 'package a;\n\nclass T {}\n',
			'Main.hx' => '#if useA\nimport a.T;\n#end\n\nclass Main {\n\tvar t:T;\n}\n'
		]);
		Assert.equals('Unknown', tierAt(index, 'T', 'Main.hx', 'var t:T'), 'the other build\'s binding is unread, not absent');
	}

	@:pin('control')
	@:killer('M-COND-WITHIN-BRANCH-IGNORED')
	public function testAUseInTheOtherBranchOfTheImportsRegionIsNotCoGuarded(): Void {
		// The `#else` arm is exactly the build WITHOUT the import.
		final index: SymbolIndex = indexOf([
			'a/T.hx' => 'package a;\n\nclass T {}\n',
			'Main.hx' => '#if useA\nimport a.T;\n#else\nclass Main {\n\tvar t:T;\n}\n#end\n'
		]);
		Assert.equals('Unknown', tierAt(index, 'T', 'Main.hx', 'var t:T'), 'the use is compiled only by builds without the import');
	}

	@:pin('control')
	@:killer('M-AMBIENT-GUARDED-UNION')
	public function testAGuardedImportAgainstAnotherBindingIsUnknown(): Void {
		final index: SymbolIndex = indexOf([
			'b/T.hx' => 'package b;\n\nclass T {}\n',
			'p/T.hx' => 'package p;\n\nclass T {}\n',
			'p/Main.hx' => 'package p;\n\n#if useB\nimport b.T;\n#end\n\nclass Main {}\n'
		]);
		Assert.equals('Unknown', tierText(index, 'T', 'p/Main.hx'), 'the two builds bind `b.T` and `p.T`');
	}

	/**
	 * What an `Unknown` may be when every candidate is read (`unknownCandidates`): both builds' bindings of a guarded import
	 * against another; none to offer when the other build's binding is unread, nor for a name a module declares itself.
	 */
	@:pin('control') @:killer('M-BINDING-EITHER-DROPS-REST') @:killer('M-BINDING-EITHER-DROPS-GUARDED') @:killer('M-BINDING-EITHER-OPEN-READ')
	@:killer('M-BINDING-CANDIDATES-OWN-TYPE')
	public function testAnUnknownCarriesTheCandidatesItReads(): Void {
		final index: SymbolIndex = indexOf([
			'b/T.hx' => 'package b;\n\n#if useA\nimport a.T;\n#end\n\nclass T {}\n',
			'p/T.hx' => 'package p;\n\nclass T {}\n',
			'p/Main.hx' => 'package p;\n\n#if useB\nimport b.T;\n#end\n\nclass Main {}\n',
			'a/T.hx' => 'package a;\n\nclass T {}\n',
			'Main.hx' => '#if useA\nimport a.T;\n#end\n\nclass Main {\n\tvar t:T;\n}\n'
		]);
		Assert.equals('b/T.hx#T | p/T.hx#T', candidatesText(index, 'T', 'p/Main.hx'), 'the two builds bind `b.T` and `p.T`');
		Assert.equals('open', candidatesText(index, 'T', 'Main.hx'), 'the other build binds a toplevel `T` nothing here reads');
		Assert.equals('open', candidatesText(index, 'T', 'b/T.hx'), 'the module declares `T`: it is bound, whatever it imports');
	}

	@:pin('control')
	@:killer('M-BINDING-STRICT-OUTSIDE')
	public function testAGuardedImportAgainstAStdTypeIsUnknown(): Void {
		if (StdResolver.stdDir() == null) {
			Assert.pass('no std discovered');
			return;
		}
		final index: SymbolIndex = indexOf([
			'a/Lambda.hx' => 'package a;\n\nclass Lambda {}\n',
			'Main.hx' => '#if useA\nimport a.Lambda;\n#end\n\nclass Main {}\n'
		]);
		Assert.equals('Unknown', tierText(index, 'Lambda', 'Main.hx'), 'the build without the import binds the std toplevel `Lambda`');
	}

	@:pin('guard')
	public function testTheStdTypesNamesAreTheStdsOwn(): Void {
		final types: Array<TypeDeclInfo> = StdTypes.moduleTypes(new HaxeQueryPlugin(), TypeNameBinding.STD_TYPES_MODULE) ?? [];
		if (types.length == 0) {
			Assert.pass('no std discovered');
			return;
		}
		final declared: Array<String> = [for (t in types) if (!t.isPrivate) t.name];
		final sorted: Array<String> -> String = names -> {
			final copy: Array<String> = names.copy();
			copy.sort(Reflect.compare);
			copy.join(',');
		};
		Assert.equals(sorted(declared), sorted(TypeNameBinding.STD_TYPE_NAMES), 'the fallback list is what the std `StdTypes.hx` declares');
	}

	@:pin('control')
	@:killer('M-BINDING-PRIVATE-VISIBLE')
	public function testAnImportLineListsTheNonPrivateTypesItBinds(): Void {
		final index: SymbolIndex = indexOf([
			'a/Mod.hx' => 'package a;\n\nclass Mod {}\n\nprivate class X {}\n\nclass Y {}\n',
			'a/Tools.hx' => 'package a;\n\nclass Helper {}\n'
		]);
		final bindings: ImportBindings = new ImportBindings(() -> index, new HaxeQueryPlugin());
		Assert.equals('Mod,Y', bindings.ofImport('a.Mod')?.types.join(','), 'a module import binds its non-private types');
		Assert.equals(
			'Mod', bindings.ofImport('a.*')?.wildcardTypes.join(','), 'a package wildcard binds main types: `Tools` declares none'
		);
	}

	/** The index over `files` (path => source), each path its module's. */
	private static function indexOf(files: Map<String, String>): SymbolIndex {
		final entries: Array<{ file: String, source: String }> = [for (file => source in files) { file: file, source: source }];
		entries.sort((a, b) -> Reflect.compare(a.file, b.file));
		return CheckFixture.index(entries, new HaxeQueryPlugin());
	}

	/** `name` as `from` binds it: each declaration `file#Type`, else `Unknown` or `Free`. */
	private static function tierText(index: SymbolIndex, name: String, from: String): String {
		final fi: Null<FileInfo> = index.fileInfo(from);
		if (fi == null) throw new Exception('the fixture must index $from');
		return switch index.refs.names.tierOf(name, fi) {
			case Bound(decls): [for (d in decls) '${d.file.file}#${d.type.name}'].join(' | ');
			case Unknown: 'Unknown';
			case Free: 'Free';
		};
	}

	/** The candidates an `Unknown` of `name` in `from` carries (`unknownCandidates`), each `file#Type` or its path; else `open`. */
	private static function candidatesText(index: SymbolIndex, name: String, from: String): String {
		final fi: Null<FileInfo> = index.fileInfo(from);
		if (fi == null) throw new Exception('the fixture must index $from');
		final targets: Null<Array<NameTarget>> = index.refs.names.unknownCandidates(name, fi);
		return targets == null
			? 'open'
			: [
				for (t in targets) switch t {
					case InIndex(decls): [for (d in decls) '${d.file.file}#${d.type.name}'].join(' | ');
					case OutOfIndex(path): path;
				}
			].join(' | ');
	}

	/**
	 * What a caller dispatching on every build's type asks (`bindingsOf`): the binding the order reads, then the types a
	 * `#if`-guarded statement binds on its builds and a wildcard the order cannot list may supply. A module nothing reads
	 * binds only the type its import names, never every name written beside it.
	 */
	@:pin('control')
	@:killer('M-TS-GUARDED-IMPORT') @:killer('M-TS-WILD-MAYBE') @:killer('M-BINDINGS-UNREADABLE-SUBTYPE') @:killer('M-TS-WILD-GUARDED')
	public function testBindingsListEveryBuildsType(): Void {
		final index: SymbolIndex = indexOf([
			'a/X.hx' => 'package a;\n\nclass X {}\n',
			'b/X.hx' => 'package b;\n\nclass X {}\n',
			'Guarded.hx' => '#if foo\nimport b.X;\n#end\nimport a.*;\n\nclass Guarded {}\n',
			'GuardedWild.hx' => 'import a.*;\n#if foo\nimport b.*;\n#end\n\nclass GuardedWild {}\n',
			'Wild.hx' => 'import lib.*;\n\nclass Wild {}\n',
			'Unread.hx' => 'import lib.Mod;\n\nclass Unread {}\n'
		]);
		Assert.equals('a/X.hx#X|b/X.hx#X|', targetsText(index, 'X', 'Guarded.hx'), 'the wildcard binds, the guarded import on its builds');
		Assert.equals(
			'a/X.hx#X|b/X.hx#X|', targetsText(index, 'X', 'GuardedWild.hx'), 'a guarded wildcard asked first binds on its builds'
		);
		Assert.equals('-||lib.Y', targetsText(index, 'Y', 'Wild.hx'), 'a wildcard nothing lists may supply the name');
		Assert.equals('lib.Mod||', targetsText(index, 'Mod', 'Unread.hx'), 'an unread module binds the type its import names');
		Assert.equals('-||', targetsText(index, 'Other', 'Unread.hx'), 'and no other name written beside it');
	}

	/**
	 * The package tier of `bindingsOf` reads the std core's modules beside the index's, package by package, nearest first
	 * (4.3.7: a project file in `sys.thread` sees the std `Lock`, before a project `Lock` of an enclosing package).
	 */
	@:pin('control') @:killer('M-TS-PACKAGE-PROJECT-FIRST')
	public function testThePackageTierReadsTheStdCoresModulesPackageByPackage(): Void {
		if (StdResolver.stdDir() == null) {
			Assert.pass('no std on this machine');
			return;
		}
		final index: SymbolIndex = indexOf([
			'sys/thread/W.hx' => 'package sys.thread;\n\nclass W {}\n',
			'sys/Lock.hx' => 'package sys;\n\nclass Lock {}\n',
			'sys/thread/deep/V.hx' => 'package sys.thread.deep;\n\nclass V {}\n',
			'sys/thread/deep/Lock.hx' => 'package sys.thread.deep;\n\nclass Lock {}\n'
		]);
		Assert.equals(
			'sys.thread.Lock||', targetsText(index, 'Lock', 'sys/thread/W.hx'),
			'the std module of the file\'s own package, before a project one of an enclosing package'
		);
		Assert.equals(
			'sys/thread/deep/Lock.hx#Lock||', targetsText(index, 'Lock', 'sys/thread/deep/V.hx'),
			'a project module of a nearer package first'
		);
	}

	@:pin('control') @:killer('M-BINDINGS-DECLS-AT-SUBTYPE') @:killer('M-CANONICAL-SUBTYPE')
	public function testADeclarationIsAtItsCanonicalPath(): Void {
		final index: SymbolIndex = indexOf(['p/Mod.hx' => 'package p;\n\nclass Mod {}\n\nclass Sub {}\n']);
		function at(path: String): String {
			return [
				for (d in index.refs.names.declsAt(path)) '${d.type.name}@${TypeNameBinding.canonicalPath(d)}'
			].join(' ');
		}
		Assert.equals('Mod@p.Mod', at('p.Mod'), 'a main type at its module\'s path');
		Assert.equals('Sub@p.Mod.Sub', at('p.Mod.Sub'), 'a sub-type at its module\'s path and its own name');
		Assert.equals('', at('p.Sub'), 'a sub-type is at no package path (4.3.7: `Type not found : p.Sub`)');
	}

	/** `bindingsOf`'s answer as `bound|guarded|unlisted`, each target a declaration `file#Name` or an outside path. */
	private static function targetsText(index: SymbolIndex, name: String, from: String): String {
		final fi: Null<FileInfo> = index.fileInfo(from);
		if (fi == null) throw new Exception('the fixture must index $from');
		final found: NameTargets = index.refs.names.bindingsOf(name, fi);
		function text(t: NameTarget): String {
			return switch t {
				case InIndex(decls): [for (d in decls) '${d.file.file}#${d.type.name}'].join(' | ');
				case OutOfIndex(path): path;
			};
		}
		final bound: Null<NameTarget> = found.bound;
		return [
			bound == null ? '-' : text(bound),
			found.guarded.map(text).join(' '),
			found.unlisted.map(text).join(' ')
		].join('|');
	}

	/** The file declaring the ONE declaration `TypeRefIndex` pins `name` to from `from`, or `unresolved`. */
	private static function pinned(index: SymbolIndex, name: String, from: String): String {
		final resolved: Null<ResolvedType> = index.refs.resolveStartType(name, from);
		return resolved == null ? 'unresolved' : resolved.file.file;
	}

	/** `tierText` for `name` written at the first occurrence of `marker` in `from` — the use site's `#if` branch decides. */
	private static function tierAt(index: SymbolIndex, name: String, from: String, marker: String): String {
		final fi: Null<FileInfo> = index.fileInfo(from);
		final source: Null<String> = index.sourceOf(from);
		if (fi == null || source == null) throw new Exception('the fixture must index $from');
		return switch index.refs.names.tierOf(name, fi, source.indexOf(marker)) {
			case Bound(decls): [for (d in decls) '${d.file.file}#${d.type.name}'].join(' | ');
			case Unknown: 'Unknown';
			case Free: 'Free';
		};
	}

}
