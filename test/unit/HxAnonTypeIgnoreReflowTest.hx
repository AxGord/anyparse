package unit;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * ω-anontype-reflow-typedef-guard — `wrapping.anonType.defaultWrap: "ignore"`
 * drops the source-newline signal of an INLINE anon type hint so the cascade
 * re-flows it by width (fits → one line, exceeds → one field per line), while
 * a typedef RHS body keeps its source line structure verbatim.
 *
 * The fork classifies the typedef brace as `BrOpenType.TypedefDecl` and routes
 * it to `MarkWrapping.typedefWrapping`, which never consults
 * `wrapping.anonType`; anyparse models both positions with the single
 * `HxType.Anon` Star, so the Ignore drop is gated off inside the typedef RHS.
 */
@:nullSafety(Strict)
class HxAnonTypeIgnoreReflowTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "anonType": {"defaultWrap": "ignore", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLineWithLeadingBreak"}]}}}';

	public function new(): Void {
		super();
	}

	public function testSourceMultilineInlineAnonCollapsesWhenItFits(): Void {
		final out: String = write('class C {\n\tfunction f():{\n\t\tx:Int,\n\t\ty:Int\n\t} {\n\t\treturn null;\n\t}\n}');
		Assert.isTrue(out.indexOf('function f():{x:Int, y:Int} {') != -1, 'expected collapsed inline anon return type in:\n<$out>');
	}

	public function testSourceFlatInlineAnonBreaksWhenItExceeds(): Void {
		// The overflow shape is `fillLineWithLeadingBreak`: the head breaks
		// after `{`, the fields then PACK across continuation lines rather
		// than taking one line each. Asserting the whole `{`-to-`}` span in
		// one string also pins that no delim padding survives the forced
		// breaks (`{ ` trailing whitespace / a stray ` }`).
		final field: String =
			'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:Int, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:Int, cccccccccccccccccccccccccccccccccccc:Int';
		final out: String = write('class C {\n\tfunction f():{$field} {\n\t\treturn null;\n\t}\n}');
		Assert.isTrue(out.indexOf('function f():{\n\t\t$field\n\t} {') != -1, 'expected packed inline anon body in:\n<$out>');
	}

	public function testTypedefBodyKeepsSourceBreaksWhileNestedAnonReflows(): Void {
		// One combined assertion on purpose: the OUTER typedef body must keep
		// its source breaks (the guard) while the NESTED anon collapses (the
		// per-element `_inTypedefBody` clear). Either half alone would be
		// satisfiable without the other.
		final out: String = write('typedef Outer = {\n\talpha:Int,\n\tnested:{\n\t\tp:Int,\n\t\tq:Int\n\t}\n}');
		Assert.isTrue(
			out.indexOf('typedef Outer = {\n\talpha:Int,\n\tnested:{p:Int, q:Int}\n}') != -1,
			'expected preserved typedef body with collapsed nested anon in:\n<$out>'
		);
	}

	private static function write(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
