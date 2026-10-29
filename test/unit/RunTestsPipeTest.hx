package unit;

import devkit.Command;
import devkit.Result;
import devkit.TempDir;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * The runner's transcript reaches a reader through a PIPE whole. utest's report ends the process with `process.exit`
 * straight after printing; where a pipe is written asynchronously that dropped the tail of a long transcript, and a
 * mutation track read through a pipe saw a failure list cut off mid-name.
 */
@:nullSafety(Strict)
final class RunTestsPipeTest extends Test {

	@:pin('control')
	@:killer('M-RUNNER-PIPE-ASYNC')
	public function testAPipedTranscriptOutlivesTheExitThatEndsIt(): Void {
		TempDir.with(dir -> {
			final input: String = dir.file('transcript');
			final text: String = [for (i in 0...20000) 'line $i of a transcript longer than any pipe buffer'].join('\n');
			File.saveContent(input, text);
			final ran: Result = Command.of([js.Node.process.execPath, js.Node.__filename])
				.env('APQ_TEST_CHILD', 'flood')
				.env('APQ_TEST_CHILD_INPUT', input)
				.run();
			Assert.equals(0, ran.status, ran.err);
			Assert.equals(text.length, ran.out.length);
		});
	}

}
