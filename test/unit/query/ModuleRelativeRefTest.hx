package unit.query;

import anyparse.query.SymbolIndex;
import unit.CheckFixture;

/**
 * `TypeRefIndex.resolveTypeRefAll` on the module-relative form `Mod.Sub`: the compiler reads it by module path from the
 * writer's package and each package above it, the nearest one whose module `Mod` declares `Sub` winning (probed on 4.3.7),
 * and never through an import of `Mod`.
 */
class ModuleRelativeRefTest extends Test {

	@:pin('control')
	@:killer('M-REF-MODULE-PARENTS-BLIND')
	public function testAModuleOfAPackageAboveIsReached(): Void {
		Assert.equals('src/a/Mod.hx', declaring(index(), 'src/a/b/c/Main.hx'));
	}

	@:pin('control')
	@:killer('M-REF-MODULE-NEAREST-LOST')
	public function testTheNearestPackageDeclaringTheSubTypeWins(): Void {
		Assert.equals('src/a/b/Mod.hx', declaring(index(), 'src/a/b/c/Near.hx', 'Mod.Near'));
	}

	@:pin('guard')
	public function testAnUnrelatedPackageIsNotReached(): Void {
		Assert.equals('', declaring(index(), 'src/z/Other.hx'));
	}

	@:pin('guard')
	public function testAnImportOfTheModuleDoesNotReachIt(): Void {
		Assert.equals('', declaring(index(), 'src/q/Imported.hx'));
	}

	/** The declaring files `written` resolves to from `from`, joined. */
	private static function declaring(index: SymbolIndex, from: String, written: String = 'Mod.Sub'): String {
		return [for (r in index.resolveTypeRefsFrom(written, from)) r.file.file].join(' | ');
	}

	/** `a.Mod` holds `Sub` and `Near`; `a.b.Mod` holds `Near` only; readers in `a.b.c`, an unrelated `z` and an importer `q`. */
	private static function index(): SymbolIndex {
		return CheckFixture.index([
			{ file: 'src/a/Mod.hx', source: 'package a;\n\nclass Mod {}\n\nclass Sub {}\n\nclass Near {}\n' },
			{ file: 'src/a/b/Mod.hx', source: 'package a.b;\n\nclass Mod {}\n\nclass Near {}\n' },
			{ file: 'src/a/b/c/Main.hx', source: 'package a.b.c;\n\nclass Main {\n\tvar s: Mod.Sub;\n}\n' },
			{ file: 'src/a/b/c/Near.hx', source: 'package a.b.c;\n\nclass Near2 {\n\tvar n: Mod.Near;\n}\n' },
			{ file: 'src/z/Other.hx', source: 'package z;\n\nclass Other {}\n' },
			{ file: 'src/q/Imported.hx', source: 'package q;\n\nimport a.Mod;\n\nclass Imported {}\n' }
		], new HaxeQueryPlugin());
	}

}
