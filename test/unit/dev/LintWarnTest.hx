package unit.dev;

import anyparse.grammar.json.JsonFormat;
import dev.HookPayloadWriter;
import dev.LintWarn;
import devkit.TempDir;
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

	/** An existing `.hx` of the tree that reports a finding on its first lint: `MutationArms`, which reads its arm tables as `Any`. */
	private static inline final FIXTURE: String = 'test/testkit/MutationArms.hx';

	public function testAResponseThatWroteNothingIsSilent(): Void {
		Assert.isNull(LintWarn.nudge(payload('hxq refs foo src/', 'src/a.hx:1:1: foo'), null), 'no write in the text at all');
		Assert.isNull(LintWarn.nudge(payload('hxq fmt src/ --write', 'apq fmt: rewrote 0 file(s)'), null), 'a zero count');
		Assert.isNull(LintWarn.nudge(payload('echo x', 'the op: wrote nothing of note'), null), 'prose, not an op');
	}

	public function testTheCommandLineSplitsOnWhitespaceOnly(): Void {
		Assert.same(['hxq', 'patch', '\'a', 'b.hx\'', '--write'], LintWarn.words(' hxq\tpatch \'a b.hx\'\n--write '));
	}

	public function testALoggedWriteLineQuotedByCatIsSilent(): Void {
		inFreshCache(tree -> {
			Assert.isNull(LintWarn.nudge(payload('cat $tree/gate.log', wroteLine(tree)), tree), 'a log read is no write');
			Assert.isNull(
				LintWarn.nudge(payload('cat $tree/gate.log | grep hxq', wroteLine(tree)), tree), 'a quoted program name is no run'
			);
		});
	}

	public function testAWriteByTheEngineIsLinted(): Void {
		inFreshCache(tree -> {
			final nudge: Null<String> = LintWarn.nudge(payload('hxq patch $tree/${FIXTURE} --write', wroteLine(tree)), tree);
			Assert.notNull(nudge, 'the fixture file carries a finding, so the silence above is not vacuous');
		});
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

	/** Runs `body` with the tree this test runs in and a snapshot cache of its own, so a first lint is a first lint. */
	private static function inFreshCache(body: String -> Void): Void {
		final previous: String = Sys.getEnv('XDG_CACHE_HOME') ?? '';
		TempDir.with(dir -> {
			Sys.putEnv('XDG_CACHE_HOME', dir.path);
			body(haxe.io.Path.removeTrailingSlashes(Sys.getCwd()));
		});
		Sys.putEnv('XDG_CACHE_HOME', previous);
	}

	private static function wroteLine(tree: String): String {
		return 'apq patch: wrote $tree/${FIXTURE}';
	}

	private static function payload(command: String, output: String): String {
		return HookPayloadWriter.write({
			sessionId: 's',
			cwd: '/',
			toolInput: { command: command },
			toolResponse: { stdout: output, stderr: '' }
		}, JsonFormat.instance.compactWriteOptions);
	}

}
