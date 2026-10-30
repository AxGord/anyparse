package anyparse.query.cli.command;

/**
 * `apq push-down` — move an instance member down to a subclass.
 *
 * The mirror of `pull-up`, and the one command that is nothing but a direction:
 * both share `PullUpCommand.runInheritanceMove`, which is the same edit read the
 * other way round.
 */
@:nullSafety(Strict)
final class PushDownCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'push-down';
	}

	public function summary(): String {
		return 'Move an instance member down to a subclass';
	}

	public function flags(): CliFlags {
		return new PullUpCommand().flags();
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return PullUpCommand.runInheritanceMove(args, false);
	}

	public function usage(): Void {
		PullUpCommand.printInheritanceMoveUsage(false);
	}

}
