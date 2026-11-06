package unit.grammar.writeshape;

import anyparse.grammar.json.JsonFormat;
import utest.Assert;
import utest.Test;

/**
 * What a by-name schema's generated writer spells beyond a field's value: `@:writeNull` keeps a held null's key, `@:bare`
 * writes a struct as its one field's value, a `Float` keeps the target's spelling, and `JsonFormat.expandedWriteOptions`
 * lays a document out as a native printer indenting by two spaces does — the Doc writer and the compact one alike.
 */
class WriteShapeTest extends Test {

	private static final HELD: WriteShapeRecord = {
		name: 'a',
		note: null,
		skip: null,
		ratio: 1,
		whole: null,
		items: [{ n: 2, tags: ['x', 'y'] }],
		empty: [],
		inner: null
	};
	private static final FULL: WriteShapeRecord = {
		name: 'b',
		note: 'n',
		skip: 3,
		ratio: 0.5,
		whole: 2,
		items: [],
		empty: [],
		inner: { n: 1, tags: [] }
	};

	/** A held null of a `@:writeNull` field is written under its key; one of a plain optional field is left out. */
	@:pin('control') @:killer('M-WRITE-NULL-IGNORED')
	public function testAWriteNullFieldKeepsItsKey(): Void {
		Assert.equals(
			'{"name":"a","note":null,"ratio":1,"whole":null,"items":[{"n":2,"tags":["x","y"]}],"empty":[],"inner":null}', compact(HELD)
		);
		Assert.equals(compact(HELD), direct(HELD));
		final pretty: String = WriteShapeRecordWriter.write(HELD, JsonFormat.instance.defaultWriteOptions);
		Assert.stringContains('"note":null', pretty);
		Assert.isFalse(pretty.indexOf('"skip"') >= 0, pretty);
	}

	/** The expanded layout: two spaces of indent, a space after each colon, every non-empty container broken. */
	@:pin('control') @:killer('M-KEY-VALUE-SPACE-IGNORED')
	public function testTheExpandedLayout(): Void {
		Assert.equals(
			'{\n  "name": "a",\n  "note": null,\n  "ratio": 1,\n  "whole": null,\n  "items": [\n    {\n      "n": 2,\n'
			+ '      "tags": [\n        "x",\n        "y"\n      ]\n    }\n  ],\n  "empty": [],\n  "inner": null\n}',
			WriteShapeRecordWriter.write(HELD, JsonFormat.instance.expandedWriteOptions)
		);
	}

	/** A `@:bare` struct is its one field's value alone, in every layout. */
	@:pin('control') @:killer('M-BARE-IGNORED')
	public function testABareStructIsItsFieldsValue(): Void {
		final list: WriteShapeList = { items: [{ n: 1, tags: [] }] };
		Assert.equals('[{"n":1,"tags":[]}]', WriteShapeListWriter.write(list, JsonFormat.instance.compactWriteOptions));
		Assert.equals('[{"n":1,"tags":[]}]', WriteShapeListDirectWriter.write(list, JsonFormat.instance.compactWriteOptions));
		Assert.equals(
			'[\n  {\n    "n": 1,\n    "tags": []\n  }\n]', WriteShapeListWriter.write(list, JsonFormat.instance.expandedWriteOptions)
		);
		Assert.equals('[]', WriteShapeListWriter.write({ items: [] }, JsonFormat.instance.expandedWriteOptions));
	}

	/** A `Float` is spelled as the target prints it — a whole number gains no `.0` — by the Doc writer as by the compact one. */
	@:pin('control') @:killer('M-FLOAT-POINT-FORCED')
	public function testAFloatKeepsTheTargetSpelling(): Void {
		Assert.equals(
			'{"name":"b","note":"n","skip":3,"ratio":0.5,"whole":2,"items":[],"empty":[],"inner":{"n":1,"tags":[]}}', compact(FULL)
		);
		Assert.equals(compact(FULL), direct(FULL));
		final pretty: String = WriteShapeRecordWriter.write(FULL, JsonFormat.instance.expandedWriteOptions);
		Assert.stringContains('"ratio": 0.5,\n  "whole": 2,\n', pretty);
		final huge: WriteShapeRecord = {
			name: 'c',
			ratio: 1e21,
			items: [],
			empty: []
		};
		Assert.stringContains(
			'"ratio": ${compactRatio(huge)},', WriteShapeRecordWriter.write(huge, JsonFormat.instance.expandedWriteOptions)
		);
	}

	private static function compact(record: WriteShapeRecord): String {
		return WriteShapeRecordWriter.write(record, JsonFormat.instance.compactWriteOptions);
	}

	private static function direct(record: WriteShapeRecord): String {
		return WriteShapeRecordDirectWriter.write(record, JsonFormat.instance.compactWriteOptions);
	}

	/** The spelling the compact writer gives `record`'s ratio. */
	private static function compactRatio(record: WriteShapeRecord): String {
		final text: String = compact(record);
		final from: Int = text.indexOf('"ratio":') + '"ratio":'.length;
		return text.substring(from, text.indexOf(',', from));
	}

}
