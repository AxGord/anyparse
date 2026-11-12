package unit.cli;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RunLedger;
import anyparse.query.cli.ProjectResolution;

/** `ProjectResolution.hostFor` says the config diagnostics it reads through the ledger it is given. */
@:nullSafety(Strict)
class ProjectResolutionTest extends Test {

	@:pin('control')
	@:killer('M-HOST-FOR-NOTES-UNSAID')
	public function testABrokenConfigIsSaidThroughTheLedger(): Void {
		#if (sys || nodejs)
		final source: String = 'class Foo {}\n';
		final dir: String = CliFixture.writeDir(
			'projectresolution', [{ name: 'apq.json', source: '{"rules": [' }, { name: 'Foo.hx', source: source }]
		);
		final printed: String = CliFixture.captureStderr(() ->
			ProjectResolution.hostFor(new HaxeQueryPlugin(), '$dir/Foo.hx', source, new RunLedger())
		);
		CliFixture.removeDir(dir);
		Assert.isTrue(printed.indexOf('failed to parse') >= 0, printed);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
