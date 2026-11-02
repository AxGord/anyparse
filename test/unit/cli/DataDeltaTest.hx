package unit.cli;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.query.cli.DataDelta;
import anyparse.query.cli.DeclarationDelta;

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

	private static function rows(delta: FileDelta): Array<String> {
		return [
			for (change in delta.values) '${change.status} ${change.path} ${change.before} ${change.after}'
		];
	}

	private static function compare(base: String, now: String): FileDelta {
		return DataDelta.compare(new JsonQueryPlugin(), base, now);
	}

}
