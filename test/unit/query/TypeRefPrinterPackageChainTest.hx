package unit.query;

import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeRefPrinter;
import unit.CheckFixture;

/**
 * The printer's PACKAGE-CHAIN reading: a bare name reaches this file's package, then each enclosing package, then the
 * root, nearest first and through a module's main type only — and a transparent root alias (`Map` for `haxe.ds.Map`)
 * is the same type as its target, not a shadow of it.
 */
class TypeRefPrinterPackageChainTest extends Test {

	/** The std's own shape: a root `Map` typedef re-pointing at the `haxe.ds.Map` abstract. */
	private static final STD_MAP: Array<{ file: String, source: String }> = [
		{ file: 'Map.hx', source: 'typedef Map<K, V> = haxe.ds.Map<K, V>;\n' },
		{ file: 'haxe/ds/Map.hx', source: 'package haxe.ds;\n\nabstract Map<K, V>(Dynamic) {}\n' }
	];

	@:pin('control')
	@:killer('M-PRINTER-PACKAGE-CHAIN-BLIND')
	public function testEnclosingPackageMainTypePrintsShort(): Void {
		final index: SymbolIndex = indexOf([{ file: 'pkg/Entity.hx', source: 'package pkg;\n\nclass Entity<T> {}\n' }]);
		final p: TypeRefPrinter = printerWith('package pkg.sub;\n\nclass C {}\n', index, 'pkg/sub/C.hx');
		Assert.equals('Entity<String>', p.printTypeExpr('pkg.Entity<String>'));
		Assert.isFalse(p.hasPendingImports());
	}

