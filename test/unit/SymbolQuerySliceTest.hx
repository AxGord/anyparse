package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolQuery;
import anyparse.query.SymbolQuery.SymbolRow;

using Lambda;

/**
 * `SymbolQuery` — the CLI-facing reporting layer over `SymbolIndex`
 * (`apq symbols` / `apq importers`). Each test drives an IN-MEMORY
 * multi-file fixture (no disk) through a real `HaxeQueryPlugin` and
 * asserts the formatted symbol rows (qualified import path, decl kind,
 * resolved 1-indexed line:col), the `--kind` filter, the importer
 * listing, and the skip-parse exclusion carried over from `SymbolIndex`.
 */
class SymbolQuerySliceTest extends Test {

	/**
	 * `symbols` lists every top-level type decl across the files, in
	 * input-file order then source order, with the import-path qualified
	 * name (module for a main type, `module.Sub` for a sub-type), the
	 * grammar kind, and the decl's resolved coordinate.
	 */
	public function testSymbolsListing():Void {
		final files = [
			{file: 'src/pkg/A.hx', source: 'package pkg;\nclass A {}\ntypedef Helper = {};'},
			{file: 'src/pkg/B.hx', source: 'package pkg;\nclass B {}'},
		];
		final rows:Array<SymbolRow> = SymbolQuery.symbols(files, plugin());

		// Three decls total, in file order then source order.
		Assert.equals(3, rows.length);
		Assert.equals('pkg.A', rows[0].qualified);
		Assert.equals('pkg.A.Helper', rows[1].qualified);
		Assert.equals('pkg.B', rows[2].qualified);

		// Main-type A: ClassDecl at line 2 col 1 of A.hx.
		final a:SymbolRow = rows[0];
		Assert.equals('A', a.name);
		Assert.equals('ClassDecl', a.kind);
		Assert.equals('src/pkg/A.hx', a.file);
		Assert.equals(2, a.line);
		Assert.equals(1, a.col);

		// Sub-type Helper: TypedefDecl on line 3, qualified as module.Sub.
		final h:SymbolRow = rows[1];
		Assert.equals('TypedefDecl', h.kind);
		Assert.equals(3, h.line);
	}

	/** `--kind` keeps only decls of one grammar kind. */
	public function testKindFilter():Void {
		final files = [
			{file: 'src/pkg/A.hx', source: 'package pkg;\nclass A {}\ntypedef Helper = {};\ninterface I {}'},
		];
		final classes:Array<SymbolRow> = SymbolQuery.symbols(files, plugin(), 'ClassDecl');
		Assert.equals(1, classes.length);
		Assert.equals('pkg.A', classes[0].qualified);

		final typedefs:Array<SymbolRow> = SymbolQuery.symbols(files, plugin(), 'TypedefDecl');
		Assert.equals(1, typedefs.length);
		Assert.equals('pkg.A.Helper', typedefs[0].qualified);
	}

	/**
	 * `importers` lists the files importing a module by its main path
	 * AND by a sub-type path; an unrelated import is excluded.
	 */
	public function testImporters():Void {
		final files = [
			{file: 'src/pkg/Refs.hx', source: 'package pkg;\nclass Refs {}\ntypedef RefHit = Int;'},
			{file: 'src/pkg/UsesModule.hx', source: 'package pkg;\nimport pkg.Refs;\nclass UsesModule {}'},
			{file: 'src/pkg/UsesSub.hx', source: 'package pkg;\nimport pkg.Refs.RefHit;\nclass UsesSub {}'},
			{file: 'src/pkg/Unrelated.hx', source: 'package pkg;\nimport pkg.Other;\nclass Unrelated {}'},
		];
		final hits:Array<String> = SymbolQuery.importers(files, plugin(), 'pkg.Refs');
		Assert.equals(2, hits.length);
		Assert.isTrue(hits.contains('src/pkg/UsesModule.hx'));
		Assert.isTrue(hits.contains('src/pkg/UsesSub.hx'));
		Assert.isFalse(hits.contains('src/pkg/Unrelated.hx'));
	}

	/** `formatSymbolRow` renders `qualified<TAB>kind<TAB>file:line:col`. */
	public function testFormatSymbolRow():Void {
		final row:SymbolRow = {qualified: 'pkg.A', name: 'A', kind: 'ClassDecl', file: 'src/pkg/A.hx', line: 2, col: 1};
		Assert.equals('pkg.A\tClassDecl\tsrc/pkg/A.hx:2:1', SymbolQuery.formatSymbolRow(row));
	}

	/**
	 * An unparseable file is excluded from the listing and `symbols`
	 * does NOT throw — the skip-parse contract inherited from
	 * `SymbolIndex.build`.
	 */
	public function testSkipParseExcluded():Void {
		final files = [
			{file: 'src/pkg/Good.hx', source: 'package pkg;\nclass Good {}'},
			{file: 'src/pkg/Bad.hx', source: 'package pkg;\nclass Bad { function f() { '},
		];
		final rows:Array<SymbolRow> = SymbolQuery.symbols(files, plugin());
		Assert.equals(1, rows.length);
		Assert.equals('pkg.Good', rows[0].qualified);
	}

	/**
	 * `declares` returns the declaration site(s) of one named type by its
	 * simple name OR its fully qualified import path, and an empty result
	 * when the type is not declared in the scope.
	 */
	public function testDeclares():Void {
		final files = [
			{file: 'src/pkg/A.hx', source: 'package pkg;\nclass A {}\ntypedef Helper = {};'},
			{file: 'src/pkg/B.hx', source: 'package pkg;\nclass B {}'},
		];
		// Simple-name match resolves the unique decl.
		final byName:Array<SymbolRow> = SymbolQuery.declares(files, plugin(), 'A');
		Assert.equals(1, byName.length);
		Assert.equals('pkg.A', byName[0].qualified);
		Assert.equals(2, byName[0].line);

		// Fully qualified path matches the same sub-type the symbols listing uses.
		final byQualified:Array<SymbolRow> = SymbolQuery.declares(files, plugin(), 'pkg.A.Helper');
		Assert.equals(1, byQualified.length);
		Assert.equals('TypedefDecl', byQualified[0].kind);

		// A name not declared in the scope yields no rows (caller reports it).
		Assert.equals(0, SymbolQuery.declares(files, plugin(), 'Missing').length);
	}

	/** Two decls of the same simple name across files are an ambiguity — both rows returned. */
	public function testDeclaresAmbiguous():Void {
		final files = [
			{file: 'src/one/Dup.hx', source: 'package one;\nclass Dup {}'},
			{file: 'src/two/Dup.hx', source: 'package two;\nclass Dup {}'},
		];
		final rows:Array<SymbolRow> = SymbolQuery.declares(files, plugin(), 'Dup');
		Assert.equals(2, rows.length);
		Assert.equals('one.Dup', rows[0].qualified);
		Assert.equals('two.Dup', rows[1].qualified);
	}

	private static function plugin():HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}
}
