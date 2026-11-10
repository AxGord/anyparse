package unit.format;

import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueWriter;
import anyparse.grammar.json.JsonFormat;
import js.Syntax;

/**
 * The generated JSON writer against the native printer: for one document, each layout's options produce the bytes
 * `JSON.stringify` produces with the matching indent argument, across nested containers, empty containers and a number.
 */
class JsonWriterBytesTest extends Test {

	private static final DOCUMENTS: Array<String> = [
		'{"a":[1,2.5,[true,null]],"b":{"c":"x","d":{"e":[]}},"f":{},"g":[]}',
		'[1,2.5]',
		'[{"z":1},{"z":-3,"y":[{}]}]',
		'[]',
		'{}',
		'42'
	];

	@:pin('control')
	@:killer('M-SEP-LIST-ALWAYS-SPACED')
	public function testCompactIsTheNativePrinter(): Void {
		assertNative(JsonFormat.instance.compactWriteOptions, null);
	}

	@:pin('control')
	@:killer('M-KEY-VALUE-LEAD-TIGHT')
	public function testExpandedIsTheNativePrinter(): Void {
		assertNative(JsonFormat.instance.expandedWriteOptions, '  ');
	}

	@:pin('control')
	@:killer('M-KEY-VALUE-LEAD-TIGHT')
	public function testTabbedIsTheNativePrinter(): Void {
		final tabbed: Null<WriteOptions> = Reflect.copy(JsonFormat.instance.expandedWriteOptions);
		if (tabbed == null) throw 'Reflect.copy returned null';
		tabbed.indentChar = IndentChar.Tab;
		assertNative(tabbed, '\t');
	}

	private static function assertNative(options: WriteOptions, space: Null<String>): Void {
		for (document in DOCUMENTS)
			Assert.equals(
				Syntax.code('JSON.stringify(JSON.parse({0}), null, {1})', document, space),
				JValueWriter.write(JValueParser.parse(document), options)
			);
	}

}
