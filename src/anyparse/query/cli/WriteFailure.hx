package anyparse.query.cli;

import haxe.Exception;

/**
 * A write that did not happen, carrying the file it was for.
 *
 * Its own type rather than a bare `Exception` because `Cli.run` catches exactly this and
 * nothing else. An internal error still reaches the reader as a stack trace, which is what a
 * bug wants; a file the run cannot write is a fact about the environment, and gets a sentence
 * and an exit code.
 */
@:nullSafety(Strict)
final class WriteFailure extends Exception {

	/** The file the write was for, spelled the way the caller spelled it — never the staging temporary. */
	public final path: String;

	public function new(path: String, reason: String) {
		super('cannot write $path: $reason');
		this.path = path;
	}

}
