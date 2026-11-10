package unit.cli;

import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * An integer flag's value that is not an integer is a usage mistake — exit 2 naming the flag and the value —
 * on every command that reads one, not a silently ignored `null`: `apq get --where n=1 --nth abc` used to exit 0
 * because the null `--nth` slipped past the `--where`/`--nth` refusal.
 */
@:nullSafety(Strict)
class CliIntFlagRefusesNonIntCliTest extends Test {

	private static final DOCUMENT: String = '[{"n": 1}, {"n": 2}]';
	private static final CODE: String = 'class C {\n\tfunction f(a: Int): Void {}\n}\n';
	private static final LIST: String = '{"list": [7, 8]}';
	private static final TWO: String = '{"a": {"list": [1]}, "b": {"list": [2]}}';

	/** `get --where … --nth abc` exits 2 and names the flag and the value. */
	@:killer('M-INT-FLAG-NON-INT-READS-AS-ZERO')
	@:pin('control')
	public function testGetRefusesANonIntegerNth(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.writeAs('int_flag_get', 'json', DOCUMENT);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['get', '--where', 'n=1', '--nth', 'abc', f]));
		Assert.equals(2, exit, 'a non-integer --nth is a usage error');
		Assert.isTrue(err.indexOf('--nth expects an integer, got "abc"') >= 0, 'stderr names the flag and the value: $err');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A second command, a second parser: `add-param … --nth abc` refuses the same way. */
	@:killer('M-INT-FLAG-NON-INT-READS-AS-ZERO')
	@:pin('control')
	public function testAddParamRefusesANonIntegerNth(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('int_flag_add_param', CODE);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['add-param', f, '2:2', '?b: Int', '--nth', 'abc']));
		Assert.equals(2, exit, 'a non-integer --nth is a usage error');
		Assert.isTrue(err.indexOf('--nth expects an integer, got "abc"') >= 0, 'stderr names the flag and the value: $err');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A well-formed integer is read as before: `--nth 1` picks the first of the matches. */
	@:killer('M-INT-FLAG-VALUE-LOST')
	@:pin('control')
	public function testAValidIntegerIsUnchanged(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.writeAs('int_flag_valid', 'json', TWO);
		var exit: Int = -1;
		final out: String = CliFixture.captureStdout(() -> exit = Cli.run(['get', '--select', 'Member:list', '--nth', '2', f, '0']));
		Assert.equals(0, exit);
		Assert.equals('2\n', out);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An absent flag never reaches the reader: the command answers as it did. */
	@:pin('guard')
	public function testAnAbsentFlagIsUnchanged(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.writeAs('int_flag_absent', 'json', LIST);
		var exit: Int = -1;
		final out: String = CliFixture.captureStdout(() -> exit = Cli.run(['get', '--select', 'Member:list', f, '0']));
		Assert.equals(0, exit);
		Assert.equals('7\n', out);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A value past Int32 is refused, not read as a double typed `Int`. */
	@:killer('M-INT-FLAG-PREFIX-PARSE')
	@:pin('control')
	public function testAnOverInt32ValueIsRefused(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.writeAs('int_flag_big', 'json', DOCUMENT);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['get', '--where', 'n=1', '--nth', '99999999999999999999', f]));
		Assert.equals(2, exit, 'an over-Int32 --nth is a usage error');
		Assert.isTrue(err.indexOf('--nth expects an integer, got "99999999999999999999"') >= 0, 'stderr names the value: $err');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--limit` is read by the same reader: `--limit 1x` is refused on a walker, not read as 1. */
	@:killer('M-LIMIT-PREFIX-PARSE')
	@:pin('control')
	public function testALimitWithTrailingTextIsRefused(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('int_flag_limit', CODE);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['refs', 'f', f, '--limit', '1x']));
		Assert.equals(2, exit, 'a --limit with trailing text is a usage error');
		Assert.isTrue(err.indexOf('--limit expects an integer, got "1x"') >= 0, 'stderr names the value: $err');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A flag with its own range check reads the integer through the same reader: `ast --depth 1x` is refused. */
	@:killer('M-AST-DEPTH-PREFIX-PARSE')
	@:pin('control')
	public function testARangeCheckedFlagWithTrailingTextIsRefused(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('int_flag_depth', CODE);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['ast', f, '--depth', '1x']));
		Assert.equals(2, exit, 'an --depth with trailing text is a usage error');
		Assert.isTrue(err.indexOf('--depth expects an integer, got "1x"') >= 0, 'stderr names the value: $err');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A trailing-garbage value is not an integer either. */
	@:killer('M-INT-FLAG-PREFIX-PARSE')
	@:pin('control')
	public function testATrailingGarbageValueIsRefused(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.writeAs('int_flag_garbage', 'json', DOCUMENT);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['get', '--where', 'n=1', '--nth', '1x', f]));
		Assert.equals(2, exit, 'a value with trailing text is a usage error');
		Assert.isTrue(err.indexOf('--nth expects an integer, got "1x"') >= 0, 'stderr names the value: $err');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
