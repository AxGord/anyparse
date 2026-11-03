package unit.dev;

import anyparse.query.ConfigFinder;
import dev.SliceMeasure;
import devkit.Cmd.cmd;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * A reading of an old revision lints its copy under that revision's own project config, whichever name the
 * config had then: a copy without it would count clones under defaults, silently.
 */
@:nullSafety(Strict)
final class SliceMeasureConfigTest extends Test {

	public function testACopyCarriesTheProjectConfigUnderEitherName(): Void {
		for (name in [ConfigFinder.PROJECT_CONFIG, ConfigFinder.LEGACY_PROJECT_CONFIG]) {
			TempDir.with(dir -> {
				final repo: String = dir.file('repo');
				FileSystem.createDirectory('$repo/src');
				File.saveContent('$repo/src/A.hx', 'class A {}\n');
				File.saveContent('$repo/$name', '{}\n');
				cmd('git -C $repo init -q -b main').check();
				cmd('git -C $repo add .').check();
				cmd('git -C $repo -c user.name=t -c user.email=t@t commit -q -m base').check();
				final measure: SliceMeasure = new SliceMeasure(repo, ['src'], dir.file('cache'));
				Assert.isTrue(measure.withCopy('HEAD', copy -> FileSystem.exists('$copy/$name')), '$name is copied');
			});
		}
	}

}
