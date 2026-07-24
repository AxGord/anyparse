package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.TypeDeclInfo;

using Lambda;

/**
 * `SymbolIndex` — the pure cross-file symbol resolver that underpins a
 * planned move-symbol op. Each test builds the index from an IN-MEMORY
 * multi-file fixture (no disk) through a real `HaxeQueryPlugin` and
 * asserts the extracted package / module / imports / types and the
 * cross-file queries (`declaringFiles` / `importPathOf` /
 * `filesImportingModule`), plus the pure `moduleOf` string logic and
 * the skip-parse exclusion contract.
 */
class SymbolIndexSliceTest extends Test {

	/**
	 * `moduleOf` — the module portion of a dotted import path is the
	 * segments up to and including the first upper-case segment; any
	 * remaining segments are sub-type access and are dropped.
	 */
	public function testModuleOf(): Void {
		// Sub-type path: module `Refs`, sub-type `RefHit` dropped.
		Assert.equals('anyparse.query.Refs', SymbolIndex.moduleOf('anyparse.query.Refs.RefHit'));
		// Main-type path: no sub-type, returned as-is.
		Assert.equals('anyparse.query.Rename', SymbolIndex.moduleOf('anyparse.query.Rename'));
		// Short package + type, no sub-type.
		Assert.equals('pkg.sub.Foo', SymbolIndex.moduleOf('pkg.sub.Foo'));
		// First upper-case segment is the module even with deeper sub-access.
		Assert.equals('pkg.Outer', SymbolIndex.moduleOf('pkg.Outer.Inner.Deep'));
		// All-lower-case path (no module segment) — returned verbatim.
		Assert.equals('pkg.sub.leaf', SymbolIndex.moduleOf('pkg.sub.leaf'));
		// Single upper-case segment (root-package module).
		Assert.equals('Foo', SymbolIndex.moduleOf('Foo'));
	}

