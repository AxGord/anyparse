package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;

using StringTools;

/**
 * `apq move` end to end over a declared `byPackage` registry: the flag survives the declaration and the registry
 * expansion, so a record follows its type to the document of the new package; a registry without the flag is only
 * rewritten in place.
 */
class MoveByPackageCliTest extends Test {

	public function testAByPackageRegistryFollowsTheMovedType(): Void {
		#if (sys || nodejs)
		final dir: String = fixture(true);
		final printed: String = CliFixture.captureStderr(() -> Assert.equals(0, run(dir, '--write')));
		Assert.isTrue(File.getContent('$dir/reg/b.json').contains('"type": "b.X"'), printed);
		Assert.isFalse(FileSystem.exists('$dir/reg/a.json'), 'the emptied document is deleted');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testARegistryWithoutTheFlagIsOnlyRewritten(): Void {
		#if (sys || nodejs)
		final dir: String = fixture(false);
		final printed: String = CliFixture.captureStderr(() -> Assert.equals(0, run(dir, '--write')));
		Assert.isTrue(File.getContent('$dir/reg/a.json').contains('"type": "b.X"'), printed);
		Assert.isFalse(FileSystem.exists('$dir/reg/b.json'), 'no document is created');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testThePreviewNamesTheDocumentsItCreatesAndRemoves(): Void {
		#if (sys || nodejs)
		final dir: String = fixture(true);
		var printed: String = '';
		CliFixture.captureStderr(() -> printed = CliFixture.captureStdout(() -> run(dir, null)));
		Assert.isTrue(printed.contains('reg/b.json: created'), printed);
		Assert.isTrue(printed.contains('reg/a.json: removed'), printed);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** A project with module `a.X`, its arm in `reg/a.json`, and a `move` declaration with or without `byPackage`. */
	private static function fixture(byPackage: Bool): String {
		final dir: String = CliFixture.writeDir('movebypackage', []);
		FileSystem.createDirectory('$dir/src');
		FileSystem.createDirectory('$dir/src/a');
		FileSystem.createDirectory('$dir/reg');
		File.saveContent('$dir/src/a/X.hx', 'package a;\n\nclass X {}\n');
		final flag: String = byPackage ? ', "byPackage": true' : '';
		File.saveContent('$dir/apq.json', '{"move": {"scope": ["src"], "registries": [{"file": "reg", "keys": ["arms.type"]$flag}]}}\n');
		File.saveContent('$dir/reg/a.json', '{\n\t"arms": [\n\t\t{\n\t\t\t"name": "M-X",\n\t\t\t"type": "a.X"\n\t\t}\n\t]\n}\n');
		return dir;
	}

	private static function run(dir: String, write: Null<String>): Int {
		final args: Array<String> = ['move', '$dir/src/a/X.hx', '--to', '$dir/src/b'];
		if (write != null) args.push(write);
		return Cli.run(args);
	}
	#end

}
