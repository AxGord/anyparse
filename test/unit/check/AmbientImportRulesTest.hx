package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.UnusedImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import haxe.Exception;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * The import rules under an AMBIENT import source, end to end through `unused-import`.
 *
 * An ambient source's statements are read by the modules under its directory, never by its own
 * text — so the liveness question is cross-file by nature, and getting it wrong in either direction
 * is a defect this rule's `fix` acts on: judged against its own text every ambient statement reads
 * as dead and the fix deletes a load-bearing import, while a governed set the run could not
 * establish makes the same verdict on the modules it never saw.
 */
@:nullSafety(Strict)
class AmbientImportRulesTest extends Test {

	/** An ambient source whose binding a module under it really uses. */
	private static final LIVE_TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/a/T.hx', source: 'package a;\n\nclass T {}\n' },
		{ name: 'src/lib/import.hx', source: 'import a.T;\n' },
		{ name: 'src/lib/Sub.hx', source: 'package lib;\n\nclass Sub extends T {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n}\n' }
	];

	/** The same shape with nothing under the directory referring to the bound name. */
	private static final DEAD_TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/a/T.hx', source: 'package a;\n\nclass T {}\n' },
		{ name: 'src/lib/import.hx', source: 'import a.T;\n' },
		{ name: 'src/lib/Other.hx', source: 'package lib;\n\nclass Other {}\n' }
	];

	@:pin('control')
	@:killer('M-AMBIENT-GOVERNANCE-BLIND')
	public function testAnAmbientImportAModuleUnderItUsesIsNotReported(): Void {
		#if (sys || nodejs)
		Assert.equals(
			'', findings(LIVE_TREE, ['src/a/T.hx', 'src/lib/import.hx', 'src/lib/Sub.hx']),
			'the statement is read by the module under the directory, so the ambient source it sits in does not own its liveness'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-GOVERNANCE-BLIND')
	public function testTheGovernedSetIsReadEvenWhenTheRunWasGivenTheAmbientSourceAlone(): Void {
		#if (sys || nodejs)
		Assert.equals(
			'', findings(LIVE_TREE, ['src/lib/import.hx']),
			'the modules under the directory are a fact about the tree, not about the scope a run was given'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-GOVERNANCE-SHORT')
	public function testAnAmbientImportNoModuleUnderItUsesIsStillReported(): Void {
		#if (sys || nodejs)
		Assert.equals(
			'src/lib/import.hx:a.T', findings(DEAD_TREE, ['src/a/T.hx', 'src/lib/import.hx', 'src/lib/Other.hx']),
			'nothing under the directory binds the name, so the statement is dead and deletable'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-GOVERNANCE-COMPLETE')
	public function testAGovernedSetThatCannotBeEstablishedWithholdsEveryVerdict(): Void {
		// The fixture is never written, so the modules under the ambient source's directory cannot be
		// enumerated at all. A short set is not a smaller one: answering from it calls a statement dead
		// on the readers the run never saw.
		final files: Array<{ file: String, source: String }> = [
			{ file: 'apq_absent_tree/a/T.hx', source: 'package a;\n\nclass T {}\n' },
			{ file: 'apq_absent_tree/lib/import.hx', source: 'import a.T;\n' },
			{ file: 'apq_absent_tree/lib/Other.hx', source: 'package lib;\n\nclass Other {}\n' }
		];
		Assert.equals('', reported(files, ''), 'an ambient source whose readers could not be enumerated is judged on nothing');
	}

	/**
	 * `unused-import`'s findings over the tree-relative subset `analysed`, each as
	 * `<file>:<import path>`, comma-joined in report order. The whole `tree` is written to disk —
	 * the governed set is read from there, not from the analysed set.
	 */
	private function findings(tree: Array<{ name: String, source: String }>, analysed: Array<String>): String {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_ambient_rules', tree);
		final files: Array<{ file: String, source: String }> = [
			for (name in analysed) { file: '$root/$name', source: sys.io.File.getContent('$root/$name') }
		];
		var out: String = '';
		try out = reported(files, '$root/') catch (exception: Exception) {
			CliFixture.removeDir(root);
			throw exception;
		}
		CliFixture.removeDir(root);
		return out;
		#else
		return '';
		#end
	}

	/** Every `unused-import` finding as `<file without prefix>:<import path>`, comma-joined in report order. */
	private function reported(files: Array<{ file: String, source: String }>, prefix: String): String {
		final violations: Array<Violation> = new UnusedImport().run(files, new HaxeQueryPlugin());
		return [
			for (v in violations) '${v.file.substr(prefix.length)}:${pathOf(v.message)}'
		].join(',');
	}

	/** The import path a finding names, taken from the quoted span of its message. */
	private static function pathOf(message: String): String {
		final open: Int = message.indexOf('\'');
		final close: Int = message.indexOf('\'', open + 1);
		return open < 0 || close < 0 ? message : message.substring(open + 1, close);
	}

}
