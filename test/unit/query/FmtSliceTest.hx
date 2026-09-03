package unit.query;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;

using StringTools;
#end

import anyparse.query.Cli;
import anyparse.query.FormatFixedPoint;
import haxe.Exception;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * End-to-end probe for `apq fmt` — the whole-file canonicaliser. Each test
 * writes a temp `.hx` fixture, drives it through `Cli.run(['fmt', ...])`, and
 * asserts on the exit code plus the on-disk result, covering the four modes:
 * `--write` (rewrite in place, idempotent), the no-flag single-file default
 * (formatted source to stdout, file untouched), `-l` list mode (non-
 * destructive), and the parse-failure / usage-error exits.
 *
 * Guarded `#if (sys || nodejs)` rather than the project's usual `#if sys` so
 * the fixtures and `Cli.run` actually execute on the JS (`-lib hxnodejs`)
 * test build — `#if sys` is FALSE under hxnodejs, which silently degrades a
 * `#if sys` CLI test to a no-op `Assert.pass` on the `node bin/test.js`
 * inner loop. `sys.io.File` / `FileSystem` / `Sys` all work on hxnodejs.
 */
class FmtSliceTest extends Test {

	/**
	 * A deliberately non-canonical module: no spaces around `:`/`=`, a glued
	 * class body, single-line members. The writer reflows all of it, so
	 * `fmt` output differs from the input on every target's default options.
	 */
	private static inline final NON_CANONICAL: String = 'package;\nclass C{var x:Int=1;function f(){return x;}}\n';

	#if (sys || nodejs)
	private static var counter: Int = 0;

	/** `--write` canonicalises in place and a second pass is a no-op. */
	public function testWriteCanonicalisesAndIsIdempotent(): Void {
		final f: String = fixture(NON_CANONICAL);
		Assert.equals(0, Cli.run(['fmt', f, '--write']));
		final canon: String = File.getContent(f);
		Assert.notEquals(NON_CANONICAL, canon);
		Assert.equals(0, Cli.run(['fmt', f, '--write']));
		Assert.equals(canon, File.getContent(f));
		FileSystem.deleteFile(f);
	}

	/** A single file with no flags emits to stdout and leaves the file untouched. */
	public function testStdoutLeavesFileUnchanged(): Void {
		final f: String = fixture(NON_CANONICAL);
		Assert.equals(0, Cli.run(['fmt', f]));
		Assert.equals(NON_CANONICAL, File.getContent(f));
		FileSystem.deleteFile(f);
	}

	/** `-l` (list) reports drift without rewriting — the file is unchanged. */
	public function testListLeavesFileUnchanged(): Void {
		final f: String = fixture(NON_CANONICAL);
		Assert.equals(0, Cli.run(['fmt', f, '-l']));
		Assert.equals(NON_CANONICAL, File.getContent(f));
		FileSystem.deleteFile(f);
	}

	/** An already-canonical file is left byte-identical under `--write`. */
	public function testAlreadyCanonicalIsUntouched(): Void {
		final f: String = fixture(NON_CANONICAL);
		Cli.run(['fmt', f, '--write']);
		final canon: String = File.getContent(f);
		final g: String = fixture(canon);
		Assert.equals(0, Cli.run(['fmt', g, '--write']));
		Assert.equals(canon, File.getContent(g));
		FileSystem.deleteFile(f);
		FileSystem.deleteFile(g);
	}

	/** An unparseable file exits `EXIT_RUNTIME` and is not rewritten. */
	public function testParseFailureExitsRuntime(): Void {
		final broken: String = 'package;\nclass C {\n';
		final f: String = fixture(broken);
		Assert.equals(1, Cli.run(['fmt', f, '--write']));
		Assert.equals(broken, File.getContent(f));
		FileSystem.deleteFile(f);
	}

	/** No input specs is a usage error. */
	public function testNoInputsIsUsageError(): Void {
		Assert.equals(2, Cli.run(['fmt']));
	}

	/**
	 * The layout-reading wrap decision, end to end. ONE `--write` must land the
	 * file where every further `--write` leaves it, or the `--list` gate that
	 * runs next disagrees with the `--write` that just ran.
	 *
	 * `objectLiteral.defaultWrap` is the widest instance — 163 of 854 Pony
	 * files under `fillLineWithLeadingBreak` — and the shape reduces to this
	 * one: a SINGLE-LINE literal wraps on rewrite 1, which makes it
	 * source-MULTILINE, which force-one-per-lines it on rewrite 2 (the cascade
	 * is never consulted for a multiline literal). The pass-1 shape the
	 * assertion rejects is `\t\t\tx: 1, y: 2`.
	 */
	public function testWriteLandsOnTheWrapCascadeFixedPoint(): Void {
		final config: String = '{"wrapping":{"objectLiteral":{"defaultWrap":"fillLineWithLeadingBreak","rules":[]}}}';
		final dir: String = CliFixture.writeDir('apq_fmt_fixed_point', [
			{ name: 'hxformat.json', source: config },
			{ name: 'A.hx', source: 'class A {\n\tpublic function f(): Void {\n\t\tvar p = { x: 1, y: 2 };\n\t}\n}\n' }
		]);
		Assert.equals(0, Cli.run(['fmt', dir, '--write']));
		final written: String = File.getContent('$dir/A.hx');
		Assert.equals(
			'class A {\n\tpublic function f():Void {\n\t\tvar p = {\n\t\t\tx: 1,\n\t\t\ty: 2\n\t\t};\n\t}\n}\n', written,
			'one --write must reach the fixed point, not the rewrite-1 shape the next --list rejects'
		);
		Assert.equals(0, Cli.run(['fmt', dir, '--write']));
		Assert.equals(written, File.getContent('$dir/A.hx'), 'a second --write over the fixed point must change nothing');
		Assert.equals(0, Cli.run(['fmt', dir, '-l']));
		Assert.equals(written, File.getContent('$dir/A.hx'), '--list must never rewrite');
		CliFixture.removeDir(dir);
	}

