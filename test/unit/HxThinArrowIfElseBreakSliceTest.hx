package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-thinarrow-break if-else: a sole bare-ident arrow arg of a call / new-expr
 * whose body is an ALREADY-multiline `if … else` (or `else if` chain) breaks
 * AFTER `->` with the enclosing `)` on its own line, even though the glued head
 * fits. Collapsing it would align `else` with the enclosing call statement
 * instead of nesting it in the lambda body. Every OTHER body shape — a plain
 * `if` (no else), `switch`, `for`, `while`, a `{ }` block, and an outer `if`
 * whose then-block merely CONTAINS a nested if/else — has no top-level `else`
 * and stays HUGGED, preserving the landed block/statement-body hug behaviour.
 */
@:nullSafety(Strict)
final class HxThinArrowIfElseBreakSliceTest extends Test {

	// A single-arg `noWrap` rule (`itemCount <= 1 && totalItemLength <= 100`) is
	// added on top of the plain `exceedsMaxLineLength` rule so a sole short arg
	// resolves to `noWrap` (HUG) even when its body carries an internal hardline.
	// This makes the block / switch / for / while / plain-if negatives HUG, so the
	// if-else positives — which break after `->` REGARDLESS of the resolved wrap
	// mode — stand out as the only shape that leading-breaks.
	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	// --- POSITIVE: if/else body breaks after `->` ---

	public function testIfElseArrowBodyBreaksAfterArrow(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tgate.waitToken(success ->\n\t\t\tif (success) {\n\t\t\t\tdoRequest();\n\t\t\t} else {\n\t\t\t\tonError();\n\t\t\t}\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testElseIfChainArrowBodyBreaksAfterArrow(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tgate.waitToken(success ->\n\t\t\tif (success) {\n\t\t\t\tdoRequest();\n\t\t\t} else if (other) {\n\t\t\t\tmiddle();\n\t\t\t} else {\n\t\t\t\tonError();\n\t\t\t}\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testNewExprIfElseArrowBodyBreaksAfterArrow(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal x = new Wrapper(success ->\n\t\t\tif (success) {\n\t\t\t\tdoRequest();\n\t\t\t} else {\n\t\t\t\tonError();\n\t\t\t}\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	// --- POSITIVE: a hugged if/else source is REFLOWED to break after `->` ---

	public function testHuggedIfElseIsReflowedToLeadingBreak(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tgate.waitToken(success -> if (success) {\n\t\t\tdoRequest();\n\t\t} else {\n\t\t\tonError();\n\t\t});\n\t}\n}';
		final want: String = 'class C {\n\tfunction test() {\n\t\tgate.waitToken(success ->\n\t\t\tif (success) {\n\t\t\t\tdoRequest();\n\t\t\t} else {\n\t\t\t\tonError();\n\t\t\t}\n\t\t);\n\t}\n}';
		Assert.equals(want, triviaWrite(src));
	}

	// --- NEGATIVE: block / switch / for / while / plain-if bodies stay HUGGED ---

	public function testBlockBodyArrowStaysHugged(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tgate.waitToken(success -> {\n\t\t\tdoRequest();\n\t\t\tonError();\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testSwitchBodyArrowStaysHugged(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tgate.waitToken(success -> switch (success) {\n\t\t\tcase TRUE: doRequest();\n\t\t\tcase FALSE: onError();\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testForBodyArrowStaysHugged(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tgate.waitToken(items -> for (item in items) {\n\t\t\tdoRequest(item);\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testWhileBodyArrowStaysHugged(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tgate.waitToken(state -> while (state.next()) {\n\t\t\tdoRequest();\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testPlainIfNoElseArrowStaysHugged(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tgate.waitToken(success -> if (success) {\n\t\t\tdoRequest();\n\t\t\tonError();\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testNestedElseUnderOuterNoElseStaysHugged(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tgate.waitToken(success -> if (success) {\n\t\t\tif (other) {\n\t\t\t\tdoRequest();\n\t\t\t} else {\n\t\t\t\tonError();\n\t\t\t}\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
