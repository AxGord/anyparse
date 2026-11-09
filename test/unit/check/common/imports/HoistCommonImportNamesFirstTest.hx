package unit.check.common.imports;

import anyparse.check.common.imports.HoistCommonImport;
import unit.cli.CliFixture;

/**
 * `hoist-common-import` asks an ambient source only WHICH modules it governs, never for their text: a governed module
 * the run holds in memory but the disk cannot open does not keep the rule from hoisting, because the names-first
 * answer opens nothing.
 */
@:nullSafety(Strict)
class HoistCommonImportNamesFirstTest extends Test {

	/** Three of four modules of one package spelling one import; the fourth is the one the disk will refuse. */
	private static final TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/qqz/Znnwwee.hx', source: 'package qqz;\n\nclass Znnwwee {}\n' },
		{ name: 'src/aqq/OneQq.hx', source: 'package aqq;\n\nimport qqz.Znnwwee;\n\nclass OneQq {\n\n\tvar a: Znnwwee;\n\n}\n' },
		{ name: 'src/aqq/TwoQq.hx', source: 'package aqq;\n\nimport qqz.Znnwwee;\n\nclass TwoQq {\n\n\tvar a: Znnwwee;\n\n}\n' },
		{ name: 'src/aqq/ThreeQq.hx', source: 'package aqq;\n\nimport qqz.Znnwwee;\n\nclass ThreeQq {\n\n\tvar a: Znnwwee;\n\n}\n' },
		{ name: 'src/aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {}\n' }
	];

	/** The hoist the tree earns is the same with every governed module readable and with one the disk refuses. */
	@:pin('control')
	@:killer('M-HOIST-GOVERNED-READS-TEXT')
	public function testAGovernedModuleTheDiskRefusesDoesNotWithholdTheHoist(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_hoist_names_first', TREE);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final files: Array<{ file: String, source: String }> = TREE.map(entry -> {file: '$root/${entry.name}', source: entry.source });
			final readable: Int = CheckFixture.violationsIn(new HoistCommonImport(), files).length;
			final locked: String = '$root/src/aqq/FourQq.hx';
			Sys.command('chmod', ['000', locked]);
			final refused: Int = CheckFixture.violationsIn(new HoistCommonImport(), files).length;
			Sys.command('chmod', ['644', locked]);
			out = '$readable:$refused';
		});
		Assert.equals('3:3', out);
		#else
		Assert.pass();
		#end
	}

}
