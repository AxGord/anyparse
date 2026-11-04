package unit.dev;

import dev.ArmRegistry;
import devkit.TempDir;
import haxe.Json;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `ArmRegistry` over synthetic registries: a registry it cannot key is refused.
 */
@:nullSafety(Strict)
final class ArmRegistryTest extends Test {

	public function testANameDeclaredTwiceIsRefused(): Void {
		Assert.raises(() -> ArmRegistry.parse(file([arm('A', '1'), arm('A', '2')])), ArmRegistryError);
	}

	public function testANameDeclaredInTwoDocumentsIsRefused(): Void {
		Assert.raises(() -> ArmRegistry.parseAll([file([arm('A', '1')]), file([arm('B', '1'), arm('A', '2')])]), ArmRegistryError);
		Assert.same(['A', 'B'], ArmRegistry.parseAll([file([arm('A', '1')]), file([arm('B', '2')])]).map(r -> r.key));
	}

	public function testADirectoryIsReadDocumentByDocumentAndMergedIntoOne(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('b.json'), file([arm('B', '2')]));
			File.saveContent(dir.file('a.json'), file([arm('A', '1')]));
			File.saveContent(dir.file('notes.txt'), 'not a registry document');
			Assert.same(['A', 'B'], ArmRegistry.read(dir.path).map(r -> r.key), 'in file-name order');
			final merged: { arms: Array<{ name: String }> } = Json.parse(ArmRegistry.merged(dir.path));
			Assert.same(['A', 'B'], merged.arms.map(a -> a.name), 'the merged text is one document');
			Assert.raises(() -> ArmRegistry.read(dir.file('missing')), ArmRegistryError);
		});
	}

	public function testAnUnreadableDocumentAndADuplicateAcrossDocumentsNameTheirDocuments(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('a.json'), '{"arms": [{"name": }]}');
			final broken: Null<String> = try {
				ArmRegistry.verify(dir.path);
				null;
			} catch (exception: ArmRegistryError) {
				exception.message;
			};
			Assert.isTrue((broken ?? '').startsWith('a.json: '), broken);
			File.saveContent(dir.file('a.json'), file([arm('A', '1')]));
			File.saveContent(dir.file('b.json'), file([arm('A', '2')]));
			final twice: Null<String> = try {
				ArmRegistry.verify(dir.path);
				null;
			} catch (exception: ArmRegistryError) {
				exception.message;
			};
			Assert.stringContains('a.json and b.json', twice ?? '');
		});
	}

	public function testAnArmKeptInAnotherPackagesDocumentIsRefused(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('a.json'), file([typed('A', 'a.X')]));
			File.saveContent(dir.file('b.json'), file([typed('B', 'a.Y')]));
			Assert.raises(() -> ArmRegistry.read(dir.path), ArmRegistryError);
			File.saveContent(dir.file('b.json'), file([typed('B', 'b.Y')]));
			Assert.same(['A', 'B'], ArmRegistry.read(dir.path).map(r -> r.key));
			File.saveContent(dir.file('anything.json'), file([typed('C', 'zz.Q')]));
			Assert.same(['C'], ArmRegistry.read(dir.file('anything.json')).map(r -> r.key), 'one document is not placed by its name');
		});
	}

	/** A registry holding `records`, laid out as the real one is. */
	private static function file(records: Array<String>): String {
		return '{\n\t"$$comment": ["the registry"],\n\t"arms": [\n\t\t${records.join(',\n\t\t')}\n\t]\n}\n';
	}

	private static function typed(name: String, type: String): String {
		return '{\n\t\t\t"name": "$name",\n\t\t\t"type": "$type"\n\t\t}';
	}

	private static function arm(name: String, note: String): String {
		return '{\n\t\t\t"name": "$name",\n\t\t\t"note": "$note"\n\t\t}';
	}

}
