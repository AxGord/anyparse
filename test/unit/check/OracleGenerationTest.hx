package unit.check;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.check.CompilerOracle;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.OracleGeneration;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A `compilerOracle` entry's `generate` command (`OracleGeneration`), against a real shell: the
 * command runs exactly when its recorded generation is not current — the hxml missing, an input's
 * content changed, the command itself changed — and a command that fails makes its configuration
 * unavailable instead of letting a stale hxml answer.
 *
 * Every fixture counts its runs in `runs.txt`, which the command appends to, so "ran" and "did not
 * run" are both observed rather than inferred from a note.
 */
@:nullSafety(Strict)
final class OracleGenerationTest extends Test {

	#if (sys || nodejs)
	private static final MAIN: String = 'class Main {\n\n\tpublic static function main() {\n\t\ttrace(1);\n\t}\n\n}\n';

	/** Writes a valid hxml and appends one line to `runs.txt`. */
	private static final WRITE: String = "printf '%s\\n' '-cp .' '-main Main' > gen.hxml && echo run >> runs.txt";
	#end

	/**
	 * A changed `generateInputs` file regenerates; the SAME call with the input unchanged does not —
	 * without that half a generation that ran every time would pass.
	 */
	@:pin('control')
	@:killer('M-GENERATE-NEVER-STALE-BY-INPUT')
	public function testAChangedInputRegeneratesAndAnUnchangedOneDoesNot(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		OracleGeneration.prepare([config]);
		Assert.equals(1, runs(dir), 'the first use generates the missing hxml');
		OracleGeneration.prepare([config]);
		Assert.equals(1, runs(dir), 'an unchanged input leaves the recorded generation current');
		File.saveContent('$dir/input.txt', 'two');
		final notes: Array<String> = OracleGeneration.prepare([config]).notes;
		Assert.equals(2, runs(dir), 'a changed input regenerates');
		Assert.isTrue(notes.length == 1 && notes[0].contains('input.txt changed'), 'and says which input: $notes');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A different command string regenerates even though no input changed. */
	@:pin('control')
	@:killer('M-GENERATE-NEVER-STALE-BY-COMMAND')
	public function testAChangedCommandRegenerates(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		OracleGeneration.prepare([entry(dir, WRITE, ['$dir/input.txt'])]);
		OracleGeneration.prepare([entry(dir, WRITE, ['$dir/input.txt'])]);
		Assert.equals(1, runs(dir), 'the same command over the same input runs once');
		OracleGeneration.prepare([entry(dir, '$WRITE # changed', ['$dir/input.txt'])]);
		Assert.equals(2, runs(dir), 'a changed command runs again');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An hxml deleted after its generation was recorded is regenerated, not reported current. */
	@:pin('control')
	@:killer('M-GENERATE-TRUSTS-A-MISSING-HXML')
	public function testAMissingHxmlRegenerates(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		OracleGeneration.prepare([config]);
		FileSystem.deleteFile('$dir/gen.hxml');
		OracleGeneration.prepare([config]);
		Assert.equals(2, runs(dir), 'the missing hxml is regenerated');
		Assert.isTrue(FileSystem.exists('$dir/gen.hxml'), 'and exists again');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A failing command makes its configuration UNAVAILABLE with the command's output quoted, and
	 * the typecheck answers so — although a valid hxml from an earlier generation is still on disk
	 * and would typecheck green. Reading that stale file is exactly the silent answer this forbids.
	 */
	@:pin('control')
	@:killer('M-GENERATE-FAILURE-USES-THE-STALE-HXML')
	public function testAFailedGenerationIsUnavailableNeverTheStaleHxml(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		File.saveContent('$dir/gen.hxml', '-cp .\n-main Main\n');
		final stale: OracleConfig = entry(dir, 'echo boom-from-the-command; exit 3', null);
		if (!CompilerOracle.typecheck(stale.hxml, stale.dir).match(Confirmed)) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final ready: Array<OracleConfig> = OracleGeneration.prepare([stale]).oracles;
		final reason: String = ready[0].unavailable ?? '';
		Assert.isTrue(reason.contains('exited 3') && reason.contains('boom-from-the-command'), 'the failure is quoted: $reason');
		final verdict: OracleOutcome = CompilerOracle.typecheckAll(ready);
		Assert.isTrue(verdict.match(Unavailable(_)), 'the configuration could not run — the stale hxml is not asked: $verdict');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function fixture(): String {
		return CliFixture.writeDir('oraclegen', [{ name: 'Main.hx', source: MAIN }, { name: 'input.txt', source: 'one' }]);
	}

	/** One configuration whose hxml `command` writes in `dir`. */
	private static function entry(dir: String, command: String, inputs: Null<Array<String>>): OracleConfig {
		return {
			hxml: '$dir/gen.hxml',
			dir: dir,
			defines: [],
			generate: {
				command: command,
				root: dir,
				inputs: inputs,
				probeDir: false
			}
		};
	}

	/** How many times the fixture's command ran. */
	private static function runs(dir: String): Int {
		final path: String = '$dir/runs.txt';
		return FileSystem.exists(path) ? [for (line in File.getContent(path).split('\n')) if (line != '') line].length : 0;
	}
	#end

}
