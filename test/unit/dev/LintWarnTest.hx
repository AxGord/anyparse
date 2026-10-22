package unit.dev;

import dev.LintWarn;
import devkit.TempDir;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * The lint-warn hook body's reading of a payload: when it stays silent before linting anything, how it splits a command
 * line, and which written `.hx` files of the op's tree it lints. The nudge itself is the acceptance matrix's
 * (`dev lint-warn-probe`), which drives the installed hook end to end.
 */
@:nullSafety(Strict)
final class LintWarnTest extends Test {

	public function testAResponseThatWroteNothingIsSilent(): Void {
		Assert.isNull(LintWarn.nudge(payload('hxq refs foo src/', 'src/a.hx:1:1: foo'), null), 'no write in the text at all');
		Assert.isNull(LintWarn.nudge(payload('hxq fmt src/ --write', 'apq fmt: rewrote 0 file(s)'), null), 'a zero count');
		Assert.isNull(LintWarn.nudge(payload('echo x', 'the op: wrote nothing of note'), null), 'prose, not an op');
	}

	public function testTheCommandLineSplitsOnWhitespaceOnly(): Void {
		Assert.same(['hxq', 'patch', '\'a', 'b.hx\'', '--write'], LintWarn.words(' hxq\tpatch \'a b.hx\'\n--write '));
	}

	public function testTheWrittenFilesOfTheTree(): Void {
		TempDir.with(dir -> {
			final root: String = dir.path;
			FileSystem.createDirectory('$root/src');
			for (name in ['A.hx', 'B.hx', 'C.hx']) File.saveContent('$root/src/$name', '');
			final wrote: Array<String> = [
				'apq patch: wrote src/A.hx',
				'apq set-doc: wrote $root/src/B.hx (doc)',
				'apq fmt: rewrote 2 file(s)'
			];
			final tokens: Array<String> = LintWarn.words('hxq x \'src/C.hx\' src/A.hx:12:3 src/Gone.hx docs/x.md /elsewhere/D.hx');
			Assert.same(['$root/src/A.hx', '$root/src/B.hx', '$root/src/C.hx'], LintWarn.written(wrote, tokens, root));
		});
	}

	private static function payload(command: String, output: String): String {
		return Json.stringify({
			session_id: 's',
			cwd: '/',
			tool_input: { command: command },
			tool_response: { stdout: output, stderr: '' }
		});
	}

}
