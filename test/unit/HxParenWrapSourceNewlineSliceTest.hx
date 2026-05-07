package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-paren-wrap-source-newline -- source-shape capture of the gap
 * between `@:wrap`'s open delimiter and the inner sub-rule's first token.
 *
 * Mechanism: `HxExpr.ParenExpr` carries `@:fmt(captureWrapOpenNewline)`.
 * In trivia mode the synth pair `HxExprT.ParenExpr` grows a positional
 * `wrapOpenNewline:Bool` arg filled by the parser via
 * `hasNewlineIn(_leadEndPos, ctx.pos)` over the post-`(` skipWs gap.
 * The writer's wrap-shape branch consumes the flag to switch between
 * two break shapes when the inner Doc opens with a hardline:
 *
 *   - `wrapOpenNewline=true`  (source had `\n` after `(`)
 *     break shape = `(\n<inner>\n)` (open broken, close on its own line).
 *     Inner's `OptHardlineSkipAtOpenDelim` collides with the freshly-
 *     emitted hardline and drops via the renderer's collision branch,
 *     so net output is `(\n<item0>\n...\n)`.
 *
 *   - `wrapOpenNewline=false` (source had `(` followed immediately by
 *     content)
 *     break shape = `(<inner>\n)` (items[0] glued to `(` via the chain
 *     emit's `OptHardlineSkipAtOpenDelim`, close on its own line). Pre-
 *     slice default behavior, unchanged.
 *
 * Targets the corpus fixture
 * `indentation/issue_187_multi_line_wrapped_assignment_oneline` which has
 * `return !(\n\tchain)` on case 1 (open broken) and `((subchain))` on
 * cases 3/4 (glued). Both round-trip with the same writer output now.
 *
 * Plain-mode pipelines do NOT receive the slot (the synth pair carrier
 * is trivia-only) and fall through to the unconditional glue shape.
 */
@:nullSafety(Strict)
final class HxParenWrapSourceNewlineSliceTest extends Test {

	private static final _forceBuildParser:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final _forceBuildWriter:Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function new():Void {
		super();
	}

	public function testParenSourceNewlinePreservedOnBrokenChain():Void {
		// Source `return !(\n\t\tchain);` -- author opened the paren with a
		// newline. Under `opBoolChain.defaultWrap=onePerLine` the chain
		// emits as OnePerLine (every operand on its own line including
		// items[0]). Expected output preserves the `\n` after `(`:
		//   return !(\n\t\titem0\n\t\titem1\n\t);
		// Without the source-newline capture the writer would always glue
		// items[0] to `(` and emit `return !(item0\n...)`.
		final src:String = 'class M {\n\tfunction f():Void {\n\t\treturn !(\n\t\t\ta || b\n\t\t);\n\t}\n}';
		final out:String = formatOnePerLine(src);
		Assert.isTrue(out.indexOf('!(\n') != -1,
			'expected `!(\\n` (newline preserved after open paren) in: <$out>');
		Assert.isTrue(out.indexOf('!(a') == -1,
			'unexpected glued items[0] after `(` -- source newline should be preserved in: <$out>');
	}

	public function testParenSourceTightKeepsGlue():Void {
		// Source `var v:Bool = (a || b || c);` -- author put `(` and inner
		// chain on the same line. Under `onePerLine` the chain still emits
		// as OnePerLine; items[0] glued to `(` (pre-slice behavior).
		final src:String = 'class M { function f():Void { var v:Bool = (a || b || c); } }';
		final out:String = formatOnePerLine(src);
		Assert.isTrue(out.indexOf('(a ||') != -1,
			'expected items[0] glued to `(` when source had no leading newline: <$out>');
		Assert.isTrue(out.indexOf('(\n') == -1,
			'unexpected `(\\n` -- source had no newline so glue should stay: <$out>');
	}

	public function testParenWithFlatChainStaysFlat():Void {
		// Source `var v:Bool = (a || b);` -- short chain that fits flat.
		// The wrap shape's flat side picks `(<inner>)` regardless of
		// `wrapOpenNewline`, so output stays tight `(a || b)`. Verifies
		// flat-mode emission is not regressed by the new break-shape arm.
		final src:String = 'class M { function f():Void { var v:Bool = (a || b); } }';
		final out:String = formatDefault(src);
		Assert.isTrue(out.indexOf('(a || b)') != -1,
			'expected flat `(a || b)` round-trip: <$out>');
	}

	public function testRoundTripIssue187OnelineCaseOne():Void {
		// Mini reproduction of issue_187_multi_line_wrapped_assignment_oneline
		// case 1 -- `return !(\n\t\t\tchain\n\t\t);` with a longer chain.
		// Under onePerLine the chain spans multiple lines; the leading
		// `\n` after `(` must be preserved AND the close `)` lands on its
		// own line at the outer indent.
		final src:String = 'class M {\n\tfunction f():Bool {\n\t\treturn !(\n\t\t\ta.y + b.h <= c.y || d.y >= e.y + f.h ||\n\t\t\tg.x + h.w <= i.x || j.x >= k.x + l.w\n\t\t);\n\t}\n}';
		final out:String = formatOnePerLine(src);
		Assert.isTrue(out.indexOf('!(\n') != -1,
			'expected open paren followed by newline (case 1 shape): <$out>');
		Assert.isTrue(out.indexOf('\n\t\t);') != -1,
			'expected close paren on its own line at outer indent: <$out>');
	}

	private inline function formatDefault(src:String):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

	private inline function formatOnePerLine(src:String):String {
		final cfg:String = '{ "wrapping": { "opBoolChain": { "defaultWrap": "onePerLine", "rules": [] } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
