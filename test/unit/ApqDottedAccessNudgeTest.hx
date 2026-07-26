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
@:access(anyparse.query.Cli)
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

	// `refs` resolved no read/write but the scope holds member accesses of the name.

	/** With nothing resolved the omission is the dangerous kind, so the warning says so outright. */
	public function testMemberAccessNudgeWarnsHardWhenNothingResolved(): Void {
		final text: String = Cli.memberAccessNudge('refs', 'parse', 4, 0);

		Assert.isTrue(text.indexOf('4 member-access') >= 0, text);
		Assert.isTrue(text.indexOf('NOT proof') >= 0, text);
		Assert.isTrue(text.indexOf('apq mentions parse <dir>') >= 0, text);
	}

	/**
	 * With reads resolved the result is merely partial, not misleading — no
	 * "unreferenced" claim to refute. `bindings` is the UNFILTERED total, so the wording
	 * does not swing with `--decls` / `--writes`.
	 */
	public function testMemberAccessNudgeSoftensWhenBindingsResolved(): Void {
		final text: String = Cli.memberAccessNudge('refs', 'parse', 4, 2);

		Assert.isTrue(text.indexOf('are not shown') >= 0, text);
		Assert.equals(-1, text.indexOf('NOT proof'), text);
	}

	/** Trailing newline is the CALL SITE's job here, as for every sibling nudge. */
	public function testMemberAccessNudgeHasNoTrailingNewline(): Void {
		final text: String = Cli.memberAccessNudge('refs', 'parse', 1, 0);
		Assert.equals(-1, text.indexOf('\n'), text);
	}

	/** A qualified static call resolves to no read, and the refs run still exits clean. */
	public function testRefsQualifiedStaticExitsClean(): Void {
		#if sys
		final fixture: String = writeFixture('class B { function g():Int return A.f(); }');
		Assert.equals(0, Cli.run(['refs', 'f', fixture]), 'member-access nudge is a warning, not an error');
		Assert.equals(0, Cli.run(['refs', 'f', fixture, '--decls']), 'the warning does not change the exit code under a filter');
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
