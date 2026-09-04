package unit.cli;

#if nodejs
import js.Node;
#end
import anyparse.query.Cli;
import anyparse.query.cli.CliCommand;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.CliRegistry;
import haxe.Exception;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * The command seam — `CliCommand` + `CliRegistry` + `CliContext` — and the two
 * things a decomposition wave can silently break.
 *
 * S69 moved three commands of three different shapes (`cases` a read-only
 * walk, `set-comment` a single-file edit, `make-final` a `--scope` edit) out of
 * `Cli.dispatch`'s 200-line switch onto a registry the dispatcher reads. S70
 * repeats that move for the remaining 66, and each repetition can go wrong in
 * exactly two ways that nothing else notices:
 *
 * - the command is registered but never LISTED, because `printUsage` still
 *   holds a literal for it (or holds neither) — `apq --help` then disagrees
 *   with what `apq` can actually run;
 * - the command is registered and its old `case` arm is left behind, which is
 *   now DEAD (the registry lookup runs before the switch) and is a second
 *   source of truth waiting to drift.
 *
 * Both arms below read the registry rather than a list of names, so a command
 * added in a later wave is covered the moment it is registered.
 *
 * The remaining arms pin the two decisions that are invisible in the output:
 * the run context is per-run state, and the registry hands out a fresh command
 * per call rather than memoising one in a `static final`. Both are invariant 1
 * at the CLI layer — a process-scoped cache here is the shape that made a
 * parallel parse silently corrupt.
 */
@:nullSafety(Strict)
class CliCommandSeamTest extends Test {

	/**
	 * The three `apq --help` lines S69's registry took over, byte for byte as
	 * the hand-written list printed them at base `cbde910e`.
	 *
	 * Written out here rather than derived from `summary()`, deliberately: a
	 * pin built from the same declaration the code renders from cannot fail.
	 * These bytes come from the BASE binary's output, so they discriminate
	 * both halves of the rendering — the summary text AND the padding rule.
	 * KILLED by `CliRegistry.HELP_NAME_WIDTH` 13 -> 12, and by any edit to a
	 * piloted command's `summary()`.
	 */
	private static final PILOTED_HELP_LINES: Array<String> = [
		'  cases         Precise case-pattern lookup (case Ctor: / case Ctor(_): / case A | Ctor:)\n',
		'  set-comment   Replace the comment at a cursor (line run or block)\n',
		'  make-final    Turn a never-reassigned var field into final\n'
	];

	/** Every command the registry owns is listed by `apq --help`, whoever added it. */
	public function testEveryRegisteredCommandIsListedInHelp(): Void {
		#if nodejs
		final help: String = captureStdout(['--help']);
		for (command in CliRegistry.commands()) {
			final line: String = CliRegistry.helpLine(command.name());
			Assert.isTrue(help.indexOf(line) >= 0, 'apq --help does not list "${command.name()}" as: $line');
		}
		#else
		Assert.pass();
		#end
	}

	/** The generated line is the one the hand-written list printed — same bytes, same column. */
	public function testTheGeneratedHelpLineIsTheOneTheHandListPrinted(): Void {
		for (expected in PILOTED_HELP_LINES) {
			final name: String = expected.substring(2, expected.indexOf(' ', 2));
			Assert.equals(expected, CliRegistry.helpLine(name));
		}
	}

	/**
	 * A registered command has NO `case` arm left in `Cli.dispatch`.
	 *
	 * The lookup runs before the switch, so a leftover arm is unreachable — it
	 * compiles, it never runs, and it keeps a second copy of the command's
	 * entry point alive for someone to edit. This is the arm that catches a
	 * half-finished S70 move.
	 */
	public function testARegisteredCommandHasNoLeftoverDispatchArm(): Void {
		#if (sys || nodejs)
		final source: String = File.getContent('${CliFixture.repoRoot()}/src/anyparse/query/Cli.hx');
		for (command in CliRegistry.commands()) {
			final arm: String = 'case \'${command.name()}\':';
			Assert.equals(
				-1, source.indexOf(arm),
				'Cli.dispatch still carries `$arm` for a registered command — the registry runs first, so that arm is dead'
			);
		}
		#else
		Assert.pass();
		#end
	}

	/**
	 * `--exit-on-empty` is a fact about ONE invocation, and the next one in the
	 * same process must not see it.
	 *
	 * CONTROL at base `cbde910e`, where `dispatch` reset its `private static var`
	 * on entry — the pin exists because moving that flag onto `CliContext` is
	 * what removes the static, and nothing else would notice it coming back.
	 * KILLED by giving `CliContext.requireMatch` a static backing, or by
	 * dropping the reset that still serves the 66 unmigrated commands.
	 */
	public function testTheRequireMatchFlagDoesNotSurviveItsRun(): Void {
		#if nodejs
		final file: String = CliFixture.write('seam_ctx', 'enum E {\n\tRed;\n}\n');
		var strict: Int = -1;
		var lenient: Int = -1;
		final nudges: String = CliFixture.captureStderr(() -> {
			strict = Cli.run(['cases', 'Missing', file, '--exit-on-empty']);
			lenient = Cli.run(['cases', 'Missing', file]);
		});
		Assert.equals(1, strict, nudges);
		Assert.equals(0, lenient, 'the next run must not inherit --exit-on-empty: $nudges');
		#else
		Assert.pass();
		#end
	}

	/**
	 * The registry allocates per call instead of memoising a shared array.
	 *
	 * A `static final COMMANDS` would be process-scoped state holding objects
	 * every run shares, which is the invariant-1 shape however stateless the
	 * implementations happen to be today. KILLED by memoising `commands()`.
	 */
	public function testTheRegistryHandsOutAFreshCommandPerCall(): Void {
		final first: Array<CliCommand> = CliRegistry.commands();
		final second: Array<CliCommand> = CliRegistry.commands();
		Assert.equals(first.length, second.length);
		for (i in 0...first.length) Assert.isFalse(first[i] == second[i], 'command ${first[i].name()} is shared between runs');
	}

	/** A name the registry does not own is a programming error, not a null. */
	public function testHelpLineRefusesAnUnregisteredName(): Void {
		Assert.raises(CliRegistry.helpLine.bind('no-such-command'));
	}

	/** The context a command is handed answers the run's own emptiness convention. */
	public function testTheContextAnswersEmptinessFromTheRunsOwnFlag(): Void {
		Assert.equals(0, new CliContext(false).emptyExit(true));
		Assert.equals(0, new CliContext(false).emptyExit(false));
		Assert.equals(1, new CliContext(true).emptyExit(true));
		Assert.equals(0, new CliContext(true).emptyExit(false));
	}

	#if nodejs
	/** Run `Cli.run(argv)` with stdout captured, and answer what it printed. */
	private static function captureStdout(argv: Array<String>): String {
		final buffer: StringBuf = new StringBuf();
		final stdout: Dynamic = Node.process.stdout; // noqa: avoid-dynamic
		final original: Dynamic = Reflect.field(stdout, 'write'); // noqa: avoid-dynamic
		Reflect.setField(stdout, 'write', (chunk: Any) -> {
			buffer.add('$chunk');
			return true;
		});
		try Cli.run(argv) catch (exception: Exception) {
			Reflect.setField(stdout, 'write', original);
			throw exception;
		}
		Reflect.setField(stdout, 'write', original);
		return buffer.toString();
	}
	#end

}
