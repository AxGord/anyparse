package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;

using StringTools;

/**
 * `apq move <file>... --to <dir>` end to end, on a project written to the temp directory: the declaration is read from
 * the project's `apqlint.json`, a write relocates the module and deletes the original, a refusal writes nothing, and
 * `--verify` puts every file back when the build the move broke was green before it.
 */
class ModuleMoveCliTest extends Test {

	private static final A: String = 'package pkg;\n\nclass A {\n\tpublic static function f(): Int return 1;\n}\n';

	@:pin('control')
	@:killer('M-MODMOVE-CLI-ORIGINAL-KEPT')
	public function testTheWriteRelocatesTheModuleRewritesItsReadersAndDeletesTheOriginal(): Void {
		#if (sys || nodejs)
		final dir: String = project([
			{ name: 'apqlint.json', source: '{"move": {"scope": ["src"], "text": ["run.sh"]}}' },
			{ name: 'run.sh', source: 'node probe.js src/pkg/A.hx\n' },
			{ name: 'src/pkg/A.hx', source: A },
			{ name: 'src/pkg/User.hx', source: 'package pkg;\n\nclass User {\n\tfunction g(): Int return A.f();\n}\n' }
		]);
		final rc: Int = Cli.run(['move', '$dir/src/pkg/A.hx', '--to', '$dir/src/pkg/sub', '--write']);
		Assert.equals(0, rc, 'the move succeeds');
		Assert.isFalse(FileSystem.exists('$dir/src/pkg/A.hx'), 'the original is gone');
		Assert.equals(A.replace('package pkg;', 'package pkg.sub;'), File.getContent('$dir/src/pkg/sub/A.hx'));
		Assert.equals(
			'package pkg;\n\nimport pkg.sub.A;\n\nclass User {\n\tfunction g(): Int return A.f();\n}\n',
			File.getContent('$dir/src/pkg/User.hx')
		);
		Assert.equals('node probe.js src/pkg/sub/A.hx\n', File.getContent('$dir/run.sh'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('guard')
	public function testARefusalWritesNothing(): Void {
		#if (sys || nodejs)
		final user: String =
			"package other;\n\nclass User {\n\tstatic function f(n: String): Dynamic return Type.resolveClass('pkg.' + n);\n}\n";
		final dir: String = project([
			{ name: 'apqlint.json', source: '{"move": {"scope": ["src"]}}' },
			{ name: 'src/pkg/A.hx', source: A },
			{ name: 'src/other/User.hx', source: user }
		]);
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() ->
			rc = Cli.run(['move', '$dir/src/pkg/A.hx', '--to', '$dir/src/pkg/sub', '--write'])
		);
		Assert.notEquals(0, rc, 'the move is refused');
		#if nodejs
		Assert.isTrue(printed.contains('composes a path from "pkg."'), printed);
		#end
		Assert.equals(A, File.getContent('$dir/src/pkg/A.hx'), 'the original stays');
		Assert.isFalse(FileSystem.exists('$dir/src/pkg/sub/A.hx'), 'no copy is written');
		Assert.equals(user, File.getContent('$dir/src/other/User.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-JOURNAL-NO-RESTORE')
	@:killer('M-WRITE-JOURNAL-DIRS-KEPT')
	public function testVerifyPutsEveryFileBackWhenTheMoveBreaksTheBuild(): Void {
		#if (sys || nodejs)
		// `Owner` lives on a classpath the scope does not index, so no binding check can see the move lose it — the case
		// only the build can catch.
		final owner: String = 'package pkg;\n\nclass Owner {\n\tpublic static function secret(): Int return 1;\n}\n';
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function f(): Int return Owner.secret();\n}\n';
		final dir: String = project([
			{ name: 'apqlint.json', source: '{"compilerOracle": "build.hxml", "move": {"scope": ["src"]}}' },
			{ name: 'build.hxml', source: '-cp src\n-cp lib\npkg.A\n' },
			{ name: 'src/pkg/A.hx', source: a },
			{ name: 'lib/pkg/Owner.hx', source: owner }
		]);
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() ->
			rc = Cli.run(['move', '$dir/src/pkg/A.hx', '--to', '$dir/src/other', '--write', '--verify'])
		);
		Assert.notEquals(0, rc, 'the move is put back');
		#if nodejs
		Assert.isTrue(printed.contains('every file put back'), printed);
		#end
		Assert.equals(a, File.getContent('$dir/src/pkg/A.hx'), 'the original is restored');
		Assert.isFalse(FileSystem.exists('$dir/src/other/A.hx'), 'the copy is removed');
		Assert.isFalse(FileSystem.exists('$dir/src/other'), 'and the directory the write created');
		Assert.equals(owner, File.getContent('$dir/lib/pkg/Owner.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-MODMOVE-CLI-TEXT-ROOT-MISSING')
	public function testADeclaredTextRootThatDoesNotExistRefuses(): Void {
		#if (sys || nodejs)
		final dir: String = project([
			{ name: 'apqlint.json', source: '{"move": {"scope": ["src"], "text": ["tool.sh"]}}' },
			{ name: 'src/pkg/A.hx', source: A }
		]);
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() ->
			rc = Cli.run(['move', '$dir/src/pkg/A.hx', '--to', '$dir/src/pkg/sub', '--write'])
		);
		Assert.notEquals(0, rc, 'the move is refused');
		#if nodejs
		Assert.isTrue(printed.contains('declares text'), printed);
		#end
		Assert.equals(A, File.getContent('$dir/src/pkg/A.hx'), 'the original stays');
		Assert.isFalse(FileSystem.exists('$dir/src/pkg/sub'), 'nothing is written');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** A project directory holding `files`, each `name` a path relative to it. */
	private static function project(files: Array<{ name: String, source: String }>): String {
		final dir: String = CliFixture.writeDir('modulemove', []);
		for (f in files) {
			final path: String = '$dir/${f.name}';
			final parent: String = haxe.io.Path.directory(path);
			if (!FileSystem.exists(parent)) FileSystem.createDirectory(parent);
			File.saveContent(path, f.source);
		}
		return dir;
	}
	#end

}
