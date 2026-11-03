package anyparse.query;

import haxe.Exception;

/**
 * A directory holding both the current project config name and its legacy name.
 *
 * Its own type rather than a bare `Exception` because `Cli.run` catches exactly this and nothing
 * else: the project's own files disagree, which is a fact about the tree and gets a sentence and
 * an exit code, while any other exception still reaches the reader as the stack an internal bug wants.
 */
@:nullSafety(Strict)
final class ConfigConflict extends Exception {

	public function new(dir: String, current: String, legacy: String) {
		super('$dir holds both $current and $legacy — keep one ($current is the current name)');
	}

}
