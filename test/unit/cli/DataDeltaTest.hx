package unit.cli;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.query.cli.DataDelta;
import anyparse.query.cli.DeclarationDelta;
import anyparse.query.merge.KeyedMerge.MergeTree;
import anyparse.query.merge.RecordTree;

using StringTools;

/**
 * `DataDelta.compare`: a data document's change named by key path — a record inserted in the middle of an array
 * shifts no other one, a digest is shortened, and a change of text alone is layout.
 */
@:nullSafety(Strict)
class DataDeltaTest extends Test {

	private static final DIGEST: String = 'af85e5ae6bf88a32af85e5ae6bf88a32af85e5ae';

	public function testOnlyJsonReadsAsData(): Void {
		Assert.isTrue(DataDelta.reads(new JsonQueryPlugin().refShape()));
		Assert.isFalse(DataDelta.reads(new HaxeQueryPlugin().refShape()));
	}

	public function testAKeyIsAddedRemovedAndChangedByItsPath(): Void {
		final delta: FileDelta = compare('{"a": {"b": 1, "c": "x"}, "d": [1, 2]}', '{"a": {"b": 2, "e": true}, "d": [1, 2]}');
		Assert.equals(ChangeClass.Values, delta.change);
		Assert.same(['~ a.b 1 2', '- a.c "x" ', '+ a.e  true'], rows(delta));
	}

	public function testARecordInsertedInTheMiddleShiftsNoOther(): Void {
		final base: String = '{"arms": [{"name": "A", "n": 1}, {"name": "B", "n": 2}, {"name": "C", "n": 3}]}';
		final now: String = '{"arms": [{"name": "A", "n": 1}, {"name": "X", "n": 9}, {"name": "B", "n": 2}, {"name": "C", "n": 4}]}';
		Assert.same(['+ arms.1  {"name":"X","n":9}', '~ arms.3.n 3 4'], rows(compare(base, now)));
	}

	public function testARecordRemovedIsNamedByItsBaseIndex(): Void {
		final delta: FileDelta = compare('[{"id": 1}, {"id": 2}, {"id": 3}]', '[{"id": 1}, {"id": 3}]');
		Assert.same(['- 1 {"id":2} '], rows(delta));
	}

	public function testScalarsOfAnArrayPairInOrder(): Void {
		Assert.same(['~ 1 "b" "c"'], rows(compare('["a", "b"]', '["a", "c"]')));
	}

	public function testADigestIsShortenedAndALongValueCut(): Void {
		final delta: FileDelta = compare('{"d": "$DIGEST", "v": "x"}', '{"d": "ffffffffffffffffffffffffffffffffffffffff", "v": "y"}');
		Assert.same(['~ d "af85e5ae6bf8…" "ffffffffffff…"', '~ v "x" "y"'], rows(delta));
		final long: String = ''.lpad('xy', 120);
		final cut: FileDelta = compare('{"k": 1}', '{"k": "$long"}');
		Assert.isTrue(cut.values[0].after.length < long.length, cut.values[0].after);
		Assert.isTrue(cut.values[0].after.endsWith('…'), cut.values[0].after);
	}

	public function testTheSameValuesInAnotherLayoutAreLayout(): Void {
		final delta: FileDelta = compare('{"a": 1, "b": [1, 2]}', '{\n\t"a": 1,\n\t"b": [1,\n 2]\n}\n');
		Assert.equals(ChangeClass.Layout, delta.change);
		Assert.same([], delta.values);
	}

	public function testKeysInAnotherOrderAreNamed(): Void {
		final delta: FileDelta = compare('{"a": 1, "b": 2}', '{"b": 2, "a": 1}');
		Assert.equals(ChangeClass.Values, delta.change);
		Assert.same(['~ (key order)  '], rows(delta));
	}

	public function testAVersionThatDoesNotParseIsText(): Void {
		final delta: FileDelta = compare('{"a": 1}', '{"a": ');
		Assert.equals(ChangeClass.Text, delta.change);
		Assert.same([], delta.values);
	}

	public function testTheSameTextIsUnchanged(): Void {
		Assert.equals(ChangeClass.Unchanged, compare('{"a": 1}', '{"a": 1}').change);
	}

	/** An array whose elements only moved is one row naming that array; keys in another order stay `(key order)`. */
	public function testReorderedElementsNameTheirArray(): Void {
		Assert.same(['~ list (order)  '], rows(compare('{"list":[1,2,3],"k":"x"}', '{"list":[3,1,2],"k":"x"}')));
		Assert.same(['~ (key order)  '], rows(compare('{"a":1,"b":2}', '{"b":2,"a":1}')));
	}

	/** A container left over beside a scalar leaves the scalar to pair with the scalar that replaced it. */
	public function testALeftoverContainerDoesNotBlockScalarPairing(): Void {
		Assert.same(['~ x.0 1 2', '- x.0 {"o":1} '], rows(compare('{"x":[{"o":1},1]}', '{"x":[2]}')));
	}

	/** A repeated key whose earlier entry was dropped is named, not read as a key order. */
	public function testADroppedDuplicateKeyIsNamed(): Void {
		Assert.same(['~ a (duplicate key)  '], rows(compare('{"a":1,"a":2}', '{"a":2}')));
	}

