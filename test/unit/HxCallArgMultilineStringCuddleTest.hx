package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * A call whose argument is a VERBATIM multi-line string literal keeps its
 * cuddled shape: the opening quote stays glued to the call's `(` and the
 * closing `');` rides the string's last line.
 *
 * The un-fixed writer measured such a token by its FULL flat width (every
 * physical line summed), so a token whose lines each fit comfortably still
 * blew the `exceedsMaxLineLength` pivot and fell to the each-arg-on-its-own-
 * line wrap — a layout that shortens nothing, since the token's interior
 * lines are emitted verbatim either way.
 *
 * Config is the real project `callParameter` cascade (`exceedsMaxLineLength`
 * pivot + a sole-item `totalItemLength <= 100` escape) at `maxLineLength`
 * 140 — a bare fixture on compiled defaults never reaches the pivot.
 */
@:nullSafety(Strict)
final class HxCallArgMultilineStringCuddleTest extends Test {

	private static final CONFIG: String =
		'{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]}}}';

	/**
	 * The cuddled form is a writer fixed point. Summed flat width here is
	 * ~150 columns while no single physical line passes 100.
	 */
	private static final CUDDLED: String = "class C {\n\tstatic function release():Void {\n\t\tuntyped __cpp__('\n"
		+ '\t\t\tEGLDisplay d = eglGetCurrentDisplay();\n'
		+ "\t\t\tif (d != EGL_NO_DISPLAY) eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)\n\t\t');\n\t}\n}";

	/** The each-arg-on-its-own-line shape the un-fixed writer produced. */
	private static final WRAPPED: String = "class C {\n\tstatic function release():Void {\n\t\tuntyped __cpp__(\n\t\t\t'\n"
		+ '\t\t\tEGLDisplay d = eglGetCurrentDisplay();\n'
		+ "\t\t\tif (d != EGL_NO_DISPLAY) eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)\n\t\t'\n\t\t);\n\t}\n}";

	public function new(): Void {
		super();
	}

	/** The cuddled call survives a round trip unchanged. */
	public function testMultilineStringArgStaysCuddled(): Void {
		Assert.equals(CUDDLED, triviaWrite(CUDDLED));
	}

	/** The wrapped shape re-cuddles onto the call's own line. */
	public function testWrappedMultilineStringArgReCuddles(): Void {
		Assert.equals(CUDDLED, triviaWrite(WRAPPED));
	}

	/**
	 * A token whose FIRST physical line already overflows is a shape the wrap
	 * can still shorten (the token moves to the next line at one more indent),
	 * so the leading break stays.
	 */
	public function testOverlongFirstLineStillWraps(): Void {
		final head: String = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
			+ 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
		final src: String = 'class C {\n\tstatic function release():Void {\n\t\tuntyped __cpp__(\'$head\n\t\t\ttail\n\t\t\');\n\t}\n}';
		final out: String = triviaWrite(src);
		Assert.isTrue(out.indexOf('__cpp__(\n') >= 0, 'over-wide first line keeps the leading break');
	}

	/**
	 * Arguments that FOLLOW the multi-line token ride its closing line, so an
	 * over-wide tail is a line the wrap can still fix — the leading break
	 * stays. TM carries no such call; this pins the refusal.
	 */
	public function testOverwideTailAfterTokenStillWraps(): Void {
		final tail: String = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, '
			+ 'cccccccccccccccccccccccccccccccccccccc, dddddddddddddddddddddddddddddddd';
		final src: String = 'class C {\n\tstatic function release():Void {\n\t\tf(\'\n\t\t\tx\n\t\t\', $tail);\n\t}\n}';
		Assert.isTrue(triviaWrite(src).indexOf('f(\n') >= 0, 'over-wide tail keeps the leading break');
	}

	/**
	 * Arguments BEFORE the token sit on the head line, which the token's own
	 * first line closes — nothing rides the tail, so the call stays cuddled.
	 */
	public function testLeadingArgsBeforeTokenStayCuddled(): Void {
		final lead: String =
			'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, cccccccccccccccccccccccccccccccccccccc';
		final src: String = 'class C {\n\tstatic function release():Void {\n\t\tf($lead, \'\n\t\t\tx\n\t\t\');\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
