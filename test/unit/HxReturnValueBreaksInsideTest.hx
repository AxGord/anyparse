package unit;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * ω-natural-trailwidth — a `return` whose value can break INSIDE itself keeps
 * the keyword glued and breaks there; the keyword break is reserved for a
 * value that cannot.
 *
 * The natural-first-line probe measures the value alone, but the statement's
 * `;` comes from the ctor's `@:trailOpt(';')` and rides the same rendered
 * line. A collection whose flat width equals the remaining budget EXACTLY
 * therefore resolved FLAT inside the probe, the natural first line came out as
 * the whole value, and the probe broke after `return` — stranding a bare
 * keyword while the value then fitted the continuation. `pushNaturalBranch`
 * now hands the walk `flatTokenWidthOfRestStack`, and the rest-aware Group
 * (`HxExpr.ArrayExpr` carries `@:fmt(groupRestProbe)`) spends it.
 */
@:nullSafety(Strict)
class HxReturnValueBreaksInsideTest extends Test {

	/** Flat, the statement is 141 columns — one past the limit, and only because of the `;`. */
	private static final SRC: String = 'class C {\n\tprivate inline function files(fileName:String, '
		+ 'sessionXML:String):Array<APIFileUploadBase> {\n\t\treturn [new APIFileUploadBase(\'sessionxml\', '
		+ 'fileName, Mime.ApplicationOctetStream, ByteArray.fromBytes(Bytes.ofString(sessionXML)))];\n\t}\n}';

	public function new(): Void {
		super();
	}

	public function testKeywordStaysGluedAndTheArrayBreaks(): Void {
		final out: String = write();
		// One assertion spanning both halves: the keyword glued to the open
		// bracket AND the element on its own continuation line. Asserting
		// either alone would pass on a shape the other half rejects.
		Assert.isTrue(
			out.indexOf('\t\treturn [\n\t\t\tnew APIFileUploadBase(') != -1,
			'expected `return [` glued with the element broken inside in:\n<$out>'
		);
	}

	public function testNoLineExceedsTheLimit(): Void {
		for (line in write().split('\n')) {
			// Each tab occupies `tabWidth` columns, not the one char it counts as.
			final cols: Int = line.length + (line.split('\t').length - 1) * 3;
			Assert.isTrue(cols <= 140, 'line over 140 columns ($cols): <$line>');
		}
	}

	private static inline function write(): String {
		final config: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "arrayWrap": '
			+ '{"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]}}}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(SRC), opts);
	}

}
