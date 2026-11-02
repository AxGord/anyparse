package unit.query;

import anyparse.query.ModuleMove;
import anyparse.query.MoveDeclaration;
import anyparse.query.PackageDocuments;
import anyparse.query.TypePathRegistries.TypePathRegistry;
import testkit.MutationArms;
import unit.cli.CliFixture;

using Lambda;
using StringTools;

/**
 * `PackageDocuments`: the document of a type is named after its package, the directory reader refuses a record kept
 * elsewhere, and a module relocation carries the record to the document of its new package.
 */
@:nullSafety(Strict)
final class PackageDocumentsTest extends Test {

	private static final KEYS: Array<String> = ['arms.type'];

	public function testADocumentIsNamedAfterThePackageOfItsType(): Void {
		Assert.equals('anyparse.check.scan.json', PackageDocuments.documentFor('anyparse.check.scan.RegionTerminator'));
		Assert.equals('_root.json', PackageDocuments.documentFor('RunTests'));
		Assert.equals('a.json', PackageDocuments.documentFor('a.Mod.Sub'));
		Assert.isNull(PackageDocuments.misplacement('a.json', 'a.X'));
		Assert.notNull(PackageDocuments.misplacement('b.json', 'a.X'));
	}

	public function testARecordInItsOwnDocumentStays(): Void {
		final carried: CarriedDocuments = PackageDocuments.carry([{ file: 'reg/a.json', source: doc('a', ['a.X', 'a.Y']) }], KEYS);
		Assert.same([], carried.written);
		Assert.same([], carried.emptied);
	}

	public function testARecordMovesToTheDocumentOfItsPackageAndAnEmptiedDocumentGoes(): Void {
		final carried: CarriedDocuments = PackageDocuments.carry([
			{ file: 'reg/a.json', source: doc('a', ['b.X']) },
			{ file: 'reg/b.json', source: doc('b', ['b.Y']) }
		], KEYS);
		Assert.same(['reg/a.json'], carried.emptied);
		Assert.equals(1, carried.written.length);
		Assert.equals(doc('b', ['b.Y', 'b.X']), carried.written.find(c -> c.file == 'reg/b.json')?.source);
	}

	public function testAMissingDocumentIsMadeInTheShapeOfTheOneThatSentTheRecord(): Void {
		final carried: CarriedDocuments = PackageDocuments.carry([{ file: 'reg/a.json', source: doc('a', ['a.X', 'c.d.Z']) }], KEYS);
		Assert.equals(doc('a', ['a.X']), carried.written.find(c -> c.file == 'reg/a.json')?.source);
		Assert.equals(doc('c.d', ['c.d.Z']), carried.written.find(c -> c.file == 'reg/c.d.json')?.source);
		final root: CarriedDocuments = PackageDocuments.carry([{ file: 'reg/a.json', source: doc('a', ['Top']) }], KEYS);
		Assert.equals(doc('(root)', ['Top']), root.written.find(c -> c.file == 'reg/_root.json')?.source);
	}

	public function testAModuleRelocationCarriesItsRecordsToTheNewPackagesDocument(): Void {
		switch ModuleMove.run({
			moves: [{ from: 'src/a/X.hx', to: 'src/b/X.hx' }],
			scopeFiles: [{ file: 'src/a/X.hx', source: 'package a;\n\nclass X {}\n' }],
			libraryFiles: [],
			textFiles: [{ file: 'reg/a.json', source: doc('a', ['a.X', 'a.Y']) }],
			registries: [{ file: 'reg/a.json', keys: KEYS, byPackage: true }],
			sortedLists: [],
			mirrors: []
		}, new HaxeQueryPlugin()) {
			case Moved(out):
				Assert.equals(doc('b', ['b.X']), out.changes.find(c -> c.file == 'reg/b.json')?.newSource);
				Assert.equals(doc('a', ['a.Y']), out.changes.find(c -> c.file == 'reg/a.json')?.newSource);
				Assert.isFalse(out.removed.contains('reg/a.json'));
			case Refused(reasons):
				Assert.fail(reasons.join(' | '));
		}
	}

