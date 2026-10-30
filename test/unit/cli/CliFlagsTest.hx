package unit.cli;

import anyparse.query.Cli;
import anyparse.query.ExitCode;
import anyparse.query.cli.CliFlags;
import anyparse.query.cli.CliRegistry;

/**
 * A command's flag spec says which argv tokens are flags, which are a flag's value and which are positionals; the
 * dispatcher refuses a `--word` the spec does not declare.
 */
@:nullSafety(Strict)
class CliFlagsTest extends Test {

	/** A valued flag's value and the separator are no positionals; a switch leaves the token after it one. */
	public function testPositionalsSkipValuesAndTheSeparator(): Void {
		final spec: CliFlags = new CliFlags(['--write'], ['--select']);
		Assert.same([0, 4, 6], spec.positionals(['F.hx', '--select', 'X', '--write', 'G.hx', '--', 'H.hx']));
		Assert.same([2], spec.positionals(['--lang', 'haxe', 'F.hx', '--bogus']));
	}

	/** An undeclared `--word` is named; a declared or global flag, a flag's value and a short token are not. */
	@:killer('M-CLI-UNKNOWN-FLAG-ADMITTED')
	@:pin('control')
	public function testAnUndeclaredLongFlagIsUnknown(): Void {
		final spec: CliFlags = new CliFlags(['--write'], ['--select']);
		Assert.equals('--bogus', spec.unknownFlag(['F.hx', '--write', '--bogus']));
		Assert.isNull(spec.unknownFlag(['F.hx', '--select', '--bogus', '--lang', 'haxe', '--help', '-', '-x', '--']));
	}

	/** A spec whose `--` ends the options reads every token after it as a positional, a flag-shaped one too. */
	public function testASeparatorThatEndsOptions(): Void {
		final args: Array<String> = ['--json', '--kind', 'K', '--', "--$x", 'src'];
		final ending: CliFlags = new CliFlags(['--json'], ['--kind'], true);
		Assert.same([4, 5], ending.positionals(args));
		Assert.isNull(ending.unknownFlag(args));
		Assert.equals("--$x", new CliFlags(['--json'], ['--kind']).unknownFlag(args));
	}

	/** The dispatcher refuses an unknown flag with a usage error, for any registered command. */
	public function testTheDispatcherRefusesAnUnknownFlag(): Void {
		Assert.equals(ExitCode.EXIT_USAGE, Cli.run(['refs', 'x', '--bogus', 'src']));
		Assert.equals(ExitCode.EXIT_USAGE, Cli.run(['test-summary', '--bogus', 'log.txt']));
	}

	/** Every registered command declares each of its flags once, as either a switch or a valued flag. */
	public function testEveryCommandDeclaresAFlagOnce(): Void {
		for (command in CliRegistry.commands()) {
			final names: Array<String> = command.flags().names();
			for (name in names) Assert.equals(1, names.filter(n -> n == name).length, '${command.name()} declares $name twice');
		}
	}

	/**
	 * Every option a command's `--help` lists is one its spec declares, taking a value exactly when the help spells one
	 * (`--flag <arg>`, `--limit N`); a bare `--flag` or an optional `--flag [<arg>]` takes none. Until the parsers read the spec
	 * themselves, this holds the spec to what each command documents.
	 */
	public function testEveryHelpOptionMatchesTheSpec(): Void {
		final option: EReg = ~/^ {1,4}(?:-[A-Za-z], )?(--[A-Za-z][A-Za-z0-9-]*)(.*)$/;
		// A `<placeholder>`, or a bare one (`N`, `a,b`, `-`) closing the column; a description after one space runs on in words.
		final valued: EReg = ~/^(?:=| )'?<|^ [^ \[]\S*(?: {2,}|$)/;
		final stdinMarker: EReg = ~/^ -(?: |$)/;
		for (command in CliRegistry.commands()) {
			final flags: CliFlags = command.flags();
			for (line in CliFixture.captureStdout(command.usage).split('\n')) if (option.match(line)) {
				final flag: String = option.matched(1);
				final where: String = '${command.name()}: $line';
				Assert.isTrue(flags.declares(flag), where);
				final rest: String = option.matched(2);
				// A `-` placeholder is the stdin marker, which `new --raw` reads optionally and `--bodies` as its value.
				if (!stdinMarker.match(rest)) Assert.equals(valued.match(rest), flags.takesValue(flag), where);
			}
		}
	}

	/** `probe` forwards `ast`'s switches without a value, so `--count` does not eat the code. */
	public function testProbeReadsAstsSwitches(): Void {
		Assert.equals(ExitCode.EXIT_OK, Cli.run(['probe', '--count', 'class C {}']));
	}

}