	/**
	 * `fileInfo` extracts the package, the module path, all four import
	 * kinds, and the type declarations with the correct `isMain` flag.
	 */
	public function testFileInfoExtraction(): Void {
		final source: String = 'package pkg.sub;\nimport other.Thing;\nimport other.Mod.Sub as Aliased;\nimport other.deep.*;\nusing other.Ext;\nclass A {}\ntypedef Helper = {};\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/sub/A.hx', source: source }], plugin());

		final info: Null<FileInfo> = index.fileInfo('src/pkg/sub/A.hx');
		Assert.notNull(info);
		final fi: FileInfo = (info: FileInfo);
		Assert.equals('pkg.sub', fi.pkg);
		Assert.equals('pkg.sub.A', fi.module);

		// All four import kinds, in source order.
		Assert.equals(4, fi.imports.length);
		assertImport(fi.imports[0], 'other.Thing', ImportKind.Import, null);
		assertImport(fi.imports[1], 'Aliased', ImportKind.Alias, 'Aliased');
		assertImport(fi.imports[2], 'other.deep.*', ImportKind.Wild, null);
		assertImport(fi.imports[3], 'other.Ext', ImportKind.Using, null);

		// Two type decls: `A` is the main type (== basename), `Helper` is not.
		Assert.equals(2, fi.types.length);
		final a: Null<TypeDeclInfo> = fi.types.find(t -> t.name == 'A');
		Assert.notNull(a);
		Assert.equals('ClassDecl', (a: TypeDeclInfo).kind);
		Assert.isTrue((a: TypeDeclInfo).isMain);
		final helper: Null<TypeDeclInfo> = fi.types.find(t -> t.name == 'Helper');
		Assert.notNull(helper);
		Assert.equals('TypedefDecl', (helper: TypeDeclInfo).kind);
		Assert.isFalse((helper: TypeDeclInfo).isMain);
	}

	/**
	 * `returnNominalOf` resolves a member's return-type outer nominal (`Null<T>` → `Null`,
	 * a plain return → its own nominal) and returns null for an unknown type / member.
	 */
	public function testReturnNominalOfResolves(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{
				file: 'src/H.hx',
				source: 'class H { public function findUser():Null<Foo> return null; public function plain():Foo return null; }'
			}
		], plugin());
		Assert.equals('Null', index.returnNominalOf('H', 'findUser'));
		Assert.equals('Foo', index.returnNominalOf('H', 'plain'));
		Assert.isNull(index.returnNominalOf('H', 'missing'));
		Assert.isNull(index.returnNominalOf('Missing', 'findUser'));
	}

	/**
	 * `returnNominalOf` is conservative under a simple-name collision: two classes named the
	 * same whose matching members disagree on the return nominal resolve to null (safe miss).
	 */
	public function testReturnNominalOfAmbiguous(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/A.hx', source: 'class H { public function findUser():Null<Foo> return null; }' },
			{ file: 'src/B.hx', source: 'class H { public function findUser():Foo return null; }' }
		], plugin());
		Assert.isNull(index.returnNominalOf('H', 'findUser'));
	}

	/**
	 * `returnNominalOf` resolves an INHERITED member's return nominal through the (cross-file)
	 * supertype closure when the subtype does not declare it directly.
	 */
	public function testReturnNominalOfInherited(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Base.hx', source: 'class Base { public function findUser():Null<Foo> return null; }' },
			{ file: 'src/Sub.hx', source: 'class Sub extends Base {}' }
		], plugin());
		Assert.equals('Null', index.returnNominalOf('Sub', 'findUser'));
	}

	/**
	 * A subtype's OWN member return shadows the base — the direct lookup runs before the
	 * supertype walk, so an override's non-null return is not masked by the base's `Null<T>`.
	 */
	public function testReturnNominalOfOverrideShadowsBase(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Base.hx', source: 'class Base { public function findUser():Null<Foo> return null; }' },
			{ file: 'src/Sub.hx', source: 'class Sub extends Base { override public function findUser():Foo return null; }' }
		], plugin());
		Assert.equals('Foo', index.returnNominalOf('Sub', 'findUser'));
	}

	/**
	 * A file with no `package;` declaration has an empty package and a
	 * module path equal to the file basename (the root package).
	 */
	public function testRootPackageModule(): Void {
		final index: SymbolIndex = SymbolIndex.build([{ file: 'Root.hx', source: 'class Root {}' }], plugin());
		final info: Null<FileInfo> = index.fileInfo('Root.hx');
		Assert.notNull(info);
		final fi: FileInfo = (info: FileInfo);
		Assert.equals('', fi.pkg);
		Assert.equals('Root', fi.module);
		Assert.isTrue(fi.types[0].isMain);
	}

	/**
	 * A `final class` is INDEXED — it parses as a nameless `FinalDecl`
	 * wrapper whose inner `ClassForm` holds the name, so the final-aware
	 * `typeDeclOf` path picks it up where a plain `node.name` guard would
	 * silently drop it. Its `kind` is normalised to `ClassDecl`, it is the
	 * module's main type, and the cross-file queries resolve it.
	 */
	public function testFinalClassIndexed(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/pkg/sub/Foo.hx', source: 'package pkg.sub;\nfinal class Foo {\n\tpublic var x:Int = 1;\n}' },
			{ file: 'src/pkg/sub/User.hx', source: 'package pkg.sub;\nimport pkg.sub.Foo;\nclass User {}' },
		], plugin());

		final info: Null<FileInfo> = index.fileInfo('src/pkg/sub/Foo.hx');
		Assert.notNull(info);
		final fi: FileInfo = (info: FileInfo);
		// The final class is recorded as a single main-type ClassDecl.
		Assert.equals(1, fi.types.length);
		final foo: TypeDeclInfo = fi.types[0];
		Assert.equals('Foo', foo.name);
		Assert.equals('ClassDecl', foo.kind);
		Assert.isTrue(foo.isMain);
		// The full span includes the `final ` keyword (starts at offset 17,
		// right after `package pkg.sub;\n`).
		Assert.equals(17, foo.span.from);

		// Cross-file queries now resolve the final class.
		final declarers: Array<FileInfo> = index.declaringFiles('Foo');
		Assert.equals(1, declarers.length);
		Assert.equals('src/pkg/sub/Foo.hx', declarers[0].file);
		Assert.equals('pkg.sub.Foo', index.importPathOf('Foo'));
	}

	/** `declaringFiles` reports 0 / 1 / many declarers of a type name. */
	public function testDeclaringFilesCount(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/pkg/A.hx', source: 'package pkg;\nclass A {}' },
			{ file: 'src/pkg/B.hx', source: 'package pkg;\nclass B {}' },
			{ file: 'src/pkg/Dup.hx', source: 'package pkg;\nclass Dup {}\ntypedef A = Int;' },
		], plugin());

		// Zero declarers.
		Assert.equals(0, index.declaringFiles('Missing').length);
		// `B` declared in exactly one file.
		final b: Array<FileInfo> = index.declaringFiles('B');
		Assert.equals(1, b.length);
		Assert.equals('src/pkg/B.hx', b[0].file);
		// `A` declared in two files (class in A.hx, sub-typedef in Dup.hx).
		Assert.equals(2, index.declaringFiles('A').length);
	}

	/**
	 * `importPathOf` returns the module path for a unique main type, the
	 * `module.Sub` path for a unique sub-type, and null when the type is
	 * declared in zero or more than one file (ambiguous).
	 */
	public function testImportPathOf(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/pkg/Rename.hx', source: 'package pkg;\nclass Rename {}\ntypedef RenameResult = Int;' },
			{ file: 'src/pkg/Dup.hx', source: 'package pkg;\nclass Dup {}\ntypedef Rename = Int;' },
			{ file: 'src/pkg/Solo.hx', source: 'package pkg;\nclass Solo {}' },
		], plugin());

		// Unique main type -> the module path.
		Assert.equals('pkg.Solo', index.importPathOf('Solo'));
		// Unique sub-type -> module + '.' + typeName.
		Assert.equals('pkg.Rename.RenameResult', index.importPathOf('RenameResult'));
		// Ambiguous (declared in Rename.hx as main and Dup.hx as sub) -> null.
		Assert.isNull(index.importPathOf('Rename'));
		// Undeclared -> null.
		Assert.isNull(index.importPathOf('Nope'));
	}

	/**
	 * `filesImportingModule` finds importers of a module by its main
	 * path AND by a sub-type path, across `import` / `using` kinds; a
	 * file importing an unrelated module is excluded.
	 */
	public function testFilesImportingModule(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/pkg/Refs.hx', source: 'package pkg;\nclass Refs {}\ntypedef RefHit = Int;' },
			{ file: 'src/pkg/UsesModule.hx', source: 'package pkg;\nimport pkg.Refs;\nclass UsesModule {}' },
			{ file: 'src/pkg/UsesSub.hx', source: 'package pkg;\nimport pkg.Refs.RefHit;\nclass UsesSub {}' },
			{ file: 'src/pkg/UsesUsing.hx', source: 'package pkg;\nusing pkg.Refs;\nclass UsesUsing {}' },
			{ file: 'src/pkg/Unrelated.hx', source: 'package pkg;\nimport pkg.Other;\nclass Unrelated {}' },
		], plugin());

		final importers: Array<String> = index.filesImportingModule('pkg.Refs').map(f -> f.file);
		Assert.equals(3, importers.length);
		Assert.isTrue(importers.contains('src/pkg/UsesModule.hx'));
		Assert.isTrue(importers.contains('src/pkg/UsesSub.hx'));
		Assert.isTrue(importers.contains('src/pkg/UsesUsing.hx'));
		Assert.isFalse(importers.contains('src/pkg/Unrelated.hx'));

		// A prefix that is NOT a dotted boundary must not match
		// (`pkg.Ref` is not a prefix of the import `pkg.Refs`).
		Assert.equals(0, index.filesImportingModule('pkg.Ref').length);
	}

	/**
	 * A file that fails to parse is recorded in `skippedFiles()` and
	 * excluded from the index; `build` does NOT throw, and the
	 * parseable sibling is indexed normally.
	 */
	public function testSkipParseExcluded(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/pkg/Good.hx', source: 'package pkg;\nclass Good {}' },
			// Unbalanced braces — the parser throws.
			{ file: 'src/pkg/Bad.hx', source: 'package pkg;\nclass Bad { function f() { ' },
		], plugin());

		final skipped: Array<String> = index.skippedFiles();
		Assert.equals(1, skipped.length);
		Assert.equals('src/pkg/Bad.hx', skipped[0]);

		// The bad file is excluded; only the good file is indexed.
		Assert.equals(1, index.allFiles().length);
		Assert.notNull(index.fileInfo('src/pkg/Good.hx'));
		Assert.isNull(index.fileInfo('src/pkg/Bad.hx'));
	}

	/**
	 * `hasSubtype` / `hasAccessGrant` — the inheritance and access-grant gates
	 * of a cross-file-safe private-member rename, matched by simple type name.
	 */
	public function testInheritanceAndAccessGrantQueries(): Void {
		final files = [
			{ file: 'pkg/Base.hx', source: 'package pkg;\nclass Base {}' },
			{ file: 'pkg/Sub.hx', source: 'package pkg;\nclass Sub extends Base implements IFace {}' },
			{ file: 'pkg/Peer.hx', source: 'package pkg;\n@:access(pkg.Base)\nclass Peer {}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.isTrue(index.hasSubtype('Base'));
		Assert.isTrue(index.hasSubtype('IFace'));
		Assert.isFalse(index.hasSubtype('Peer'));
		Assert.isTrue(index.hasAccessGrant('Base'));
		Assert.isFalse(index.hasAccessGrant('Sub'));
	}

	/**
	 * A type declared inside a `#if ... #end` region is indexed like a plain
	 * top-level one, with its members and its cross-file declaring-file entry.
	 */
	public function testConditionalRegionTypeIsIndexed(): Void {
		final source: String = 'package pkg;\n#if js\nclass Guarded {\n\tpublic var gv:Int;\n}\n#end\nclass Cond {}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Cond.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Cond.hx');

		Assert.equals(2, fi.types.length);
		final guarded: Null<TypeDeclInfo> = fi.types.find(t -> t.name == 'Guarded');
		Assert.notNull(guarded);
		Assert.equals('ClassDecl', (guarded: TypeDeclInfo).kind);
		Assert.isFalse((guarded: TypeDeclInfo).isMain);
		Assert.isTrue((guarded: TypeDeclInfo).members.exists(m -> m.name == 'gv'));
		Assert.equals(1, index.declaringFiles('Guarded').length);
	}

	/**
	 * Both branches of a `#if / #else` region project as siblings of one
	 * wrapper, but no compilation sees more than one: the FIRST declaration of
	 * a name is indexed and later same-named ones are dropped, so the name
	 * never reads as ambiguous.
	 */
	public function testConditionalDuplicateNameKeepsFirstBranch(): Void {
		final source: String = 'package pkg;\n#if js\nclass Dup {\n\tpublic var jsOnly:Int;\n}\n#else\nclass Dup {\n\tpublic var cppOnly:Int;\n}\n#end\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Dup.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Dup.hx');

		Assert.equals(1, fi.types.length);
		Assert.equals(1, index.declaringFiles('Dup').length);
		final dup: TypeDeclInfo = fi.types[0];
		Assert.equals('Dup', dup.name);
		Assert.isTrue(dup.members.exists(m -> m.name == 'jsOnly'));
		Assert.isFalse(dup.members.exists(m -> m.name == 'cppOnly'));
	}

	/** Two SIBLING regions declaring the same type collapse to one entry too. */
	public function testSiblingConditionalRegionsDedupeByName(): Void {
		final source: String = 'package pkg;\n#if js\nclass Twin {\n\tpublic var jsOnly:Int;\n}\n#end\n#if !js\nclass Twin {\n\tpublic var nativeOnly:Int;\n}\n#end\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Twin.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Twin.hx');

		Assert.equals(1, fi.types.length);
		Assert.isTrue(fi.types[0].members.exists(m -> m.name == 'jsOnly'));
	}

	/** Distinct names across `#if` / `#elseif` / `#else` branches are ALL indexed. */
	public function testConditionalBranchDistinctNamesAllIndexed(): Void {
		final source: String = 'package pkg;\n#if js\nclass MA {}\n#elseif cpp\nclass MB {}\n#else\ntypedef MC = Int;\n#end\nclass Multi {}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Multi.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Multi.hx');

		Assert.equals(4, fi.types.length);
		Assert.notNull(fi.types.find(t -> t.name == 'MA'));
		Assert.notNull(fi.types.find(t -> t.name == 'MB'));
		final mc: Null<TypeDeclInfo> = fi.types.find(t -> t.name == 'MC');
		Assert.notNull(mc);
		Assert.equals('TypedefDecl', (mc: TypeDeclInfo).kind);
		final multi: Null<TypeDeclInfo> = fi.types.find(t -> t.name == 'Multi');
		Assert.notNull(multi);
		Assert.isTrue((multi: TypeDeclInfo).isMain);
	}

	/** A region nested inside another region is descended into as well. */
	public function testNestedConditionalRegionTypeIsIndexed(): Void {
		final source: String = 'package pkg;\n#if js\n#if debug\nclass Nested {}\n#end\n#end\nclass Outer {}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Outer.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Outer.hx');

		Assert.equals(2, fi.types.length);
		Assert.notNull(fi.types.find(t -> t.name == 'Nested'));
	}

	/**
	 * A SPLIT-HEADER region - `#if a class X extends B { #else class X { #end
	 * <members> }` - indexes the first branch's header: its name, kind and
	 * heritage come from the `*Head` child, its members are the head's
	 * SIBLINGS, and its span is the WRAPPER's, so the members written after
	 * `#end` are inside it.
	 */
	public function testSplitHeaderDeclIndexed(): Void {
		final source: String = 'package pkg;\n#if js\nclass Split extends Base implements Marker {\n#else\nclass Split {\n#end\n\tpublic var shared:Int;\n}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Split.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Split.hx');

		Assert.equals(1, fi.types.length);
		final split: TypeDeclInfo = fi.types[0];
		Assert.equals('Split', split.name);
		Assert.equals('ClassDecl', split.kind);
		Assert.isTrue(split.isMain);
		Assert.equals(0, split.typeParamArity);
		Assert.isFalse(split.isAnonStruct);
		Assert.isTrue(split.supertypes.contains('Base'));
		Assert.isTrue(split.supertypes.contains('Marker'));
		Assert.isTrue(split.members.exists(m -> m.name == 'shared'));
		Assert.isTrue(index.hasSubtype('Base'));

		final memberAt: Int = source.indexOf('shared');
		Assert.isTrue(split.span.from <= memberAt && memberAt < split.span.to);
	}

	/** The `abstract` split-header form, with its type-parameter arity read off the head. */
	public function testSplitHeaderAbstractTypeParamArity(): Void {
		final source: String = 'package pkg;\n#if js\nabstract Gen<T>(Array<T>) from Array<T> {\n#else\nabstract Gen<T>(List<T>) from List<T> {\n#end\n\tpublic var g:Int;\n}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Gen.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Gen.hx');

		Assert.equals(1, fi.types.length);
		final gen: TypeDeclInfo = fi.types[0];
		Assert.equals('Gen', gen.name);
		Assert.equals('AbstractDecl', gen.kind);
		Assert.equals(1, gen.typeParamArity);
		Assert.isTrue(gen.members.exists(m -> m.name == 'g'));
	}

	/**
	 * An `import` guarded by a `#if ... #end` region is LIFTED into the file's
	 * import scope, so a reference resolvable only through that guarded import is
	 * seen by the index. The top-level import is kept alongside it.
	 */
	public function testConditionalRegionImportIsIndexed(): Void {
		final source: String = 'package pkg;\n#if js\nimport js.Browser;\n#end\nimport other.Thing;\nclass Guard {}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Guard.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Guard.hx');

		Assert.equals(2, fi.imports.length);
		final guarded: Null<ImportInfo> = fi.imports.find(i -> i.raw == 'js.Browser');
		Assert.notNull(guarded);
		Assert.isTrue((guarded: ImportInfo).guarded);
		final topLevel: Null<ImportInfo> = fi.imports.find(i -> i.raw == 'other.Thing');
		Assert.notNull(topLevel);
		Assert.isFalse((topLevel: ImportInfo).guarded);
	}

	/**
	 * A guarded `using` and a guarded aliased import are lifted too, each with
	 * the correct kind and (for the alias) its alias name.
	 */
	public function testConditionalRegionUsingAndAliasIndexed(): Void {
		final source: String = 'package pkg;\n#if js\nusing other.Ext;\nimport other.Mod.Sub as Aliased;\n#end\nclass Guard {}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Guard.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Guard.hx');

		final u: Null<ImportInfo> = fi.imports.find(i -> i.raw == 'other.Ext');
		Assert.notNull(u);
		Assert.isTrue((u: ImportInfo).kind == ImportKind.Using);
		final a: Null<ImportInfo> = fi.imports.find(i -> i.raw == 'Aliased');
		Assert.notNull(a);
		Assert.isTrue((a: ImportInfo).kind == ImportKind.Alias);
		Assert.equals('Aliased', (a: ImportInfo).alias);
	}

	/**
	 * A guarded import that DUPLICATES a top-level one is dropped regardless of
	 * document order - the top-level appears once, the guarded copy does not
	 * double it.
	 */
	public function testGuardedImportDedupedAgainstTopLevel(): Void {
		final source: String = 'package pkg;\nimport other.Thing;\n#if js\nimport other.Thing;\n#end\nclass Guard {}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Guard.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Guard.hx');

		Assert.equals(1, fi.imports.length);
		Assert.equals('other.Thing', fi.imports[0].raw);
	}

	/**
	 * The same import in a `#if` and its `#else` branch - which project as
	 * siblings of one wrapper - collapses to a single entry.
	 */
	public function testGuardedImportBranchesDedupe(): Void {
		final source: String = 'package pkg;\n#if js\nimport other.Thing;\n#else\nimport other.Thing;\n#end\nclass Guard {}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Guard.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Guard.hx');

		Assert.equals(1, fi.imports.length);
		Assert.equals('other.Thing', fi.imports[0].raw);
	}

	/** Distinct imports across `#if` branches are all lifted. */
	public function testGuardedImportBranchesDistinctAllIndexed(): Void {
		final source: String = 'package pkg;\n#if js\nimport js.Browser;\n#else\nimport sys.io.File;\n#end\nclass Guard {}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Guard.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Guard.hx');

		Assert.equals(2, fi.imports.length);
		Assert.notNull(fi.imports.find(i -> i.raw == 'js.Browser'));
		Assert.notNull(fi.imports.find(i -> i.raw == 'sys.io.File'));
	}

	/**
	 * `subtypeDeclaresMember` — a member is OVERRIDDEN below `typeName` when a
	 * transitive subtype declares it. Backs `unused-parameter`'s rename gate,
	 * which leaves a base method's parameter alone when an override may use it.
	 */
	public function testSubtypeDeclaresMember(): Void {
		final files = [
			{ file: 'pkg/Base.hx', source: 'package pkg;\nclass Base {\n\tfunction over():Void {}\n\n\tfunction only():Void {}\n}' },
			{ file: 'pkg/Mid.hx', source: 'package pkg;\nclass Mid extends Base {}' },
			{ file: 'pkg/Leaf.hx', source: 'package pkg;\nclass Leaf extends Mid {\n\toverride function over():Void {}\n}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		// `over` is overridden by Leaf, a TRANSITIVE subtype of Base (Leaf -> Mid -> Base).
		Assert.isTrue(index.subtypeDeclaresMember('Base', 'over'));
		// `only` is declared solely in Base — no subtype declares it.
		Assert.isFalse(index.subtypeDeclaresMember('Base', 'only'));
		// A leaf type has no subtype at all.
		Assert.isFalse(index.subtypeDeclaresMember('Leaf', 'over'));
	}

	/** The `FileInfo` `index` holds for `file`, asserted present. */
	private function fileInfoOf(index: SymbolIndex, file: String): FileInfo {
		final info: Null<FileInfo> = index.fileInfo(file);
		Assert.notNull(info);
		return (info: FileInfo);
	}

	private function assertImport(imp: ImportInfo, raw: String, kind: ImportKind, alias: Null<String>): Void {
		Assert.equals(raw, imp.raw);
		Assert.isTrue(imp.kind == kind);
		Assert.equals(alias, imp.alias);
		Assert.notNull(imp.span);
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

}
