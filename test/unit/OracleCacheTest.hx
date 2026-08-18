package unit;

import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifier;
import anyparse.check.OracleCache;
import anyparse.core.EnvFlag;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * End-to-end and unit coverage of the content-addressed oracle verdict cache
 * (`OracleCache`): the HIT that skips a whole project typecheck, the MISS that a
 * same-second content edit still forces, the fall-through on every corrupt or
 * mismatched record, and the discriminating pair proving `--fix` never reads it.
 *
 * Every filesystem/compiler scenario is wrapped in `#if (sys || nodejs)` and probes
 * `haxe` availability first (`oracleWorks`), skipping with `Assert.pass` on a host
 * without a compiler. The token- and probe-parsing tests are pure and always run.
 *
 * Fixtures are `CliFixture.writeDir` temp dirs holding `Good.hx`, a `-cp .` hxml and an
 * `apqlint.json` naming it. Each `writeDir` call yields a UNIQUE directory, which is
 * what keeps every test's fingerprint — and therefore its cache file — distinct.
 */
@:nullSafety(Strict)
final class OracleCacheTest extends Test {

	/** Every token shape `hxmlRefs` must read: a comment line, all three classpath spellings, both library spellings, an include, flags it must ignore, and two tokens on one line. */
	private static final HXML_FIXTURE: String = '# a comment\n-cp src\n--class-path test\n-lib utest\n'
		+ '--library hxnodejs:1.2.3\nother.hxml\n-D analyzer-optimize\n-js bin/out.js\n-cp lib -lib heaps\n';

	/** A `haxe -v` stdout shaped exactly as the real compiler prints it, empty classpath entry included. */
	private static final PROBE_STDOUT: String =
		'Classpath: /a/;;/b/std/\nDefines: dce=std;haxe=4.3.7;utest=1.13.2\nParsed /b/std/StdTypes.hx\n';

	#if (sys || nodejs)
	private static final VALID: String = 'class Good {\n\tstatic function main() {\n\t\tvar x:Int = 1;\n\t\ttrace(x);\n\t}\n}\n';
	private static final BROKEN: String = 'class Good {\n\tstatic function main() {\n\t\tvar x:Int = "no";\n\t\ttrace(x);\n\t}\n}\n';
	private static final OTHER: String = 'class Good {\n\tstatic function main() {\n\t\tvar y:Int = 7;\n\t\ttrace(y);\n\t}\n}\n';
	private static final HXML: String = '-cp .\n-main Good\n';
	private static final CONFIG: String = '{"compilerOracle":"check.hxml"}';
	#end

