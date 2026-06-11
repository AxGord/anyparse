package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if sys
import sys.FileSystem;
#end

/**
 * End-to-end probe for `apq writer-equals`.
 *
 * Verifies the byte-equality writer assertion subcommand: parse + write
 * via the plugin pipeline, compare against an `expected` file's bytes,
 * exit 0 on match / 1 on diff. Covers both the trivia (default) and
 * the plain (`--plain`) pipeline so the Slice-26 lesson — "plain writer
 * flattens anon struct, terminators differ" — is captured as a
 * regression check (concrete expected bytes for each pipeline, byte-
 * level mismatch would force one of the two assertions to fail).
 */
@:nullSafety(Strict)
class ApqWriterEqualsCliTest extends Test {

	public function testTriviaMatch(): Void {
		#if sys
		final input: String = CliFixture.write('apq_writer_equals', 'typedef T = {\n\tvar x:Int;\n}');
		final expected: String = CliFixture.writeAs('apq_writer_equals_expected', 'txt', 'typedef T = {\n\tvar x:Int;\n}\n');
		Assert.equals(0, Cli.run(['writer-equals', input, expected]), 'trivia writer must round-trip a simple typedef byte-identically');
		FileSystem.deleteFile(input);
		FileSystem.deleteFile(expected);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testPlainFlattensAnonStruct(): Void {
		#if sys
		// Captures the Slice-26 lesson: plain writer flattens the
		// anon-struct body and emits a trailing `;`. The trivia writer
		// preserves source layout — the two pipelines diverge by these
		// exact bytes. If a future change made plain match trivia on
		// this input the assertion would fail (because the trivia
		// expected bytes are different — see `testTriviaMatch`).
		final input: String = CliFixture.write('apq_writer_equals', 'typedef T = {\n\tvar x:Int;\n}');
		final expectedPlain: String = CliFixture.writeAs('apq_writer_equals_expected', 'txt', 'typedef T = {var x:Int;};\n');
		Assert.equals(
			0, Cli.run(['writer-equals', '--plain', input, expectedPlain]),
			'plain writer must flatten the anon struct to the canonical form'
		);
		FileSystem.deleteFile(input);
		FileSystem.deleteFile(expectedPlain);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testByteMismatchExits1(): Void {
		#if sys
		final input: String = CliFixture.write('apq_writer_equals', 'class C {}');
		final wrong: String = CliFixture.writeAs('apq_writer_equals_expected', 'txt', 'class WRONG {}\n');
		Assert.equals(1, Cli.run(['writer-equals', input, wrong]), 'byte mismatch must exit 1, not 0 and not 2');
		FileSystem.deleteFile(input);
		FileSystem.deleteFile(wrong);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMissingArgsExitsUsage(): Void {
		Assert.equals(2, Cli.run(['writer-equals']), 'no args → EXIT_USAGE');
		Assert.equals(2, Cli.run(['writer-equals', 'only-one.hx']), 'one arg → EXIT_USAGE');
	}

	public function testUnknownFlagExitsUsage(): Void {
		Assert.equals(2, Cli.run(['writer-equals', '--bogus', 'a', 'b']), 'unknown flag → EXIT_USAGE');
	}

}
