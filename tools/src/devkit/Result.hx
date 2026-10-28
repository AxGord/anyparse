package devkit;

import anyparse.check.HaxeSpawn.HaxeRun;

using StringTools;
using Lambda;

/**
 * What one `Command` run produced: its exit `status` (null when it gave none), both streams, and `failure` — non-empty
 * only when no status could be had at all (not launched, killed by its timeout, out-wrote the stream cap).
 */
@:nullSafety(Strict)
final class Result {

	/** Whether the command ran and exited 0. */
	public var ok(get, never): Bool;

	/** The command as `Command.toString` shows it, for messages. */
	public final command: String;

	public final status: Null<Int>;
	public final out: String;
	public final err: String;
	public final failure: String;

	public function new(command: String, run: HaxeRun) {
		this.command = command;
		status = run.status;
		out = run.out;
		err = run.err;
		failure = run.failure;
	}

	private inline function get_ok(): Bool {
		return status == 0;
	}

	/** The lines of `out` without their `\n`; a final line break ends the last line rather than starting an empty one. */
	public function lines(): Array<String> {
		if (out == '') return [];
		final all: Array<String> = out.split('\n');
		if (all[all.length - 1] == '') all.pop();
		return all;
	}

	/** This result when `ok`; otherwise throws `CommandFailed`, which names the command and why. */
	public function check(): Result {
		if (!ok) throw new CommandFailed(this);
		return this;
	}

	/** The first line of either stream (or of `failure`) that reads like an error, else the first line; for one-line reports. */
	public function firstError(): String {
		final lines: Array<String> = '$err\n$out\n$failure'.split('\n').map(l -> l.trim()).filter(l -> l != '');
		final error: Null<String> = lines.find(l ->
			~/error|Error|ERROR|FAIL|fail|not found|refused|CONFLICT/.match(l) && l.indexOf('Warning') < 0
		);
		return error ?? lines[0] ?? 'exited $status';
	}

}
