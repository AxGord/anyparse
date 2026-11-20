package unit.cli;

import anyparse.query.Cli;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * `apq safe-delete <file> --scope <dir>` with no member removes the TYPE: through the in-process CLI over a real tree, the
 * only type of a module takes its file, a type among others loses its declaration, a surviving reference refuses and is
 * listed, and the test companions a project's `move.mirrors` declares are named.
 */
class SafeDeleteTypeCliTest extends Test {

	private static final DEAD: String = 'package pkg;\n\nclass Dead {\n\tpublic function new() {}\n}\n';
	private static final HOST: String =
		'package pkg;\n\nclass Host {\n\tpublic function new() {}\n}\n\nclass Sub {\n\tpublic function new() {}\n}\n';

	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-CLI-DELETES-FILE')
	public function testWriteDeletesTheFileOfTheOnlyType(): Void {
		final dir: String = fixture([{ name: 'src/pkg/Dead.hx', source: DEAD }]);
		Assert.equals(0, Cli.run(['safe-delete', '$dir/src/pkg/Dead.hx', '--scope', '$dir/src', '--write']));
		Assert.isFalse(FileSystem.exists('$dir/src/pkg/Dead.hx'));
		CliFixture.removeDir(dir);
	}

	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-CLI-PREVIEW')
	public function testWithoutWriteTheFileStays(): Void {
		final dir: String = fixture([{ name: 'src/pkg/Dead.hx', source: DEAD }]);
		Assert.equals(0, Cli.run(['safe-delete', '$dir/src/pkg/Dead.hx', '--scope', '$dir/src']));
		Assert.isTrue(FileSystem.exists('$dir/src/pkg/Dead.hx'), 'a preview deletes nothing');
		CliFixture.removeDir(dir);
	}

	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-CLI-WRITES-DECLARATION')
	public function testWriteCutsASubTypeOutOfItsFile(): Void {
		final dir: String = fixture([{ name: 'src/pkg/Host.hx', source: HOST }]);
		Assert.equals(0, Cli.run([
			'safe-delete',
			'$dir/src/pkg/Host.hx',
			'--type',
			'Sub',
			'--scope',
			'$dir/src',
			'--write',
			'--reformat'
		]));
		final text: String = File.getContent('$dir/src/pkg/Host.hx');
		Assert.isFalse(text.contains('class Sub'), text);
		Assert.isTrue(text.contains('class Host'), text);
		CliFixture.removeDir(dir);
	}

	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-CLI-LISTS-REASONS')
	public function testReferenceRefusesAndIsListed(): Void {
		final user: String = 'package pkg;\n\nclass User {\n\tpublic var d: Dead;\n}\n';
		final dir: String = fixture([
			{ name: 'src/pkg/Dead.hx', source: DEAD },
			{ name: 'src/pkg/User.hx', source: user }
		]);
		var code: Int = -1;
		final err: String = CliFixture.captureStderr(() ->
			code = Cli.run(['safe-delete', '$dir/src/pkg/Dead.hx', '--scope', '$dir/src', '--write'])
		);
		Assert.equals(1, code);
		Assert.isTrue(err.contains('User.hx:4'), err);
		Assert.isTrue(FileSystem.exists('$dir/src/pkg/Dead.hx'), 'a refused delete removes nothing');
		CliFixture.removeDir(dir);
	}

	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-CLI-COMPANIONS')
	public function testMirrorCompanionIsNamedNotRemoved(): Void {
		final mirrors: String = '{"move":{"mirrors":[{"source":"src","test":"test","suffixes":["Test"]}]}}';
		final dir: String = fixture([
			{ name: 'apq.json', source: mirrors },
			{ name: 'src/pkg/Dead.hx', source: DEAD },
			{ name: 'test/pkg/DeadTest.hx', source: 'package pkg;\n\nclass DeadTest {}\n' }
		]);
		final err: String = CliFixture.captureStderr(() ->
			Cli.run(['safe-delete', '$dir/src/pkg/Dead.hx', '--scope', '$dir/src', '--write'])
		);
		Assert.isTrue(err.contains('DeadTest.hx'), err);
		Assert.isTrue(FileSystem.exists('$dir/test/pkg/DeadTest.hx'), 'the companion is never removed silently');
		CliFixture.removeDir(dir);
	}

	private static function fixture(files: Array<{ name: String, source: String }>): String {
		return CliFixture.writeTree('safedeletetype', files);
	}

}
