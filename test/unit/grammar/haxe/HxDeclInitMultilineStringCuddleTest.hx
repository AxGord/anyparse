package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A declaration whose initialiser is a VERBATIM multi-line string literal
 * keeps its cuddled shape: the opening quote stays glued to the `=` and the
 * closing `';` rides the string's last line.
 *
 * Declaration-init sibling of `HxCallArgMultilineStringCuddleTest`. Same
 * defect, different probe: the call-arg path pivots on `fitsFlat`, this one on
 * the natural-first-line probe (`IfNaturalFirstLineExceeds`, armed for a
 * string-atom RHS by `WriterLowering.breakAfterLeadOnOverflowWrap`). Its walk
 * measured a `Text` leaf carrying embedded newlines by its SUMMED width, as if
 * every physical line landed on one, so a token whose first line fits well
 * inside the limit still crossed the probe and the `=` broke -- a break that
 * shortens nothing, since the token's later lines are emitted byte for byte
 * either way.
 *
 * Live instances: TM `video/GlProgressOverlay.hx` (4) and
 * `video/GpuReadbackPipeline.hx` (2), GLSL shader sources held as multi-line
 * string constants.
 *
 * Config pins the two knobs the probe reads -- tab indentation at width 4 and
 * `maxLineLength` 140, the real project values. A bare fixture on compiled
 * defaults measures against a different limit and does not reproduce.
 */
@:nullSafety(Strict)
final class HxDeclInitMultilineStringCuddleTest extends Test {

	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140}}';

	/**
	 * The cuddled form is a writer fixed point. Summed flat width here is
	 * ~153 columns while no single physical line passes 80.
	 */
	private static final CUDDLED: String = 'class C {\n\tstatic final FRAG:String = \'varying vec2 v_uv;\nuniform sampler2D u_tex;\n'
		+ "void main() { gl_FragColor = texture2D(u_tex, vec2(v_uv.x, 1.0 - v_uv.y)); }';\n}";

	/** The break-after-`=` shape the un-fixed writer produced. */
	private static final BROKEN: String = 'class C {\n\tstatic final FRAG:String =\n\t\t\'varying vec2 v_uv;\nuniform sampler2D u_tex;\n'
		+ "void main() { gl_FragColor = texture2D(u_tex, vec2(v_uv.x, 1.0 - v_uv.y)); }';\n}";

	public function new(): Void {
		super();
	}

	/** The cuddled declaration survives a round trip unchanged. */
	public function testMultilineStringDeclStaysCuddled(): Void {
		Assert.equals(CUDDLED, triviaWrite(CUDDLED));
	}

	/** The broken shape re-cuddles onto the declaration's own line. */
	public function testBrokenMultilineStringDeclReCuddles(): Void {
		Assert.equals(CUDDLED, triviaWrite(BROKEN));
	}

	/**
	 * A token whose FIRST physical line already overflows is a shape the break
	 * can still shorten (the token moves to the next line at one more indent),
	 * so the break after `=` stays.
	 */
	public function testOverlongFirstLineDeclStillBreaks(): Void {
		final head: String = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
			+ 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
		final src: String = 'class C {\n\tstatic final FRAG:String = \'$head\ntail\';\n}';
		final broken: String = 'class C {\n\tstatic final FRAG:String =\n\t\t\'$head\ntail\';\n}';
		Assert.equals(broken, triviaWrite(src));
	}

	/**
	 * Regression pin for the arming gate this fix narrows: a SINGLE-line string
	 * atom past the limit has no internal wrap point at all, so the break after
	 * `=` is the only shortening the writer can apply and it must still fire.
	 */
	public function testOverlongSingleLineStringDeclStillBreaks(): Void {
		final body: String = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
			+ 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
		final src: String = 'class C {\n\tstatic final FRAG:String = \'$body\';\n}';
		final broken: String = 'class C {\n\tstatic final FRAG:String =\n\t\t\'$body\';\n}';
		Assert.equals(broken, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
