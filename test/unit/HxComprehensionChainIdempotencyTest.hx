package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-comprehension-count: `hxq fmt` MUST be a fixed point — `write(write(x))
 * == write(x)`. A `for`/`while` array comprehension used inside a wrapping
 * parent (method chain, binary `+`) used to lower to a bare counted `Group`
 * when the source was compact, but to a width-0-deferred `BodyGroup` once a
 * prior pass exploded it (`[`->`[`+newline+`for`). So the SAME comprehension
 * measured wide on one pass and ~0 on the next, flipping the parent's wrap
 * decision -> non-idempotent. The fix forces a comprehension to ALWAYS count
 * (bare `Group`, real width), making the parent measure trivia-independent.
 * Identifiers are synthetic.
 */
@:nullSafety(Strict)
final class HxComprehensionChainIdempotencyTest extends Test {

	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}}';

	public function new(): Void {
		super();
	}

	/** A `[for...].concat([for...]).join('\n')` method chain formats to a fixed point (write(write(x)) == write(x)). */
	public function testConcatJoinComprehensionChainIsIdempotent(): Void {
		final src: String = 'class M {\n\tfunction f() {\n\t\t_row.firstValue = [ for (a in coll.items)\n\t\t\tif (n++ < LIMIT) a.name\n\t\t].concat(\n\t\t\t[ for (b in other.items) if (n++ < LIMIT) b.name ]\n\t\t).join(\'\\n\');\n\t}\n}';
		final once: String = triviaWrite(src);
		Assert.equals(once, triviaWrite(once));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CFG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
