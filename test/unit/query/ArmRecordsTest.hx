package unit.query;

import anyparse.query.ArmRecords;
import anyparse.query.PackageDocumentCarry.RegistryDocument;
import haxe.ds.Either;

/**
 * `ArmRecords`: a record joins the document of its type's package in the registry's own layout, the document is made when
 * the package has none, and a record that cannot be found again, or a name already taken, is refused.
 */
@:nullSafety(Strict)
final class ArmRecordsTest extends Test {

	private static final HEAD: String = '{\n\t"$$comment": [\n\t\t"c"\n\t],\n\t"arms": [\n';
	private static final TAIL: String = '\n\t]\n}\n';
	private static final FIRST: String =
		'\t\t{\n\t\t\t"name": "M-A",\n\t\t\t"type": "a.X",\n\t\t\t"method": "m",\n\t\t\t"force": "1",\n\t\t\t"note": "n"\n\t\t}';
	private static final SECOND_JSON: String = '{"name":"M-B","type":"a.Y","method":"go","force":"2","note":"n"}';
	private static final SECOND: String =
		'{\n\t\t\t"name": "M-B",\n\t\t\t"type": "a.Y",\n\t\t\t"method": "go",\n\t\t\t"force": "2",\n\t\t\t"note": "n"\n\t\t}';

	@:pin('control')
	@:killer('M-ARMRECORDS-APPEND-LOST')
	@:killer('M-ARMRECORDS-DOCUMENT-OF-TYPE')
	public function testARecordJoinsTheDocumentOfItsPackageAndKeepsTheOthersByteForByte(): Void {
		final written: Array<RegistryDocument> = added([{ file: 'reg/a.json', source: HEAD + FIRST + TAIL }], [SECOND_JSON]);
		Assert.equals(1, written.length);
		Assert.equals('reg/a.json', written[0].file);
		Assert.equals('${HEAD + FIRST},\n\t\t$SECOND$TAIL', written[0].source);
	}

	@:pin('control')
	@:killer('M-ARMRECORDS-FRESH-DOCUMENT')
	@:killer('M-ARMRECORDS-DOCUMENT-OF-TYPE')
	public function testAPackageWithNoDocumentGetsOneInTheShapeOfTheOthers(): Void {
		final written: Array<RegistryDocument> = added([{ file: 'reg/a.json', source: HEAD + FIRST + TAIL }], [
			'{"name":"M-C","type":"b.c.Z","method":"m","force":"1","note":"n"}',
			'{"name":"M-D","type":"Top","method":"m","force":"1","note":"n"}'
		]);
		Assert.equals(2, written.length);
		Assert.equals('reg/b.c.json', written[0].file);
		Assert.isTrue(written[0].source.indexOf('"Mutation arms cutting the types of package b.c. Format and rules') > 0);
		Assert.equals('reg/_root.json', written[1].file);
		Assert.isTrue(written[1].source.indexOf('package (root).') > 0);
		Assert.isTrue(written[1].source.indexOf('"name": "M-D"') > 0);
	}

	@:pin('control')
	@:killer('M-ARMRECORDS-APPEND-LOST')
	public function testTheFirstRecordOfAnEmptyArrayTakesNoSeparator(): Void {
		final written: Array<RegistryDocument> = added([{ file: 'reg/a.json', source: '$HEAD\t]\n}\n' }], [SECOND_JSON]);
		Assert.equals('$HEAD\t\t$SECOND$TAIL', written[0].source);
	}

	@:pin('control')
	@:killer('M-ARMRECORDS-DUPLICATE-NAME')
	public function testANameAlreadyInTheRegistryOrTheBatchIsRefused(): Void {
		final existing: Array<RegistryDocument> = [{ file: 'reg/a.json', source: HEAD + FIRST + TAIL }];
		final taken: String = '{"name":"M-A","type":"a.Y","method":"m","force":"1","note":"n"}';
		Assert.stringContains('already in the registry', refusal(existing, [taken]));
		Assert.stringContains('already in the registry', refusal([], [SECOND_JSON, SECOND_JSON]));
	}

