package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

#if sys
import sys.FileSystem;
#end

/**
 * End-to-end probe for `apq writer-probe` — emits trivia + plain
 * writer outputs side-by-side from a single CLI invocation. Replaces
 * the two-command dance (`hxq ast --writer-output` then
 * `--writer-output-plain`) when constructing a unit-test
 * `writerEquals` expected literal.
 *
 * Asserts exit codes only — stdout is written via Sys.print. The
 * pipeline divergence between trivia and plain (anon flatten,
 * trailing `;`, comments) is covered by the existing
 * `ApqWriterEqualsCliTest`; here we verify both pipelines run
 * independently and only-both-success → exit 0.
 */
@:nullSafety(Strict)
class ApqWriterProbeCliTest extends Test {

	public function testHelpReturnsOk():Void {
		Assert.equals(0, Cli.run(['writer-probe', '--help']));
	}

	public function testSimpleClassSucceeds():Void {
		#if sys
		final input:String = CliFixture.write('apq_writer_probe', 'class C {}');
		Assert.equals(0, Cli.run(['writer-probe', input]));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTypedefAnonStructSucceeds():Void {
		// The pipeline divergence target: trivia keeps layout, plain
		// flattens — both must succeed independently.
		#if sys
		final input:String = CliFixture.write('apq_writer_probe', 'typedef T = {\n\tvar x:Int;\n}');
		Assert.equals(0, Cli.run(['writer-probe', input]));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testUnparseableInputExitsRuntime():Void {
		#if sys
		final input:String = CliFixture.write('apq_writer_probe', 'class C {');
		Assert.equals(1, Cli.run(['writer-probe', input]));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMissingFileExitsUsage():Void {
		Assert.equals(2, Cli.run(['writer-probe']));
	}

	public function testUnknownFlagExitsUsage():Void {
		Assert.equals(2, Cli.run(['writer-probe', '--bogus', 'foo.hx']));
	}

	public function testTwoFilesExitsUsage():Void {
		Assert.equals(2, Cli.run(['writer-probe', 'a.hx', 'b.hx']));
	}
}
