package unit.cli;

import anyparse.query.Cli;
import anyparse.query.ExitCode;
import anyparse.query.cli.CliArg;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliFlags;
import anyparse.query.cli.CliRegistry;
import anyparse.query.cli.UsageFailure;
import anyparse.query.cli.command.AddElementCommand;
import anyparse.query.cli.command.NewCommand;
import anyparse.query.cli.command.RefsCommand;
import anyparse.query.cli.command.SweepCommand;
import haxe.Exception;

/**
 * A command's flag spec says which argv tokens are flags, which are a flag's value and which are positionals; the
 * dispatcher refuses a `--word` the spec does not declare.
 */
@:nullSafety(Strict)
class CliFlagsTest extends Test {

	/** A valued flag's value and the separator are no positionals; a switch leaves the token after it one. */
	public function testPositionalsSkipValuesAndTheSeparator(): Void {
		final spec: CliFlags = new CliFlags(['--write'], ['--select'], Splits);
		Assert.same([0, 4, 6], spec.positionals(['F.hx', '--select', 'X', '--write', 'G.hx', '--', 'H.hx']));
		Assert.same([2], spec.positionals(['--lang', 'haxe', 'F.hx', '--bogus']));
	}

	/** An undeclared `--word` is named; a declared or global flag, a flag's value and a short token are not. */
	@:killer('M-CLI-UNKNOWN-FLAG-ADMITTED')
	@:pin('control')
	public function testAnUndeclaredLongFlagIsUnknown(): Void {
		final spec: CliFlags = new CliFlags(['--write'], ['--select'], Splits);
		Assert.equals('--bogus', spec.unknownFlag(['F.hx', '--write', '--bogus']));
		Assert.isNull(spec.unknownFlag(['F.hx', '--select', '--bogus', '--lang', 'haxe', '--help', '-', '-x', '--']));
	}

