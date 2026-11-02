package unit.dev;

import anyparse.query.Cli;
import dev.ArmRegistry;
import devkit.TempDir;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * A module relocation over a scratch copy of the REAL arm registry: the record leaves its package's document for the one of
 * the new package, the directory still reads, and the arm's cut still finds its member in the relocated module.
 */
@:nullSafety(Strict)
final class ArmMoveTest extends Test {

	private static inline final ARM: String = 'M-TAILMERGE-NORM-ONLY';

	public function testARelocatedModulesArmMovesToTheNewPackagesDocumentAndStillApplies(): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			final arms: String = Path.join([repo, 'test/testkit/arms']);
			FileSystem.createDirectory(arms);
			final real: String = Path.join([FileSystem.fullPath('.'), ArmRegistry.DIRECTORY]);
			for (name in FileSystem.readDirectory(real)) File.copy(Path.join([real, name]), Path.join([arms, name]));
			final record: Null<ArmRecord> = ArmRegistry.read(arms).find(r -> r.key == ARM);
			if (record == null) {
				Assert.fail('the real registry no longer holds $ARM');
				return;
			}
			final arm: { type: String, method: String, find: String } = Json.parse(record.text);
			final simple: String = arm.type.substr(arm.type.lastIndexOf('.') + 1);
			final oldPackage: String = arm.type.substr(0, arm.type.length - simple.length - 1);
			final from: String = Path.join([repo, 'src', oldPackage.split('.').join('/'), '$simple.hx']);
			final to: String = Path.join([repo, 'src/zz/moved', '$simple.hx']);
			FileSystem.createDirectory(Path.directory(from));
			final head: String = 'package $oldPackage;\n\nclass $simple {\n\n';
			final body: String = '\tpublic static function ${arm.method}():Int {\n\t\t${arm.find}\n\t\treturn 1;\n\t}\n\n}\n';
			final source: String = head + body;
			File.saveContent(from, source);
			final entry: Null<Any> = (cast Json.parse(File.getContent('apqlint.json'))
				.move.registries: Array<Any>).find(r -> Reflect.field(r, 'file') == ArmRegistry.DIRECTORY);
			if (entry == null) {
				Assert.fail('apqlint.json declares no move registry for ${ArmRegistry.DIRECTORY}');
				return;
			}
			File.saveContent(Path.join([repo, 'apqlint.json']), Json.stringify({ move: { scope: ['src'], registries: [entry] } }));
			final printed: String = CliFixture.captureStderr(() ->
				Assert.equals(0, Cli.run(['move', from, '--to', Path.directory(to), '--write']))
			);
			Assert.isTrue(FileSystem.exists(to), printed);
			final oldDocument: String = File.getContent(Path.join([arms, '$oldPackage.json']));
			Assert.equals(-1, oldDocument.indexOf('"$ARM"'), 'the record left the old package document');
			final newDocument: String = File.getContent(Path.join([arms, 'zz.moved.json']));
			Assert.isTrue(newDocument.indexOf('"$ARM"') > 0, 'the record sits in the document of the new package');
			final moved: Null<ArmRecord> = ArmRegistry.read(arms).find(r -> r.key == ARM);
			Assert.equals('zz.moved.$simple', Reflect.field(Json.parse(moved?.text ?? '{}'), 'type'), 'the record names the moved type');
			Assert.isTrue(FileSystem.exists(to) && !FileSystem.exists(from));
			final status: Int = ArmApply.applyOnly(repo, [ARM]);
			Assert.equals(0, status, 'the arm still finds its member in the relocated module');
		});
	}

}
