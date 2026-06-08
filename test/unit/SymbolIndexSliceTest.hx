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
	public function testModuleOf():Void {
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
	public function testFileInfoExtraction():Void {
		final source:String =
			'package pkg.sub;\n'
			+ 'import other.Thing;\n'
			+ 'import other.Mod.Sub as Aliased;\n'
			+ 'import other.deep.*;\n'
			+ 'using other.Ext;\n'
			+ 'class A {}\n'
			+ 'typedef Helper = {};\n';
		final index:SymbolIndex = SymbolIndex.build([{file: 'src/pkg/sub/A.hx', source: source}], plugin());

		final info:Null<FileInfo> = index.fileInfo('src/pkg/sub/A.hx');
		Assert.notNull(info);
		final fi:FileInfo = (info : FileInfo);
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
		final a:Null<TypeDeclInfo> = fi.types.find(t -> t.name == 'A');
		Assert.notNull(a);
		Assert.equals('ClassDecl', (a : TypeDeclInfo).kind);
		Assert.isTrue((a : TypeDeclInfo).isMain);
		final helper:Null<TypeDeclInfo> = fi.types.find(t -> t.name == 'Helper');
		Assert.notNull(helper);
		Assert.equals('TypedefDecl', (helper : TypeDeclInfo).kind);
		Assert.isFalse((helper : TypeDeclInfo).isMain);
	}

	/**
	 * A file with no `package;` declaration has an empty package and a
	 * module path equal to the file basename (the root package).
	 */
	public function testRootPackageModule():Void {
		final index:SymbolIndex = SymbolIndex.build([{file: 'Root.hx', source: 'class Root {}'}], plugin());
		final info:Null<FileInfo> = index.fileInfo('Root.hx');
		Assert.notNull(info);
		final fi:FileInfo = (info : FileInfo);
		Assert.equals('', fi.pkg);
		Assert.equals('Root', fi.module);
		Assert.isTrue(fi.types[0].isMain);
	}

	/** `declaringFiles` reports 0 / 1 / many declarers of a type name. */
	public function testDeclaringFilesCount():Void {
		final index:SymbolIndex = SymbolIndex.build([
			{file: 'src/pkg/A.hx', source: 'package pkg;\nclass A {}'},
			{file: 'src/pkg/B.hx', source: 'package pkg;\nclass B {}'},
			{file: 'src/pkg/Dup.hx', source: 'package pkg;\nclass Dup {}\ntypedef A = Int;'},
		], plugin());

		// Zero declarers.
		Assert.equals(0, index.declaringFiles('Missing').length);
		// `B` declared in exactly one file.
		final b:Array<FileInfo> = index.declaringFiles('B');
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
	public function testImportPathOf():Void {
		final index:SymbolIndex = SymbolIndex.build([
			{file: 'src/pkg/Rename.hx', source: 'package pkg;\nclass Rename {}\ntypedef RenameResult = Int;'},
			{file: 'src/pkg/Dup.hx', source: 'package pkg;\nclass Dup {}\ntypedef Rename = Int;'},
			{file: 'src/pkg/Solo.hx', source: 'package pkg;\nclass Solo {}'},
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
	public function testFilesImportingModule():Void {
		final index:SymbolIndex = SymbolIndex.build([
			{file: 'src/pkg/Refs.hx', source: 'package pkg;\nclass Refs {}\ntypedef RefHit = Int;'},
			{file: 'src/pkg/UsesModule.hx', source: 'package pkg;\nimport pkg.Refs;\nclass UsesModule {}'},
			{file: 'src/pkg/UsesSub.hx', source: 'package pkg;\nimport pkg.Refs.RefHit;\nclass UsesSub {}'},
			{file: 'src/pkg/UsesUsing.hx', source: 'package pkg;\nusing pkg.Refs;\nclass UsesUsing {}'},
			{file: 'src/pkg/Unrelated.hx', source: 'package pkg;\nimport pkg.Other;\nclass Unrelated {}'},
		], plugin());

		final importers:Array<String> = index.filesImportingModule('pkg.Refs').map(f -> f.file);
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
	public function testSkipParseExcluded():Void {
		final index:SymbolIndex = SymbolIndex.build([
			{file: 'src/pkg/Good.hx', source: 'package pkg;\nclass Good {}'},
			// Unbalanced braces — the parser throws.
			{file: 'src/pkg/Bad.hx', source: 'package pkg;\nclass Bad { function f() { '},
		], plugin());

		final skipped:Array<String> = index.skippedFiles();
		Assert.equals(1, skipped.length);
		Assert.equals('src/pkg/Bad.hx', skipped[0]);

		// The bad file is excluded; only the good file is indexed.
		Assert.equals(1, index.allFiles().length);
		Assert.notNull(index.fileInfo('src/pkg/Good.hx'));
		Assert.isNull(index.fileInfo('src/pkg/Bad.hx'));
	}

	private function assertImport(imp:ImportInfo, raw:String, kind:ImportKind, alias:Null<String>):Void {
		Assert.equals(raw, imp.raw);
		Assert.isTrue(imp.kind == kind);
		Assert.equals(alias, imp.alias);
		Assert.notNull(imp.span);
	}

	private static function plugin():HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}
}
