package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import utest.Assert;
import utest.Test;

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
		final source: String = 'package pkg.sub;\nimport other.Thing;\nimport other.Mod.Sub as Aliased;\nimport other.deep.*;\n'
			+ 'using other.Ext;\nclass A {}\ntypedef Helper = {};\n';
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
		final files: Array<{ source: String, file: String }> = [
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
	 * Two DISTINCT subtypes sharing a simple name: the closure must not dedupe them away
	 * before the predicate runs. Deduping by name is right for the WALK (each name is
	 * expanded once) but wrong for the predicate — the second `D`'s own declaration slice
	 * is what carries its `@:build`, and skipping it silently drops that evidence.
	 */
	public function testSameSimpleNameSubtypesBothVisitPredicate(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/C.hx', source: 'class C { public var x:Int = 0; }' },
			{ file: 'src/a/D.hx', source: 'package a;\nclass D extends C {}' },
			{ file: 'src/b/D.hx', source: 'package b;\n@:build(M.gen())\nclass D extends C {}' }
		], plugin());
		final seen: Array<String> = [];

		index.subtypeDeclMatches('C', 'x', (subtype, src, _, _) -> {
			seen.push(subtype + (src.indexOf('@:build') >= 0 ? ':build' : ':plain'));
			return false;
		});
		Assert.isTrue(seen.contains('D:build'), 'the @:build subtype slice must reach the predicate — got $seen');
		Assert.isTrue(seen.contains('D:plain'), 'got $seen');
	}

	/**
	 * `members` is the type's DIRECTLY-declared members. An anonymous-structure type
	 * annotation writes its fields with the same grammar kinds a class member uses
	 * (`VarField` / `FinalField`), so a member whose TYPE is such a structure must not
	 * contribute that structure's fields as members of the enclosing type.
	 */
	public function testAnonStructureFieldIsNotAMember(): Void {
		final source: String = 'package pkg;\nclass Holder {\n\tpublic var cfg:{ var inner:Int; } = { inner: 1 };\n}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Holder.hx', source: source }], plugin());
		final holder: TypeDeclInfo = fileInfoOf(index, 'src/pkg/Holder.hx').types[0];

		Assert.isTrue(holder.members.exists(m -> m.name == 'cfg'));
		Assert.isFalse(holder.members.exists(m -> m.name == 'inner'));
	}

	/**
	 * `CondNameFnMember` — a method whose NAME is a `#if` region — is a member like any
	 * other, so its parameter types must not leak either. It is a distinct grammar ctor
	 * from `FnMember`, so a member-kind list that forgets it lets the phantom back in.
	 */
	public function testConditionalNameMethodParamIsNotAMember(): Void {
		final source: String = 'package pkg;\nclass Cn {\n\tfunction #if js set_a #else setA #end (b:{ var phantomA:Int; }):Void {}\n}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Cn.hx', source: source }], plugin());

		Assert.isFalse(fileInfoOf(index, 'src/pkg/Cn.hx').types[0].members.exists(m -> m.name == 'phantomA'));
	}

	/**
	 * An anonymous structure in the type declaration's own HEADER — a type-parameter
	 * constraint or a heritage type argument — is a type expression, not a member list.
	 * Only a typedef's `Anon` is the body whose fields ARE the members.
	 */
	public function testAnonStructureInTypeHeaderIsNotAMember(): Void {
		final source: String = 'package pkg;\nclass Hdr<T:{ var z:Int; }> extends Base<{ var e:Int; }> {\n\tpublic var real:Int = 0;\n}\n';
		final hdr: TypeDeclInfo = fileInfoOf(
			SymbolIndex.build([{ file: 'src/pkg/Hdr.hx', source: source }], plugin()), 'src/pkg/Hdr.hx'
		).types[0];

		Assert.isTrue(hdr.members.exists(m -> m.name == 'real'));
		Assert.isFalse(hdr.members.exists(m -> m.name == 'z'));
		Assert.isFalse(hdr.members.exists(m -> m.name == 'e'));
	}

	/** Control for the header rule: a typedef's own `Anon` IS its member list. */
	public function testTypedefAnonFieldsAreMembers(): Void {
		final source: String = 'package pkg;\ntypedef Td = { var x:Int; final y:String; }\n';
		final td: TypeDeclInfo = fileInfoOf(
			SymbolIndex.build([{ file: 'src/pkg/Td.hx', source: source }], plugin()), 'src/pkg/Td.hx'
		).types[0];

		Assert.isTrue(td.members.exists(m -> m.name == 'x'));
		Assert.isTrue(td.members.exists(m -> m.name == 'y'));
	}

	/**
	 * `collectAccessGrants` must keep the UNPRUNED walk: a block-level `@:access(pkg.P)`
	 * lives inside a method body, so pruning it away like the member walk does would drop
	 * the grant — and `prefer-final-field` reads a missing grant as "nothing can write
	 * this", the unsound direction. This test is the guard on that deliberate asymmetry.
	 */
	public function testBlockLevelAccessGrantIsIndexed(): Void {
		final source: String = 'package pkg;\nclass G {\n\tfunction f():Void {\n\t\t@:access(pkg.P) {\n\t\t\ttrace(1);\n\t\t}\n\t}\n}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/G.hx', source: source }], plugin());

		Assert.isTrue(index.hasAccessGrant('P'), 'a grant inside a method body must still be indexed');
	}

	/** The same for an anonymous structure annotating a LOCAL inside a method body. */
	public function testAnonStructureLocalIsNotAMember(): Void {
		final source: String = 'package pkg;\nclass Local {\n\tfunction f():Void {\n\t\tfinal o:{ var deep:Int; } = { deep: 1 };\n\t}\n}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Local.hx', source: source }], plugin());
		final local: TypeDeclInfo = fileInfoOf(index, 'src/pkg/Local.hx').types[0];

		Assert.isTrue(local.members.exists(m -> m.name == 'f'));
		Assert.isFalse(local.members.exists(m -> m.name == 'deep'));
	}

	/**
	 * Both branches of a `#if / #else` region project as siblings of one
	 * wrapper, but no compilation sees more than one: the FIRST declaration of
	 * a name is indexed and later same-named ones are dropped, so the name
	 * never reads as ambiguous.
	 */
	public function testConditionalDuplicateNameKeepsFirstBranch(): Void {
		final source: String =
			'package pkg;\n#if js\nclass Dup {\n\tpublic var jsOnly:Int;\n}\n#else\nclass Dup {\n\tpublic var cppOnly:Int;\n}\n#end\n';
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
		final source: String = 'package pkg;\n#if js\nclass Twin {\n\tpublic var jsOnly:Int;\n}\n#end\n#if !js\nclass Twin {\n'
			+ '\tpublic var nativeOnly:Int;\n}\n#end\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Twin.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/Twin.hx');

		Assert.equals(1, fi.types.length);
		Assert.isTrue(fi.types[0].members.exists(m -> m.name == 'jsOnly'));
	}

	/** Distinct names across `#if` / `#elseif` / `#else` branches are ALL indexed. */
	public function testConditionalBranchDistinctNamesAllIndexed(): Void {
		final source: String =
			'package pkg;\n#if js\nclass MA {}\n#elseif cpp\nclass MB {}\n#else\ntypedef MC = Int;\n#end\nclass Multi {}\n';
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
		final source: String =
			'package pkg;\n#if js\nclass Split extends Base implements Marker {\n#else\nclass Split {\n#end\n\tpublic var shared:Int;\n}\n';
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
		final source: String = 'package pkg;\n#if js\nabstract Gen<T>(Array<T>) from Array<T> {\n#else\n'
			+ 'abstract Gen<T>(List<T>) from List<T> {\n#end\n\tpublic var g:Int;\n}\n';
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
	 * The header type-parameter table: arity AND the ordered names, over every written form the
	 * scan has to segment. `typeParamNames` is POSITIONAL — its index is the argument index the
	 * substituting path walk reads — so a phantom or shifted entry resolves a member to the wrong
	 * type. The shape worth naming is the STRUCTURAL constraint `<T:{a:Int, b:Int}>`: its comma is
	 * not a parameter separator, and a brace-blind segmentation read it as a second parameter
	 * named after the structure's second field.
	 *
	 * Two forms are absent on purpose, both because the grammar refuses them outright (a file
	 * carrying either is skipped by the index, so no scan ever sees it): the Haxe 3 paren
	 * multi-constraint `<T:(A, B)>` — `<T:A & B>` is its modern spelling and is pinned here — and
	 * metadata on a parameter, `<@:const N>`.
	 */
	public function testHeaderTypeParamNames(): Void {
		assertHeaderParams('class Plain {}', 0, []);
		assertHeaderParams('class One<T> {}', 1, ['T']);
		assertHeaderParams('class Two<K, V> {}', 2, ['K', 'V']);
		assertHeaderParams('class Bound<T:Item> {}', 1, ['T']);
		assertHeaderParams('class Amp<T:A & B> {}', 1, ['T']);
		assertHeaderParams('class Struct<T:{a:Int, b:Int}> {}', 1, ['T']);
		assertHeaderParams('class Nested<T:Array<Int>, K> {}', 2, ['T', 'K']);
		assertHeaderParams('class Fn<T:Int->Void> {}', 1, ['T']);
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
	 * `isExtern` — positive and negative controls, unconditional. A plain `extern class`
	 * is recorded extern; a plain `class` right after it is not — the flag does not default
	 * to true, and consuming the modifier does not smear it onto the type that follows.
	 */
	public function testIsExternUnconditionalControls(): Void {
		final source: String = 'package pkg;\nextern class Native {}\nclass Plain {}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/E.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/E.hx');

		final native: Null<TypeDeclInfo> = fi.types.find(t -> t.name == 'Native');
		Assert.notNull(native);
		Assert.isTrue((native: TypeDeclInfo).isExtern);
		final plain: Null<TypeDeclInfo> = fi.types.find(t -> t.name == 'Plain');
		Assert.notNull(plain);
		Assert.isFalse((plain: TypeDeclInfo).isExtern);
	}

	/**
	 * A GUARDED `extern class` — `#if js extern class B {} #end` — projects the `extern`
	 * modifier as a nameless sibling of the `ClassDecl` inside the `Conditional` wrapper
	 * (`(Conditional (Extern) (ClassDecl B))`). `pushGuardedDecl` already lifts a guarded
	 * leading meta so it reaches `extractFileInfo`'s pending run; the `extern` modifier gets
	 * the same lift, so the guarded declaration is indexed extern like its unconditional twin.
	 */
	public function testIsExternGuardedClassIsExtern(): Void {
		final source: String = 'package pkg;\n#if js\nextern class B {}\n#end\nclass Cond {}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/G.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/G.hx');

		final b: Null<TypeDeclInfo> = fi.types.find(t -> t.name == 'B');
		Assert.notNull(b);
		Assert.isTrue((b: TypeDeclInfo).isExtern, 'a guarded extern class must be indexed extern');
		final cond: Null<TypeDeclInfo> = fi.types.find(t -> t.name == 'Cond');
		Assert.notNull(cond);
		Assert.isFalse((cond: TypeDeclInfo).isExtern);
	}

	/**
	 * A SPLIT `extern` — `#if cpp extern #end class NativeThing {}` — guards only the
	 * modifier, with the class declaration itself unconditional (the natural idiom for
	 * "extern on this target only"). The `Conditional` wrapper here carries no declaration
	 * at all (`(Conditional (Extern))`), so the lift must not require a co-located decl.
	 */
	public function testIsExternSplitModifierAppliesToFollowingDecl(): Void {
		final source: String = 'package pkg;\n#if cpp\nextern\n#end\nclass NativeThing {}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/S.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/S.hx');

		final nt: TypeDeclInfo = fi.types[0];
		Assert.equals('NativeThing', nt.name);
		Assert.isTrue(nt.isExtern, 'a split guarded extern modifier must mark the unconditional decl that follows it');
	}

	/**
	 * The leak guard: a split `extern` modifier followed by an UNRELATED `import` before
	 * the next type declaration must not smear onto that later, unrelated type. `pendingMeta`
	 * already resets at every import / using / package boundary (6 points); `pendingExtern`
	 * must reset at the same 6, not just 2 (type-decl-consume and `PackageDecl`) — otherwise a
	 * stray guarded `extern` with no decl of its own in its branch leaks past an `import` onto
	 * whichever type happens to come next.
	 */
	public function testIsExternDoesNotLeakPastImport(): Void {
		final source: String = 'package pkg;\n#if cpp\nextern\n#end\nimport other.Thing;\nclass Plain {}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/L.hx', source: source }], plugin());
		final fi: FileInfo = fileInfoOf(index, 'src/pkg/L.hx');

		final plain: TypeDeclInfo = fi.types[0];
		Assert.equals('Plain', plain.name);
		Assert.isFalse(plain.isExtern, 'the stray extern must not leak past the intervening import onto an unrelated type');
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
		final files: Array<{ source: String, file: String }> = [
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

	/**
	 * The modifier-run flags a member carries: `kind` / `isStatic` / `isInline`, reset at
	 * every member so one member's modifiers never leak onto the next. `kind` is the
	 * member's own projected declaration kind, which is how a consumer tells a `final`
	 * field from a `var` or from a method without re-walking the tree.
	 */
	public function testMemberModifierFlags(): Void {
		final source: String = 'package pkg;\nclass M {\n\tpublic static inline final A:String = \'a\';\n'
			+ "\tpublic static final B:String = 'b';\n\tpublic static inline var C:String = 'c';\n"
			+ '\tpublic static var D:String = \'d\';\n\tprivate final e:String = \'e\';\n\tpublic function f():Void {}\n}\n';
		final m: TypeDeclInfo = fileInfoOf(
			SymbolIndex.build([{ file: 'src/pkg/M.hx', source: source }], plugin()), 'src/pkg/M.hx'
		).types[0];

		assertFlags(memberOf(m, 'A'), 'FinalMember', true, true, false);
		assertFlags(memberOf(m, 'B'), 'FinalMember', true, false, false);
		assertFlags(memberOf(m, 'C'), 'VarMember', true, true, false);
		assertFlags(memberOf(m, 'D'), 'VarMember', true, false, false);
		// A non-static `final` field: its own kind still projects, but no modifier is set.
		assertFlags(memberOf(m, 'e'), 'FinalMember', false, false, false);
		assertFlags(memberOf(m, 'f'), 'FnMember', false, false, false);
	}

	/**
	 * A member declared inside a `#if` region is `guarded` — the declaration exists but
	 * its presence and value are branch-dependent, while the index is branch-blind. Its
	 * modifier flags are still read correctly: the conditional region is the member HOST,
	 * and the modifier siblings sit inside it.
	 */
	public function testGuardedMemberFlag(): Void {
		final source: String = 'package pkg;\nclass G {\n\tpublic static inline final PLAIN:String = \'p\';\n\t#if js\n'
			+ '\tpublic static inline final GUARDED:String = \'g\';\n\t#end\n}\n';
		final g: TypeDeclInfo = fileInfoOf(
			SymbolIndex.build([{ file: 'src/pkg/G.hx', source: source }], plugin()), 'src/pkg/G.hx'
		).types[0];

		assertFlags(memberOf(g, 'PLAIN'), 'FinalMember', true, true, false);
		assertFlags(memberOf(g, 'GUARDED'), 'FinalMember', true, true, true);
	}

	/**
	 * An enum-abstract VALUE carries no `static` modifier — the enum-abstract kind is what
	 * makes it a constant, which is why a consumer must ask the hosting type's kind and not
	 * only the member's flags.
	 */
	public function testEnumAbstractValueFlags(): Void {
		final source: String = 'package pkg;\nenum abstract Ea(Int) {\n\tfinal P = 0;\n\tvar Q = 1;\n}\n';
		final ea: TypeDeclInfo = fileInfoOf(
			SymbolIndex.build([{ file: 'src/pkg/Ea.hx', source: source }], plugin()), 'src/pkg/Ea.hx'
		).types[0];

		Assert.equals('EnumAbstractDecl', ea.kind);
		assertFlags(memberOf(ea, 'P'), 'FinalMember', false, false, false);
		assertFlags(memberOf(ea, 'Q'), 'VarMember', false, false, false);
	}

	/**
	 * `memberDeclarationsOf` returns EVERY indexed declaration of a member paired with its
	 * hosting type — one per same-simple-name type — and an empty array for an unknown
	 * type / member, which a consumer must read as "unknown", never as "absent".
	 */
	public function testMemberDeclarationsOf(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/A.hx', source: "class Dup { public static inline final K:String = 'a'; }" },
			{ file: 'src/B.hx', source: "class Dup { public static var K:String = 'b'; }" }
		], plugin());

		final decls: Array<{ type: TypeDeclInfo, member: MemberInfo }> = index.memberDeclarationsOf('Dup', 'K');
		Assert.equals(2, decls.length);
		Assert.isTrue(decls.exists(d -> d.member.isInline));
		Assert.isTrue(decls.exists(d -> !d.member.isInline));
		for (d in decls) Assert.equals('Dup', d.type.name);
		Assert.equals(0, index.memberDeclarationsOf('Dup', 'missing').length);
		Assert.equals(0, index.memberDeclarationsOf('Missing', 'K').length);
	}

	public function testSubtypeOverridesProperty(): Void {
		final files: Array<{ source: String, file: String }> = [
			{
				file: 'pkg/Base.hx',
				source: 'package pkg;\nclass Base {\n\tpublic var data(get, set):Int;\n\tfunction get_data():Int return 0;\n}'
			},
			{ file: 'pkg/Plain.hx', source: 'package pkg;\nclass Plain extends Base {\n\tpublic function ping():Void {}\n}' },
			{ file: 'pkg/Over.hx', source: 'package pkg;\nclass Over extends Base {\n\toverride function get_data():Int return 1;\n}' },
			{
				file: 'pkg/Solo.hx',
				source: 'package pkg;\nclass Solo {\n\tpublic var tag(get, set):Int;\n\tfunction get_tag():Int return 0;\n}'
			},
			{ file: 'pkg/SoloSub.hx', source: 'package pkg;\nclass SoloSub extends Solo {\n\tpublic function ping():Void {}\n}' },
			{
				file: 'pkg/Fresh.hx',
				source: 'package pkg;\nclass Fresh {\n\tpublic var tag(get, set):Int;\n\tfunction get_tag():Int return 5;\n}'
			}
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		// A resolved subtype (Over) overriding get_data blocks Base's collapse.
		Assert.isTrue(index.subtypeOverridesProperty('Base', 'data'));
		// Solo has only a non-touching resolved subtype (SoloSub); Fresh is an unrelated same-named
		// declarer, not a subtype -> collapse stays safe.
		Assert.isFalse(index.subtypeOverridesProperty('Solo', 'tag'));
		// A leaf owner with no subtype at all is clean.
		Assert.isFalse(index.subtypeOverridesProperty('Over', 'data'));
	}

	public function testSubtypeOverridesPropertyUnresolvable(): Void {
		// Loose OVERRIDES get_tag but reaches through Ext, which is NOT indexed -> its position
		// relative to Root is unresolvable, so it conservatively blocks Root's collapse.
		final blocking: Array<{ source: String, file: String }> = [
			{
				file: 'pkg/Root.hx',
				source: 'package pkg;\nclass Root {\n\tpublic var tag(get, set):Int;\n\tfunction get_tag():Int return 0;\n}'
			},
			{ file: 'pkg/Loose.hx', source: 'package pkg;\nclass Loose extends Ext {\n\toverride function get_tag():Int return 7;\n}' }
		];
		Assert.isTrue(SymbolIndex.build(blocking, new HaxeQueryPlugin()).subtypeOverridesProperty('Root', 'tag'));
		// Fresh declares get_tag as a FRESH (non-override) accessor through the same unresolvable Ext
		// base -> it is not overriding Root, so the collapse stays safe (the DropDownListItem shape).
		final safe: Array<{ source: String, file: String }> = [
			{
				file: 'pkg/Root.hx',
				source: 'package pkg;\nclass Root {\n\tpublic var tag(get, set):Int;\n\tfunction get_tag():Int return 0;\n}'
			},
			{
				file: 'pkg/Fresh.hx',
				source: 'package pkg;\nclass Fresh extends Ext {\n\tpublic var tag(get, set):Int;\n\tfunction get_tag():Int return 7;\n}'
			}
		];
		Assert.isFalse(SymbolIndex.build(safe, new HaxeQueryPlugin()).subtypeOverridesProperty('Root', 'tag'));
	}

	public function testSubtypeReferencesField(): Void {
		final files: Array<{ source: String, file: String }> = [
			{ file: 'pkg/Base.hx', source: 'package pkg;\nclass Base {\n\tprivate var _x:Int = 0;\n}' },
			{ file: 'pkg/Reader.hx', source: 'package pkg;\nclass Reader extends Base {\n\tpublic function get():Int return _x;\n}' },
			{ file: 'pkg/Clean.hx', source: 'package pkg;\nclass Clean {\n\tprivate var _y:Int = 0;\n}' },
			{ file: 'pkg/CleanSub.hx', source: 'package pkg;\nclass CleanSub extends Clean {\n\tpublic function ping():Void {}\n}' },
			{ file: 'pkg/Owner2.hx', source: 'package pkg;\nclass Owner2 {\n\tprivate var _x:Int = 0;\n}' },
			{
				file: 'pkg/Peer.hx',
				source: 'package pkg;\nclass Peer {\n\tprivate var _x:Int = 5;\n\tpublic function get():Int return _x;\n}'
			}
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		// Reader, a subtype of Base, reads Base._x directly -> deleting _x would break it.
		Assert.isTrue(index.subtypeReferencesField('Base', '_x'));
		// CleanSub, a subtype of Clean, never mentions _y -> safe to drop.
		Assert.isFalse(index.subtypeReferencesField('Clean', '_y'));
		// Peer is NOT a subtype of Owner2 and references its OWN _x (which it declares) -> Owner2's _x is safe.
		Assert.isFalse(index.subtypeReferencesField('Owner2', '_x'));
	}

	/**
	 * A supertype reference resolves through the REFERRING file's package / imports, not by a
	 * globally-unique simple name: two interfaces sharing one simple name in different
	 * packages no longer make the closure unprovable. This is TM's real shape —
	 * `common.IResizable` beside `rightmenu.IResizable`, with `common.Resizable` implementing
	 * the same-package one — and it used to block the `_`-prefix rename of every private
	 * field under `Resizable`.
	 */
	public function testProvablyLacksMemberResolvesAmbiguousSimpleSupertypeName(): Void {
		final index: SymbolIndex = SymbolIndex.build(ambiguousInterfaceFiles(), plugin());
		Assert.isTrue(index.typeProvablyLacksMember('Sub', '_absent'));
	}

	/** The member the IN-SCOPE same-named interface declares is still found — the proof stays sound. */
	public function testProvablyLacksMemberFindsMemberOfInScopeSameNamedSupertype(): Void {
		final index: SymbolIndex = SymbolIndex.build(ambiguousInterfaceFiles(), plugin());
		Assert.isFalse(index.typeProvablyLacksMember('Sub', 'inCommon'));
	}

	/**
	 * A member declared ONLY by the same-named interface that is OUT of scope is not inherited,
	 * so the closure still proves absence — the union-over-same-simple-name reading would not.
	 */
	public function testProvablyLacksMemberIgnoresMemberOfOutOfScopeSameNamedSupertype(): Void {
		final index: SymbolIndex = SymbolIndex.build(ambiguousInterfaceFiles(), plugin());
		Assert.isTrue(index.typeProvablyLacksMember('Sub', 'inRightmenu'));
	}

	/** An inline-qualified supertype reference resolves to the type its path names, not to the same-package one. */
	public function testProvablyLacksMemberResolvesQualifiedSupertypeReference(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/common/IResizable.hx', source: 'package common;\ninterface IResizable { function inCommon():Void; }' },
			{
				file: 'src/rightmenu/IResizable.hx',
				source: 'package rightmenu;\ninterface IResizable { function inRightmenu():Void; }'
			},
			{
				file: 'src/common/Q.hx',
				source: 'package common;\nclass Q implements rightmenu.IResizable { private var _own:Int; }'
			}
		], plugin());
		// The qualified clause names the `rightmenu` one, so ITS member is inherited and the
		// same-package `common.IResizable`'s is not.
		Assert.isFalse(index.typeProvablyLacksMember('Q', 'inRightmenu'));
		Assert.isTrue(index.typeProvablyLacksMember('Q', 'inCommon'));
	}

	/** A supertype outside the index stays unprovable — the conservative side is unchanged. */
	public function testProvablyLacksMemberRefusesUnindexedSupertype(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Lone.hx', source: 'class Lone extends SomethingExternal { private var _own:Int; }' }
		], plugin());
		Assert.isFalse(index.typeProvablyLacksMember('Lone', '_absent'));
	}

	/**
	 * `supertypeChainResolved` answers whether EVERY supertype hop, transitively, names a declaration
	 * the index holds — the question a consumer asks before reading `supertypeDeclaresMember`'s
	 * `false` as a proof. A chain reaching a library class the index never saw is false; so is a name
	 * the index holds NO declaration for, which used to answer the permissive true a consumer would
	 * have read as proof. The fully-indexed chain answers true, so the gate is not simply off.
	 */
	public function testSupertypeChainResolvedFailsClosed(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Base.hx', source: 'class Base {}' },
			{ file: 'src/Mid.hx', source: 'class Mid extends Base {}' },
			{ file: 'src/Leaf.hx', source: 'class Leaf extends Mid {}' },
			{ file: 'src/Free.hx', source: 'class Free extends SomethingExternal {}' },
		], plugin());
		Assert.isTrue(index.supertypeChainResolved('Leaf'));
		Assert.isFalse(index.supertypeChainResolved('Free'));
		Assert.isFalse(index.supertypeChainResolved('Nowhere'));
	}

	/**
	 * A supertype whose simple name is ambiguous AND whose referring file brings neither into
	 * scope stays unprovable: resolution returning several candidates is refused exactly like
	 * resolution returning none.
	 */
	public function testProvablyLacksMemberRefusesUnresolvableAmbiguousSupertype(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/a/I.hx', source: 'package a;\ninterface I { function m():Void; }' },
			{ file: 'src/b/I.hx', source: 'package b;\ninterface I { function m():Void; }' },
			{ file: 'src/c/Q.hx', source: 'package c;\nclass Q implements I { private var _own:Int; }' }
		], plugin());
		Assert.isFalse(index.typeProvablyLacksMember('Q', '_absent'));
	}

	/** An inheritance cycle between two SAME-NAMED types terminates without a false proof. */
	public function testProvablyLacksMemberTerminatesOnSameNamedCycle(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/a/C.hx', source: 'package a;\nimport b.C;\nclass C extends b.C { private var _fromA:Int; }' },
			{ file: 'src/b/C.hx', source: 'package b;\nclass C extends a.C { private var _fromB:Int; }' }
		], plugin());
		Assert.isFalse(index.typeProvablyLacksMember('C', '_absent'));
		Assert.isFalse(index.typeProvablyLacksMember('C', '_fromA'));
	}

	/**
	 * `typeProvablyLacksMember` walks the full supertype closure, but a `Dynamic` supertype
	 * — `implements Dynamic<T>` marks dynamic field ACCESS and declares no NAMED member, and
	 * reaches `supertypes` from a `#if`-guarded openfl `DisplayObject`-style `implements
	 * Dynamic<..>` clause — is SKIPPED, not treated as an unresolvable dead end. So a
	 * subclass field is still provably absent (the openfl display-subclass rename case),
	 * while a genuinely inherited member is still found.
	 * `Dynamic` passed as the STARTING type — which happens when a caller feeds an
	 * `implements` clause's entry straight in (`implementsInterfaceDeclaringMember`) — declares
	 * no named member either, so it must not read as an unindexed, unprovable type.
	 * An ambiguous SIMPLE starting name resolves against the file the caller names — the shape
	 * every `implements`-clause consumer passes (`prefer-inline`, `trivial-getter`). `Holder`
	 * imports the `rightmenu` one, so ITS member is the inherited one.
	 */
	public function testProvablyLacksMemberResolvesAmbiguousStartFromFile(): Void {
		final index: SymbolIndex = SymbolIndex.build(ambiguousStartFiles(), plugin());
		Assert.isFalse(index.typeProvablyLacksMember('IResizable', 'inRightmenu', 'src/Holder.hx'));
		Assert.isTrue(index.typeProvablyLacksMember('IResizable', 'inCommon', 'src/Holder.hx'));
	}

	/** A file whose scope brings NEITHER same-named type in cannot pin the start — still refused. */
	public function testProvablyLacksMemberRefusesAmbiguousStartFromUnrelatedFile(): Void {
		final index: SymbolIndex = SymbolIndex.build(ambiguousStartFiles(), plugin());
		Assert.isFalse(index.typeProvablyLacksMember('IResizable', '_absent', 'src/other/Away.hx'));
	}

	/** With no context at all the original rule stands: an ambiguous simple name is unprovable. */
	public function testProvablyLacksMemberRefusesAmbiguousStartWithoutContext(): Void {
		final index: SymbolIndex = SymbolIndex.build(ambiguousStartFiles(), plugin());
		Assert.isFalse(index.typeProvablyLacksMember('IResizable', '_absent'));
	}

	/**
	 * A QUALIFIED starting name needs no file — the import-path arm pins it. This is what the
	 * `using`-conflict scan passes now that it forwards the whole module path.
	 */
	public function testProvablyLacksMemberResolvesQualifiedStartWithoutContext(): Void {
		final index: SymbolIndex = SymbolIndex.build(ambiguousStartFiles(), plugin());
		Assert.isFalse(index.typeProvablyLacksMember('rightmenu.IResizable', 'inRightmenu'));
		Assert.isTrue(index.typeProvablyLacksMember('rightmenu.IResizable', 'inCommon'));
	}

	/** A qualified name no indexed file declares is unprovable, not silently reduced to its tail. */
	public function testProvablyLacksMemberRefusesUnknownQualifiedStart(): Void {
		final index: SymbolIndex = SymbolIndex.build(ambiguousStartFiles(), plugin());
		Assert.isFalse(index.typeProvablyLacksMember('nowhere.IResizable', '_absent'));
	}

	/** A `fromFile` the index does not hold degrades to the unique-simple-name rule, not to a refusal. */
	public function testProvablyLacksMemberFallsBackForUnindexedFromFile(): Void {
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/Only.hx', source: 'class Only { private var _taken:Int; }' }], plugin());
		Assert.isTrue(index.typeProvablyLacksMember('Only', '_absent', 'src/NotIndexed.hx'));
		Assert.isFalse(index.typeProvablyLacksMember('Only', '_taken', 'src/NotIndexed.hx'));
	}

	/** `Dynamic` short-circuits before any resolution, with or without a context. */
	public function testProvablyLacksMemberAcceptsDynamicWithFileContext(): Void {
		final index: SymbolIndex = SymbolIndex.build(ambiguousStartFiles(), plugin());
		Assert.isTrue(index.typeProvablyLacksMember('Dynamic', '_absent', 'src/Holder.hx'));
	}

	/**
	 * `provablyNotSubtype` resolves each supertype edge by written path, so an ancestor whose simple
	 * name another package reuses reaches the one actually in scope. Before that, the ambiguity
	 * failed the whole proof and every occurrence attributed through it stayed unattributed.
	 */
	public function testProvablyNotSubtypeResolvesAmbiguousAncestorName(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/a/Base.hx', source: 'package a;\nclass Base {}' },
			{ file: 'src/b/Base.hx', source: 'package b;\nclass Base {}' },
			{ file: 'src/Owner.hx', source: 'import a.Base;\n\nclass Owner extends Base {}' },
			{ file: 'src/Other.hx', source: 'import b.Base;\n\nclass Other extends Base {}' }
		], plugin());
		// `Other`'s closure is {b.Base}; `Owner` is nowhere in it, and both ends resolve.
		Assert.isTrue(index.provablyNotSubtype('Other', 'Owner'));
	}

	/** A real ancestor is still found — the proof does not go blind by getting more precise. */
	public function testProvablyNotSubtypeFindsRealAncestorThroughAmbiguousName(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/a/Base.hx', source: 'package a;\nclass Base {}' },
			{ file: 'src/b/Base.hx', source: 'package b;\nclass Base {}' },
			{ file: 'src/Mid.hx', source: 'import a.Base;\n\nclass Mid extends Base {}' },
			{ file: 'src/Leaf.hx', source: 'class Leaf extends Mid {}' }
		], plugin());
		Assert.isFalse(index.provablyNotSubtype('Leaf', 'Mid'));
		Assert.isTrue(index.provablyNotSubtype('Leaf', 'Unrelated'));
	}

	/** An unresolvable supertype leaves the closure unenumerated — refused, as before. */
	public function testProvablyNotSubtypeRefusesUnresolvableAncestor(): Void {
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/Sub.hx', source: 'class Sub extends SomethingExternal {}' }], plugin());
		Assert.isFalse(index.provablyNotSubtype('Sub', 'Whatever'));
	}

	/**
	 * An ANONYMOUS STRUCTURE reaches other types only through the `> Base` extensions the closure walk
	 * already follows, and can never be a subtype of a class — so its closure IS complete. An ALIAS
	 * (`typedef A = C`) or a `@:forward` abstract reaches types through `@:from` / `@:to` edges the walk
	 * cannot see, and stays refused.
	 */
	public function testProvablyNotSubtypeEnumeratesAnonStructClosure(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Shape.hx', source: 'typedef Shape = { name:String, size:Int }' },
			{ file: 'src/Alias.hx', source: 'typedef Alias = Owner' },
			{ file: 'src/Fwd.hx', source: '@:forward\nabstract Fwd(Owner) from Owner {}' },
			{ file: 'src/Owner.hx', source: 'class Owner {}' }
		], plugin());
		Assert.isTrue(index.provablyNotSubtype('Shape', 'Owner'));
		Assert.isFalse(index.provablyNotSubtype('Alias', 'Owner'));
		Assert.isFalse(index.provablyNotSubtype('Fwd', 'Owner'));
	}

	/** A structure EXTENDING the target is a subtype — the walk follows `> Base` and refuses. */
	public function testProvablyNotSubtypeFollowsStructuralExtension(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Base.hx', source: 'typedef Base = { name:String }' },
			{ file: 'src/Ext.hx', source: 'typedef Ext = { > Base, size:Int }' }
		], plugin());
		Assert.isFalse(index.provablyNotSubtype('Ext', 'Base'));
	}

	public function testProvablyLacksMemberAcceptsDynamicAsStartingType(): Void {
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/Sub.hx', source: 'class Sub {}' }], plugin());
		Assert.isTrue(index.typeProvablyLacksMember('Dynamic', '_absent'));
	}

	public function testProvablyLacksMemberSkipsDynamicSupertype(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Base.hx', source: 'class Base extends EventDispatcher implements Dynamic<Base> { private var _taken:Int; }' },
			{ file: 'src/EventDispatcher.hx', source: 'class EventDispatcher {}' },
			{ file: 'src/Sub.hx', source: 'class Sub extends Base {}' }
		], plugin());
		// `Dynamic` is skipped, the rest of the closure resolves, and nothing declares `_absent`.
		Assert.isTrue(index.typeProvablyLacksMember('Sub', '_absent'));
		// A real inherited member (Base's `_taken`) is still found through the closure.
		Assert.isFalse(index.typeProvablyLacksMember('Sub', '_taken'));
	}

	/**
	 * A `typedef T = { > Base, … }` structural extension is a SUPERTYPE link, so a member
	 * declared on `Base` resolves through `T` — and the shorthand `name:Type` / `?name:Type`
	 * fields of an anonymous structure are indexed as members at all (the class-notation
	 * `var name:Type;` form is not the only one a typedef body may use).
	 */
	public function testAnonStructuralExtensionResolvesInheritedField(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/pkg/Base.hx', source: 'package pkg;\ntypedef Base = {\n\tcount:Int,\n\t?label:String\n}\n' },
			{
				file: 'src/pkg/Res.hx',
				source: 'package pkg;\ntypedef Res = {\n\t> Base,\n\tname:String\n}\n'
			}
		], plugin());
		Assert.equals('String', index.resolvePathFinalMemberTypeSource('src/pkg/Res.hx', 'Res', ['name']));
		Assert.equals('Int', index.resolvePathFinalMemberTypeSource('src/pkg/Res.hx', 'Res', ['count']));
		Assert.equals('String', index.resolvePathFinalMemberTypeSource('src/pkg/Res.hx', 'Res', ['label']));
	}

	/**
	 * A MODULE import carries every type the module declares into simple-name scope, not only
	 * its main one, and a ROOT-package type is in scope everywhere with no import at all — the
	 * two rules that let `import pkg.Mod;` reach `pkg.Mod.Sub` and any file reach `Array`.
	 */
	public function testModuleImportAndRootPackageInScope(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Array.hx', source: 'extern class Array<T> {\n\tpublic var length(default, null):Int;\n}\n' },
			{
				file: 'src/pkg/Mod.hx',
				source: 'package pkg;\ntypedef Sub = {\n\titems:Array<String>\n}\n\ntypedef Mod = {\n\tflag:Bool\n}\n'
			},
			{ file: 'src/app/Use.hx', source: 'package app;\nimport pkg.Mod;\nclass Use {}\n' }
		], plugin());
		// The sub-module type `Sub` resolves from `Use.hx` through the module import alone.
		Assert.equals('Array<String>', index.resolvePathFinalMemberTypeSource('src/app/Use.hx', 'Sub', ['items']));
		// … and the root-package `Array` it names resolves from `Mod.hx`'s scope with no import.
		Assert.equals('Int', index.resolvePathFinalMemberTypeSource('src/app/Use.hx', 'Sub', ['items', 'length']));
	}

	/**
	 * `Leaf` overrides `set_tag`, but the member it overrides is declared by `Mid`, NOT by the
	 * owner `Root` — two unrelated hierarchies that merely share a property name. `Mid`'s own
	 * ancestry runs through an UNINDEXED `Ext` (the openfl-through-`Sprite` shape), so the negative
	 * `provablyNotSubtype` proof cannot succeed; resolving the overridden declaration answers
	 * directly and keeps `Root`'s collapse safe.
	 */
	public function testSubtypeOverridesPropertyForeignDeclarer(): Void {
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'pkg/Root.hx',
				source: 'package pkg;\nclass Root {\n\tpublic var tag(get, set):Int;\n\tfunction get_tag():Int return 0;\n'
					+ '\tfunction set_tag(v:Int):Int return v;\n}'
			},
			{
				file: 'pkg/Mid.hx',
				source: 'package pkg;\nclass Mid extends Ext {\n\tpublic var tag(get, set):Int;\n\tfunction get_tag():Int return 1;\n'
					+ '\tfunction set_tag(v:Int):Int return v;\n}'
			},
			{
				file: 'pkg/Leaf.hx',
				source: 'package pkg;\nclass Leaf extends Mid {\n\toverride function set_tag(v:Int):Int return v;\n}'
			}
		];
		Assert.isFalse(SymbolIndex.build(files, new HaxeQueryPlugin()).subtypeOverridesProperty('Root', 'tag'));
	}

	/**
	 * The same resolution, pointing the other way: `Leaf` reaches `Root` through an intermediate
	 * that declares nothing, so the overridden declaration IS the owner's and the collapse must
	 * stay blocked.
	 */
	public function testSubtypeOverridesPropertyOwnDeclarerBlocks(): Void {
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'pkg/Root.hx',
				source: 'package pkg;\nclass Root {\n\tpublic var tag(get, set):Int;\n\tfunction get_tag():Int return 0;\n'
					+ '\tfunction set_tag(v:Int):Int return v;\n}'
			},
			{ file: 'pkg/Mid.hx', source: 'package pkg;\nclass Mid extends Root {\n\tpublic function ping():Void {}\n}' },
			{
				file: 'pkg/Leaf.hx',
				source: 'package pkg;\nclass Leaf extends Mid {\n\toverride function set_tag(v:Int):Int return v;\n}'
			}
		];
		Assert.isTrue(SymbolIndex.build(files, new HaxeQueryPlugin()).subtypeOverridesProperty('Root', 'tag'));
	}

	/**
	 * An `abstract` can never be a class's supertype — an `implements Dynamic<T>` link (openfl's
	 * `DisplayObject` carries one inside a dead `#if` branch) is not an inheritance edge and must
	 * not end the negative proof. Without this, every openfl-derived type is unprovable.
	 */
	public function testProvablyNotSubtypeIgnoresAbstractSupertypeLink(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/Root.hx', source: 'package pkg;\nclass Root {\n\tpublic function ping():Void {}\n}' },
			{ file: 'pkg/Plain.hx', source: 'package pkg;\nclass Plain {\n\tpublic function ping():Void {}\n}' },
			{ file: 'pkg/Dyn.hx', source: 'package pkg;\nabstract Dyn(Int) {\n\tpublic function new(v:Int) this = v;\n}' },
			{
				file: 'pkg/Leaf.hx',
				source: 'package pkg;\nclass Leaf extends Plain implements Dyn {\n\tpublic function ping2():Void {}\n}'
			}
		];
		Assert.isTrue(SymbolIndex.build(files, new HaxeQueryPlugin()).provablyNotSubtype('Leaf', 'Root'));
	}

	/**
	 * `Leaf`'s superclass is UNINDEXED and the only resolvable link is an interface that happens to
	 * name `tag`. Haxe grants `override` against a superclass member, never an interface's, so the
	 * interface must not be read as the overridden declaration — the unresolvable superclass keeps
	 * `Root`'s collapse blocked.
	 */
	public function testSubtypeOverridesPropertyIgnoresInterfaceDeclarer(): Void {
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'pkg/Root.hx',
				source: 'package pkg;\nclass Root {\n\tpublic var tag(get, set):Int;\n\tfunction get_tag():Int return 0;\n'
					+ '\tfunction set_tag(v:Int):Int return v;\n}'
			},
			{ file: 'pkg/ITagged.hx', source: 'package pkg;\ninterface ITagged {\n\tpublic var tag(get, set):Int;\n}' },
			{
				file: 'pkg/Leaf.hx',
				source: 'package pkg;\nclass Leaf extends Ext implements ITagged {\n\toverride function set_tag(v:Int):Int return v;\n}'
			}
		];
		Assert.isTrue(SymbolIndex.build(files, new HaxeQueryPlugin()).subtypeOverridesProperty('Root', 'tag'));
	}

	/**
	 * `memberGetter` reaches a plain instance member declared on a project-resolvable
	 * SUPERTYPE — the inherited arm's base case. `false` means "provably accessor-less",
	 * which is the direction `TypeResolver.isPlainFieldRead` acts on.
	 */
	public function testMemberGetterInheritedPlainField(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Base.hx', source: 'class Base { public var f:Int; }' },
			{ file: 'src/Sub.hx', source: 'class Sub extends Base {}' }
		], plugin());
		Assert.equals(false, index.memberGetter('Sub', 'f'), 'an inherited plain field is accessor-less');
	}

	/**
	 * An inherited GETTER property still wins: reading it runs code, so the walk
	 * returns `true` from the declaring supertype.
	 */
	public function testMemberGetterInheritedGetter(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Base.hx', source: 'class Base { public var f(get, never):Int; }' },
			{ file: 'src/Sub.hx', source: 'class Sub extends Base {}' }
		], plugin());
		Assert.equals(true, index.memberGetter('Sub', 'f'), 'an inherited getter property runs code on read');
	}

	/**
	 * The canary shape: a member declared on a GENERIC supertype, reached through an
	 * `extends Base<Int>` clause. The projection drops the type arguments, so
	 * `supertypesRaw` carries the bare nominal and the link resolves.
	 */
	public function testMemberGetterGenericSupertypeField(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Base.hx', source: 'class Base<T> { public final d:T; }' },
			{ file: 'src/Sub.hx', source: 'class Sub extends Base<Int> {}' }
		], plugin());
		Assert.equals(false, index.memberGetter('Sub', 'd'), 'no type-argument substitution needed, accessor shape only');
	}

	/** The walk is transitive — a member three levels up still resolves. */
	public function testMemberGetterTransitiveInheritance(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Base.hx', source: 'class Base { public var f:Int; }' },
			{ file: 'src/Mid.hx', source: 'class Mid extends Base {}' },
			{ file: 'src/Leaf.hx', source: 'class Leaf extends Mid {}' }
		], plugin());
		Assert.equals(false, index.memberGetter('Leaf', 'f'), 'a two-hop inherited plain field resolves');
	}

	/** An `implements` link is walked like an `extends` one — an interface-declared getter is reached. */
	public function testMemberGetterInterfaceGetter(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/ITagged.hx', source: 'interface ITagged { public var f(get, never):Int; }' },
			{ file: 'src/Sub.hx', source: 'class Sub implements ITagged {}' }
		], plugin());
		Assert.equals(true, index.memberGetter('Sub', 'f'), 'a getter declared on an implemented interface is reached');
	}

	/**
	 * Statics are NOT inherited in Haxe: a supertype's `static f` never answers a
	 * subtype's instance access, so the inherited arm skips it and the subtype's
	 * answer stays unknown. The ROOT arm is untouched — `Base` itself still answers
	 * `false` for the very same member.
	 */
	public function testMemberGetterStaticNotInherited(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Base.hx', source: 'class Base { public static var f:Int; }' },
			{ file: 'src/Sub.hx', source: 'class Sub extends Base {}' }
		], plugin());
		Assert.isNull(index.memberGetter('Sub', 'f'), 'a supertype static is not part of the subtype instance namespace');
		Assert.equals(false, index.memberGetter('Base', 'f'), 'root arm unchanged: the static gate is inert at the root');
	}

	/**
	 * An out-of-scope supertype link resolves to nothing (`resolveTypeRef` is
	 * import-aware), so that branch simply ends — the member IS indexed, as the
	 * direct query on `Base` proves, and is still not folded in.
	 */
	public function testMemberGetterUnresolvedSupertypeLink(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/other/Base.hx', source: 'package other;\nclass Base { public var f:Int; }' },
			{ file: 'src/pkg/Sub.hx', source: 'package pkg;\nclass Sub extends Base {}' }
		], plugin());
		Assert.isNull(index.memberGetter('Sub', 'f'), 'an out-of-scope supertype link ends the branch');
		Assert.equals(false, index.memberGetter('Base', 'f'), 'the member itself is indexed — the null came from resolution');
	}

	/**
	 * Two same-simple-named `Base` declarations are both in `Sub`'s package, so the
	 * link is AMBIGUOUS and resolves to neither — a namesake's member can never be
	 * folded in. The ROOT entry stays simple-name unioned, as it always was.
	 */
	public function testMemberGetterAmbiguousSupertypeLink(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/pkg/Base.hx', source: 'package pkg;\nclass Base { public var f:Int; }' },
			{ file: 'src/pkg/Other.hx', source: 'package pkg;\nclass Other {}\nclass Base { public var f:Int; }' },
			{ file: 'src/pkg/Sub.hx', source: 'package pkg;\nclass Sub extends Base {}' }
		], plugin());
		Assert.isNull(index.memberGetter('Sub', 'f'), 'an ambiguous supertype link resolves to nothing');
		Assert.equals(false, index.memberGetter('Base', 'f'), 'the root entry stays simple-name unioned');
	}

	/**
	 * A `@:build` macro on an INHERITED declaring type may rewrite that type's own
	 * field into a property, so its accessor shape is unreadable from source — the
	 * inherited arm contributes no `false` there. The ROOT arm keeps shipped
	 * behaviour: querying `Base` directly still answers `false`.
	 */
	public function testMemberGetterBuildOnInheritedDeclarer(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Base.hx', source: '@:build(M.gen())\nclass Base { public var f:Int; }' },
			{ file: 'src/Sub.hx', source: 'class Sub extends Base {}' }
		], plugin());
		Assert.isNull(index.memberGetter('Sub', 'f'), '@:build may turn the inherited field into a property');
		Assert.equals(false, index.memberGetter('Base', 'f'), 'root arm unchanged: a @:build root still answers false');
	}

	/** An inheritance cycle terminates — `seen` ends the re-entered branch as unknown. */
	public function testMemberGetterInheritanceCycleTerminates(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/A.hx', source: 'class A extends B {}' },
			{ file: 'src/B.hx', source: 'class B extends A {}' }
		], plugin());
		Assert.isNull(index.memberGetter('A', 'f'), 'a cycle ends its branch instead of recursing forever');
	}

	/**
	 * `@:autoBuild` on an ancestor ABOVE the declaring type generates into every DESCENDANT, so
	 * it can rewrite `Base`'s own `f` into a property — the identical hazard the `hasBuild` gate
	 * refuses. The inherited arm's `false` is downgraded to null. The ROOT arm keeps shipped
	 * behaviour: querying `Base` directly still answers `false`, autoBuild ancestor and all.
	 */
	public function testMemberGetterAutoBuildAncestorAboveDeclarer(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Marker.hx', source: '@:autoBuild(M.gen())\ninterface Marker {}' },
			{ file: 'src/Base.hx', source: 'class Base implements Marker { public var f:Int = 1; }' },
			{ file: 'src/Sub.hx', source: 'class Sub extends Base {}' }
		], plugin());
		Assert.isNull(index.memberGetter('Sub', 'f'), '@:autoBuild above the declarer may have rewritten the field');
		Assert.equals(false, index.memberGetter('Base', 'f'), 'root arm unchanged: the autoBuild gate is inert at the root');
	}

	/**
	 * A declaration reached while climbing is CONCLUSIVE — Haxe forbids redeclaring an inherited
	 * field, so `Base`'s `@:build`-shadowed `f` ends the walk at null rather than falling through
	 * to the interface's plain one. Without the short-circuit `I` would contribute a `false`.
	 */
	public function testMemberGetterDeclarationStopsTheClimb(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/I.hx', source: 'interface I { public var f:Int; }' },
			{ file: 'src/Base.hx', source: '@:build(M.gen())\nclass Base implements I { public var f:Int; }' },
			{ file: 'src/Sub.hx', source: 'class Sub extends Base {}' }
		], plugin());
		Assert.isNull(index.memberGetter('Sub', 'f'), 'the @:build declaration ends the climb — the interface never answers');
	}

	/**
	 * A `static` skipped by the inherited arm is deliberately NOT a declaration, so the climb continues
	 * past it and reaches the instance member above. The plain-`f` half alone cannot see the gate (both
	 * answers are `false`); the getter half is what discriminates — without the gate `Mid`'s static
	 * would answer `false` and `Top`'s getter would never be reached.
	 */
	public function testMemberGetterClimbsPastSkippedStatic(): Void {
		final plain: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Top.hx', source: 'class Top { public var f:Int; }' },
			{ file: 'src/Mid.hx', source: 'class Mid extends Top { public static var f:Int; }' },
			{ file: 'src/Leaf.hx', source: 'class Leaf extends Mid {}' }
		], plugin());
		Assert.equals(false, plain.memberGetter('Leaf', 'f'), 'a skipped static does not stop the climb');
		final getter: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Top.hx', source: 'class Top { public var f(get, never):Int; }' },
			{ file: 'src/Mid.hx', source: 'class Mid extends Top { public static var f:Int; }' },
			{ file: 'src/Leaf.hx', source: 'class Leaf extends Mid {}' }
		], plugin());
		Assert.equals(true, getter.memberGetter('Leaf', 'f'), 'the instance getter above the static still answers');
	}

	/**
	 * The `@:autoBuild` carrier IS in the index but is not import-visible from the type that
	 * declares the field (`o.Marker` from `p.Base`), so `resolveTypeRef` ends that link — while the
	 * compiler still applies the macro. A skip would FAIL OPEN here: in this scan a hit means
	 * REFUSE, the opposite miss-direction from the evidence climb, so it falls back to a
	 * project-wide UNIQUE simple-name lookup and reaches the carrier anyway.
	 */
	public function testMemberGetterAutoBuildCarrierNotImportVisible(): Void {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/o/Marker.hx', source: 'package o;\n@:autoBuild(M.gen())\ninterface Marker {}' },
			{ file: 'src/p/Base.hx', source: 'package p;\nclass Base implements Marker { public var f:Int = 1; }' },
			{ file: 'src/p/Sub.hx', source: 'package p;\nclass Sub extends Base {}' }
		], plugin());
		Assert.isNull(index.memberGetter('Sub', 'f'), 'a non-import-visible @:autoBuild carrier is still reached');
	}

	/**
	 * That fallback is a UNIQUE simple-name lookup, never a blanket refusal on an unresolvable
	 * link. A genuinely EXTERNAL supertype (0 in-index declarers — the `Sprite` shape the real
	 * `unused-local` fix depends on) and an AMBIGUOUS simple name (2+ declarers) both leave the
	 * plain inherited answer intact.
	 */
	public function testMemberGetterUnresolvableSupertypeDoesNotRefuse(): Void {
		final external: SymbolIndex = SymbolIndex.build([
			{ file: 'src/Base.hx', source: 'class Base extends Sprite { public var f:Int; }' },
			{ file: 'src/Sub.hx', source: 'class Sub extends Base {}' }
		], plugin());
		Assert.equals(false, external.memberGetter('Sub', 'f'), 'an external supertype is not evidence of a macro');
		final ambiguous: SymbolIndex = SymbolIndex.build([
			{ file: 'src/x/Marker.hx', source: 'package x;\ninterface Marker {}' },
			{ file: 'src/y/Marker.hx', source: 'package y;\n@:autoBuild(M.gen())\ninterface Marker {}' },
			{ file: 'src/p/Base.hx', source: 'package p;\nclass Base implements Marker { public var f:Int = 1; }' },
			{ file: 'src/p/Sub.hx', source: 'package p;\nclass Sub extends Base {}' }
		], plugin());
		Assert.equals(false, ambiguous.memberGetter('Sub', 'f'), 'an ambiguous simple name resolves to neither');
	}

	/**
	 * `overrideFamilyOf` — the ACTIONABLE counterpart of `subtypeDeclaresMember`. A proven subtype
	 * that redeclares the member is family; an unrelated type merely sharing the name is not; and an
	 * implementation of an interface method is family even though it carries no `override` keyword.
	 */
	public function testOverrideFamilyOfProvenMembers(): Void {
		final base: String = 'package pkg;\nclass B {\n\tpublic function draw():Void {}\n}';
		final sub: String = 'package pkg;\nclass S extends B {\n\toverride public function draw():Void {}\n}';
		final iface: String = 'package pkg;\ninterface I {\n\tpublic function draw():Void;\n}';
		final impl: String = 'package pkg;\nclass Impl implements I {\n\tpublic function draw():Void {}\n}';
		final alien: String = 'package pkg;\nclass Alien {\n\tpublic function draw():Void {}\n}';
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'pkg/B.hx', source: base },
			{ file: 'pkg/S.hx', source: sub },
			{ file: 'pkg/I.hx', source: iface },
			{ file: 'pkg/Impl.hx', source: impl },
			{ file: 'pkg/Alien.hx', source: alien }
		], plugin());
		final family: Null<Array<OverrideFamilyMember>> = index.overrideFamilyOf('B', 'draw');
		Assert.notNull(family);
		if (family == null) return;
		// `Alien` declares the same name and is provably unrelated, so it must NOT be an edit target.
		Assert.equals(1, family.length);
		Assert.equals('S', family[0].typeName);
		Assert.equals('pkg/S.hx', family[0].file);
		// The offset addresses the override's own declaration — the cursor a rename takes.
		Assert.equals('function draw', sub.substr(family[0].declFrom, 13));
		// No `override` keyword on an interface implementation, and it is still family.
		final ifaceFamily: Null<Array<OverrideFamilyMember>> = index.overrideFamilyOf('I', 'draw');
		Assert.notNull(ifaceFamily);
		if (ifaceFamily != null) Assert.equals('Impl', ifaceFamily.length == 1 ? ifaceFamily[0].typeName : '<${ifaceFamily.length}>');
	}

	/**
	 * A same-named declaration on a type whose ancestry does NOT resolve is neither proven family nor
	 * proven unrelated, so the whole answer is `null` — the caller must refuse rather than rename a
	 * partial family. `[]` stays the answer when nothing else declares the member at all.
	 */
	public function testOverrideFamilyOfRefusesUnprovable(): Void {
		final base: String = 'package pkg;\nclass B {\n\tpublic function draw():Void {}\n}';
		final foreign: String = 'package pkg;\nclass F extends Absent {\n\toverride public function draw():Void {}\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/B.hx', source: base },
			{ file: 'pkg/F.hx', source: foreign }
		];
		Assert.isNull(SymbolIndex.build(files, plugin()).overrideFamilyOf('B', 'draw'));
		// The SAME unresolvable type WITHOUT the override modifier cannot be `B`'s override at all —
		// Haxe rejects a bare redeclaration under a plain-class owner — so it must veto nothing. Without
		// this exclusion the refusal is near-universal in a framework tree, where no class's ancestry
		// resolves to the end.
		final bare: String = 'package pkg;\nclass F extends Absent {\n\tpublic function draw():Void {}\n}';
		final bareFamily: Null<Array<OverrideFamilyMember>> = SymbolIndex.build([
			{ file: 'pkg/B.hx', source: base },
			{ file: 'pkg/F.hx', source: bare }
		], plugin()).overrideFamilyOf('B', 'draw');
		Assert.notNull(bareFamily);
		if (bareFamily != null) Assert.equals(0, bareFamily.length);
		// Alone, the same base has an EMPTY family — `null` above is the unprovable type talking.
		final solo: Null<Array<OverrideFamilyMember>> = SymbolIndex.build([files[0]], plugin()).overrideFamilyOf('B', 'draw');
		Assert.notNull(solo);
		if (solo != null) Assert.equals(0, solo.length);
	}

	/**
	 * The two facts a `using` STATIC EXTENSION needs beyond an ordinary member lookup: the type
	 * its FIRST PARAMETER accepts (`firstParamTypeSource`) and, joined with the receiver, the
	 * return it hands back (`extensionReturnNominal`).
	 */
	public function testStaticExtensionSignature(): Void {
		final index: SymbolIndex = SymbolIndex.build(extensionFiles(), plugin());

		Assert.equals('String', memberOf(fileInfoOf(index, 'Ext.hx').types[0], 'tag').firstParamTypeSource);
		Assert.isNull(memberOf(fileInfoOf(index, 'Ext.hx').types[0], 'bare').firstParamTypeSource);

		Assert.equals('Int', index.extensionReturnNominal('Ext', 'tag', 'String'));
		// The first parameter must ACCEPT the receiver, not merely exist.
		Assert.isNull(index.extensionReturnNominal('Ext', 'ints', 'String'));
		// A parameterless static is not an extension at all, and neither is an instance method.
		Assert.isNull(index.extensionReturnNominal('Ext', 'bare', 'String'));
		Assert.isNull(index.extensionReturnNominal('Inst', 'tag', 'String'));
		// An unannotated return names no type, so it proves nothing.
		Assert.isNull(index.extensionReturnNominal('Ext', 'inferred', 'String'));
		// A SUBTYPE of the first parameter's type is accepted; an unrelated receiver is not.
		Assert.equals('Base', index.extensionReturnNominal('BaseExt', 'id', 'Sub'));
		Assert.isNull(index.extensionReturnNominal('BaseExt', 'id', 'String'));
		// A module the index does not hold answers nothing.
		Assert.isNull(index.extensionReturnNominal('Missing', 'tag', 'String'));
	}

	/** The static-extension fixture set: one module of statics, one instance host, and a two-level `extends` pair. */
	private function extensionFiles(): Array<{ file: String, source: String }> {
		return [
			{
				file: 'Ext.hx',
				source: 'class Ext {\n\tpublic static function tag(s:String):Int return 0;\n\n'
					+ '\tpublic static function ints(i:Int):String return null;\n\n'
					+ '\tpublic static function bare():Int return 0;\n\n\tpublic static function inferred(s:String) return 0;\n}'
			},
			{ file: 'Inst.hx', source: 'class Inst {\n\tpublic function tag(s:String):Int return 0;\n}' },
			{ file: 'Base.hx', source: 'class Base {}' },
			{ file: 'Sub.hx', source: 'class Sub extends Base {}' },
			{ file: 'BaseExt.hx', source: 'class BaseExt {\n\tpublic static function id(b:Base):Base return b;\n}' }
		];
	}

	/** Build a one-type index from `source` and assert its single declaration's type-parameter arity and names. */
	private function assertHeaderParams(source: String, arity: Int, names: Array<String>): Void {
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/H.hx', source: source }], plugin());
		final decl: TypeDeclInfo = fileInfoOf(index, 'src/H.hx').types[0];
		Assert.equals(arity, decl.typeParamArity, 'arity of $source');
		Assert.equals(names.join(','), decl.typeParamNames.join(','), 'names of $source');
	}

	/** The named member of `type` — the fixtures all declare each name exactly once. */
	private function memberOf(type: TypeDeclInfo, name: String): MemberInfo {
		final found: Null<MemberInfo> = type.members.find(m -> m.name == name);
		Assert.notNull(found);
		return (found: MemberInfo);
	}

	/** Assert a member's kind and its three modifier-derived flags in one line per member. */
	private function assertFlags(member: MemberInfo, kind: String, isStatic: Bool, isInline: Bool, guarded: Bool): Void {
		Assert.equals(kind, member.kind, 'kind of ${member.name}');
		Assert.equals(isStatic, member.isStatic, 'isStatic of ${member.name}');
		Assert.equals(isInline, member.isInline, 'isInline of ${member.name}');
		Assert.equals(guarded, member.guarded, 'guarded of ${member.name}');
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

	/**
	 * TM's real collision: two `IResizable` interfaces in different packages, and a class whose
	 * base implements the SAME-PACKAGE one with no import. Each carries a distinctly named member
	 * so a fixture can tell which one the closure actually reached.
	 * The same collision seen from the STARTING side: nothing extends anything, the caller names
	 * `IResizable` directly, and `Holder` imports the `rightmenu` one while `other/Away.hx`
	 * imports neither.
	 */
	private static function ambiguousStartFiles(): Array<{ file: String, source: String }> {
		return [
			{ file: 'src/common/IResizable.hx', source: 'package common;\ninterface IResizable { function inCommon():Void; }' },
			{
				file: 'src/rightmenu/IResizable.hx',
				source: 'package rightmenu;\ninterface IResizable { function inRightmenu():Void; }'
			},
			{ file: 'src/Holder.hx', source: 'import rightmenu.IResizable;\n\nclass Holder {}' },
			{ file: 'src/other/Away.hx', source: 'package other;\n\nclass Away {}' }
		];
	}

	private static function ambiguousInterfaceFiles(): Array<{ file: String, source: String }> {
		return [
			{ file: 'src/common/IResizable.hx', source: 'package common;\ninterface IResizable { function inCommon():Void; }' },
			{
				file: 'src/rightmenu/IResizable.hx',
				source: 'package rightmenu;\ninterface IResizable { function inRightmenu():Void; }'
			},
			{
				file: 'src/common/Resizable.hx',
				source: 'package common;\nclass Resizable implements IResizable { public function inCommon():Void {} }'
			},
			{ file: 'src/Sub.hx', source: 'import common.Resizable;\nclass Sub extends Resizable { private var _own:Int; }' }
		];
	}

}
