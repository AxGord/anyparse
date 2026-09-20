package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.RedundantImport;
import anyparse.check.UnusedImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

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

	/**
	 * An ambient `using` of a module that calls its OWN statics extension-style — so the declaring
	 * module depends on that statement and is one of its readers.
	 */
	private static final SELF_USING_TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/import.hx', source: 'using aaa.Extqqw;\n' },
		{
			name: 'src/aaa/Extqqw.hx',
			source: 'package aaa;\n\nclass Extqqw {\n\n\tpublic static function tagqqw(s: String): String {\n\t\treturn \'S\' + s;\n'
				+ '\t}\n\n\tpublic static function twiceqqw(s: String): String {\n\t\treturn s.tagqqw().tagqqw();\n\t}\n\n}\n'
		}
	];

	/** An ambient `using` nothing under its own directory reaches for — the same arm's reporting half. */
	private static final DEAD_USING_TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/lib/import.hx', source: 'using aaa.Extqqw;\n' },
		{
			name: 'src/aaa/Extqqw.hx',
			source: 'package aaa;\n\nclass Extqqw {\n\n\tpublic static function tagqqw(s: String): String {\n\t\treturn \'S\' + s;\n'
				+ '\t}\n\n}\n'
		},
		{ name: 'src/lib/Other.hx', source: 'package lib;\n\nclass Other {}\n' }
	];

	/** An ambient statement whose target module lies INSIDE the subtree the source governs. */
	private static final DECLARER_TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/import.hx', source: 'import a.Zqq;\n' },
		{ name: 'src/a/Zqq.hx', source: 'package a;\n\nclass Zqq {}\n' },
		{ name: 'src/lib/Other.hx', source: 'package lib;\n\nclass Other {}\n' }
	];

	/**
	 * A nearer ambient group whose ONLY binder of the name is `#if`-guarded, above a farther group
	 * carrying the statement the module also spells itself.
	 */
	private static final GUARDED_NEARER_TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/a/T.hx', source: 'package a;\n\nclass T {}\n' },
		{ name: 'src/b/T.hx', source: 'package b;\n\nclass T {}\n' },
		{ name: 'src/outer/import.hx', source: 'import a.T;\n' },
		{ name: 'src/outer/inner/import.hx', source: '#if useB\nimport b.T;\n#end\n' },
		{ name: 'src/outer/inner/Modq.hx', source: 'package outer.inner;\n\nimport a.T;\n\nclass Modq {}\n' }
	];

	/** The same shape with the nearer group's guard gone, so nothing competes for the name. */
	private static final GUARDED_NEARER_CONTROL: Array<{ name: String, source: String }> = [
		{ name: 'src/a/T.hx', source: 'package a;\n\nclass T {}\n' },
		{ name: 'src/b/T.hx', source: 'package b;\n\nclass T {}\n' },
		{ name: 'src/outer/import.hx', source: 'import a.T;\n' },
		{ name: 'src/outer/inner/import.hx', source: 'import b.Wqq;\n' },
		{ name: 'src/outer/inner/Modq.hx', source: 'package outer.inner;\n\nimport a.T;\n\nclass Modq {}\n' }
	];

	/** A file whose own `using` an ambient source repeats, with a SECOND own `using` beside it. */
	private static final USING_RIVAL_TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/a/Sqq.hx', source: 'package a;\n\nclass Sqq {}\n' },
		{ name: 'src/b/Rqq.hx', source: 'package b;\n\nclass Rqq {}\n' },
		{ name: 'src/lib/import.hx', source: 'using a.Sqq;\n' },
		{ name: 'src/lib/Modq.hx', source: 'package lib;\n\nusing b.Rqq;\nusing a.Sqq;\n\nclass Modq {}\n' }
	];

	/** The same shape with the rival `using` gone, so the two positions are interchangeable. */
	private static final USING_RIVAL_CONTROL: Array<{ name: String, source: String }> = [
		{ name: 'src/a/Sqq.hx', source: 'package a;\n\nclass Sqq {}\n' },
		{ name: 'src/b/Rqq.hx', source: 'package b;\n\nclass Rqq {}\n' },
		{ name: 'src/lib/import.hx', source: 'using a.Sqq;\n' },
		{ name: 'src/lib/Modq.hx', source: 'package lib;\n\nusing a.Sqq;\n\nclass Modq {}\n' }
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
	@:killer('M-AMBIENT-DECLARER-READS-USING')
	public function testTheDeclaringModuleIsAReaderOfAnAmbientUsingOfItself(): Void {
		#if (sys || nodejs)
		// A module's own declaration outranks an IMPORT of itself, so it never needs one — but it does
		// not `using` itself, and one that calls its own statics extension-style depends on exactly that
		// statement. Checked against the compiler: the module compiles with the ambient `using` and
		// fails with `String has no field tagqqw` without it.
		Assert.equals(
			'', findings(SELF_USING_TREE, ['src/import.hx', 'src/aaa/Extqqw.hx']),
			'the declaring module is a reader of an ambient `using` of itself'
		);
		Assert.equals(
			'src/lib/import.hx:aaa.Extqqw', findings(DEAD_USING_TREE, ['src/lib/import.hx', 'src/aaa/Extqqw.hx', 'src/lib/Other.hx']),
			'an ambient `using` nothing under its directory reaches for is still reported'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-DECLARER-READS')
	public function testTheModuleAnAmbientStatementImportsIsNotOneOfItsReaders(): Void {
		#if (sys || nodejs)
		// The governed subtree holds the declaring module, and the used-test is textual, so that
		// module's own `class Zqq` read as a use of the statement that imports it — which no module
		// ever needs of itself, and which made a stale statement in a root ambient source unreportable.
		Assert.equals(
			'src/import.hx:a.Zqq', findings(DECLARER_TREE, ['src/import.hx', 'src/a/Zqq.hx', 'src/lib/Other.hx']),
			'the declaring module is not a reader of the import that names it'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-REDUNDANT-GUARDED-SKIP')
	public function testAGuardedBinderInTheNearestGroupKeepsTheOwnStatement(): Void {
		#if (sys || nodejs)
		// Checked against the compiler: with the own statement the name means `a.T` in both builds;
		// without it, `a.T` undefined and `b.T` with the define — the nearer group DECIDES the name, so
		// searching past it because its binder is guarded reports a farther group as the provider.
		Assert.equals(
			'', redundantFindings(GUARDED_NEARER_TREE, 'src/outer/inner/Modq.hx'),
			'a nearer ambient group binding the name under a guard makes the deletion a retarget'
		);
		Assert.equals(
			'src/outer/inner/Modq.hx:a.T', redundantFindings(GUARDED_NEARER_CONTROL, 'src/outer/inner/Modq.hx'),
			'with nothing nearer competing for the name the same statement IS redundant'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-REDUNDANT-USING-POSITION')
	public function testAnOwnUsingIsKeptWhereAnotherUsingCouldTakeItsPosition(): Void {
		#if (sys || nodejs)
		// A `using` binds a name AND a position: extensions resolve in reverse declaration order and
		// every own statement outranks every ambient one, so deleting the own copy hands each method to
		// whichever rival is next. Checked against the compiler on a method both modules declare.
		Assert.equals(
			'', redundantFindings(USING_RIVAL_TREE, 'src/lib/Modq.hx'),
			'another `using` in scope could take the position the deleted one held'
		);
		Assert.equals(
			'src/lib/Modq.hx:a.Sqq', redundantFindings(USING_RIVAL_CONTROL, 'src/lib/Modq.hx'),
			'with no rival `using` the ambient statement holds the same position'
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
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final files: Array<{ file: String, source: String }> = [
				for (name in analysed) { file: '$root/$name', source: sys.io.File.getContent('$root/$name') }
			];
			out = reported(files, '$root/');
		});
		return out;
		#else
		return '';
		#end
	}

	/**
	 * `redundant-import`'s findings over `tree` written to disk, as `<file>:<import path>`, comma-joined
	 * in report order. `subject` is the one module the run analyses — the chain is read from disk, so the
	 * ambient sources need not be in the set.
	 */
	private function redundantFindings(tree: Array<{ name: String, source: String }>, subject: String): String {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_ambient_redundant', tree);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final files: Array<{ file: String, source: String }> = [
				for (entry in tree) if (!entry.name.endsWith('import.hx')) { file: '$root/${entry.name}', source: entry.source }
			];
			final violations: Array<Violation> = new RedundantImport().run(files, new HaxeQueryPlugin());
			out = [for (v in violations) '${v.file.substr(root.length + 1)}:${pathOf(v.message)}'].join(',');
		});
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
