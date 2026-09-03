package unit.check;

import anyparse.check.HaxeSpawn;
import utest.Assert;
import utest.Test;

/**
 * `HaxeSpawn` — the one `haxe` child process the compiler-oracle package starts, and the
 * three OUTCOMES its callers read apart.
 *
 * They were three near-copies before, and what had drifted between them is exactly what
 * these tests pin: whether a non-zero exit is a verdict or a refusal, and whether an output
 * OVERFLOW is distinguishable from a compiler that never ran. The second one has no other
 * cover: an overflow arrives as a spawn error with a null status, so a caller that reads
 * only `status` cannot tell "the build failed and here is why" from "there is no `haxe` on
 * this machine".
 */
@:nullSafety(Strict)
final class HaxeSpawnTest extends Test {

	/** Big enough that nothing this test runs can reach it. */
	private static inline final ROOMY: Int = 8 * 1024 * 1024;

	/** A run that PRODUCED a verdict carries no `failure`, whatever it exited with. */
	public function testASuccessfulRunCarriesNoFailure(): Void {
		final run: HaxeRun = HaxeSpawn.run(['--version'], null, ROOMY);
		if (run.failure != '') {
			Assert.pass('haxe unavailable — skipped (${run.failure})');
			return;
		}
		Assert.equals(0, run.status);
		Assert.isFalse(run.overflowed);
		Assert.isTrue(run.out.length + run.err.length > 0, 'the version text reaches the caller through one of the two streams');
	}

	/**
	 * A compiler that ran and REFUSED is not a failure of the spawn: `status` carries the
	 * refusal and `failure` stays empty, which is what lets `CompilerOracle` answer `Rejected`
	 * here and `Unavailable` for a missing binary.
	 */
	public function testARejectedRunIsStillARun(): Void {
		final run: HaxeRun = HaxeSpawn.run(['--no-such-flag-zzz'], null, ROOMY);
		if (run.failure != '' && run.status == null && run.out == '' && run.err == '') {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		Assert.equals('', run.failure, 'the process ran; only its verdict was negative');
		Assert.notEquals(0, run.status);
		Assert.isFalse(run.overflowed);
	}

	/** On nodejs the working directory is honoured; the native `sys` branch has none to honour. */
	public function testHonoursCwdMatchesTheTarget(): Void {
		Assert.equals(#if nodejs true #else false #end, HaxeSpawn.honoursCwd());
	}

	#if nodejs
	/**
	 * An overflow says the compiler RAN. `status` is null either way, so without `overflowed`
	 * this is indistinguishable from a missing binary — and the two send a reader to opposite
	 * places. One byte of buffer against `haxe --version` is the smallest way to produce it.
	 */
	public function testAnOverflowIsToldApartFromAMissingBinary(): Void {
		final run: HaxeRun = HaxeSpawn.run(['--version'], null, 1);
		if (!run.overflowed && run.failure.indexOf('could not launch') != -1) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		Assert.isTrue(run.overflowed, 'got: ${run.failure}');
		Assert.isNull(run.status);
		Assert.isTrue(run.failure.indexOf('output buffer') != -1, 'and the sentence names the buffer: ${run.failure}');
	}
	#end

}
