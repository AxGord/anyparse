package unit.check.common.design.threads;

import anyparse.check.LintConfig.ConfigNote;
import anyparse.check.common.design.threads.ProjectCoverage;
import unit.cli.CliFixture;

/** `ProjectCoverage`'s chain walk notes its config diagnostics into the run's notes it was given, never on stderr. */
class ProjectCoverageTest extends Test {

	@:pin('control')
	@:killer('M-PROJECT-COVERAGE-NOTES-DROPPED')
	public function testTheChainWalkNotesIntoTheRunsNotes(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('coveragenotes', [
			{ name: 'apq.json', source: '{"rules": [' },
			{ name: 'Foo.hx', source: 'class Foo {}\n' }
		]);
		final notes: Array<ConfigNote> = [];
		final coverage: ProjectCoverage = new ProjectCoverage(['$dir/Foo.hx'], notes);
		var project: String = '';
		final said: String = CliFixture.captureStderr(() -> project = coverage.projectOf('$dir/Foo.hx'));
		CliFixture.removeDir(dir);
		Assert.equals('', project, 'a chain declaring no closedWorld closes no project');
		Assert.equals(1, notes.filter(n -> n.message.indexOf('failed to parse') >= 0).length, 'the broken document is a note');
		Assert.equals(-1, said.indexOf('failed to parse'), 'and nothing said it on stderr');
		#else
		Assert.pass('non-sys target');
		#end
	}

}
