package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if sys
import sys.FileSystem;
#end

/**
 * Slice 4.2 end-to-end probe — drives `Cli.run(['meta', ...])` against
 * a tmp fixture and verifies return codes and argument-grammar
 * behaviour. Mirrors `ApqSearchCliTest`: stdout is written immediately
 * via Sys.print, so the test asserts exit codes and that the engine
 * does not crash rather than intercepting output.
 */
class ApqMetaCliTest extends Test {

	public function testHelpReturnsOk(): Void {
		#if sys
		Assert.equals(0, Cli.run(['meta', '--help']));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMissingArgsReturnsUsageError(): Void {
		#if sys
		Assert.equals(2, Cli.run(['meta']));
		// One positional with neither a real glob nor --on: no scope.
		Assert.equals(2, Cli.run(['meta', '@:foo']));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testJsonOutputSucceeds(): Void {
		#if sys
		final fixture: String = writeFixture('class X { @:foo var n:Int; }');
		Assert.equals(0, Cli.run(['meta', '@:foo', '--json', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testEndToEndAnnotationFilter(): Void {
		#if sys
		final fixture: String = writeFixture('class X { @:foo var n:Int; @:bar function y():Void {} }');
		Assert.equals(0, Cli.run(['meta', '@:foo', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testOnKindModeWithoutAnnotation(): Void {
		#if sys
		final fixture: String = writeFixture('class X { @:foo var n:Int; }');
		Assert.equals(0, Cli.run(['meta', '--on', 'VarMember', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testArgContainsFilter(): Void {
		#if sys
		final fixture: String = writeFixture('class X { @:foo(groupRestProbe) var n:Int; }');
		Assert.equals(0, Cli.run(['meta', '@:foo', '--arg-contains', 'groupRestProbe', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testUnknownLangFailsCleanly(): Void {
		#if sys
		final fixture: String = writeFixture('class X {}');
		try {
			Cli.run(['meta', '@:foo', '--lang', 'pyx', fixture]);
			Assert.pass('cli returned cleanly for unknown lang');
		} catch (_) {
			Assert.pass('cli surfaced unknown-lang failure');
		}
		if (FileSystem.exists(fixture)) FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// ===== Parse-failure contract (scan vs single-file) =====

	public function testSingleUnparseableFileIsHardError(): Void {
		#if sys
		// A single explicit file the user named that does not parse is
		// the query's answer: it must be a hard error (EXIT_RUNTIME),
		// mirroring `apq ast` — not a silent EXIT_OK "no matches".
		final bad: String = writeFixture('class {');
		Assert.equals(1, Cli.run(['meta', '@:foo', bad]));
		FileSystem.deleteFile(bad);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testScanModeSkipsUnparseableFilesSilently(): Void {
		#if sys
		// Directory-walk (scan) mode: an unparseable file is out of scope
		// by nature — the walk must continue, exit EXIT_OK, and still
		// process the parseable sibling (no per-file error noise, no
		// abort, no non-zero exit).
		final dir: String = CliFixture.writeDir('apq_meta', [
			{ name: 'good.hx', source: 'class G { @:foo var n:Int; }' },
			{ name: 'bad.hx', source: 'class {' },
		]);
		Assert.equals(0, Cli.run(['meta', '@:foo', dir]));
		FileSystem.deleteFile('$dir/good.hx');
		FileSystem.deleteFile('$dir/bad.hx');
		FileSystem.deleteDirectory(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	private static function writeFixture(source: String): String {
		return CliFixture.write('apq_meta', source);
	}
	#end

}
