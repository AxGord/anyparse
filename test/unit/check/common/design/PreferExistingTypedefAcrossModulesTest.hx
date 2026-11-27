package unit.check.common.design;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.LintConfig;
import anyparse.check.SourceEntry;
import anyparse.check.common.design.PreferExistingTypedef;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;

/**
 * `prefer-existing-typedef` offers its rewrite only to a typedef already visible to the hit's file: a typedef of an unrelated
 * module that agrees on shape by chance is reported with a hint, never rewritten, unless `acrossModules` asks for it.
 */
class PreferExistingTypedefAcrossModulesTest extends Test {

	private static inline final SIZE: String = '{ width:Int, height:Int }';

	private final _plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());

	@:pin('control')
	@:killer('M-PET-VISIBLE')
	public function testAnUnrelatedModulesTypedefIsReportedNotRewritten(): Void {
		final files: Array<SourceEntry> = [export(), layout('b.scene', '')];
		final check: PreferExistingTypedef = new PreferExistingTypedef();
		final found: Array<Violation> = violations(check, files);
		Assert.equals(1, found.length);
		Assert.isTrue((found[0].declineReason ?? '').contains('a.media.Export.OutputSize by shape'), found[0].message);
		Assert.equals(0, fixGroups(check, files, found).length);
	}

	@:pin('control')
	@:killer('M-PET-REACHES')
	public function testAnImportedModuleOrTypeOrTheOwnPackageMakesTheTypedefVisible(): Void {
		for (imports in ['import a.media.Export;', 'import a.media.Export.OutputSize;'])
			Assert.isTrue(fixed([export(), layout('b.scene', imports)], 'src/b/scene/Layout.hx').contains('canvas:OutputSize'), imports);
		Assert.isTrue(fixed([export(), layout('a.media', '')], 'src/a/media/Layout.hx').contains('canvas:OutputSize'));
	}

	@:pin('control')
	@:killer('M-PET-SPELLS')
	public function testAnImplementedInterfacesMemberTypeMakesTheTypedefVisible(): Void {
		final spelling: SourceEntry = {
			file: 'src/c/api/Sizing.hx',
			source: 'package c.api;\n\nimport a.media.Export.OutputSize;\n\ninterface Sizing {\n\tfunction size(): OutputSize;\n}\n'
		};
		final other: SourceEntry = {
			file: 'src/c/api/Sizing.hx',
			source: 'package c.api;\n\ninterface Sizing {\n\tfunction size(): Int;\n}\n'
		};
		Assert.isTrue(fixed([export(), spelling, implementation()], 'src/b/scene/Impl.hx').contains('size(): OutputSize'));
		final check: PreferExistingTypedef = new PreferExistingTypedef();
		final found: Array<Violation> = violations(check, [export(), other, implementation()]);
		Assert.equals(1, found.length);
		Assert.equals(0, fixGroups(check, [export(), other, implementation()], found).length);
	}

	@:pin('control')
	@:killer('M-PET-ACROSS-OPTION')
	public function testAcrossModulesRestoresTheRewriteOfAnUnrelatedTypedef(): Void {
		final files: Array<SourceEntry> = [export(), layout('b.scene', '')];
		final check: PreferExistingTypedef = new PreferExistingTypedef();
		check.setConfigResolver(_ -> LintConfig.parse('{"rules":{"prefer-existing-typedef":{"acrossModules":true}}}'));
		final found: Array<Violation> = violations(check, files);
		Assert.equals(1, found.length);
		Assert.isNull(found[0].declineReason);
		final groups: Array<Array<CrossFileEdits>> = fixGroups(check, files, found);
		Assert.equals(1, groups.length);
		final text: String = applied(files, groups[0])['src/b/scene/Layout.hx'] ?? '';
		Assert.isTrue(text.contains('canvas:OutputSize') && text.contains('import a.media.Export.OutputSize;'), text);
		Assert.same(['acrossModules'], check.acceptedOptions());
	}

	/** The one file of `files` named `file`, after its first fix group is applied; empty when the run planned no fix. */
	private function fixed(files: Array<SourceEntry>, file: String): String {
		final check: PreferExistingTypedef = new PreferExistingTypedef();
		final groups: Array<Array<CrossFileEdits>> = fixGroups(check, files, violations(check, files));
		return groups.length == 1 ? applied(files, groups[0])[file] ?? '' : '';
	}

	private function violations(check: PreferExistingTypedef, files: Array<SourceEntry>): Array<Violation> {
		return CheckFixture.violationsIn(check, files, _plugin);
	}

	private function fixGroups(
		check: PreferExistingTypedef, files: Array<SourceEntry>, found: Array<Violation>
	): Array<Array<CrossFileEdits>> {
		return check.crossFileFix(files, found, _plugin, CheckFixture.index(files, _plugin));
	}

	private static function export(): SourceEntry {
		return { file: 'src/a/media/Export.hx', source: 'package a.media;\n\ntypedef OutputSize = $SIZE\n' };
	}

	/** A module of `pkg` holding the config typedef whose nested `canvas` spells `SIZE`, after the `imports` line. */
	private static function layout(pkg: String, imports: String): SourceEntry {
		final head: String = imports == '' ? '' : '$imports\n\n';
		return {
			file: 'src/${pkg.split('.').join('/')}/Layout.hx',
			source: 'package $pkg;\n\n${head}private typedef Config = { items:Array<Int>, canvas:$SIZE }\n'
		};
	}

	/** A class implementing `c.api.Sizing` whose method writes the structure out. */
	private static function implementation(): SourceEntry {
		return {
			file: 'src/b/scene/Impl.hx',
			source: 'package b.scene;\n\nimport c.api.Sizing;\n\nclass Impl implements Sizing {\n\tpublic function size(): $SIZE'
				+ ' return null;\n}\n'
		};
	}

	/** `files` with the slices applied: an edit list is spliced into the file's source. */
	private static function applied(files: Array<SourceEntry>, slices: Array<CrossFileEdits>): Map<String, String> {
		final out: Map<String, String> = [ for (f in files) f.file => f.source ];
		for (slice in slices) out[slice.file] = CanonicalEdit.applyEdits(out[slice.file] ?? '', slice.edits);
		return out;
	}

}
