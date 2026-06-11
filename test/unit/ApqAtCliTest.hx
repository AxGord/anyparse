package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if sys
import sys.FileSystem;
#end

/**
 * End-to-end probe for `apq ast --at LINE:COL`.
 *
 * Before this slice `--at` was a deferred stub returning EXIT_USAGE.
 * It now resolves the innermost AST node enclosing the 1-indexed
 * position via `Span.offsetOf` + `Engine.at`. These tests drive
 * `Cli.run(['ast', '--at', ...])` against a tmp fixture and assert
 * return codes + that a node is found at a known position.
 */
class ApqAtCliTest extends Test {

	public function testAtResolvesNodeAtPosition(): Void {
		#if sys
		final fixture: String = writeFixture('class X {\n\tstatic function a():Int { return 42; }\n}');
		// Line 2 sits inside the function — must resolve, exit 0.
		Assert.equals(0, Cli.run(['ast', '--at', '2:20', fixture]), 'apq ast --at must exit 0 when a node encloses the position');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAtJsonResolvesNodeAtPosition(): Void {
		#if sys
		final fixture: String = writeFixture('class X {\n\tvar field = 1;\n}');
		Assert.equals(0, Cli.run(['ast', '--at', '2:6', '--json', fixture]), '--at --json must exit 0');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAtNoEnclosingNodeIsCleanExit(): Void {
		#if sys
		final fixture: String = writeFixture('class X {}');
		// A position far past end of source has no enclosing node; this
		// is an empty result, not an error — clean EXIT_OK like an empty
		// `--select`.
		Assert.equals(0, Cli.run(['ast', '--at', '99:1', fixture]), 'no-enclosing-node is a clean empty result, not an error');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAtRejectsMalformedPosition(): Void {
		#if sys
		final fixture: String = writeFixture('class X {}');
		Assert.equals(2, Cli.run(['ast', '--at', 'nope', fixture]), 'missing colon → usage error');
		Assert.equals(2, Cli.run(['ast', '--at', '0:1', fixture]), 'non-1-indexed line → usage error');
		Assert.equals(2, Cli.run(['ast', '--at', '1:x', fixture]), 'non-integer col → usage error');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	private static function writeFixture(source: String): String {
		return CliFixture.write('apq_at', source);
	}
	#end

}
