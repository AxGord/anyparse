package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * An object literal that is an arrow-lambda body pads both braces alike under the
 * `after` / `before` brace policy without any `arrowBodyOpenPad` key: the open pad
 * is not dropped by default.
 */
@:nullSafety(Strict)
final class HxArrowBodyPadDefaultTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": 140}, "whitespace": {"bracesConfig": {"objectLiteralBraces": {'
		+ '"openingPolicy": "after", "closingPolicy": "before"}}}}';
	private static final CONFIG_KEY_OFF: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": 140}, "whitespace": {"bracesConfig": {"objectLiteralBraces": {'
		+ '"openingPolicy": "after", "closingPolicy": "before", "arrowBodyOpenPad": false}}}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-ARROW-BODY-PAD-DEFAULT-OFF')
	public function testLambdaBodyLiteralIsSymmetricByDefault(): Void {
		final src: String = inMethod('final entries = users.map(e -> { a: e.a, b: e.b });');
		Assert.equals(src, write(src));
	}

	@:pin('control')
	@:killer('M-ARROW-BODY-PAD-DEFAULT-OFF')
	public function testLambdaBodyLiteralWithoutPadsGainsBoth(): Void {
		final src: String = inMethod('final entries = users.map(e -> {a: e.a, b: e.b});');
		Assert.equals(inMethod('final entries = users.map(e -> { a: e.a, b: e.b });'), write(src));
	}

	@:pin('control')
	@:killer('M-ARROW-BODY-PAD-DEFAULT-OFF')
	public function testParenLambdaBodyLiteralIsSymmetricByDefault(): Void {
		final src: String = inMethod('final entries = users.map((e, f) -> { a: e.a, b: f.b });');
		Assert.equals(src, write(src));
	}

	@:pin('control')
	@:killer('M-ARROW-BODY-PAD-KEY-IGNORED')
	public function testKeyOffKeepsTheForkLayout(): Void {
		final src: String = inMethod('final entries = users.map(e -> { a: e.a, b: e.b });');
		Assert.equals(inMethod('final entries = users.map(e -> {a: e.a, b: e.b });'), writeWith(CONFIG_KEY_OFF, src));
	}

	private static function write(src: String): String {
		return writeWith(CONFIG, src);
	}

	private static function writeWith(config: String, src: String): String {
		return HxWriteFixture.triviaWrite(src, HxWriteFixture.listsKeepSource(config));
	}

	private static function inMethod(statements: String): String {
		return 'class C {\n\tfunction test() {\n\t\t$statements\n\t}\n}';
	}

}
