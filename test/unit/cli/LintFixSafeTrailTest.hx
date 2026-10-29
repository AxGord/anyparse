package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.check.oracle.CompilerOracle.OracleOutcome;
import anyparse.query.LintFixSafePass;
import anyparse.query.cli.WriteFailure;
import anyparse.query.cli.command.LintFixSafeTrail;
import haxe.Exception;

/**
 * The disk half of `lint --fix`'s safe-pass net: a probe the disk refuses stops the isolation instead of escaping it, and a
 * settled tree the disk does not hold ends the run as a `WriteFailure` — one line and `EXIT_RUNTIME`, never a stack.
 */
@:nullSafety(Strict)
class LintFixSafeTrailTest extends Test {

	/**
	 * A candidate that cannot be written is a probe that could not run: the isolation falls back with the reason, so the
	 * caller still reaches `settle` and puts the confirmed tree back — the write failure no longer skips it.
	 */
	@:pin('control')
	@:killer('M-SAFE-PROBE-WRITE-ESCAPES')
	public function testAProbeTheDiskRefusesStopsTheIsolationInsteadOfEscapingIt(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_safe_trail_write', [{ name: 'blocker', source: 'a file, not a directory' }]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final changed: Array<String> = ['$root/blocker/A.hx', '$root/blocker/B.hx'];
			final fixedOf: Map<String, String> = ['$root/blocker/A.hx' => 'fixed A', '$root/blocker/B.hx' => 'fixed B'];
			final trail: LintFixSafeTrail = new LintFixSafeTrail((_, _, _) -> null, LintFixSafePass.PROBE_CAP);
			var why: String = 'no verdict';
			try
				switch LintFixSafePass.isolate(
					WholeWave('the compiler blames no file this run wrote', 'errors'), changed, [],
					trail.seat(changed, [], [], fixedOf, [])
				) {
					case WholeWave(reason, _):
						why = reason;
					case other:
						why = 'expected WholeWave, got $other';
				}
			catch (failure: WriteFailure)
				why = 'the write failure escaped the isolation: ${failure.message}';
			Assert.stringContains('a probe could not run (its candidate could not be put on disk: cannot write $root/blocker/', why);
		});
		#else
		Assert.pass();
		#end
	}

	/** A file the candidate must not hold and the filesystem keeps is a candidate that was not put on disk either. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-REFUSAL-IGNORED')
	public function testAFileTheFilesystemWillNotDeleteIsAProbeThatCouldNotRun(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_safe_trail_delete', [{ name: 'kept/Inner.hx', source: 'class Inner {}' }]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final created: String = '$root/kept';
			final trail: LintFixSafeTrail = new LintFixSafeTrail((_, _, _) -> null, LintFixSafePass.PROBE_CAP);
			final outcome: OracleOutcome = trail.seat([created], [], [], [], []).probe([], []);
			switch outcome {
				case Unavailable(reason):
					Assert.stringContains('cannot write $created: the file could not be deleted', reason);
				case other:
					Assert.fail('expected Unavailable, got $other');
			}
		});
		#else
		Assert.pass();
		#end
	}

	/**
	 * The disk holding other bytes than the tree the oracle confirmed stops the run as a `WriteFailure` naming the files —
	 * the type `Cli.run` turns into one line and `EXIT_RUNTIME` — not as a bare exception that reaches the reader as a stack.
	 */
	@:pin('control')
	@:killer('M-SAFE-SETTLE-RAW-EXCEPTION')
	public function testASettledTreeTheDiskDoesNotHoldIsAWriteFailure(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_safe_trail_settle', [{ name: 'A.hx', source: 'candidate' }]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final file: String = '$root/A.hx';
			final files: Array<{ file: String, source: String }> = [{ file: file, source: 'fixed' }];
			var message: String = 'nothing thrown';
			try
				LintFixSafeTrail.settle([
					{
						file: file,
						rules: ['poison'],
						keptRules: [],
						kept: null
					}
				], [file], files, [file => 'original'], [file => 'fixed'], [], _ -> {})
			catch (failure: WriteFailure)
				message = 'WriteFailure: ${failure.message}'
			catch (other: Exception)
				message = 'other: ${other.message}';
			Assert.stringContains('WriteFailure: cannot write $file: ', message);
			Assert.stringContains('the disk holds other bytes', message);
			Assert.equals('candidate', File.getContent(file), 'the check reads the disk, it does not repair it');
			Assert.isTrue(FileSystem.exists(file));
		});
		#else
		Assert.pass();
		#end
	}

}
