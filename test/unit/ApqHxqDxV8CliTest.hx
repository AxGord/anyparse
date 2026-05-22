package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

#if sys
import sys.FileSystem;
#end

/**
 * `hxq DX v8` trio:
 *
 *  - `apq recon --probe <file> --predict-strip ...` — single-file
 *    upper-bound predictor (PREDICT UNBLOCK / STILL FAIL / NO MATCH +
 *    per-pattern totals + typo guard). Mirrors the sweep-mode
 *    predict-strip semantics for a one-shot check.
 *  - `apq lit '.<name>'` — leading-dot field-name slot nudge: 0-hit
 *    nudge suggests `apq search '$x.<name>'` (field-access shape) +
 *    `lit '<name>' --any-kind` + `refs <name> --decls`.
 *  - `apq strip --per-pattern` — isolation diagnostic for multi-pattern
 *    strip on a single file. Runs baseline + each pattern alone +
 *    combined; surfaces the interlocking-blockers signature (combined
 *    OK + every isolated row FAIL = slice scope needs N separate code
 *    mechanisms, not one).
 */
@:nullSafety(Strict)
class ApqHxqDxV8CliTest extends Test {

	// --- recon --probe --predict-strip ---

	public function testReconProbePredictStripUnblockExitsOk():Void {
		// A file with one parse-blocker; the strip removes it. Sweep-mode
		// equivalent of this case prints PREDICT UNBLOCK + exit 0.
		#if sys
		final input:String = CliFixture.write('apq_recon_probe_predict',
			'class C { function f() { switch (foo) { case var bar: y(); case _: z(); } } }');
		// `case var bar:` parses post-Slice 34, but the original blocker
		// shape (a `var` keyword in pattern position) is gone. Use a
		// pattern that REMOVES the case so the result still parses.
		Assert.equals(0, Cli.run(['recon', '--probe', input, '--predict-strip', '--delete', 'switch (foo) { case var bar: y(); case _: z(); }']));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconProbePredictStripNoMatchExitsRuntime():Void {
		// Pattern matches 0 occurrences ⇒ PREDICT NO MATCH + typo-guard
		// WARNING + exit 1, same as sweep mode's any-zero contract.
		#if sys
		final input:String = CliFixture.write('apq_recon_probe_predict',
			'class C { var x:Int = 1; }');
		Assert.equals(1, Cli.run(['recon', '--probe', input, '--predict-strip', '--delete', 'NOPATTERN_AT_ALL']));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconProbeWithoutPredictStillWorks():Void {
		// Regression: `--predict-strip` is purely additive on the probe
		// path. Without it, the existing PARSE OK / PARSE FAIL contract
		// stands — a parseable file exits 0.
		#if sys
		final input:String = CliFixture.write('apq_recon_probe_predict',
			'class C { var x:Int = 1; }');
		Assert.equals(0, Cli.run(['recon', '--probe', input]));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- lit '.<name>' leading-dot nudge ---

	public function testLitLeadingDotExitsCleanWithNudge():Void {
		#if sys
		final fixture:String = CliFixture.write('apq_lit_leading_dot',
			'class X { var y:Int; }');
		Assert.equals(0, Cli.run(['lit', '.expr', fixture]),
			'leading-dot lit query is a clean 0-hit; nudge points at search shape');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLitLeadingDotMultiSegmentFallsThrough():Void {
		// `.a.b` is NOT a single-tail leading-dot — falls through to the
		// existing dotted-access nudge (which also rejects empty leading
		// segments, so the plain `lit` nudge fires).
		#if sys
		final fixture:String = CliFixture.write('apq_lit_leading_dot',
			'class X { var y:Int; }');
		Assert.equals(0, Cli.run(['lit', '.obj.field', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRefsLeadingDotAlsoExitsClean():Void {
		// refs/uses share the dispatch — `.expr` is a leading-dot for
		// refs too, even though refs is a value-binding walker.
		#if sys
		final fixture:String = CliFixture.write('apq_lit_leading_dot',
			'class X { var y:Int; }');
		Assert.equals(0, Cli.run(['refs', '.expr', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- strip --per-pattern isolation ---

	public function testStripPerPatternSoleBlockerExitsOk():Void {
		// One pattern alone unblocks parse; sibling pattern is redundant.
		// VERDICT: "1 of 2 patterns unblock alone".
		#if sys
		final input:String = CliFixture.write('apq_strip_pp',
			'class C { var x = test( ; }');
		Assert.equals(0, Cli.run([
			'strip', input,
			'--replace', '( ; }', '--with', '(); }',
			'--replace', 'NOOP_NOPE', '--with', 'X',
			'--per-pattern',
		]));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testStripPerPatternInterlockingExitsOk():Void {
		// Each pattern alone leaves the OTHER blocker; only combined
		// parses. VERDICT: "interlocking blockers". Combined exits 0
		// regardless of the verdict — the verdict is informational.
		#if sys
		final input:String = CliFixture.write('apq_strip_pp',
			'class C { var x = test( ; }\nclass D { function f() : { } }');
		Assert.equals(0, Cli.run([
			'strip', input,
			'--replace', '( ; }', '--with', '(); }',
			'--replace', 'f() : {', '--with', 'f() {',
			'--per-pattern',
		]));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testStripPerPatternStillFailsExitsRuntime():Void {
		// Neither pattern (nor the combination) parses; combined row
		// PARSE FAIL ⇒ exit 1.
		#if sys
		final input:String = CliFixture.write('apq_strip_pp',
			'class C { var x = test( ; }\nclass D { function f() : { } }');
		Assert.equals(1, Cli.run([
			'strip', input,
			'--replace', '( ; }', '--with', '(@still_broken ; }',
			'--replace', 'f() : {', '--with', 'f() : {',
			'--per-pattern',
		]));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testStripPerPatternRequiresMultiplePatterns():Void {
		// `--per-pattern` with one pattern is a usage error — the
		// isolation diagnostic only makes sense with ≥2 patterns.
		#if sys
		final input:String = CliFixture.write('apq_strip_pp',
			'class C { var x:Int = 1; }');
		Assert.equals(2, Cli.run([
			'strip', input,
			'--replace', 'var', '--with', 'final',
			'--per-pattern',
		]));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testStripPerPatternRequiresSingleFile():Void {
		// `--per-pattern` is single-file only — multi-file would
		// produce an NxM matrix the diagnostic doesn't model.
		#if sys
		final f1:String = CliFixture.write('apq_strip_pp_a', 'class A {}');
		final f2:String = CliFixture.write('apq_strip_pp_b', 'class B {}');
		Assert.equals(2, Cli.run([
			'strip', f1, f2,
			'--replace', 'A', '--with', 'X',
			'--replace', 'B', '--with', 'Y',
			'--per-pattern',
		]));
		FileSystem.deleteFile(f1);
		FileSystem.deleteFile(f2);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testStripPerPatternIncompatibleWithDryRun():Void {
		#if sys
		final input:String = CliFixture.write('apq_strip_pp',
			'class C { var x:Int = 1; }');
		Assert.equals(2, Cli.run([
			'strip', input,
			'--replace', 'var', '--with', 'final',
			'--replace', 'x', '--with', 'y',
			'--per-pattern', '--dry-run',
		]));
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}
}
