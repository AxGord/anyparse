package unit.check.haxe.imports;

import anyparse.check.haxe.imports.PreferUsingOverStaticImport;
import unit.cli.CliFixture;

/**
 * `prefer-using-over-static-import` under an AMBIENT `using`: `import StringTools.trim;` in a folder whose
 * `import.hx` carries `using StringTools;` duplicates it, so the import is reported.
 */
class PreferUsingOverStaticImportAmbientUsingTest extends Test {

	private static final USER_SOURCE: String =
		'import StringTools.trim;\n\nclass B {\n\tpublic static function t(s:String):String {\n\t\treturn trim(s);\n\t}\n}\n';

	@:pin('control')
	@:killer('M-PSE-AMBIENT-USING-IGNORED')
	public function testAmbientUsingMakesTheStaticImportAFinding(): Void {
		final vs: Array<Violation> = violationsUnder('using StringTools;\n');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-using-over-static-import', vs[0].rule);
		Assert.isTrue(vs[0].message.indexOf('StringTools.trim') != -1, vs[0].message);
	}

	@:pin('guard')
	public function testNoAmbientUsingNoFinding(): Void {
		Assert.equals(0, violationsUnder('\n').length);
	}

	private function violationsUnder(importHx: String): Array<Violation> {
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'src/lib/B.hx', source: USER_SOURCE },
			{ name: 'src/lib/import.hx', source: importHx }
		];
		final root: String = CliFixture.writeTree('puosi_ambient', tree);
		final files: Array<{ file: String, source: String }> = tree.map(t -> { file: '$root/${t.name}', source: t.source });
		final out: Array<Violation> = CheckFixture.violationsIn(new PreferUsingOverStaticImport(), files)
			.filter(v -> v.file == files[0].file);
		CliFixture.removeDir(root);
		return out;
	}

}
