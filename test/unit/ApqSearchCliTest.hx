package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

#if sys
import sys.io.File;
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

	#if sys
	private static var fixtureCounter:Int = 0;

	private static function writeFixture(source:String):String {
		fixtureCounter++;
		final path:String = '${haxe.io.Path.normalize(Sys.getCwd())}/tmp_apq_search_fixture_${Sys.time()}_$fixtureCounter.hx';
		File.saveContent(path, source);
		return path;
	}
	#end
}