	public function testTheDirectoryReaderRefusesARecordKeptInAnotherPackagesDocument(): Void {
		final dir: String = CliFixture.writeTree('armplace', [
			{ name: 'a.json', source: doc('a', ['a.X']) },
			{ name: 'b.json', source: doc('b', ['a.Y']) }
		]);
		final table: ArmTable = MutationArms.parseDirectory(dir);
		CliFixture.removeDir(dir);
		Assert.equals(1, table.errors.length, table.errors.join('; '));
		Assert.isTrue(table.errors[0].indexOf('b.json') == 0 && table.errors[0].indexOf('belongs in a.json') > 0, table.errors[0]);
	}

	public function testARegistryNotDeclaredByPackageIsNeverCarriedCreatedOrRemoved(): Void {
		switch ModuleMove.run(request([{ file: 'reg/a.json', keys: KEYS }], doc('a', ['a.X', 'a.Y'])), new HaxeQueryPlugin()) {
			case Moved(out):
				Assert.equals(doc('a', ['b.X', 'a.Y']), out.changes.find(c -> c.file == 'reg/a.json')?.newSource);
				Assert.isNull(out.changes.find(c -> c.file == 'reg/b.json'));
				Assert.same(['src/a/X.hx'], out.removed);
			case Refused(reasons):
				Assert.fail(reasons.join(' | '));
		}
	}

	public function testADocumentThatCannotBeCutRefusesTheMoveInsteadOfThrowing(): Void {
		switch ModuleMove.run(request([{ file: 'reg/a.json', keys: KEYS, byPackage: true }], '{}'), new HaxeQueryPlugin()) {
			case Moved(_):
				Assert.fail('a byPackage document without its array must not be skipped in silence');
			case Refused(reasons):
				Assert.isTrue(reasons.join(' | ').contains('byPackage'), reasons.join(' | '));
		}
	}

	public function testTheDeclarationKeepsByPackageAndRefusesItWithoutAnArrayFieldKey(): Void {
		switch MoveDeclaration.read(
			'{"move": {"registries": [{"file": "reg", "keys": ["arms.type"], "byPackage": true}, {"file": "other", "keys": ["arms.type"]}]}}',
			'/p'
		) {
			case Right(found):
				Assert.isTrue(found?.registries[0].byPackage == true);
				Assert.isFalse(found?.registries[1].byPackage == true);
			case Left(message):
				Assert.fail(message);
		}
		switch MoveDeclaration.read('{"move": {"registries": [{"file": "reg", "keys": ["type"], "byPackage": true}]}}', '/p') {
			case Left(message):
				Assert.isTrue(message.contains('byPackage'), message);
			case Right(_):
				Assert.fail('a byPackage registry with no <array>.<field> key would carry nothing');
		}
	}

	/** A registry document of package `pkg` holding one arm per type path in `types`, in the layout the registry is written in. */
	private static function doc(pkg: String, types: Array<String>): String {
		final rest: String = '\t\t\t"method": "m",\n\t\t\t"force": "1",\n\t\t\t"note": "n"\n\t\t}';
		final records: Array<String> = [
			for (type in types) '\t\t{\n\t\t\t"name": "M-$type",\n\t\t\t"type": "$type",\n$rest'
		];
		final body: String = records.join(',\n');
		return '{\n\t"$$comment": [\n\t\t"Mutation arms cutting the types of package $pkg'
			+ '. Format and rules: docs/testing.md, Declared arms."\n\t],\n\t"arms": [\n$body\n\t]\n}\n';
	}

	/** The move of `a.X` to package `b`, with the registry document `reg/a.json` holding `registryText`. */
	private static function request(registries: Array<TypePathRegistry>, registryText: String): ModuleMoveRequest {
		return {
			moves: [{ from: 'src/a/X.hx', to: 'src/b/X.hx' }],
			scopeFiles: [{ file: 'src/a/X.hx', source: 'package a;\n\nclass X {}\n' }],
			libraryFiles: [],
			textFiles: [{ file: 'reg/a.json', source: registryText }],
			registries: registries,
			sortedLists: [],
			mirrors: []
		};
	}

}
