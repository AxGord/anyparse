package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.format.wrap.WrapMode;

/**
 * ω-postfix-call-trailing — `Call(operand, args)` postfix Star-suffix
 * ctor needs a `closeTrailing:Null<String>` synth slot for trailing
 * comments captured between the close `)` and the next chain step.
 *
 * Without the slot the postfix loop's per-iteration `skipWs(ctx)` eats
 * inter-segment line comments before the chain's next `.foo()` matches
 * — losing them for the writer. Mirrors `feedback_pratt_skipws_eats_trailing.md`
 * but at the postfix-step granularity (Pratt-loop rewind only fires
 * when the outer infix dispatch fails to match, not between adjacent
 * postfix steps).
 *
 * Driving fixture: `indentation/method_chain_with_line_comment.hxtest`
 * — chain `bildLink = new Tag("img").src(...).alt(...) // .width(100)\n.height(66);`
 * must preserve the trailing line comment on the `.alt(...)` segment's line.
 */
@:nullSafety(Strict)
class HxMethodChainCloseTrailingTest extends Test {

	private static final _forceBuildParser:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final _forceBuildWriter:Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function new():Void {
		super();
	}

	public function testTrailingLineCommentBetweenChainSegmentsRoundTrips():Void {
		final source:String = 'class Foo {\n\tstatic function f() {\n\t\ta.b().c() // mid\n\t\t\t.d();\n\t}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.methodChainWrap = {rules: [], defaultMode: WrapMode.OnePerLineAfterFirst};
		opts.finalNewline = false;
		final ast = HaxeModuleTriviaParser.parse(source);
		final out:String = HaxeModuleTriviaWriter.write(ast, opts);
		Assert.isTrue(out.indexOf('.c() // mid') != -1,
			'expected `.c() // mid` preserved on the chain segment line: <$out>');
		Assert.isTrue(out.indexOf('.d();') != -1, 'expected `.d();` follows: <$out>');
	}
}