	@:pin('control')
	@:killer('M-PRINTER-PACKAGE-CHAIN-FIRST-HIT')
	public function testNearerPackageTypeKeepsTheEnclosingPathQualified(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/Entity.hx', source: 'package pkg;\n\nclass Entity<T> {}\n' },
			{ file: 'pkg/sub/Entity.hx', source: 'package pkg.sub;\n\nclass Entity<T> {}\n' }
		]);
		final file: String = 'package pkg.sub.deep;\n\nclass C {}\n';
		// The bare name means the NEARER `pkg.sub.Entity`; an import, which outranks the package chain, is the short route left.
		Assert.equals('import pkg.Entity', spelled(printerWith(file, index, 'pkg/sub/deep/C.hx'), 'pkg.Entity'));
		Assert.equals('Entity', spelled(printerWith(file, index, 'pkg/sub/deep/C.hx'), 'pkg.sub.Entity'));
	}

	/** An import the printer promised is an import of the file once spliced: it outranks the package chain for every later print. */
	@:pin('control')
	@:killer('M-PRINTER-PENDING-IMPORT-BLIND')
	public function testAPendingImportOutranksThePackageChain(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/Entity.hx', source: 'package pkg;\n\nclass Entity<T> {}\n' },
			{ file: 'pkg/sub/Entity.hx', source: 'package pkg.sub;\n\nclass Entity<T> {}\n' }
		]);
		final p: TypeRefPrinter = printerWith('package pkg.sub.deep;\n\nclass C {}\n', index, 'pkg/sub/deep/C.hx');
		Assert.equals('import pkg.Entity', spelled(p, 'pkg.Entity'));
		Assert.equals('pkg.sub.Entity', spelled(p, 'pkg.sub.Entity'));
	}

	public function testSecondaryTypeOfAnEnclosingPackageBindsNothing(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/Entity.hx', source: 'package pkg;\n\nclass Entity<T> {}\n' },
			{ file: 'pkg/sub/Mod.hx', source: 'package pkg.sub;\n\nclass Mod {}\n\nclass Entity<T> {}\n' }
		]);
		// A secondary type binds no bare name outside its module, in its own package too: the chain goes on to `pkg.Entity`.
		Assert.equals('Entity', spelled(printerWith('package pkg.sub;\n\nclass C {}\n', index, 'pkg/sub/C.hx'), 'pkg.Entity'));
		Assert.equals('Entity', spelled(printerWith('package pkg.sub.deep;\n\nclass C {}\n', index, 'pkg/sub/deep/C.hx'), 'pkg.Entity'));
	}

	/** A root module's SECONDARY type is not visible by its bare name (4.3.7: `Type not found : ValueType`); an import is. */
	@:pin('control')
	@:killer('M-RESOLVE-BARE-SECONDARY-ROOT')
	public function testASecondaryTypeOfARootModuleNeedsAnImport(): Void {
		final index: SymbolIndex = indexOf([{ file: 'Type.hx', source: 'class Type {}\n\nenum ValueType {\n\tTNull;\n}\n' }]);
		Assert.equals('import Type.ValueType', spelled(printerWith('package unit;\n\nclass C {}\n', index, 'unit/C.hx'), 'Type.ValueType'));
	}

	/** A `using` imports its module too, so the module's main type is already visible by its bare name. */
	public function testAUsingMakesItsModulesTypeVisible(): Void {
		final index: SymbolIndex = indexOf([{ file: 'u/Tools.hx', source: 'package u;\n\nclass Tools {}\n' }]);
		Assert.equals('Tools', spelled(printerWith('package app;\n\nusing u.Tools;\n\nclass C {}\n', index, 'app/C.hx'), 'u.Tools'));
	}

	@:pin('control')
	@:killer('M-RESOLVE-BARE-GUARDED-DECL')
	public function testGuardedEnclosingTypeProvesNothing(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'q/Thing.hx', source: 'package q;\n\n#if never\nclass Thing {}\n#else\nclass Thing {}\n#end\n' }
		]);
		Assert.equals('import q.Thing', spelled(printerWith('package q.sub;\n\nclass C {}\n', index, 'q/sub/C.hx'), 'q.Thing'));
	}

	public function testNoIndexProvesNoEnclosingPackageType(): Void {
		Assert.equals('import pkg.Entity', spelled(printerWith('package pkg.sub;\n\nclass C {}\n', null, 'pkg/sub/C.hx'), 'pkg.Entity'));
	}

	@:pin('control')
	@:killer('M-PRINTER-PACKAGE-CHAIN-BUILTIN')
	public function testEnclosingPackageTypeShadowsTheBuiltin(): Void {
		final index: SymbolIndex = indexOf([{ file: 'pkg/Map.hx', source: 'package pkg;\n\nclass Map<K, V> {}\n' }]);
		Assert.equals('import haxe.ds.Map', spelled(printerWith('package pkg.sub;\n\nclass C {}\n', index, 'pkg/sub/C.hx'), 'haxe.ds.Map'));
	}

	@:pin('control')
	@:killer('M-PRINTER-TRANSPARENT-ALIAS')
	public function testTransparentRootAliasDoesNotShadowItsTarget(): Void {
		final index: SymbolIndex = indexOf(STD_MAP);
		final nested: TypeRefPrinter = printerWith('package pkg.sub;\n\nclass C {}\n', index, 'pkg/sub/C.hx');
		Assert.equals('Map<String, Int>', nested.printTypeExpr('haxe.ds.Map<String, Int>'));
		Assert.isFalse(nested.hasPendingImports(), 'the root alias reaches the target with no import');
		Assert.equals('Map', spelled(printerWith('class C {}\n', index, 'C.hx'), 'haxe.ds.Map'));
	}

	public function testReorderingRootAliasShadowsItsTarget(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'Map.hx', source: 'typedef Map<K, V> = haxe.ds.Map<V, K>;\n' },
			{ file: 'haxe/ds/Map.hx', source: 'package haxe.ds;\n\nabstract Map<K, V>(Dynamic) {}\n' }
		]);
		// The root `Map` is another type here, so the bare name needs the import that outranks it.
		Assert.equals('import haxe.ds.Map', spelled(printerWith('package pkg;\n\nclass C {}\n', index, 'pkg/C.hx'), 'haxe.ds.Map'));
	}

	/** A printer over `source` read as the file `file`, whose path names the module and package it resolves from. */
	private function printerWith(source: String, index: Null<SymbolIndex>, file: String): TypeRefPrinter {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final root: QueryNode = plugin.parseFile(source);
		return TypeRefPrinter.forFile(file, source, root, plugin.importMap(source), plugin, index);
	}

	/** How `path` is printed, as `import <path>` when its short name needs a fresh import — the route shows in the answer. */
	private function spelled(p: TypeRefPrinter, path: String): String {
		final printed: PrintedTypeRef = p.print(path);
		return printed.importPath == null ? printed.text : 'import ${printed.importPath}';
	}

	private function indexOf(files: Array<{ file: String, source: String }>): SymbolIndex {
		return CheckFixture.index(files, new HaxeQueryPlugin());
	}

}
