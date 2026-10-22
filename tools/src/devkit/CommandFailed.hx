package devkit;

using StringTools;

/** A `Command` that did not exit 0, thrown by `Result.check`: the message names the command, its status and its stderr. */
@:nullSafety(Strict)
final class CommandFailed extends haxe.Exception {

	public final result: Result;

	public function new(result: Result) {
		super(describe(result));
		this.result = result;
	}

	private static function describe(result: Result): String {
		final why: String = result.failure != '' ? result.failure : 'exited ${result.status}';
		final err: String = result.err.trim();
		return '`${result.command}` $why' + (err == '' ? '' : ':\n$err');
	}

}
