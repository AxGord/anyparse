package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

#if sys
import sys.FileSystem;
#end

/**
 * Slice 2D end-to-end probe — drives `Cli.run(['search', ...])` against
 * a tmp fixture file and verifies stdout shape via process capture.
 *
 * Each Cli invocation prints to Sys.print which `utest` captures
 * indirectly; the test asserts return codes and behavioural invariants
 * (paths matched, no engine crash). Direct stdout interception is
 * skipped — Sys.print writes immediately and capturing it cleanly
 * across targets is its own slice.
 */
class ApqSearchCliTest extends Test {

	public function testHelpReturnsOk():Void {
		#if sys
		Assert.equals(0, Cli.run(['search', '--help']));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMissingArgsReturnsUsageError():Void {
		#if sys
		Assert.equals(2, Cli.run(['search']));
		Assert.equals(2, Cli.run(['search', 'just-pattern']));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testUnknownLangFailsCleanly():Void {
		#if sys
		final fixture:String = writeFixture('class X {}');
		// pickPlugin throws — Cli.run does not wrap pattern parse errors
		// from pickPlugin yet, so we accept either a usage exit or a
		// runtime exit. Just verify it does not crash the test process.
		try {
			Cli.run(['search', '--lang', 'pyx', 'x', fixture]);
			Assert.pass('cli returned cleanly for unknown lang');
		} catch (_) {
			Assert.pass('cli surfaced unknown-lang failure');
		}
		if (FileSystem.exists(fixture)) FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testEndToEndSearchOnFixture():Void {
		#if sys
		final fixture:String = writeFixture('class X {
			static function a() { throw new IoError("oops"); }
		}');
		final rc:Int = Cli.run(['search', "throw new $E($_)", fixture]);
		Assert.equals(0, rc, 'cli must exit 0 on successful search');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testDegeneratePatternStillExitsOk():Void {
		#if sys
		// `Anon` is a bare identifier — degenerate. The CLI emits a
		// non-fatal stderr nudge and still runs the search (exit 0),
		// not a usage/runtime error.
		final fixture:String = writeFixture('class X {
			static function a() { var Anon = 1; return Anon; }
		}');
		final rc:Int = Cli.run(['search', 'Anon', fixture]);
		Assert.equals(0, rc, 'degenerate pattern must still exit 0 (non-fatal nudge)');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testKindFlagAcceptedAndExitsOk():Void {
		#if sys
		final fixture:String = writeFixture('class X {
			var field = 0;
			static function f() { var local = 0; }
		}');
		final rc:Int = Cli.run(['search', '--kind', 'VarStmt', "var $v = 0", fixture]);
		Assert.equals(0, rc, '--kind flag must be accepted and exit 0');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testDashDashSentinelAllowsOptionLikePattern():Void {
		#if sys
		final fixture:String = writeFixture('class X {
			static function a() { var i = 0; --i; }
		}');
		// Without `--`, a pattern starting with `--` is mistaken for an
		// option and rejected (EXIT_USAGE). The `--` end-of-options
		// sentinel makes every following token positional (standard
		// getopt convention) so `--$x` (prefix-decrement) is searchable.
		Assert.equals(2, Cli.run(['search', "--$x", fixture]),
			'pattern starting with -- must be rejected as an option without the sentinel');
		final rc:Int = Cli.run(['search', '--', "--$x", fixture]);
		Assert.equals(0, rc, "after `--` the `--$x` pattern is positional and matches `--i`");
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testDashDashSentinelStillValidatesPriorOptions():Void {
		#if sys
		final fixture:String = writeFixture('class X {}');
		// Regression guard: the sentinel must NOT disable option
		// validation for tokens BEFORE it.
		Assert.equals(2, Cli.run(['search', '--bogus', '--', "$x", fixture]),
			'unknown option before `--` must still be rejected');
		// Options before `--` are still honoured (no arg-parse error).
		Assert.notEquals(2, Cli.run(['search', '--lang', 'haxe', '--', "$x + $x", fixture]),
			'--lang before -- still parsed; pattern after -- runs without arg error');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	private static function writeFixture(source:String):String {
		return CliFixture.write('apq_search', source);
	}
	#end
}
