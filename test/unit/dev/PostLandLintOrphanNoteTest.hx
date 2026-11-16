package unit.dev;

import dev.PostLand;
import devkit.Lease.LeaseMode;
import devkit.Summary.Outcome;
import devkit.TempDir;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The whole lint behind a lease wrapper that ended while it still waited, leaving a process of its group behind: the driver
 * names that process, command line and all, in the run's stderr, and the lint's own start mark is part of that command line.
 */
@:nullSafety(Strict)
final class PostLandLintOrphanNoteTest extends Test {

	@:killer('M-POSTLAND-LINT-ORPHAN-NOTE-IS-NO-START')
	@:pin('control')
	public function testAWrapperReapedBeforeItsGrantIsNotRunWhateverItsOrphanNoteSays(): Void {
		TempDir.with(dir -> {
			final verdict: Outcome = PostLand.wholeLint(
				'/nonexistent', 'abc1234', dir.path, PostLandLintVerdictTest.tree(dir, 'echo "[]"'), leftBehind(dir)
			);
			switch verdict {
				case NotRun(why): Assert.isFalse(why.contains('orphan'), why);
				case _: Assert.fail('got $verdict');
			}
		});
	}

	/** A `wf-run` that waits: it starts a sibling holding the command it was asked to run in its argument vector, then ends. */
	private static function leftBehind(dir: TempDir): LeaseMode {
		final path: String = dir.file('wf-run-orphan');
		final script: String = '#!/bin/sh\necho \'wf-run: waiting for 1 threads\' >&2\n'
			+ 'while [ "$$1" != "--" ]; do shift; done\nshift\nsh -c \'sleep 30; :\' "$$@" &\nexit 3\n';
		File.saveContent(path, script);
		js.node.Fs.chmodSync(path, '755');
		return Own(path, 1);
	}

}
