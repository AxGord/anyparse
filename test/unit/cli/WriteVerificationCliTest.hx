package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.check.oracle.CompilerOracle;
import anyparse.query.Cli;
import anyparse.query.cli.CliIo;

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
		FileSystem.createDirectory('$dir/src/pkg');
		File.saveContent('$dir/src/pkg/Other.hx', 'class Other {\n\t// Bad is created beside this\n}\n');
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = newModule(dir, 'pkg/Bad.hx', 'return "x";'));
		Assert.equals(1, rc, printed);
		Assert.isFalse(FileSystem.exists('$dir/src/pkg/Bad.hx'), 'the created module is removed');
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

	@:pin('control')
	@:killer('M-WRITE-VERIFY-HOLDERS-COMPILE')
	public function testACreatedModuleNoBuildParsesIsNamedToTheBuildAfterItsConfiguredCompile(): Void {
		#if (sys || nodejs)
		final dir: String = sourceProject();
		if (!compiles(dir)) return;
		final spawned: Int = CompilerOracle.invocations;
		var rc: Int = 1;
		final printed: String = CliFixture.captureStderr(() -> rc = newModule(dir, 'pkg/Fine.hx', 'return 1;'));
		Assert.equals(0, rc, printed);
		Assert.equals(2, CompilerOracle.invocations - spawned, 'the configured compile of the holder, then the module named to it');
		Assert.isTrue(FileSystem.exists('$dir/src/pkg/Fine.hx'));
		#if nodejs
		Assert.isTrue(printed.contains('verified by 1 configured build'), printed);
		#end
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-NO-PLAIN-RETRY')
	public function testARejectionBlamingACreatedModuleIsFinalWithoutAPlainRetry(): Void {
		#if (sys || nodejs)
		final dir: String = sourceProject();
		if (!compiles(dir)) return;
		final spawned: Int = CompilerOracle.invocations;
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = newModule(dir, 'pkg/Bad.hx', 'return "x";'));
		Assert.equals(1, rc, printed);
		Assert.equals(
			2, CompilerOracle.invocations - spawned, 'the configured compile and the module named: no plain run of the rejected one'
		);
		Assert.isFalse(FileSystem.exists('$dir/src/pkg/Bad.hx'), 'the created module is removed');
		Assert.isFalse(FileSystem.exists('$dir/src/pkg'), 'and the directory made for it');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-BLAMED-CREATED-NO-ROLLBACK-COMPILE')
	public function testARedBuildBlamingACreatedModuleIsPutBackWithoutACompileOfTheOldTree(): Void {
		#if (sys || nodejs)
		if (!compiles(sourceProject())) return;
		final dir: String = sourceProject();
		FileSystem.createDirectory('$dir/src/pkg');
		File.saveContent('$dir/src/Good.hx', 'import pkg.Bad;\n\nclass Good {\n\tstatic function main() {\n\t\ttrace(Bad.f());\n\t}\n}\n');
		File.saveContent('$dir/src/pkg/Other.hx', 'class Other {\n\t// Bad is created beside this\n}\n');

		final spawned: Int = CompilerOracle.invocations;
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = newModule(dir, 'pkg/Bad.hx', 'return "x";'));
		Assert.equals(1, rc, printed);
		Assert.equals(
			1, CompilerOracle.invocations - spawned, 'the build reds on the new module: no plain run, no compile of the tree without it'
		);
		Assert.isFalse(FileSystem.exists('$dir/src/pkg/Bad.hx'), 'the created module is removed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-ONE-HOLDER-NOT-FINAL')
	public function testACheapBuildMissingTheModulesDependencyDoesNotDecideAGreenerHolderDoes(): Void {
		#if (sys || nodejs)
		final dir: String = twoBuilds('class Big {\n\tstatic function main() {}\n}\n', [
			{ name: 'more/Util.hx', source: 'class Util {\n\tpublic static function one(): Int {\n\t\treturn 1;\n\t}\n}\n' }
		]);
		if (!compilesBoth(dir)) return;
		final spawned: Int = CompilerOracle.invocations;
		var rc: Int = 1;
		final printed: String = CliFixture.captureStderr(() -> rc = Cli.run([
			'new',
			'$dir/src/pkg/UsesUtil.hx',
			'--kind',
			'class',
			'--field',
			'public static function f(): Int { return Util.one(); }',
			'--write'
		]));
		Assert.equals(0, rc, printed);
		Assert.isTrue(FileSystem.exists('$dir/src/pkg/UsesUtil.hx'), 'the module stays: a build holding its dependency typechecks it');
		Assert.equals(
			4, CompilerOracle.invocations - spawned,
			'both configured, then the cheap build rejected the module named to it and the larger one vouched'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-DECISIVE-DIAGNOSTICS-ONLY')
	public function testADecisiveRejectionQuotesOnlyTheDiagnostics(): Void {
		#if (sys || nodejs)
		final dir: String = sourceProject();
		if (!compiles(dir)) return;
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = newModule(dir, 'pkg/Bad.hx', 'return "x";'));
		Assert.equals(1, rc, printed);
		Assert.isTrue(printed.contains('Bad.hx'), printed);
		Assert.isFalse(printed.contains('Parsed '), 'the -v stream is no part of the quoted errors');
		Assert.isFalse(printed.contains('Typing macro'), 'nor is any other -v line');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-HOLDERS-COMPILE')
	public function testACreatedModuleShadowingAStandardLibraryOneTakesTheFullPass(): Void {
		#if (sys || nodejs)
		final dir: String = twoBuilds('class Big {\n\tstatic function main() {\n\t\ttrace(Xml.parse(\'<a/>\'));\n\t}\n}\n', []);
		if (!compilesBoth(dir)) return;
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = Cli.run([
			'new',
			'$dir/src/haxe/xml/Parser.hx',
			'--kind',
			'class',
			'--field',
			'public static function other(): Int { return 1; }',
			'--write'
		]));
		Assert.equals(1, rc, printed);
		Assert.isFalse(FileSystem.exists('$dir/src/haxe/xml/Parser.hx'), 'the shadow is put back');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-HOLDERS-COMPILE')
	public function testACreatedModuleAWildcardImportBindsTakesTheFullPass(): Void {
		#if (sys || nodejs)
		final dir: String = twoBuilds('class Big {\n\tstatic function main() {\n\t\ttrace(other.X.f());\n\t}\n}\n', [
			{
				name: 'more/other/X.hx',
				source: 'package other;\n\nimport app.*;\n\nclass X {\n\tpublic static function f(): Float {\n'
				+ '\t\treturn Date.now().getTime();\n\t}\n}\n'
			},
			{ name: 'more/app/Keep.hx', source: 'package app;\n\nclass Keep {}\n' }
		]);
		if (!compilesBoth(dir)) return;
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = Cli.run([
			'new',
			'$dir/src/app/Date.hx',
			'--kind',
			'class',
			'--field',
			'public static function other(): Int { return 1; }',
			'--write'
		]));
		Assert.equals(1, rc, printed);
		Assert.isFalse(FileSystem.exists('$dir/src/app/Date.hx'), 'the module the wildcard now binds is put back');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-HOLDERS-COMPILE')
	public function testACreatedModuleASubPackageFileBindsByParentLookupTakesTheFullPass(): Void {
		#if (sys || nodejs)
		final dir: String = twoBuilds('class Big {\n\tstatic function main() {\n\t\ttrace(app.sub.User.f());\n\t}\n}\n', [
			{
				name: 'more/app/sub/User.hx',
				source: 'package app.sub;\n\nclass User {\n\tpublic static function f(): Float {\n\t\treturn Date.now().getTime();\n\t}\n'
				+ '}\n'
			},
			{ name: 'more/app/Keep.hx', source: 'package app;\n\nclass Keep {}\n' }
		]);
		if (!compilesBoth(dir)) return;
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = Cli.run([
			'new',
			'$dir/src/app/Date.hx',
			'--kind',
			'class',
			'--field',
			'public static function other(): Int { return 1; }',
			'--write'
		]));
		Assert.equals(1, rc, printed);
		Assert.isFalse(FileSystem.exists('$dir/src/app/Date.hx'), 'the module the sub-package now binds is put back');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-HOLDERS-COMPILE')
	public function testABuildThatWalksTheFolderOfACreatedModuleReadsItInItsConfiguredCompile(): Void {
		#if (sys || nodejs)
		final dir: String = twoBuilds('class Big {\n\tstatic function main() {}\n}\n', [
			{
				name: 'more/Walk.hx',
				source: 'class Walk {\n\tpublic static function run(): Void {\n'
				+ '\t\tif (sys.FileSystem.exists(\'src/pkg\')) for (name in sys.FileSystem.readDirectory(\'src/pkg\')) if (name == '
				+ '\'Refused.hx\') haxe.macro.Context.error(\'the walk refuses \' + name, haxe.macro.Context.currentPos());\n\t}\n}\n'
			}
		]);
		File.saveContent('$dir/big.hxml', '-cp src\n-cp more\n--macro Walk.run()\n-main Big\n');
		if (!compilesBoth(dir)) return;
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = newModule(dir, 'pkg/Refused.hx', 'return 1;'));
		Assert.equals(1, rc, printed);
		Assert.isFalse(FileSystem.exists('$dir/src/pkg/Refused.hx'), 'the module the walk refuses is put back');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-ONLY-HOLDERS')
	public function testABuildHoldingNoCreatedModuleIsNotCompiled(): Void {
		#if (sys || nodejs)
		final dir: String = twoBuilds('class Big {\n\tstatic function main() {}\n}\n', [], true);
		if (!compilesBoth(dir)) return;
		var rc: Int = 1;
		final printed: String = CliFixture.captureStderr(() -> rc = newModule(dir, 'pkg/Fine.hx', 'return 1;'));
		Assert.equals(0, rc, printed);
		Assert.isFalse(printed.contains('alien.hxml'), 'the build whose class paths hold none of it is not asked: $printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-VERIFY-STOPS-AT-FIRST-GREEN')
	public function testACreatedModuleIsNamedToTheCheapestHolderAndNoFurther(): Void {
		#if (sys || nodejs)
		final dir: String = twoBuilds('class Big {\n\tstatic function main() {}\n}\n', []);
		if (!compilesBoth(dir)) return;
		final spawned: Int = CompilerOracle.invocations;
		var rc: Int = 1;
		final printed: String = CliFixture.captureStderr(() -> rc = newModule(dir, 'pkg/Fine.hx', 'return 1;'));
		Assert.equals(0, rc, printed);
		Assert.equals(3, CompilerOracle.invocations - spawned, 'both holders as configured, the module named to the cheaper one only');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A project of two builds over `src/`, the cheap one `Good` alone and the larger one `Big` (in `more/`, also a class path
	 * of it), with `extras` written beside them (paths relative to the project) and an `apq.json` naming both.
	 */
	private static function twoBuilds(big: String, extras: Array<{ name: String, source: String }>, alien: Bool = false): String {
		final builds: String = alien ? ', {"hxml": "alien.hxml"}' : '';
		final dir: String = CliFixture.writeDir('writeverify', [
			{ name: 'cheap.hxml', source: '-cp src\n-main Good\n' },
			{ name: 'big.hxml', source: '-cp src\n-cp more\n-main Big\n' },
			{ name: 'alien.hxml', source: '-cp alien\n-main Alien\n' },
			{ name: 'apq.json', source: '{"compilerOracle": [{"hxml": "cheap.hxml"}, {"hxml": "big.hxml"}$builds]}' }
		]);
		final files: Array<{ name: String, source: String }> = extras.concat([
			{ name: 'alien/Alien.hx', source: 'class Alien {\n\tstatic var red: Int = \'no\';\n\n\tstatic function main() {}\n}\n' },
			{ name: 'src/Good.hx', source: GOOD },
			{ name: 'more/Big.hx', source: big }
		]);
		CliIo.writeFiles(files.map(f -> {path: '$dir/${f.name}', content: f.source }));
		return dir;
	}

	/** Whether both builds of `twoBuilds` typecheck — false, with the test passed and `dir` removed, on a host with no compiler. */
	private static function compilesBoth(dir: String): Bool {
		if (CompilerOracle.typecheck('cheap.hxml', dir).match(Confirmed) && CompilerOracle.typecheck('big.hxml', dir).match(Confirmed))
			return true;
		Assert.pass('haxe unavailable — skipped');
		CliFixture.removeDir(dir);
		return false;
	}

	#if (sys || nodejs)
	/** A one-class project in the temp directory holding `good`, its build, and — with `oracle` — an `apq.json` naming it. */
	private static function project(good: String, oracle: Bool): String {
		final files: Array<{ name: String, source: String }> = [
			{ name: 'Good.hx', source: good },
			{ name: 'build.hxml', source: '-cp .\n-main Good\n' }
		];
		if (oracle) files.push({ name: 'apq.json', source: '{"compilerOracle": "build.hxml"}' });
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

	/** A project whose build reaches `src/Good.hx` only, through `-cp src`, with an `apq.json` naming it. */
	private static function sourceProject(): String {
		final dir: String = CliFixture.writeDir('writeverify', [
			{ name: 'build.hxml', source: '-cp src\n-main Good\n' },
			{ name: 'apq.json', source: '{"compilerOracle": "build.hxml"}' }
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
