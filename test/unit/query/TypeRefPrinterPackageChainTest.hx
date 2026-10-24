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
		final p: TypeRefPrinter = printerWith('package pkg.sub.deep;\n\nclass C {}\n', index, 'pkg/sub/deep/C.hx');
		// The bare name means the NEARER `pkg.sub.Entity`; an import, which outranks the package chain, is the short route left.
		Assert.equals('import pkg.Entity', spelled(p, 'pkg.Entity'));
		Assert.equals('Entity', spelled(p, 'pkg.sub.Entity'));
	}

	public function testSecondaryTypeOfAnEnclosingPackageBindsNothing(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'pkg/Entity.hx', source: 'package pkg;\n\nclass Entity<T> {}\n' },
			{ file: 'pkg/sub/Mod.hx', source: 'package pkg.sub;\n\nclass Mod {}\n\nclass Entity<T> {}\n' }
		]);
		// Inside `pkg.sub` itself the secondary `Entity` still vetoes, conservatively; one package deeper it is skipped.
		Assert.equals('pkg.Entity', spelled(printerWith('package pkg.sub;\n\nclass C {}\n', index, 'pkg/sub/C.hx'), 'pkg.Entity'));
		Assert.equals('Entity', spelled(printerWith('package pkg.sub.deep;\n\nclass C {}\n', index, 'pkg/sub/deep/C.hx'), 'pkg.Entity'));
	}

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
		Assert.equals('Map', printerWith('class C {}\n', index, 'C.hx').print('haxe.ds.Map').text);
	}

	public function testReorderingRootAliasShadowsItsTarget(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'Map.hx', source: 'typedef Map<K, V> = haxe.ds.Map<V, K>;\n' },
			{ file: 'haxe/ds/Map.hx', source: 'package haxe.ds;\n\nabstract Map<K, V>(Dynamic) {}\n' }
		]);
		Assert.equals('haxe.ds.Map', printerWith('package pkg;\n\nclass C {}\n', index, 'pkg/C.hx').print('haxe.ds.Map').text);
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
