package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

#if sys
import sys.FileSystem;
#end

/**
 * End-to-end probe for `apq strip --dry-run` — typo guard mode. Skips
 * the parse step, only verifies that every supplied
 * `--replace`/`--delete` pattern matched at least one occurrence
 * somewhere across the input file set. Exit 0 only when every
 * pattern has ≥1 hit AND at least one substitution would change the
 * source; exit 1 (EXIT_RUNTIME) on any zero-match pattern.
 *
 * Coverage: matching pattern → 0, typo-only pattern → 1, mixed
 * (one match + one typo) → 1 (per the strict semantics), and the
 * --dry-run vs. normal-strip path independence.
 */
@:nullSafety(Strict)
class ApqStripDryRunCliTest extends Test {

	public function testMatchingPatternExitsOk():Void {
		#if sys
		final input:String = CliFixture.write('apq_strip_dry', 'class C { var x:Int = 1; }');
		Assert.equals(0, Cli.run(['strip', input, '--replace', 'var x', '--with', 'final x', '--dry-run']));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTypoPatternExitsRuntime():Void {
		#if sys
		final input:String = CliFixture.write('apq_strip_dry', 'class C { var x:Int = 1; }');
		Assert.equals(1, Cli.run(['strip', input, '--replace', 'NOPATTERN', '--with', '', '--dry-run']));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMixedHitAndTypoExitsRuntime():Void {
		// Per-pattern strictness: even when one pattern matches, a
		// sibling zero-match pattern still fails the dry-run (the
		// typo-guard's whole purpose).
		#if sys
		final input:String = CliFixture.write('apq_strip_dry', 'class C { var x:Int = 1; }');
		Assert.equals(1, Cli.run([
			'strip', input,
			'--replace', 'var x', '--with', 'final x',
			'--replace', 'BOGUS', '--with', '',
			'--dry-run',
		]));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testDeleteShortcutCounts():Void {
		// `--delete <pat>` is `--replace <pat> --with ''` — same
		// match-count semantics under --dry-run.
		#if sys
		final input:String = CliFixture.write('apq_strip_dry', 'class C { @:meta var x:Int; }');
		Assert.equals(0, Cli.run(['strip', input, '--delete', '@:meta ', '--dry-run']));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testBatchModeAcrossFiles():Void {
		// One pattern, two files — one has the match, the other
		// doesn't. As long as the GLOBAL total > 0 AND every supplied
		// pattern has ≥1 match across the whole input set, exit 0.
		#if sys
		final f1:String = CliFixture.write('apq_strip_dry_batch_a', 'class A { var x = 1; }');
		final f2:String = CliFixture.write('apq_strip_dry_batch_b', 'class B {}');
		Assert.equals(0, Cli.run(['strip', f1, f2, '--replace', 'var x', '--with', 'final x', '--dry-run']));
		FileSystem.deleteFile(f1);
		FileSystem.deleteFile(f2);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testDryRunSkipsParseStep():Void {
		// Stripped source would normally fail to parse (we sed-strip
		// the closing brace away). Without --dry-run the strip would
		// emit PARSE FAIL and exit non-zero. With --dry-run the parse
		// step is skipped — only pattern-match matters — so an
		// otherwise-broken substitution still exits 0 when the
		// pattern matched.
		#if sys
		final input:String = CliFixture.write('apq_strip_dry', 'class C {}');
		Assert.equals(0, Cli.run(['strip', input, '--replace', '}', '--with', '', '--dry-run']));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testWithoutDryRunStillWorksMatching():Void {
		// Regression: --dry-run is purely additive; the existing
		// non-dry-run strip path must still succeed on a benign
		// substitution.
		#if sys
		final input:String = CliFixture.write('apq_strip_dry', 'class C { var x:Int = 1; }');
		Assert.equals(0, Cli.run(['strip', input, '--replace', 'var x', '--with', 'final x']));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}
}
