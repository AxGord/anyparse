package unit.devkit;

import anyparse.query.Cli;
import unit.cli.CliFixture;

/** The devkit tests' own folder keeps no `using` that `hoist-common-import` says belongs in its `import.hx`. */
@:nullSafety(Strict)
final class DevkitAmbientImportsTest extends Test {

	private static inline final DIR: String = 'test/unit/devkit';

	@:pin('guard')
	public function testNoModuleHoldsAStatementTheFolderAmbientSourceShouldCarry(): Void {
		#if nodejs
		final args: Array<String> = ['lint', '--rule', 'hoist-common-import', '--flat', '--no-oracle', DIR];
		var code: Int = -1;
		var err: String = '';
		final out: String = CliFixture.captureStdout(() -> err = CliFixture.captureStderr(() -> code = Cli.run(args)));
		final found: Array<String> = out.split('\n').filter(line -> line.endsWith('(hoist-common-import)'));
		Assert.same([], found);
		Assert.equals(0, code);
		Assert.isTrue((out + err).contains('no issues in '), out + err);
		#else
		Assert.pass('stdout capture needs the node target');
		#end
	}

}