	/** A file already at its fixed point pays exactly one round trip. */
	public function testCanonicalInputTakesOneRoundTrip(): Void {
		var calls: Int = 0;
		function identity(text: String): Null<String> {
			calls++;
			return text;
		}
		final result: FormatFixedPointResult = FormatFixedPoint.run(identity, 'a');
		Assert.equals(1, calls, 'a canonical file must not pay a confirming round trip');
		Assert.equals(0, result.rewrites);
		Assert.isTrue(result.converged);
		Assert.equals('a', result.text);
	}

	/** The healthy case: one rewrite, confirmed by a round trip that changes nothing. */
	public function testOneRewriteConvergesAndIsNotReportable(): Void {
		final result: FormatFixedPointResult = FormatFixedPoint.run(stepping(['a' => 'b']), 'a');
		Assert.equals(1, result.rewrites, 'one rewrite is the healthy count and must not read as a writer defect');
		Assert.isTrue(result.converged);
		Assert.equals('b', result.text);
	}

	/** The layout-reading shape: a second rewrite the caller must both apply and report. */
	public function testSecondRewriteIsReachedAndCounted(): Void {
		final result: FormatFixedPointResult = FormatFixedPoint.run(stepping(['a' => 'b', 'b' => 'c']), 'a');
		Assert.equals(2, result.rewrites);
		Assert.isTrue(result.converged);
		Assert.equals('c', result.text, 'the caller must write the fixed point, not the intermediate rewrite');
	}

	/** A writer that flips between two shapes has no fixed point and must not be written. */
	public function testOscillatingWriterNeverConverges(): Void {
		final result: FormatFixedPointResult = FormatFixedPoint.run(stepping(['a' => 'b', 'b' => 'a']), 'a');
		Assert.isFalse(result.converged, 'a 2-cycle must be refused, not written on whichever pass the bound ends on');
		Assert.equals(FormatFixedPoint.MAX_REWRITES, result.rewrites);
		Assert.isTrue(result.failure != null);
	}

	/**
	 * A failure on the writer's OWN output is a writer defect, not the file's:
	 * captured into `failure` so the caller declines to write without blaming
	 * the source it was handed.
	 */
	public function testMidLoopFailureIsCapturedNotPropagated(): Void {
		var calls: Int = 0;
		function failsOnItsOwnOutput(text: String): Null<String> {
			calls++;
			if (calls == 1) return '$text!';
			throw new Exception('unexpected input');
		}
		final result: FormatFixedPointResult = FormatFixedPoint.run(failsOnItsOwnOutput, 'a');
		Assert.isFalse(result.converged);
		final failure: String = result.failure == null ? '' : (result.failure: String);
		Assert.isTrue(failure.indexOf('rewrite 2') >= 0, 'the failure must name the rewrite that broke: $failure');
		Assert.isTrue(failure.indexOf('unexpected input') >= 0, 'the failure must carry the writer message: $failure');
	}

	/** The FIRST round trip is the file's own — its failure propagates to the caller's report. */
	public function testFirstRoundTripFailurePropagates(): Void {
		function failsImmediately(text: String): Null<String> {
			throw new Exception('unexpected input');
		}
		Assert.raises(FormatFixedPoint.run.bind(failsImmediately, 'a'), Exception);
	}

	/**
	 * A round trip that walks `steps` and then repeats its own last answer —
	 * the shape of a writer that settles after N rewrites (or, with a cycle in
	 * `steps`, of one that never does).
	 */
	private static function stepping(steps: Map<String, String>): (text:String) -> Null<String> {
		return text -> steps.exists(text) ? steps[text] : text;
	}

	private static function fixture(source: String): String {
		counter++;
		final env: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = if (env == null || env.length <= 0)
			'/tmp'
		else if (env.endsWith('/'))
			env.substr(0, env.length - 1)
		else
			env;
		final path: String = '$base/tmp_apq_fmt_${Sys.time()}_$counter.hx';
		File.saveContent(path, source);
		return path;
	}
	#else
	public inline function testNonSysTarget(): Void {
		Assert.pass('apq fmt requires a sys / nodejs target');
	}
	#end

}
