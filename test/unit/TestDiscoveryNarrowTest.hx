package unit;

import dev.Binaries;
import devkit.Cmd.cmd;
import devkit.NarrowBuild;
import devkit.Result;
import devkit.TempDir;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * The narrow registry path of `testkit.TestDiscovery`, through the compiler itself: a build carrying
 * `devkit.NarrowBuild`'s define registers exactly the classes it lists, in that order, and holds none of the views a
 * full build derives from the whole tree; a name that is no test class stops the build.
 */
@:nullSafety(Strict)
final class TestDiscoveryNarrowTest extends Test {

	/** A test class that needs none of the harness beyond the runner, so the build stays small. */
	private static inline final FIRST: String = 'unit.devkit.NarrowBuildTest';

	private static inline final SECOND: String = 'unit.DiscoveryOnlyProbeTest';

	/** The query engine's entry class, which a build holds only when something names `Cli`. */
	private static inline final ENGINE_ENTRY: String = 'anyparse_query_Cli';

	@:pin('control')
	@:killer('M-NARROW-FLOOR-HARNESS')
	public function testANarrowBuildRegistersExactlyTheClassesItNames(): Void {
		TempDir.with(dir -> {
			final binary: String = dir.file('narrow.js');
			final built: Result = narrowBuild([SECOND, FIRST], binary);
			Assert.isTrue(built.ok, built.err);
			Assert.same([SECOND, FIRST], listing(binary, '--list-classes'));
			Assert.equals(
				-1, File.getContent(binary).indexOf(ENGINE_ENTRY),
				'the runner and the registry reach no query engine, which is the narrow build\'s floor'
			);
			for (view in [
				'--list-pins',
				'--list-arms',
				'--list-dead',
				'--list-bases',
				'--list-claims',
				'--list-deferred'
			]) Assert.same([], listing(binary, view), '$view is empty in a narrow build');
		});
	}

	@:pin('guard')
	public function testANameThatIsNoTestClassStopsTheBuild(): Void {
		TempDir.with(dir -> {
			final notATest: Result = narrowBuild(['devkit.NarrowBuild'], dir.file('a.js'));
			Assert.isFalse(notATest.ok, 'a class that is not a test');
			Assert.stringContains('devkit.NarrowBuild, which is not a test class', notATest.err + notATest.out);
			Assert.isFalse(narrowBuild(['unit.NoSuchTest'], dir.file('b.js')).ok, 'a name that is no type');
		});
	}

	private static function narrowBuild(classes: Array<String>, output: String): Result {
		final define: String = NarrowBuild.define(classes);
		return cmd('haxe test-js-common.hxml ${Binaries.CODEGEN} -D $define -js $output').at(CliFixture.repoRoot()).run();
	}

	private static function listing(binary: String, flag: String): Array<String> {
		return cmd('node $binary $flag').at(CliFixture.repoRoot()).lines();
	}

}
