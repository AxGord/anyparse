package unit.cli;

import anyparse.query.Cli;

using StringTools;

/**
 * A `lint --fix` run says each config diagnostic once, whichever of its phases read the config: the passes, the fixes and
 * the residue lints over the changed lines all say through the run's ledger. An oracle declaration that reads to nothing
 * is re-read on every ask, so a phase that fell back to stderr would say it again.
 */
class LintFixConfigNoteOnceTest extends Test {

	@:pin('control')
	@:killer('M-FIX-RESIDUE-NOTES-DROPPED')
	public function testAnOracleDeclarationReadingToNothingIsSaidOnceOverTheFixRun(): Void {
		#if nodejs
		final dir: String = CliFixture.writeTree('fixnoteonce', [
			{ name: 'apq.json', source: '{"compilerOracle":[{"noSuchKnob":1}]}' },
			{ name: 'src/a/C.hx', source: deadSafeNav('a') },
			{ name: 'src/b/C.hx', source: deadSafeNav('b') }
		]);
		var exit: Int = -1;
		final said: String = CliFixture.captureStderr(() ->
			exit = Cli.run(['lint', '$dir/src', '--rule', 'dead-safe-nav', '--no-oracle', '--fix'])
		);
		final fixed: String = sys.io.File.getContent('$dir/src/a/C.hx');
		CliFixture.removeDir(dir);
		Assert.equals(0, exit, said);
		Assert.isFalse(fixed.contains('x?.length'), 'the fix rewrote the file, so the residue lints ran: $fixed');
		Assert.equals(2, said.split('noSuchKnob').length, 'the declaration\'s diagnostic is said once: $said');
		#else
		Assert.pass('stderr is captured on node only');
		#end
	}

	/** A dead `?.` the fix rewrites, in package `pkg`. */
	private static function deadSafeNav(pkg: String): String {
		return 'package $pkg;\n\nclass C {\n\tfunction f(x:Null<String>) {\n\t\tfinal ok = x != null;\n\t\tif (ok) {\n'
			+ '\t\t\tvar n = x?.length;\n\t\t}\n\t}\n}\n';
	}

}
