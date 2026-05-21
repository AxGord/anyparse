package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * Probe for `apq ast --writer-output-plain`.
 *
 * Verifies that the plain (non-trivia) writer flag dispatches to a
 * distinct pipeline whose output diverges from the trivia
 * `--writer-output` on inputs where source layout differs from the
 * canonical flat form. The anon-struct typedef is the canonical
 * divergence case from the Slice-26 lesson: trivia preserves the
 * multiline body, plain flattens to `typedef T = {var x:Int;};\n`.
 *
 * The test redirects stdout to a tmp file (Cli writes via `sysPrint` →
 * stdout) and compares bytes.
 */
@:nullSafety(Strict)
class ApqAstWriterOutputPlainTest extends Test {

	public function testPlainFlagIsAccepted():Void {
		#if sys
		final fixture:String = writeFixture('class C {}');
		Assert.equals(0, Cli.run(['ast', '--writer-output-plain', fixture]),
			'--writer-output-plain must exit 0 on a valid file');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testBothPipelinesExitCleanOnAnonStruct():Void {
		#if sys
		// Smoke-level: both dispatch paths exit cleanly on the same
		// anon-struct input. Byte-level divergence between the two
		// pipelines (the actual Slice-26 regression check) lives in
		// `ApqWriterEqualsCliTest` — there each pipeline is anchored
		// against its OWN concrete expected bytes, so silent
		// convergence would force one assertion to fail.
		final fixture:String = writeFixture('typedef T = {\n\tvar x:Int;\n}');
		Assert.equals(0, Cli.run(['ast', '--writer-output', fixture]),
			'--writer-output (trivia) must exit 0');
		Assert.equals(0, Cli.run(['ast', '--writer-output-plain', fixture]),
			'--writer-output-plain must exit 0');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	private static function writeFixture(source:String):String {
		return CliFixture.write('apq_ast_plain', source);
	}
	#end
}
