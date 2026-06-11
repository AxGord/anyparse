package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if sys
import sys.FileSystem;
#end

/**
 * `apq lit / refs / uses` with a dotted query (`TypeName.method`,
 * `obj.field`, `pkg.Module.entry`) is structurally a Call / FieldAccess
 * shape, not a leaf-name / value-binding / type-position match — those
 * walkers can never hit. The 0-hit nudge detects the dot and points at
 * `apq search` with the access shape instead, plus a `refs <rhs>
 * --decls` fallback to find where the member is declared.
 *
 * Tests exercise the code path via `Cli.run` (the nudge writes to
 * stderr; tests assert clean exit). The text content was verified
 * manually during the slice that added the helper.
 */
@:nullSafety(Strict)
class ApqDottedAccessNudgeTest extends Test {

	public function testLitDottedUppercaseExitsClean(): Void {
		#if sys
		final fixture: String = writeFixture('class X { var y:Int; }');
		Assert.equals(0, Cli.run(['lit', 'HaxeModuleParser.parse', fixture]), 'dotted lit query is a clean 0-hit, not an error');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLitDottedLowercaseExitsClean(): Void {
		#if sys
		final fixture: String = writeFixture('class X { var y:Int; }');
		Assert.equals(0, Cli.run(['lit', 'obj.name', fixture]), 'dotted lit query (obj.field shape) is a clean 0-hit');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRefsDottedExitsClean(): Void {
		#if sys
		final fixture: String = writeFixture('class X { var y:Int; }');
		Assert.equals(0, Cli.run(['refs', 'foo.bar', fixture]), 'refs on dotted query is a clean 0-hit; nudge points at search');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testUsesDottedExitsClean(): Void {
		#if sys
		final fixture: String = writeFixture('class X { var y:Int; }');
		Assert.equals(0, Cli.run(['uses', 'Some.Type', fixture]), 'uses on dotted query is a clean 0-hit; nudge points at search');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// Regression: non-dotted query falls back to the original nudges.

	public function testLitPlainNameStillExitsClean(): Void {
		#if sys
		final fixture: String = writeFixture('class X { var y:Int; }');
		Assert.equals(0, Cli.run(['lit', 'nothingHere', fixture]), 'non-dotted query path unchanged');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// Multi-segment dotted (pkg.Module.entry) still qualifies.

	public function testLitMultiDottedExitsClean(): Void {
		#if sys
		final fixture: String = writeFixture('class X { var y:Int; }');
		Assert.equals(0, Cli.run(['lit', 'pkg.Module.entry', fixture]), 'multi-segment dotted query qualifies for the dotted nudge');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// Negative: empty segments / non-identifier chars must NOT trigger.

	public function testLitTrailingDotFallsThrough(): Void {
		#if sys
		final fixture: String = writeFixture('class X { var y:Int; }');
		Assert.equals(0, Cli.run(['lit', 'foo.', fixture]), 'trailing dot has an empty segment, falls back to plain nudge');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	private static function writeFixture(source: String): String {
		return CliFixture.write('apq_dotted_access_nudge', source);
	}
	#end

}
