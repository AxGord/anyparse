package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;

using StringTools;

/**
 * `apq move` names its files absolutely while `--scope` is relative: the scope walk and the named files are one set of
 * files however each was spelled, so the type is declared once under scope, not once per spelling.
 */
class MoveScopeSpellingCliTest extends Test {

	@:pin('control')
	@:killer('M-SCOPE-FILES-BY-SPELLING')
	public function testAbsoluteFilesUnderARelativeScopeAreOneFileEach(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('movescopespelling', []);
		FileSystem.createDirectory('$dir/src');
		FileSystem.createDirectory('$dir/src/p');
		File.saveContent('$dir/src/p/A.hx', 'package p;\n\nclass A {}\n');
		File.saveContent('$dir/src/p/B.hx', 'package p;\n');
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = Cli.run([
			'move',
			'$dir/src/p/A.hx',
			'--select',
			'ClassDecl:A',
			'$dir/src/p/B.hx',
			'--scope',
			relative('$dir/src'),
			'--write'
		]));
		Assert.equals(0, rc, printed);
		Assert.isFalse(printed.contains('ambiguous'), printed);
		Assert.isTrue(File.getContent('$dir/src/p/B.hx').contains('class A'), 'the declaration lands in the destination');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** `path` spelled relative to the working directory, climbing to the root first. */
	private static function relative(path: String): String {
		final cwd: String = FileSystem.absolutePath(Sys.getCwd());
		final depth: Int = [for (segment in cwd.split('/')) if (segment != '') segment].length;
		return [for (_ in 0...depth) '..'].join('/') + FileSystem.absolutePath(path);
	}
	#end

}