	/** The pairing `RecordTree` gives the records of an arms document is the pairing the delta reports changes under. */
	public function testRecordsPairAsTheMergeDriverPairsThem(): Void {
		final base: String = '{"arms": [{"name": "A", "n": 1}, {"name": "B", "n": 2}, {"name": "C", "n": 3}]}';
		final now: String = '{"arms": [{"name": "C", "n": 30}, {"name": "A", "n": 10}, {"name": "X", "n": 0}, {"name": "B", "n": 2}]}';
		final keysBase: Array<String> = keysOf(base);
		final baseValues: Array<Int> = [1, 2, 3];
		final nowValues: Array<Int> = [30, 10, 0, 2];
		final expected: Array<String> = ['~ arms (order)  '];
		for (i => key in keysOf(now)) {
			final j: Int = keysBase.indexOf(key);
			if (j < 0)
				expected.push('+ arms.$i  {"name":"X","n":0}')
			else if (baseValues[j] != nowValues[i])
				expected.push('~ arms.$i.n ${baseValues[j]} ${nowValues[i]}');
		}
		Assert.same(expected, rows(compare(base, now)));
		Assert.same(['arms[name="C"]', 'arms[name="A"]', 'arms[name="X"]', 'arms[name="B"]'], keysOf(now));
	}

	/** A record keyed by a container leads like any other: `a` names it though its value is a list. */
	public function testARecordLedByAContainerPairsByIt(): Void {
		final base: String = '{"r": [{"a": [1], "n": 1}, {"a": [2], "n": 2}]}';
		final now: String = '{"r": [{"a": [1], "n": 10}, {"a": [2], "n": 2}]}';
		Assert.same(['~ r.0.n 1 10'], rows(compare(base, now)));
	}

	/** An element that leads otherwise, added in one version, re-keys none of its siblings. */
	public function testAnOddElementAddedLeavesTheRecordsPaired(): Void {
		final base: String = '{"r": [{"name": "A", "n": 1}, {"name": "B", "n": 2}]}';
		final record: String = '{"name": "A", "n": 10}, {"name": "B", "n": 2}';
		Assert.same(['~ r.0.n 1 10', '+ r.2  {"id":"z"}'], rows(compare(base, '{"r": [$record, {"id": "z"}]}')));
		Assert.same(['~ r.0.n 1 10', '+ r.2  {}'], rows(compare(base, '{"r": [$record, {}]}')));
		Assert.same(['~ r.0.n 1 10', '+ r.2  7'], rows(compare(base, '{"r": [$record, 7]}')));
	}

	public function testRecordsThatLeadWithDifferentNamesPairEachByItsOwn(): Void {
		final base: String = '{"r": [{"id": "a", "n": 1}, {"name": "b", "n": 2}]}';
		final now: String = '{"r": [{"id": "a", "n": 10}, {"name": "b", "n": 20}]}';
		Assert.same(['~ r.0.n 1 10', '~ r.1.n 2 20'], rows(compare(base, now)));
	}

	/** Elements repeating one key pair in order among those no equal element took. */
	public function testRepeatedKeysPairAmongTheUnpairedOnes(): Void {
		final base: String = '{"r": [{"k": "a", "n": 1}, {"k": "a", "n": 2}]}';
		final now: String = '{"r": [{"k": "a", "n": 2}, {"k": "a", "n": 9}]}';
		Assert.same(['~ r (order)  ', '~ r.1.n 1 9'], rows(compare(base, now)));
	}

	/** The same value under another lead name, or a scalar, is no counterpart of a record. */
	public function testAnotherLeadNameOrAScalarIsNoCounterpart(): Void {
		final base: String = '{"r": [{"id": 1, "v": 2}, {"id": 2, "v": 3}]}';
		Assert.same([
			'+ r.0  {"a":1,"w":"x"}',
			'+ r.1  {"a":2,"w":"y"}',
			'- r.0 {"id":1,"v":2} ',
			'- r.1 {"id":2,"v":3} '
		], rows(compare(base, '{"r": [{"a": 1, "w": "x"}, {"a": 2, "w": "y"}]}')));
		Assert.same(['+ r.0  1', '+ r.1  2', '- r.0 {"id":1,"v":2} ', '- r.1 {"id":2,"v":3} '], rows(compare(base, '{"r": [1, 2]}')));
	}

	public function testADocumentAddedWholeNamesItsKeysAndItsRecordCount(): Void {
		final added: FileDelta = compare('', '{"$$comment": ["x"], "arms": [{"name": "A"}, {"name": "B"}], "k": 1}');
		Assert.equals(ChangeClass.Values, added.change);
		Assert.same(['+ .  {$$comment[1], arms[2], k}'], rows(added));
		Assert.same(['- . [3 element(s)] '], rows(compare('[1, 2, 3]', '')));
		Assert.same([], rows(compare('', 'not json {')));
		Assert.same(['+ .  {a, b[2]}'], rows(compare('', '{"a": 1, "a": 2, "b": {"c": 1, "d": 2}}')));
	}

	/** A tuple led by a string is no record: its first element names no member, so a changed tuple is a removal and an addition. */
	public function testAStringLedTupleIsKeyedByItsText(): Void {
		Assert.same(['+ r.1  ["b",3]', '- r.1 ["b",2] '], rows(compare('{"r": [["a", 1], ["b", 2]]}', '{"r": [["a", 1], ["b", 3]]}')));
	}

	private static function rows(delta: FileDelta): Array<String> {
		return [
			for (change in delta.values) '${change.status} ${change.path} ${change.before} ${change.after}'
		];
	}

	private static function compare(base: String, now: String): FileDelta {
		return DataDelta.compare(new JsonQueryPlugin(), base, now);
	}

	private static function keysOf(source: String): Array<String> {
		final tree: MergeTree = RecordTree.of(source, new JsonQueryPlugin().parseFile(source));
		final arms: Null<MergeTree> = tree.children[0].tree;
		return arms == null ? [] : [for (child in arms.children) child.key];
	}

}
