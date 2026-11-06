package unit.cli;

/**
 * A fixture repository commits and tags without signing, whatever signing the user's git configuration asks for.
 *
 * The repository here asks for signing through a program that always fails, the way a loaded gpg agent does, and the
 * commit goes through `CliFixture.git` like any fixture's: it succeeds only while `ScratchRoot.isolateTempDir`
 * switches signing off for the suite process, so a fixture commit path that bypasses `CliFixture.git` is covered too.
 */
@:nullSafety(Strict)
final class FixtureGitSigningTest extends Test {

	@:pin('control')
	@:killer('M-FIXTURE-GIT-SIGNING-ON')
	public function testACommitAndATagInAFixtureRepoIgnoreARepoThatDemandsSigning(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_gitsign', [{ name: 'a.txt', source: 'one\n' }]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			CliFixture.git(root, ['init', '-q']);
			CliFixture.git(root, ['config', 'commit.gpgsign', 'true']);
			CliFixture.git(root, ['config', 'tag.gpgsign', 'true']);
			CliFixture.git(root, ['config', 'gpg.program', 'false']);
			CliFixture.git(root, ['add', '-A']);
			CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
			CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'tag', '-m', 'v', 'v1']);
			Assert.pass();
		});
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

}
