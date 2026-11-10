package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * `wrapping.anonType.defaultWrap: "ignore"` drops the source-newline signal of
 * an anon type, so the cascade re-flows it by width (fits → one line, exceeds →
 * one field per line) — an inline type hint and a typedef RHS body alike.
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

	public function testTypedefBodyReflowsLikeAnInlineAnon(): Void {
		final out: String = write('typedef Outer = {\n\talpha:Int,\n\tnested:{\n\t\tp:Int,\n\t\tq:Int\n\t}\n}');
		Assert.isTrue(
			out.indexOf('typedef Outer = {alpha:Int, nested:{p:Int, q:Int}}') != -1, 'expected a collapsed typedef body in:\n<$out>'
		);
	}

	private static function write(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
