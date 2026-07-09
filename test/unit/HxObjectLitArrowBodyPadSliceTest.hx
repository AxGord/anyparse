package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-arrow-body-objlit-pad scope: under `objectLiteralBraces.openingPolicy:
 * "after"` the open-side inner pad (`{ alpha`) is DROPPED when the object
 * literal is the leftmost leaf of an arrow-lambda body — its `{` sits
 * directly after the `->` token (`u -> {alpha: v }`). Mirrors fork
 * `MarkWhitespace.successiveParenthesis` compress-mode `case Arrow:
 * return;`, which never applies the opening-brace policy to an opening
 * delimiter whose previous token is Arrow. Every other context — nested
 * literal, parenthesised body, call arg, `function return`, var-init —
 * keeps the configured pad; the close-side pad is never affected.
 */
@:nullSafety(Strict)
final class HxObjectLitArrowBodyPadSliceTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, "whitespace": {"bracesConfig": {"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before"}}}}';

	public function new(): Void {
		super();
	}

	public function testArrowBodyLeadingObjectLitDropsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(u -> {alpha: u.a, beta: u.b });\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testParenLambdaBodyLeadingObjectLitDropsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map((u, w) -> {alpha: u.a, beta: w.b });\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testPaddedArrowBodyObjectLitStripsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(u -> { alpha: u.a, beta: u.b });\n\t}\n}';
		final expected: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(u -> {alpha: u.a, beta: u.b });\n\t}\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	public function testNestedObjectLitInsideArrowBodyKeepsPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(u -> {alpha: { gamma: u.g }, beta: u.b });\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testParenthesisedArrowBodyKeepsPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(u -> ({ alpha: u.a }));\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testCallArgInsideArrowBodyKeepsPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(u -> makeEntry({ alpha: u.a }));\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testAnonFunctionReturnKeepsPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(function(u) return { alpha: u.a });\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testVarInitKeepsPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entry = { alpha: 1, beta: 2 };\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testInfixLeftOperandLeafDropsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal flags = users.filter(u -> {alpha: u.a }.alpha > 0);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}


	private static final CONFIG_KEEP_PAD: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, "whitespace": {"bracesConfig": {"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before", "arrowBodyOpenPad": true}}}}';

	/**
	 * ω-arrow-body-objlit-pad-keep: `arrowBodyOpenPad: true` disables the
	 * arrow-body open-pad suppression — the literal keeps the configured
	 * `openingPolicy` pad like every other context.
	 */
	public function testArrowBodyOpenPadKeptWithConfigKnob(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(u -> { alpha: u.a, beta: u.b });\n\t}\n}';
		Assert.equals(src, triviaWriteKeepPad(src));
	}

	public function testArrowBodyOpenPadAddedWithConfigKnob(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(u -> {alpha: u.a, beta: u.b });\n\t}\n}';
		final expected: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(u -> { alpha: u.a, beta: u.b });\n\t}\n}';
		Assert.equals(expected, triviaWriteKeepPad(src));
	}

	public function testParenLambdaBodyOpenPadKeptWithConfigKnob(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map((u, w) -> { alpha: u.a, beta: w.b });\n\t}\n}';
		Assert.equals(src, triviaWriteKeepPad(src));
	}

	private inline function triviaWriteKeepPad(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG_KEEP_PAD);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}


	private static final CONFIG_REFLOW: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, "whitespace": {"bracesConfig": {"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before", "arrowBodyOpenPad": true, "arrowBodyReflow": true}}}}';

	/**
	 * ω-arrow-body-objlit-reflow: `arrowBodyReflow: true` drops the source
	 * newlines of an arrow-lambda-body literal so the wrap cascade re-flows
	 * it by width — a source-multiline body collapses to the canonical
	 * inline form when it fits.
	 */
	public function testArrowBodyMultilineSourceReflowsInline(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(u -> {\n\t\t\talpha: u.a,\n\t\t\tbeta: u.b\n\t\t});\n\t}\n}';
		final expected: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(u -> { alpha: u.a, beta: u.b });\n\t}\n}';
		Assert.equals(expected, triviaWriteReflow(src));
	}

	public function testArrowBodyMultilineSourceKeptWithoutReflowKnob(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entries = users.map(u -> {\n\t\t\talpha: u.a,\n\t\t\tbeta: u.b\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWriteKeepPad(src));
	}

	public function testNonArrowMultilineObjectLitKeptWithReflowKnob(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal entry = {\n\t\t\talpha: 1,\n\t\t\tbeta: 2\n\t\t};\n\t}\n}';
		Assert.equals(src, triviaWriteReflow(src));
	}

	private inline function triviaWriteReflow(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG_REFLOW);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