	/** A spec whose `--` ends the options reads every token after it as a positional, a flag-shaped one too. */
	public function testASeparatorThatEndsOptions(): Void {
		final args: Array<String> = ['--json', '--kind', 'K', '--', "--$x", 'src'];
		final ending: CliFlags = new CliFlags(['--json'], ['--kind'], EndsOptions);
		Assert.same([4, 5], ending.positionals(args));
		Assert.isNull(ending.unknownFlag(args));
		Assert.equals("--$x", new CliFlags(['--json'], ['--kind'], Splits).unknownFlag(args));
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
	 * (`--flag <arg>`, `--limit N`) and an optional one exactly when it spells `--flag [<arg>]`. The parsers read the spec, so
	 * this holds what each command documents to what it reads.
	 */
	public function testEveryHelpOptionMatchesTheSpec(): Void {
		final option: EReg = ~/^ {1,4}(?:-[A-Za-z], )?(--[A-Za-z][A-Za-z0-9-]*)(.*)$/;
		// A `<placeholder>`, or a bare one (`N`, `a,b`, `-`) closing the column; a description after one space runs on in words.
		final valued: EReg = ~/^(?:=| )'?<|^ [^ \[]\S*(?: {2,}|$)/;
		final stdinMarker: EReg = ~/^ -(?: |$)/;
		final optional: EReg = ~/^ \[/;
		var checked: Int = 0;
		for (command in CliRegistry.commands()) {
			final flags: CliFlags = command.flags();
			for (line in CliFixture.captureStdout(command.usage).split('\n')) if (option.match(line)) {
				final flag: String = option.matched(1);
				final where: String = '${command.name()}: $line';
				Assert.isTrue(flags.declares(flag), where);
				final rest: String = option.matched(2);
				// A `-` placeholder is the stdin marker, which `new --raw` reads optionally and `--bodies` as its value.
				if (!stdinMarker.match(rest)) {
					Assert.equals(valued.match(rest), flags.takesValue(flag), where);
					Assert.equals(optional.match(rest), flags.takesOptionalValue(flag), where);
				}
				checked++;
			}
		}
		Assert.isTrue(checked > 0, 'no help line read as an option');
	}

	/** `probe` forwards `ast`'s switches without a value, so `--count` does not eat the code. */
	public function testProbeReadsAstsSwitches(): Void {
		Assert.equals(ExitCode.EXIT_OK, Cli.run(['probe', '--count', 'class C {}']));
	}

	/** A parser reads each flag with the value its spec says it takes, and each positional with its argv index. */
	public function testWalkPairsEachFlagWithItsValue(): Void {
		final spec: CliFlags = new CliFlags(['--write'], ['--select']);
		final read: Array<String> = [
			for (arg in spec.walk(['F.hx', '--select', '--write', '--write', '--lang', 'haxe', 'G.hx']))
				arg.flag == null ? 'pos ${arg.token}@${arg.index}' : arg.hasValue() ? '${arg.flag}=${arg.value()}' : '${arg.flag}'
		];
		Assert.same(['pos F.hx@0', '--select=--write', '--write', '--lang=haxe', 'pos G.hx@6'], read);
	}

	/** An optional-value flag takes the next token only when its own test accepts it; alone it reads as a switch. */
	@:killer('M-CLI-OPTIONAL-VALUE-NEVER-TAKEN')
	@:pin('control')
	public function testAnOptionalValueFlagTakesOnlyWhatItAccepts(): Void {
		final spec: CliFlags = new CliFlags([], ['--select']).withOptional('--after', CliArgs.isPosSpec);
		final read: Array<CliArg> = spec.walk(['F.hx', '--after', '3:4', 'x', '--after', '--select', 'S']);
		Assert.equals('3:4', read[1].valueOr(''));
		Assert.equals('x', read[2].token);
		Assert.isFalse(read[3].hasValue());
		Assert.same([0, 3], spec.positionals(['F.hx', '--after', '3:4', 'x']));
		Assert.isTrue(spec.takesOptionalValue('--after'));
		Assert.isFalse(spec.takesValue('--after'));
	}

	/** A walk refuses an undeclared `--word` and a valued flag argv ends on, as usage errors. */
	public function testWalkRefusesWhatItCannotRead(): Void {
		final spec: CliFlags = new CliFlags(['--write'], ['--select']);
		Assert.raises(() -> spec.walk(['F.hx', '--bogus']), UsageFailure);
		Assert.raises(() -> spec.walk(['F.hx', '--select']), UsageFailure);
		Assert.raises(() -> spec.walk(['--write'])[0].value(), Exception);
	}

	/** A flag counts as given only where it is read as a flag, never as another flag's value. */
	public function testGivenSkipsAFlagsValue(): Void {
		final spec: CliFlags = new CliFlags(['--write'], ['--name']);
		Assert.isTrue(spec.given(['F.hx', '--write'], '--write'));
		Assert.isFalse(spec.given(['F.hx', '--name', '--write'], '--write'));
	}

	/** `sweep --diff` alone, `new --raw -` and `add-element --after <pos>` parse as their specs declare them. */
	public function testOptionalValueFlagsOfTheCommands(): Void {
		Assert.isTrue(new SweepCommand().flags().takesOptionalValue('--diff'));
		final raw: Array<CliArg> = new NewCommand().flags().walk(['A.hx', '--raw', '-']);
		Assert.equals(2, raw.length);
		Assert.equals('-', raw[1].value());
		final after: Array<CliArg> = new AddElementCommand().flags().walk(['F.hx', '--after', '3', 'x']);
		Assert.equals('3', after[1].value());
	}

	/** A flag its spec gives two values takes both tokens after it, and neither is a positional (`graph --diff A B src`). */
	public function testAFlagWithTwoValuesTakesBoth(): Void {
		final spec: CliFlags = new CliFlags([], []).withValues('--diff', 2);
		final read: Array<CliArg> = spec.walk(['--diff', 'HEAD~1', 'HEAD', 'src']);
		Assert.equals('HEAD', read[0].valueAt(1));
		Assert.same([3], spec.positionals(['--diff', 'HEAD~1', 'HEAD', 'src']));
		Assert.raises(() -> spec.walk(['--diff', 'HEAD~1']), UsageFailure);
	}

	/** A bare `--` is an unknown option to a command whose parser reads no separator, and a split to one that does. */
	@:killer('M-CLI-SEPARATOR-ALWAYS-ADMITTED')
	@:pin('control')
	public function testABareSeparatorIsRefusedUnlessTheCommandReadsIt(): Void {
		Assert.equals('--', new CliFlags(['--write'], []).unknownFlag(['F.hx', '--', 'G.hx']));
		Assert.equals(ExitCode.EXIT_USAGE, Cli.run(['fmt', '--', 'F.hx']));
		Assert.equals(ExitCode.EXIT_USAGE, Cli.run(['lint', 'F.hx', '--', '--no-oracle']));
		final refs: Array<CliArg> = new RefsCommand().flags().walk(['a', 'b', '--', 'src']);
		Assert.same(['a', '--', 'src'], [refs[0].token, refs[2].flag, refs[3].token]);
		Assert.isNull(new RefsCommand().flags().unknownFlag(['a', 'b', '--', 'src']));
	}

}
