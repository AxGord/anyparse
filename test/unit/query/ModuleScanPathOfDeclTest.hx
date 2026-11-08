package unit.query;

import anyparse.query.ModuleScan;
import anyparse.query.SymbolIndex;

using Lambda;

/**
 * The import path a declaration carries is the module for its main type and `module.name` for a type declared beside it.
 */
class ModuleScanPathOfDeclTest extends Test {

	@:pin('control') @:killer('M-MODULESCAN-SUBTYPE-PATH-BARE')
	public function testSubModuleTypeCarriesItsName(): Void {
		final fi: FileInfo = fixture();
		final helper: TypeDeclInfo = fi.types.find(t -> t.name == 'Helper');
		Assert.equals('pkg.Main.Helper', ModuleScan.pathOfDecl(fi, helper));
	}

	@:pin('control') @:killer('M-MODULESCAN-MAIN-PATH-QUALIFIED')
	public function testMainTypeIsTheModule(): Void {
		final fi: FileInfo = fixture();
		final main: TypeDeclInfo = fi.types.find(t -> t.name == 'Main');
		Assert.equals('pkg.Main', ModuleScan.pathOfDecl(fi, main));
	}

	private static function fixture(): FileInfo {
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'src/pkg/Main.hx', source: 'package pkg;\nclass Main {}\ntypedef Helper = {};\n' }
		], new HaxeQueryPlugin());
		return (index.fileInfo('src/pkg/Main.hx'): FileInfo);
	}

}
