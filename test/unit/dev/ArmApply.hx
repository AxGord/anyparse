package unit.dev;

import dev.MutationArm;
import devkit.Cmd.cmd;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;

/**
 * The one way a test asks `dev mutation-arm --apply-only` about a scratch repo: the fixture is committed, and the engine
 * beside the test binary is pinned in `HXQ_BIN` for the run only.
 */
@:nullSafety(Strict)
final class ArmApply {

	/** The exit status of `--apply-only` for `arms` over the scratch repo `repo`, which is committed first. */
	public static function applyOnly(repo: String, arms: Array<String>): Int {
		if (!FileSystem.exists(Path.join([repo, '.git']))) {
			cmd('git -C $repo init --quiet').check();
			cmd('git -C $repo add -A').check();
			cmd('git -C $repo -c user.name=t -c user.email=t@t commit --quiet -m fixture').check();
		}
		final engine: String = Path.join([Path.directory(FileSystem.fullPath(js.Node.__filename)), 'apq.js']);
		final pinned: String = Sys.getEnv('HXQ_BIN') ?? '';
		Sys.putEnv('HXQ_BIN', engine);
		try {
			final status: Int = MutationArm.main(arms.concat(['--apply-only', '--repo', repo]));
			Sys.putEnv('HXQ_BIN', pinned);
			return status;
		} catch (exception: Exception) {
			Sys.putEnv('HXQ_BIN', pinned);
			throw exception;
		}
	}

}
