package unit.dev;

import dev.WorkerBuild;
import devkit.Args.UsageError;
import devkit.TempDir;
import sys.FileSystem;
import utest.Assert;
import utest.Test;

/**
 * `dev worker-build`'s refusals, each before anything is built: no workdir, an empty one, an unknown target. The build
 * itself and the shared-`bin/` guard are proven against the shell twin by running both.
 */
@:nullSafety(Strict)
final class WorkerBuildTest extends Test {

	public function testACommandLineItCannotBuildFromIsRefused(): Void {
		TempDir.with(dir -> {
			final workdir: String = dir.file('w');
			Assert.raises(() -> WorkerBuild.main([]), UsageError, 'no workdir');
			Assert.raises(() -> WorkerBuild.main(['']), UsageError, 'an empty workdir');
			Assert.raises(() -> WorkerBuild.main([workdir, 'bogus']), UsageError, 'an unknown target');
			Assert.isFalse(FileSystem.exists(workdir), 'a refusal creates nothing');
		});
	}

}
