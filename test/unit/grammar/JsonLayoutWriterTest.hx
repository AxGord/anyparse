package unit.grammar;

import anyparse.grammar.json.JsonLayoutWriter;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.runtime.Span;
#if (sys || nodejs)
import sys.io.File;
#end
import utest.Assert;
import utest.Test;

/**
 * `JsonLayoutWriter` — the JSON grammar's format-preserving writer. A document written with no edit
 * is its own bytes, whatever its layout; an edit's text is laid out the way its siblings are, and a
 * gap it touched is re-derived from the container's untouched ones. Every case asserts the whole
 * document.
 */
@:nullSafety(Strict)
class JsonLayoutWriterTest extends Test {

	/** The JSON files this repository holds, read relative to the repository root the suite runs from. */
	private static final REPO_FILES: Array<String> = [
		'.hxformat.json',
		'apqlint.json',
		'haxelib.json',
		'hxformat.json',
		'test/apqlint.json',
		'test/testkit/mutation-arms.json',
		'tools/data/xconfig-hxformat.json'
	];

	private final _plugin: JsonQueryPlugin = new JsonQueryPlugin();

	/** Every layout survives untouched: indentation, inline and one-per-line containers, `:` spacing, line ends, both ends. */
	@:killer('M-JSON-ROOT-UNTIGHTENED')
	@:pin('control')
	public function testWritingWithNoEditKeepsEveryByte(): Void {
		for (source in [
			'{\n\t"a": [\n\t\t1,\n\t\t2\n\t],\n\t"b": {}\n}\n',
			'{\n  "a" : [1, 2],\n  "b": {"c": null}\n}',
			'{"compact":[1,2,{"x":true}],"s":"\\u00e9\\"q"}',
			'\r\n  [\r\n    "x",\r\n    -1.5e3\r\n  ]  \r\n',
			'[1, 2,]',
			'  "lone string"  ',
			'[ ]'
		]) Assert.equals(source, JsonLayoutWriter.layout(source, []), 'round trip of ${haxe.Json.stringify(source)}');
	}

	/** The repository's own JSON — the arm registry, the lint and formatter configs — comes back byte for byte. */
	public function testTheRepositoryJsonFilesRoundTrip(): Void {
		#if (sys || nodejs)
		for (path in REPO_FILES) {
			final source: String = File.getContent(path);
			Assert.isTrue(JsonLayoutWriter.layout(source, []) == source, '$path round-trips');
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An entry appended to a one-per-line array takes a line of its own at its siblings' indentation. */
	public function testAnAppendedEntryTakesItsOwnLine(): Void {
		final source: String = '{\n\t"r": [\n\t\t"a"\n\t]\n}\n';
		Assert.equals('{\n\t"r": [\n\t\t"a",\n\t\t"b"\n\t]\n}\n', insertAfter(source, '"a"', ', "b"'));
	}

	/** An inline array stays inline, with the separator its entries already use. */
	@:killer('M-JSON-STYLE-ALWAYS-EXPANDED')
	@:pin('control')
	public function testAnInlineArrayStaysInline(): Void {
		Assert.equals('{"r": ["a", "b", "c"]}', insertAfter('{"r": ["a", "b"]}', '"b"', ',"c"'));
	}

	/** The first entry of an empty container follows the container's parent: one per line under an expanded parent. */
	@:killer('M-JSON-EMPTY-INLINE')
	@:killer('M-JSON-TOUCH-IGNORED')
	@:pin('control')
	public function testAnEmptyContainerFollowsItsParent(): Void {
		Assert.equals('{\n\t"r": [\n\t\t"x"\n\t]\n}', insertAfter('{\n\t"r": []\n}', '[', '"x"'));
		Assert.equals('{"r": ["x"]}', insertAfter('{"r": []}', '[', '"x"'));
	}

	/** A new object takes the shape of its nearest sibling object: inline beside an inline one, expanded beside an expanded one. */
	@:killer('M-JSON-NEW-MODEL-IGNORED')
	@:killer('M-JSON-NOTHING-NEW')
	@:pin('control')
	public function testANewObjectTakesItsSiblingsShape(): Void {
		Assert.equals('[\n\t{"a": 1},\n\t{"a": 2, "b": 3}\n]', insertAfter('[\n\t{"a": 1}\n]', '{"a": 1}', ', {"a":2,\n"b":3}'));
		Assert.equals('[\n\t{\n\t\t"a": 1\n\t},\n\t{\n\t\t"a": 2\n\t}\n]', insertAfter('[\n\t{\n\t\t"a": 1\n\t}\n]', '}', ', {"a": 2}'));
	}

	/** A new member takes its siblings' `:` spacing, and a value container under it follows the member's object. */
	@:killer('M-JSON-KEYSEP-DEFAULT')
	@:pin('control')
	public function testANewMemberTakesItsSiblingsKeySpacing(): Void {
		Assert.equals('{\n  "a" : 1,\n  "b" : 2\n}', insertAfter('{\n  "a" : 1\n}', '1', ', "b":2'));
	}

	/** A document indented by spaces gives a new line the same unit. */
	@:killer('M-JSON-INDENT-DEFAULT')
	@:pin('control')
	public function testTheIndentUnitIsTheDocuments(): Void {
		Assert.equals('{\n  "a": 1,\n  "r": [\n    "x"\n  ]\n}', insertAfter('{\n  "a": 1,\n  "r": []\n}', '[', '"x"'));
	}

	/** A document whose lines end in CRLF gets CRLF on every line an edit adds. */
	@:killer('M-JSON-LINE-END-LF')
	@:pin('control')
	public function testACrlfDocumentGetsCrlfLines(): Void {
		Assert.equals('[\r\n\t"a",\r\n\t"b"\r\n]\r\n', insertAfter('[\r\n\t"a"\r\n]\r\n', '"a"', ', "b"'));
	}

	/** A deletion closes the gap it leaves with the separator the untouched entries use. */
	@:killer('M-JSON-DIRTY-NEVER')
	@:pin('control')
	public function testADeletionClosesItsGap(): Void {
		final source: String = '["a", "b", "c"]';
		final from: Int = source.indexOf('"b"');
		Assert.equals('["a", "c"]', _plugin.layoutSplice(source, [{ span: new Span(from, from + 4), text: '' }]));
	}

	/** Two edits in one splice: the second's footprint is shifted by the first's text, so both land laid out. */
	@:killer('M-JSON-MARKS-UNSHIFTED')
	@:pin('control')
	public function testTheSecondEditsFootprintIsShifted(): Void {
		final source: String = '[\n\t"b",\n\t"d"\n]';
		final b: Int = source.indexOf('"b"');
		final d: Int = source.indexOf('"d"');
		final edits: Array<{ span: Span, text: String }> =
			[{ span: new Span(b, b), text: '"a", ' }, { span: new Span(d, d), text: '"c", ' }];
		Assert.equals('[\n\t"a",\n\t"b",\n\t"c",\n\t"d"\n]', _plugin.layoutSplice(source, edits));
	}

	/** The splice of one insert of `text` right after the first occurrence of `anchor`. */
	private function insertAfter(source: String, anchor: String, text: String): Null<String> {
		final at: Int = source.indexOf(anchor) + anchor.length;
		return _plugin.layoutSplice(source, [{ span: new Span(at, at), text: text }]);
	}

}
