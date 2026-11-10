package unit.check.common.imports;

import anyparse.check.common.imports.HoistCommonImport;
import unit.cli.CliFixture;

/**
 * A `hoist-common-import` finding's IDENTITY survives a change in how many sibling modules the
 * directory holds: the shares in its message are counts of those modules, and a count moves when a
 * file the finding is not about is added or removed.
 */
@:nullSafety(Strict)
class HoistCommonImportIdentityTest extends Test {

	/** Three of four modules spelling `qqz.Zqqwwee`. */
	private static final HOIST_TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/qqz/Zqqwwee.hx', source: 'package qqz;\n\nclass Zqqwwee {}\n' },
		{ name: 'src/aqq/OneQq.hx', source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass OneQq {\n\n\tvar a: Zqqwwee;\n\n}\n' },
		{ name: 'src/aqq/TwoQq.hx', source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass TwoQq {\n\n\tvar a: Zqqwwee;\n\n}\n' },
		{ name: 'src/aqq/ThreeQq.hx', source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass ThreeQq {\n\n\tvar a: Zqqwwee;\n\n}\n' },
		{ name: 'src/aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {}\n' }
	];

	/** One of five modules reading the statement an ambient source carries. */
	private static final SINK_TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/qqz/Rqqwwee.hx', source: 'package qqz;\n\nclass Rqqwwee {}\n' },
		{ name: 'src/aqq/import.hx', source: 'import qqz.Rqqwwee;\n' },
		{ name: 'src/aqq/OneQq.hx', source: 'package aqq;\n\nclass OneQq {\n\n\tvar a:Rqqwwee;\n\n}\n' },
		{ name: 'src/aqq/TwoQq.hx', source: 'package aqq;\n\nclass TwoQq {}\n' },
		{ name: 'src/aqq/ThreeQq.hx', source: 'package aqq;\n\nclass ThreeQq {}\n' },
		{ name: 'src/aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {}\n' },
		{ name: 'src/aqq/FiveQq.hx', source: 'package aqq;\n\nclass FiveQq {}\n' }
	];

	/** A module added to the directory moves the denominator of the share the hoist finding quotes, not the finding's identity. */
	@:pin('control')
	@:killer('M-HOIST-IDENTITY-DENOMINATOR')
	public function testHoistIdentityIgnoresTheCountOfSiblingModules(): Void {
		final more: Array<{ name: String, source: String }> = HOIST_TREE.concat([{
			name: 'src/aqq/FiveQq.hx',
			source: 'package aqq;\n\nclass FiveQq {}\n'
		}]);
		Assert.equals(identityOf(HOIST_TREE, 'OneQq'), identityOf(more, 'OneQq'));
	}

	/** The sink finding's denominator counts the modules its source governs; one more of them leaves the identity as it was. */
	@:pin('control')
	@:killer('M-HOIST-IDENTITY-DENOMINATOR')
	public function testSinkIdentityIgnoresTheCountOfSiblingModules(): Void {
		final more: Array<{ name: String, source: String }> = SINK_TREE.concat([{
			name: 'src/aqq/SixQq.hx',
			source: 'package aqq;\n\nclass SixQq {}\n'
		}]);
		Assert.equals(identityOf(SINK_TREE, 'import'), identityOf(more, 'import'));
	}

	/** The identity of the one finding landing in module `module` of `tree`, with the fixture root taken off its paths. */
	private function identityOf(tree: Array<{ name: String, source: String }>, module: String): String {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_hoist_identity', tree);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final files: Array<{ file: String, source: String }> = [
				for (entry in tree) if (entry.name.endsWith('.hx')) { file: '$root/${entry.name}', source: entry.source }
			];
			final rule: HoistCommonImport = new HoistCommonImport();
			final found: Array<Violation> = CheckFixture.violationsIn(rule, files).filter(v -> v.file.endsWith('/$module.hx'));
			Assert.equals(1, found.length);
			out = found.length == 1 ? rule.messageIdentity(found[0].message).replace(root, '') : '';
		});
		return out;
		#else
		return '';
		#end
	}

}
