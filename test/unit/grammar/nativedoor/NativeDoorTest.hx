package unit.grammar.nativedoor;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JsonFormat;
import anyparse.runtime.ParseError;
import anyparse.runtime.Parser;
import anyparse.runtime.StringInput;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * What a by-name schema's generated parser and writer do through the format's native door (`NativeDocLowering`): the shape
 * check refuses what the byte-level parser refuses, and hands every refusal to it, so `parse` answers as before; the compact
 * writer spells what the engine's writer spells for the record, and the pretty one is untouched.
 */
class NativeDoorTest extends Test {

	private static inline final GOOD: String = '{"name":"a","size":1,"ratio":1.5,"on":true,"function":"f","points":[1,2],'
		+ '"rows":[["x"],[]],"holes":["h",null],"inner":{"n":1},"kids":[{"n":2,"label":"\\u00e9\\n"}],"junk":{"a":[1]}}';

	/** A record the door reads is the record the byte-level parser reads: written back, the two spell one document. */
	public function testTheDoorReadsWhatTheBytesRead(): Void {
		Assert.notNull(DoorRecordParser.parseNative(GOOD));
		Assert.equals(compact(bytes(GOOD)), compact(DoorRecordParser.parse(GOOD)));
	}

	/** A value of the wrong kind fails the shape check, and `parse` refuses it in the byte-level parser's words. */
	@:pin('control') @:killer('M-NATIVE-STRING-UNCHECKED')
	public function testAWrongKindRefuses(): Void {
		final text: String = GOOD.replace('"name":"a"', '"name":1');
		Assert.isNull(DoorRecordParser.parseNative(text));
		Assert.equals(errorOf(bytes.bind(text)), errorOf(() -> DoorRecordParser.parse(text)));
	}

	/** A fraction where the schema says `Int` fails the check, as the byte-level parser refuses it. */
	@:pin('control') @:killer('M-NATIVE-INT-UNCHECKED')
	public function testAFractionIsNoInt(): Void {
		final text: String = GOOD.replace('"size":1', '"size":1.5');
		Assert.isNull(DoorRecordParser.parseNative(text));
		Assert.notEquals('', errorOf(() -> DoorRecordParser.parse(text)));
	}

	/**
	 * A required key that is missing or holds `null` fails the check, and so does an optional one holding `null`: the
	 * byte-level parser reads that one as absent.
	 */
	public function testNullIsAbsent(): Void {
		final missing: String = GOOD.replace('"name":"a",', '');
		Assert.isNull(DoorRecordParser.parseNative(missing));
		Assert.stringContains('missing required field "name"', errorOf(() -> DoorRecordParser.parse(missing)));
		Assert.isNull(DoorRecordParser.parseNative(GOOD.replace('"name":"a"', '"name":null')));
		final held: String = '{"first":null,${GOOD.substr(1)}';
		Assert.isNull(DoorRecordParser.parseNative(held));
		Assert.isNull(DoorRecordParser.parse(held).first);
		final record: DoorRecord = DoorRecordParser.parse(GOOD);
		Assert.isTrue([record.first].contains(null), 'an absent optional field is null, not undefined, as the byte-level parser leaves it');
		Assert.isTrue([record.tail].contains(null), 'an absent optional field is null, not undefined, as the byte-level parser leaves it');
	}

	/** A field spelled with `@:key` reads from its key, under its Haxe name. */
	@:pin('control') @:killer('M-NATIVE-KEY-UNRENAMED')
	public function testAKeyedFieldReadsItsKey(): Void {
		final read: Null<DoorRecord> = DoorRecordParser.parseNative(GOOD);
		Assert.equals('f', read?.member);
	}

	/** Of two spellings of one key the last is read, by the door as by the bytes. */
	public function testTheLastSpellingWins(): Void {
		final text: String = '{"name":"first",${GOOD.substr(1)}';
		Assert.equals('a', DoorRecordParser.parse(text).name);
		Assert.equals('a', bytes(text).name);
	}

	/** A lone surrogate reads as the code unit it escapes and is written escaped again. */
	public function testALoneSurrogateKeepsItsEscape(): Void {
		final text: String = GOOD.replace('"name":"a"', '"name":"\\ud800"');
		final read: DoorRecord = DoorRecordParser.parse(text);
		Assert.equals(0xD800, read.name.charCodeAt(0));
		Assert.stringContains('"name":"\\ud800"', compact(read));
	}

	/** A raw part holding an object goes to the byte-level parser, which alone keeps its keys in order. */
	public function testARawObjectKeepsItsOrder(): Void {
		final text: String = '{"id":"i","raw":{"b":1,"a":2},"tuples":[]}';
		Assert.isNull(DoorRawRecordParser.parseNative(text));
		switch DoorRawRecordParser.parse(text).raw {
			case JObject(entries):
				Assert.equals('b,a', [for (e in entries) (e.key: String)].join(','));
			case _:
				Assert.fail('the raw part is no object');
		}
	}

