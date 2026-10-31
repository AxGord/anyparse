package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.check.oracle.CompilerOracle;
import anyparse.query.Cli;

using StringTools;

/**
 * The typecheck after a write command (`WriteVerification`), end to end on a one-class project in the temp directory: a
 * write that breaks a build that typechecked before it is put back with the compiler's message and a non-zero exit, one
 * that compiles stays, a build red before the write judges nothing, `--no-verify` skips the check, and a project with no
 * `compilerOracle` keeps the write and says it is unverified. Every scenario that needs the compiler passes when the host
 * has none.
 */
@:nullSafety(Strict)
class WriteVerificationCliTest extends Test {

	#if (sys || nodejs)
	private static final GOOD: String = 'class Good {\n\tstatic function main() {\n\t\ttrace(1);\n\t}\n}\n';
	private static final RED: String =
		'class Good {\n\tstatic var red:Int = \'no\';\n\n\tstatic function main() {\n\t\ttrace(1);\n\t}\n}\n';
	private static final BREAKING: String = 'static var broken: Int = "no";';
	private static final COMPILING: String = 'static var fine: Int = 1;';
	#end

	@:pin('control')
	@:killer('M-WRITE-VERIFY-NO-ROLLBACK')
	public function testAWriteThatBreaksTheBuildIsPutBack(): Void {
		#if (sys || nodejs)
		final dir: String = project(GOOD, true);
		if (!compiles(dir)) return;
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = addMember(dir, BREAKING, []));
		Assert.equals(1, rc, printed);
		Assert.equals(GOOD, File.getContent('$dir/Good.hx'), 'the file is put back');
		#if nodejs
		Assert.isTrue(printed.contains('String should be Int'), 'the compiler says why: $printed');
		Assert.isTrue(printed.contains('every file put back'), printed);
		#end
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAWriteThatCompilesStays(): Void {
		#if (sys || nodejs)
		final dir: String = project(GOOD, true);
		if (!compiles(dir)) return;
		var rc: Int = 1;
		final printed: String = CliFixture.captureStderr(() -> rc = addMember(dir, COMPILING, []));
		Assert.equals(0, rc, printed);
		Assert.isTrue(File.getContent('$dir/Good.hx').contains('fine'), 'the write stays');
		#if nodejs
		Assert.isTrue(printed.contains('verified by 1 configured build'), printed);
		#end
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-RED-BEFORE-JUDGES')
	public function testABuildRedBeforeTheWriteJudgesNothing(): Void {
		#if (sys || nodejs)
		if (!compiles(project(GOOD, false))) return;
		final dir: String = project(RED, true);
		var rc: Int = 1;
		final printed: String = CliFixture.captureStderr(() -> rc = addMember(dir, COMPILING, []));
		Assert.equals(0, rc, printed);
		Assert.isTrue(File.getContent('$dir/Good.hx').contains('fine'), 'the write is replayed after the second compile');
		#if nodejs
		Assert.isTrue(printed.contains('judges nothing'), printed);
		#end
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testNoVerifyKeepsABreakingWriteAndCompilesNothing(): Void {
		#if (sys || nodejs)
		final dir: String = project(GOOD, true);
		final spawned: Int = CompilerOracle.invocations;
		Assert.equals(0, addMember(dir, BREAKING, ['--no-verify']));
		Assert.isTrue(File.getContent('$dir/Good.hx').contains('broken'), 'the write stays unchecked');
		Assert.equals(spawned, CompilerOracle.invocations, 'no compiler is spawned');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testWithoutAnOracleTheWriteStaysUnverified(): Void {
		#if (sys || nodejs)
		final dir: String = project(GOOD, false);
		final spawned: Int = CompilerOracle.invocations;
		var rc: Int = 1;
		final printed: String = CliFixture.captureStderr(() -> rc = addMember(dir, BREAKING, []));
		Assert.equals(0, rc, printed);
		Assert.isTrue(File.getContent('$dir/Good.hx').contains('broken'));
		Assert.equals(spawned, CompilerOracle.invocations, 'no compiler is spawned');
		#if nodejs
		Assert.isTrue(printed.contains('unverified'), printed);
		#end
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAnInPlaceEditWithoutVerifyCompilesNothingAndSaysNothing(): Void {
		#if (sys || nodejs)
		final dir: String = project(GOOD, true);
		final spawned: Int = CompilerOracle.invocations;
		var rc: Int = 1;
		final printed: String = CliFixture.captureStderr(() ->
			rc = Cli.run(['add-member', '$dir/Good.hx', '--type', 'Good', BREAKING, '--write'])
		);
		Assert.equals(0, rc, printed);
		Assert.equals(spawned, CompilerOracle.invocations, 'no compiler is spawned for an edit that creates and deletes nothing');
		Assert.isFalse(printed.contains('verified'), printed);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-UNREACHED-KEPT')
	public function testACreatedModuleNoBuildReachesIsNamedToTheBuildAndPutBackWhenItDoesNotCompile(): Void {
		#if (sys || nodejs)
		final dir: String = sourceProject();
		if (!compiles(dir)) return;
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = newModule(dir, 'pkg/Bad.hx', 'return "x";'));
		Assert.equals(1, rc, printed);
		Assert.isFalse(FileSystem.exists('$dir/src/pkg/Bad.hx'), 'the created module is removed');
		Assert.isFalse(FileSystem.exists('$dir/src/pkg'), 'and the directory made for it');
		#if nodejs
		Assert.isTrue(printed.contains('String should be Int'), printed);
		#end
		final kept: Int = newModule(dir, 'pkg/Fine.hx', 'return 1;');
		Assert.equals(0, kept, 'a created module that compiles when named stays');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-COUNTS-EVERY-BUILD')
	public function testABuildThatNeverParsedTheWrittenFileDoesNotVouchForIt(): Void {
		#if (sys || nodejs)
		final dir: String = sourceProject();
		if (!compiles(dir)) return;
		var rc: Int = 1;
		final printed: String = CliFixture.captureStderr(() -> rc = Cli.run(['new', '$dir/other/Lone.hx', '--kind', 'class', '--write']));
		Assert.equals(0, rc, printed);
		#if nodejs
		Assert.isFalse(printed.contains('verified by'), 'a green build that never read the file is no verdict: $printed');
		Assert.isTrue(printed.contains('compiled by no configured build'), printed);
		#end
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** A one-class project in the temp directory holding `good`, its build, and — with `oracle` — an `apqlint.json` naming it. */
	private static function project(good: String, oracle: Bool): String {
		final files: Array<{ name: String, source: String }> = [
			{ name: 'Good.hx', source: good },
			{ name: 'build.hxml', source: '-cp .\n-main Good\n' }
		];
		if (oracle) files.push({ name: 'apqlint.json', source: '{"compilerOracle": "build.hxml"}' });
		return CliFixture.writeDir('writeverify', files);
	}

	/** Whether `dir`'s build typechecks — false, with the test passed and `dir` removed, on a host with no compiler. */
	private static function compiles(dir: String): Bool {
		if (CompilerOracle.typecheck('build.hxml', dir).match(Confirmed)) return true;
		Assert.pass('haxe unavailable — skipped');
		CliFixture.removeDir(dir);
		return false;
	}

	/** `add-member` of `member` into the project's class with `--write --verify` — an in-place edit asks for the check — and `extra`. */
	private static function addMember(dir: String, member: String, extra: Array<String>): Int {
		return Cli.run(['add-member', '$dir/Good.hx', '--type', 'Good', member, '--write', '--verify'].concat(extra));
	}

	/** A project whose build reaches `src/Good.hx` only, through `-cp src`, with an `apqlint.json` naming it. */
	private static function sourceProject(): String {
		final dir: String = CliFixture.writeDir('writeverify', [
			{ name: 'build.hxml', source: '-cp src\n-main Good\n' },
			{ name: 'apqlint.json', source: '{"compilerOracle": "build.hxml"}' }
		]);
		FileSystem.createDirectory('$dir/src');
		File.saveContent('$dir/src/Good.hx', GOOD);
		return dir;
	}

	/** `new` of the class at `path` under `src/`, one static `f(): Int` whose body is `body`, with `--write`. */
	private static function newModule(dir: String, path: String, body: String): Int {
		return Cli.run([
			'new',
			'$dir/src/$path',
			'--kind',
			'class',
			'--field',
			'public static function f(): Int { $body }',
			'--write'
		]);
	}
	#end

}