	/**
	 * THE HIT. Two identical lints of an untouched tree must spawn the compiler once.
	 * The second run re-derives the same fingerprint, finds the stored verdict and
	 * returns it, so `CompilerOracle.invocations` — a pure spawn counter for
	 * `haxe <hxml> --no-output` — does not move, and the verdict is still a pass.
	 */
	public function testUnchangedTreeIsNotTypecheckedTwice(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		if (cacheDeclined()) return;
		final dir: String = writeLintDir(VALID);
		Assert.equals(0, Cli.run(['lint', '$dir/Good.hx']), 'the cold run confirms and records');
		final before: Int = CompilerOracle.invocations;
		Assert.equals(0, Cli.run(['lint', '$dir/Good.hx']), 'the cached verdict is still a pass');
		Assert.equals(before, CompilerOracle.invocations, 'an unchanged tree is not typechecked twice');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * THE MISS, and the staleness proof. The break is written in the SAME wall-clock
	 * second as the read that preceded it — precisely the case the compiler's
	 * one-second modification-time granularity cannot see, and content hashing can.
	 *
	 * This is the test that would go green on a BROKEN build if the key were ever
	 * mtime-based: the recorded `Confirmed` would still match and the run would report
	 * a project that no longer typechecks as clean.
	 */
	public function testChangedSourceMissesAndReTypechecks(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		if (cacheDeclined()) return;
		final dir: String = writeLintDir(VALID);
		Assert.equals(0, Cli.run(['lint', '$dir/Good.hx']), 'the first run records a Confirmed');
		File.saveContent('$dir/Good.hx', BROKEN);
		final before: Int = CompilerOracle.invocations;
		Assert.equals(1, Cli.run(['lint', '$dir/Good.hx']), 'the broken tree is rejected, not read off the cache');
		Assert.isTrue(CompilerOracle.invocations > before, 'a content change forces a real typecheck');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A tree nothing has ever recorded a verdict for has no record to find: `lookup` is null and the caller runs the compiler. */
	public function testAbsentCacheFallsThrough(): Void {
		#if (sys || nodejs)
		final dir: String = writeLintDir(VALID);
		final print: Null<String> = OracleCache.fingerprint('check.hxml', dir);
		if (print == null)
			Assert.pass('no fingerprint on this host — skipped');
		else
			Assert.isNull(OracleCache.lookup('check.hxml', dir, print), 'nothing recorded means nothing to reuse');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Three ways a record can fail to be believed, and the one way it is: unparseable
	 * bytes, a well-formed record carrying a DIFFERENT fingerprint, and finally a
	 * genuine store under the current one. The first two must be indistinguishable from
	 * an absent cache — silence, never a guess.
	 */
	public function testCorruptCacheFallsThrough(): Void {
		#if (sys || nodejs)
		final dir: String = writeLintDir(VALID);
		final print: Null<String> = OracleCache.fingerprint('check.hxml', dir);
		if (print == null) {
			skipNoFingerprint(dir);
			return;
		}
		final record: String = OracleCache.cacheFile('check.hxml', dir);
		File.saveContent(record, 'not json at all');
		Assert.isNull(OracleCache.lookup('check.hxml', dir, print), 'unparseable bytes are not a verdict');
		File.saveContent(record, '{"fingerprint":"deadbeef","verdict":"confirmed","errors":""}');
		Assert.isNull(OracleCache.lookup('check.hxml', dir, print), 'a record for another tree is not a verdict for this one');
		OracleCache.store('check.hxml', dir, print, Confirmed);
		final reused: Null<OracleOutcome> = OracleCache.lookup('check.hxml', dir, print);
		Assert.isTrue(reused != null && reused.match(Confirmed), 'a record stored under this fingerprint IS reused');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The discriminating pair. Arm A poisons the cache with a `Rejected` on a project
	 * that DOES typecheck and shows report mode reading it — without that arm the test
	 * would be vacuous, since a cache nobody consults passes "fix ignores it" trivially.
	 * Arm B then runs the `--fix` verification over the same poisoned record and gets
	 * the compiler's own answer, because `FixVerifier` calls `CompilerOracle` directly
	 * and never comes near this cache.
	 */
	public function testFixNeverConsultsTheCache(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		if (cacheDeclined()) return;
		final dir: String = writeLintDir(VALID);
		final print: Null<String> = OracleCache.fingerprint('check.hxml', dir);
		if (print == null) {
			skipNoFingerprint(dir);
			return;
		}
		OracleCache.store('check.hxml', dir, print, Rejected('poisoned'));
		final before: Int = CompilerOracle.invocations;
		Assert.equals(1, Cli.run(['lint', '$dir/Good.hx']), 'report mode reads the poisoned verdict');
		Assert.equals(before, CompilerOracle.invocations, 'and reads it INSTEAD of compiling — the poison is real');

		OracleCache.store('check.hxml', dir, print, Rejected('poisoned'));
		final path: String = '$dir/Good.hx';
		final result: FixVerifyResult = FixVerifier.verify(
			[{ file: path, source: VALID }],
			[new TestRiskyLiteralRewrite('2')], new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
		);
		Assert.isTrue(result.baseline.match(Confirmed), 'the fix path asked the compiler itself, not the cache');
		Assert.equals(1, result.applied.length, 'and applied the risky fix the poisoned record would have blocked');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The hxml token grammar: comments skipped, all three classpath spellings, both library spellings with the version suffix stripped, includes by extension, and several tokens on one line. */
	public function testHxmlRefsReadsCpLibAndIncludes(): Void {
		final refs: HxmlRefs = OracleCache.hxmlRefs(HXML_FIXTURE);
		Assert.same(['src', 'test', 'lib'], refs.classPaths);
		Assert.same(['utest', 'hxnodejs', 'heaps'], refs.libs);
		Assert.same(['other.hxml'], refs.includes);
	}

	/** The `haxe -v` probe parsing: the classpath entries with the empty one dropped, the whole `Defines:` line, and null/empty degradation when neither line is there. */
	public function testProbeParsingReadsClasspathAndDefines(): Void {
		Assert.same(['/a/', '/b/std/'], OracleCache.probeDirs(PROBE_STDOUT));
		Assert.equals('Defines: dce=std;haxe=4.3.7;utest=1.13.2', OracleCache.probeDefines(PROBE_STDOUT));
		Assert.same([], OracleCache.probeDirs('Parsed /b/std/StdTypes.hx\n'));
		Assert.isNull(OracleCache.probeDefines('Parsed /b/std/StdTypes.hx\n'));
	}

	/**
	 * The key is CONTENT, not "something happened": rewriting a source moves the
	 * fingerprint, and restoring the original bytes moves it back to the very same
	 * value. A key derived from a modification time or a counter could satisfy the
	 * first half and never the second.
	 */
	public function testFingerprintTracksContent(): Void {
		#if (sys || nodejs)
		final dir: String = writeLintDir(VALID);
		final path: String = '$dir/Good.hx';
		final first: Null<String> = OracleCache.fingerprint('check.hxml', dir);
		if (first == null) {
			Assert.pass('no fingerprint on this host — skipped');
			CliFixture.removeDir(dir);
			return;
		}
		File.saveContent(path, OTHER);
		final changed: Null<String> = OracleCache.fingerprint('check.hxml', dir);
		Assert.notEquals(first, changed, 'different content, different key');
		File.saveContent(path, VALID);
		Assert.equals(first, OracleCache.fingerprint('check.hxml', dir), 'the original bytes restore the original key');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** A fixture project: one source, a `-cp .` hxml naming it, and an `apqlint.json` pointing the oracle at that hxml. */
	private function writeLintDir(main: String): String {
		return CliFixture.writeDir('oraclecache', [
			{ name: 'Good.hx', source: main },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: CONFIG }
		]);
	}

	/** Pass-and-clean-up for a host where no fingerprint can be derived (no `haxe`): the caller still owns the `return`. */
	private function skipNoFingerprint(dir: String): Void {
		Assert.pass('no fingerprint on this host — skipped');
		CliFixture.removeDir(dir);
	}

	/**
	 * Whether the cache these scenarios pin is live at all, reporting the skip itself when
	 * it is not. `APQ_NO_ORACLE_CACHE` declines the cache process-wide, and no claim about
	 * REUSE can be made under it — so skipping is the honest answer. The alternative is a
	 * suite that goes red for anyone who exports the documented opt-out, which is exactly
	 * how this guard was found.
	 */
	private function cacheDeclined(): Bool {
		if (!EnvFlag.isSet('APQ_NO_ORACLE_CACHE')) return false;
		Assert.pass('APQ_NO_ORACLE_CACHE declines the cache — skipped');
		return true;
	}

	/** Whether this host has a `haxe` that answers at all — the skip gate every compiler-dependent test opens with. */
	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('oraclecacheprobe', [
			{ name: 'Good.hx', source: VALID },
			{ name: 'check.hxml', source: HXML }
		]);
		final ok: Bool = CompilerOracle.typecheck('check.hxml', dir).match(Confirmed);
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}
