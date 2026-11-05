package unit.query;

import anyparse.query.CanonicalEdit;
import anyparse.query.MoveDeclaration;
import anyparse.query.TypePathRegistries;

using StringTools;

/**
 * The JSON half of a registry that names members: `TypePathRegistries.memberRecords` reads a record as its `members` layout
 * declares, decoding each string and keeping where its code units sit in the document; `MoveDeclaration` carries the layout.
 */
@:nullSafety(Strict)
final class TypePathRegistriesMemberTest extends Test {

	private static final LAYOUT: MemberKeys = {
		records: 'arms',
		name: 'name',
		type: 'type',
		member: 'method',
		kind: 'kind',
		defaultKind: 'FnMember',
		find: 'find',
		replace: 'replace',
		opaque: ['force']
	};
	private static final DOC: String = '{"arms": [{"name": "A", "type": "p.Mod", "method": "walk", "force": "walk(1)"}, {'
		+ '"name": "B", "type": "p.Mod", "method": "other", "kind": "VarMember", "find": ["a\\n\\tb", "c"], "replace": "d\\u0041"}]}';

	public function testARecordIsReadThroughItsLayout(): Void {
		final records: Array<MemberRecord> = TypePathRegistries.memberRecords(LAYOUT, DOC);
		Assert.equals(2, records.length);
		Assert.equals('A', records[0].name);
		Assert.equals('p.Mod', records[0].type);
		Assert.equals('FnMember', records[0].kind);
		Assert.equals('walk', records[0].member?.value);
		Assert.equals('force', records[0].opaque[0].key);
		Assert.equals('walk(1)', records[0].opaque[0].slot.value);
		Assert.equals('VarMember', records[1].kind);
	}

	public function testAFindIsOneStringOrAListAndDecoded(): Void {
		final record: MemberRecord = TypePathRegistries.memberRecords(LAYOUT, DOC)[1];
		Assert.same(['a\n\tb', 'c'], [for (slot in record.finds) slot.value]);
		Assert.same(['dA'], [for (slot in record.replaces) slot.value]);
		Assert.equals(0, TypePathRegistries.memberRecords(LAYOUT, DOC)[0].finds.length);
	}

	public function testASpliceLandsOnTheRawBytesOfTheDecodedRange(): Void {
		final record: MemberRecord = TypePathRegistries.memberRecords(LAYOUT, DOC)[1];
		final edit: RegistryEdit = TypePathRegistries.spliceOf(record.finds[0], 3, 4, 'X');
		Assert.equals('"a\\n\\tX", "c"', CanonicalEdit.applyEdits(DOC, [edit]).substring(DOC.indexOf('"a\\n'), DOC.indexOf('"c"') + 3));
		final escaped: RegistryEdit = TypePathRegistries.spliceOf(record.replaces[0], 1, 2, 'Y');
		Assert.isTrue(CanonicalEdit.applyEdits(DOC, [escaped]).contains('"replace": "dY"'));
	}

	public function testAnEscapeJsonDoesNotDefineIsTheParsersRefusal(): Void {
		Assert.raises(() -> TypePathRegistries.memberRecords(LAYOUT, '{"arms": [{"name": "A", "find": "a\\qb"}]}'));
	}

	public function testTheDeclarationReadsTheLayoutAndRefusesAnUnknownOrMissingKey(): Void {
		final full: String = '"records": "arms", "name": "name", "type": "type", "member": "method", "kind": "kind", '
			+ '"defaultKind": "FnMember", "find": "find", "replace": "replace", "opaque": ["force"]';
		switch MoveDeclaration.read('{"move": {"registries": [{"file": "reg", "keys": ["arms.type"], "members": {$full}}]}}', '/p') {
			case Right(found):
				final registry: Null<TypePathRegistry> = found?.registries[0];
				Assert.equals('method', registry?.members?.member);
				Assert.equals('FnMember', registry?.members?.defaultKind);
				Assert.same(['force'], registry?.members?.opaque);
			case Left(message):
				Assert.fail(message);
		}
		switch MoveDeclaration.read('{"move": {"registries": [{"file": "reg", "keys": [], "members": {"record": "arms"}}]}}', '/p') {
			case Left(message):
				Assert.isTrue(message.contains('record'), message);
			case Right(_):
				Assert.fail('a misspelt members key must not be dropped in silence');
		}
		switch MoveDeclaration.read('{"move": {"registries": [{"file": "reg", "keys": [], "members": {"records": "arms"}}]}}', '/p') {
			case Left(message):
				Assert.isTrue(message.contains('name'), message);
			case Right(_):
				Assert.fail('a layout with a key missing must refuse');
		}
	}

}