	@:pin('control')
	@:killer('M-ARMRECORDS-ONE-CUT')
	@:killer('M-ARMRECORDS-UNKNOWN-KEY')
	public function testARecordTheReaderCannotUseIsRefusedByWhatIsWrongWithIt(): Void {
		Assert.stringContains('not JSON', refusal([], ['{"name":']));
		Assert.stringContains('not a JSON object', refusal([], ['[]']));
		Assert.stringContains(
			'unknown key "frob"', refusal([], ['{"name":"M","type":"a.X","method":"m","force":"1","note":"n","frob":"1"}'])
		);
		Assert.stringContains('no non-empty "note"', refusal([], ['{"name":"M","type":"a.X","method":"m","force":"1"}']));
		Assert.stringContains('neither "force" nor "find"', refusal([], ['{"name":"M","type":"a.X","method":"m","note":"n"}']));
		Assert.stringContains('both "force" and "find"', refusal([], [
			'{"name":"M","type":"a.X","method":"m","force":"1","find":"x","replace":"y","note":"n"}'
		]));
		Assert.stringContains('"find" without "replace"', refusal([], ['{"name":"M","type":"a.X","method":"m","find":"x","note":"n"}']));
	}

	@:pin('control')
	@:killer('M-ARMRECORDS-APPEND-LOST')
	public function testARegistryIndentedWithSpacesGetsARecordIndentedWithSpaces(): Void {
		final spaced: String = '{\n  "arms": [\n    {\n      "name": "M-A",\n      "type": "a.X",\n      "method": "m",\n'
			+ '      "force": "1",\n      "note": "n"\n    }\n  ]\n}\n';
		final written: Array<RegistryDocument> = added([{ file: 'reg/a.json', source: spaced }], [SECOND_JSON]);
		Assert.equals(-1, written[0].source.indexOf('\t'));
		Assert.isTrue(written[0].source.indexOf('\n      "name": "M-B",\n') > 0);
	}

	@:pin('control')
	@:killer('M-ARMRECORDS-APPEND-LOST')
	public function testAListOfFragmentsIsKeptAsAListOfStrings(): Void {
		final written: Array<RegistryDocument> = added([{ file: 'reg/a.json', source: HEAD + FIRST + TAIL }], [
			'{"name":"M-B","type":"a.Y","method":"go","find":["x","y"],"replace":["1",""],"note":"n"}'
		]);
		Assert.isTrue(~/"find": \[\s*"x",\s*"y"\s*\]/.match(written[0].source));
		Assert.isTrue(~/"replace": \[\s*"1",\s*""\s*\]/.match(written[0].source));
	}

	@:pin('control')
	@:killer('M-ARMRECORDS-VALUE-KIND')
	@:killer('M-ARMRECORDS-NAME-KIND')
	public function testAValueOfTheWrongKindIsRefusedByTheKeyThatHoldsIt(): Void {
		final head: String = '{"name":"M-B","type":"a.Y","method":"go",';
		Assert.stringContains('arm M-B: "kind" is not a string', refusal([], ['$head"kind":7,"force":"1","note":"n"}']));
		Assert.stringContains('arm M-B: "force" is not a string', refusal([], ['$head"force":["1"],"note":"n"}']));
		Assert.stringContains(
			'arm M-B: "find" is not a string or a list of strings', refusal([], ['$head"find":7,"replace":"1","note":"n"}'])
		);
		Assert.stringContains(
			'arm M-B: "find" is not a string or a list of strings', refusal([], ['$head"find":["x",{"a":1}],"replace":"1","note":"n"}'])
		);
		Assert.stringContains('"name" is not a string', refusal([], ['{"name":7,"type":"a.Y","method":"go","force":"1","note":"n"}']));
	}

	private static function added(existing: Array<RegistryDocument>, records: Array<String>): Array<RegistryDocument> {
		return switch ArmRecords.add('reg', existing, records) {
			case Right(documents): documents;
			case Left(message):
				Assert.fail(message);
				[];
		}
	}

	private static function refusal(existing: Array<RegistryDocument>, records: Array<String>): String {
		return switch ArmRecords.add('reg', existing, records) {
			case Left(message): message;
			case Right(_): 'accepted';
		}
	}

}