	/** Raw scalars and arrays, nested arrays of raw values and a map are read by the door as the bytes read them. */
	public function testRawPartsReadAsTheBytesRead(): Void {
		final text: String = '{"id":"i","raw":[1,"a",null,true],"tuples":[[1,"t"]],"named":{"k":{"n":3}}}';
		Assert.notNull(DoorRawRecordParser.parseNative(text));
		final door: DoorRawRecord = DoorRawRecordParser.parse(text);
		final bytes: DoorRawRecord = DoorRawRecordParser.parseWith(new Parser(new StringInput(text)));
		Assert.isTrue(JValueTools.equals(bytes.raw, door.raw));
		Assert.isTrue(JValueTools.equals(JArray(bytes.tuples[0]), JArray(door.tuples[0])));
		Assert.equals(3, door.named?.get('k')?.n);
		Assert.isNull(door.maybe);
	}

	/** The compact options write the record with no whitespace, its keys in the schema's order and an absent one left out. */
	@:pin('control') @:killer('M-NATIVE-COMPACT-NEVER')
	public function testTheCompactWriterSpellsTheRecord(): Void {
		Assert.equals(
			'{"name":"a","size":1,"ratio":1.5,"on":true,"function":"f","points":[1,2],"rows":[["x"],[]],"holes":["h",null],'
			+ '"inner":{"n":1},"kids":[{"n":2,"label":"é\\n"}]}',
			compact(DoorRecordParser.parse(GOOD))
		);
		Assert.equals('{"n":1,"label":"x"}', DoorRawRecordText.compactDoorInner({ n: 1, label: 'x' }));
		Assert.equals('{"n":1}', DoorRawRecordText.compactDoorInner({ n: 1, label: null }));
	}

	/**
	 * The buffer compact writer, the one of every target the door does not write, spells what the door's writer spells:
	 * with the optional fields absent, held as null, or present.
	 */
	public function testTheBufferWriterSpellsWhatTheDoorSpells(): Void {
		final absent: DoorRecord = DoorRecordParser.parse(GOOD);
		Assert.equals(compact(absent), direct(absent));
		final present: DoorRecord = DoorRecordParser.parse('{"first":"z",${GOOD.substr(1, GOOD.length - 2)},"tail":{"n":3,"label":"t"}}');
		Assert.equals('z', present.first);
		Assert.equals(compact(present), direct(present));
		final held: DoorRecord = {
			first: null,
			name: 'a',
			size: 1,
			ratio: 0.5,
			on: false,
			member: 'f',
			points: [],
			rows: [],
			holes: [null],
			inner: { n: 1, label: null },
			kids: [],
			tail: null
		};
		Assert.equals(
			'{"name":"a","size":1,"ratio":0.5,"on":false,"function":"f","points":[],"rows":[],"holes":[null],"inner":{"n":1},"kids":[]}',
			direct(held)
		);
		Assert.equals(compact(held), direct(held));
	}

	/** A raw part keeps the Doc writer for the compact options too: its arrays are spaced as the Doc writer spaces them. */
	public function testARawPartKeepsTheDocWriter(): Void {
		final record: DoorRawPart = { id: 'a', raw: JArray([JBool(true), JNull]), tuples: [[JBool(false), JNull]] };
		Assert.stringContains('[true, null]', DoorRawPartWriter.write(record, JsonFormat.instance.compactWriteOptions));
	}

	/**
	 * A rule with no optional field asks for each of its keys: a raw part holding `null` reads as the format's null, and one
	 * missing refuses, as a missing required key of any other kind does.
	 */
	public function testARuleWithNoOptionalFieldAsksForEachKey(): Void {
		final read: Null<DoorRawPart> = DoorRawPartParser.parseNative('{"id":"a","raw":null,"tuples":[[1,"x"]]}');
		Assert.isTrue(read != null && read.raw.match(JNull));
		Assert.isNull(DoorRawPartParser.parseNative('{"id":"a","tuples":[]}'));
		Assert.isNull(DoorRawPartParser.parseNative('{"raw":1,"tuples":[]}'));
	}

	/** Any other options keep the Doc writer: the pretty document breaks, indents, and spaces its arrays as before. */
	public function testOtherOptionsKeepTheDocWriter(): Void {
		final pretty: String = DoorRecordWriter.write(DoorRecordParser.parse(GOOD), JsonFormat.instance.defaultWriteOptions);
		Assert.stringContains('{\n    "name":"a",\n', pretty);
		Assert.stringContains('"points":[1, 2]', pretty);
	}

	/** What the compact writer writes reads back as the record it wrote. */
	public function testACompactDocumentReadsBack(): Void {
		final record: DoorRecord = DoorRecordParser.parse(GOOD.replace('"ratio":1.5', '"ratio":2.0'));
		final again: DoorRecord = DoorRecordParser.parse(compact(record));
		Assert.equals(compact(record), compact(again));
		Assert.equals(2.0, again.ratio);
	}

	private static function bytes(text: String): DoorRecord {
		return DoorRecordParser.parseWith(new Parser(new StringInput(text)));
	}

	private static function compact(record: DoorRecord): String {
		return DoorRecordWriter.write(record, JsonFormat.instance.compactWriteOptions);
	}

	/** The message `parse` throws on `text`, or '' when it reads. */
	private static function errorOf(parse: () -> DoorRecord): String {
		return try {
			parse();
			'';
		} catch (error: ParseError) {
			error.toString();
		}
	}

	private static function direct(record: DoorRecord): String {
		return DoorRecordDirectWriter.write(record, JsonFormat.instance.compactWriteOptions);
	}

}
