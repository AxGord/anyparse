package unit.dev;

import devkit.Cmd.cmd;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** A scratch git work tree standing for a downstream checkout the tests of `FrozenSnapshot` and the `frozen` row read. */
@:nullSafety(Strict)
final class LiveGitTree {

	/** A work tree in `dir` holding one committed file `a.hx`. */
	public static function make(dir: TempDir): String {
		final live: String = dir.file('live');
		FileSystem.createDirectory(live);
		File.saveContent(Path.join([live, 'a.hx']), 'class A {}\n');
		cmd('git init -q -b main').at(live).check();
		commit(live, 'base');
		return live;
	}

	/** Commit everything in `live`. */
	public static function commit(live: String, message: String): Void {
		cmd('git add -A').at(live).check();
		cmd('git -c user.name=t -c user.email=t@t commit -q -m $message').at(live).check();
	}

}
