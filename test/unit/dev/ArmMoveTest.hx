package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.query.Cli;
import dev.ArmRegistry;
import devkit.RawJson;
import devkit.TempDir;
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
			final arm: JValue = JValueParser.parse(record.text);
			final type: String = RawJson.stringAt(arm, 'type') ?? '';
			final simple: String = type.substr(type.lastIndexOf('.') + 1);
			final oldPackage: String = type.substr(0, type.length - simple.length - 1);
			final from: String = Path.join([repo, 'src', oldPackage.split('.').join('/'), '$simple.hx']);
			final to: String = Path.join([repo, 'src/zz/moved', '$simple.hx']);
			FileSystem.createDirectory(Path.directory(from));
			final head: String = 'package $oldPackage;\n\nclass $simple {\n\n';
			final method: Null<String> = RawJson.stringAt(arm, 'method');
			final find: Null<String> = RawJson.stringAt(arm, 'find');
			final body: String = '\tpublic static function $method():Int {\n\t\t$find\n\t\treturn 1;\n\t}\n\n}\n';
			final source: String = head + body;
			File.saveContent(from, source);
			final entry: Null<JValue> = RawJson.items(JValueTools.at(JValueParser.parse(File.getContent('apq.json')), 'move.registries'))
				.find(r -> RawJson.stringAt(r, 'file') == ArmRegistry.DIRECTORY);
			if (entry == null) {
				Assert.fail('apq.json declares no move registry for ${ArmRegistry.DIRECTORY}');
				return;
			}
			File.saveContent(Path.join([repo, 'apq.json']), '{"move":{"scope":["src"],"registries":[${RawJson.print(entry)}]}}');
			final printed: String = CliFixture.captureStderr(() ->
				Assert.equals(0, Cli.run(['move', from, '--to', Path.directory(to), '--write']))
			);
			Assert.isTrue(FileSystem.exists(to), printed);
			final oldDocument: String = File.getContent(Path.join([arms, '$oldPackage.json']));
			Assert.equals(-1, oldDocument.indexOf('"$ARM"'), 'the record left the old package document');
			final newDocument: String = File.getContent(Path.join([arms, 'zz.moved.json']));
			Assert.isTrue(newDocument.indexOf('"$ARM"') > 0, 'the record sits in the document of the new package');
			final moved: Null<ArmRecord> = ArmRegistry.read(arms).find(r -> r.key == ARM);
			Assert.equals(
				'zz.moved.$simple', RawJson.stringAt(JValueParser.parse(moved?.text ?? '{}'), 'type'), 'the record names the moved type'
			);
			Assert.isTrue(FileSystem.exists(to) && !FileSystem.exists(from));
			final status: Int = ArmApply.applyOnly(repo, [ARM]);
			Assert.equals(0, status, 'the arm still finds its member in the relocated module');
		});
	}

}
