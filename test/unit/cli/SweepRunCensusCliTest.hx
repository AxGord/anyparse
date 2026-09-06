package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;
import anyparse.query.cli.command.SweepCommand;
import utest.Assert;
import utest.Test;

/**
 * End-to-end probe for `apq sweep --run` — the corpus census re-derived
 * from the fixtures rather than read out of `bin/.last-sweep.json`.
 *
 * Why it exists: `781 pass / 120 fail / 43 skip-parse` is quoted as a gate in
 * every slice of this project, and the only thing that could produce it was a
 * full `node bin/test.js` under `$ANYPARSE_HXFORMAT_FORK`. `apq sweep` read
 * that run's snapshot back and `apq fmt` could not even open a `.hxtest`. A
 * number nothing can re-derive is one bad refactor away from being decorative.
 *
 * The fixtures below are a miniature corpus carrying one instance of each of
 * the six verdicts, so a classification arm that stops firing changes the
 * totals line here rather than only the fork's numbers — which no unit test
 * can see, because the fork is not part of this repository.
 */
@:nullSafety(Strict)
class SweepRunCensusCliTest extends Test {

	/**
	 * Every verdict arm fires, and the line is the one `apq sweep` prints off a
	 * snapshot — the same sentence, so the two forms can be compared by eye.
	 */
	public function testSweepRunClassifiesEveryVerdict(): Void {
		#if nodejs
		final dir: String = miniCorpus();
		var code: Int = 0;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run(['sweep', '--run', '--corpus', dir]));
		Assert.equals(0, code, 'a census of a readable corpus exits 0 - got: $out');
		Assert.equals('3 pass / 1 fail / 1 skip-parse / 0 skip-write / 1 skip-config / 1 malformed (total 7)\n', out);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/**
	 * `--save` writes the snapshot schema the harness writes, so `--diff` pairs
	 * a live census against a recorded one fixture by fixture. That pairing IS
	 * the reproducibility check: `apq sweep --run --diff bin/.last-sweep.json`
	 * reports `0 fixtures changed` when the two agree.
	 */
	public function testSweepRunSavesASnapshotItsOwnDiffCanRead(): Void {
		#if nodejs
		final dir: String = miniCorpus();
		final snapshot: String = CliFixture.writeAs('apq_sweep_run_snapshot', 'json', '{}');
		Assert.equals(0, Cli.run(['sweep', '--run', '--corpus', dir, '--save', snapshot]), 'saving a census exits 0');
		final same: String = CliFixture.captureStdout(() -> Cli.run(['sweep', '--run', '--corpus', dir, '--diff', snapshot]));
		Assert.stringContains('0 fixtures changed', same);
		// A flipped baseline must be REPORTED, not absorbed — otherwise the
		// `0 fixtures changed` above would be a gate that cannot fail.
		final raw: String = File.getContent(snapshot);
		File.saveContent(snapshot, raw.split('{"path":"b_fail.hxtest","status":"FAIL"}').join('{"path":"b_fail.hxtest","status":"PASS"}'));
		final flipped: String = CliFixture.captureStdout(() -> Cli.run(['sweep', '--run', '--corpus', dir, '--diff', snapshot]));
		Assert.stringContains('PASS -> FAIL: b_fail.hxtest', flipped);
		Assert.stringContains('1 fixtures changed', flipped);
		FileSystem.deleteFile(snapshot);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A corpus directory that is not there is named, not reported as an empty census. */
	public function testSweepRunNamesAMissingCorpusDirectory(): Void {
		#if nodejs
		var code: Int = 0;
		final err: String = CliFixture.captureStderr(() -> code = Cli.run(['sweep', '--run', '--corpus', '/no/such/corpus']));
		Assert.equals(1, code);
		Assert.stringContains('/no/such/corpus', err);
		Assert.stringContains('does not exist', err);
		#else
		Assert.pass('non-node target');
		#end
	}

	/**
	 * A `.hxtest` is three sections, not a source file. `apq fmt` used to read
	 * the whole thing and answer `unexpected input`, which reads as a parser
	 * defect; and a `--write` that formatted only the input section would
	 * overwrite the fixture with a third of itself.
	 */
	public function testFmtRefusesAHxtestFixtureByNameAndLeavesItAlone(): Void {
		#if nodejs
		final dir: String = miniCorpus();
		final fixture: String = '$dir/a_pass.hxtest';
		final before: String = File.getContent(fixture);
		var code: Int = 0;
		final err: String = CliFixture.captureStderr(() -> code = Cli.run(['fmt', fixture, '--write']));
		Assert.equals(1, code);
		Assert.stringContains('not a source file', err);
		Assert.stringContains('apq sweep --run', err);
		Assert.equals(before, File.getContent(fixture), 'the fixture must be byte-identical after a refused format');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/**
	 * Both sides of a `--diff` key on the same string. A harness snapshot roots
	 * fixture paths at the FORK (`test/testcases/<subdir>/<name>`); a census
	 * roots them at the corpus directory it was pointed at.
	 */
	public function testFixtureKeysNormaliseToOneForm(): Void {
		Assert.equals('whitespace/a.hxtest', SweepCommand.normaliseFixtureKey('test/testcases/whitespace/a.hxtest'));
		Assert.equals('whitespace/a.hxtest', SweepCommand.normaliseFixtureKey('whitespace/a.hxtest'));
	}

	#if (sys || nodejs)
	/**
	 * One fixture per verdict `HxFormatterCorpusTest.runCategory` can record.
	 * `f_disabled` and `g_excluded` are the fork's two driver-level meta-config
	 * keys: both mean the formatter never ran, so the expected section is empty
	 * and an empty actual is a PASS.
	 */
	private static function miniCorpus(): String {
		return CliFixture.writeDir('apq_sweep_run', [
			{ name: 'a_pass.hxtest', source: '{}\n\n---\n\nclass C {}\n\n---\n\nclass C {}\n' },
			{ name: 'b_fail.hxtest', source: '{}\n\n---\n\nclass C {}\n\n---\n\nclass D {}\n' },
			{ name: 'c_skipparse.hxtest', source: '{}\n\n---\n\nclass C {\n\n---\n\nclass C {}\n' },
			{ name: 'd_malformed.hxtest', source: 'no sections here\n' },
			{ name: 'e_skipconfig.hxtest', source: '{"sameLine": {"ifBody": "bogus"}}\n\n---\n\nclass C {}\n\n---\n\nclass C {}\n' },
			{ name: 'f_disabled.hxtest', source: '{"disableFormatting": true}\n\n---\n\nclass C {}\n\n---\n\n' },
			{ name: 'g_excluded.hxtest', source: '{"excludes": ["g_excluded.hxtest"]}\n\n---\n\nclass C {}\n\n---\n\n' }
		]);
	}
	#end

}
