package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-comprehension-fitline-nobreak: under `sameLine.comprehensionFor: fitLine`
 * a single-generator array comprehension whose flat line FITS within
 * `wrapping.maxLineLength` must stay on ONE line (`[ for (...) body ]`), NOT
 * leading-break the `[`.
 *
 * The bug: a comprehension array was routed through the generic
 * `defaultArrayLiteralWrap` cascade, whose fixed thresholds
 * (`totalItemLength < 80 -> noWrap`, `anyItemLength > 30 -> onePerLine`) break
 * the SINGLE for-expr element as soon as it exceeds ~80 chars — regardless of
 * the configured `maxLineLength`. The fork instead leaves comprehension layout
 * to the `comprehensionFor` fit policy: flat while the physical line fits, break
 * only on genuine `maxLineLength` overflow.
 *
 * Here the for-expr element is ~90 chars (> 80, so it tripped the old rule) yet
 * the whole line is ~111 chars (< 140), so it must render flat. Identifiers are
 * synthetic.
 */
@:nullSafety(Strict)
final class HxComprehensionFitLineNoBreakTest extends Test {

	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, "sameLine": {"comprehensionFor": "fitLine"}}';

	public function new(): Void {
		super();
	}

	/** A comprehension whose flat width (~111) fits maxLineLength (140) stays on one line even though its sole for-expr element is ~90 chars (> 80). */
	public function testFittingComprehensionStaysOnOneLine(): Void {
		final src: String = 'class M {\n\tfunction f() {\n\t\t_series = [for (k in 0...Std.int(values.length / 2)) new Vector(values[k * 2 + 0], values[k * 2 + 1])];\n\t}\n}';
		final out: String = triviaWrite(src);
		Assert.isTrue(
			out.indexOf('[ for (k in 0...Std.int(values.length / 2)) new Vector(values[k * 2 + 0], values[k * 2 + 1]) ]') != -1,
			'expected fitting comprehension on one line, got:\n<$out>'
		);
		// The `[` must not leading-break: no standalone `for (` continuation line, no bare `];` close line.
		Assert.isTrue(out.indexOf('\n\t\t\tfor (k in') == -1, 'comprehension `[` must not open onto its own line, got:\n<$out>');
	}

	/** An already-wrapped (source-multiline) comprehension that still fits maxLineLength reflows back to one line, and the result is idempotent. */
	public function testWrappedFittingComprehensionCollapses(): Void {
		final src: String = 'class M {\n\tfunction f() {\n\t\t_series = [\n\t\t\tfor (k in 0...Std.int(values.length / 2)) new Vector(values[k * 2 + 0], values[k * 2 + 1])\n\t\t];\n\t}\n}';
		final out: String = triviaWrite(src);
		Assert.isTrue(
			out.indexOf('[ for (k in 0...Std.int(values.length / 2)) new Vector(values[k * 2 + 0], values[k * 2 + 1]) ]') != -1,
			'expected wrapped-but-fitting comprehension to reflow to one line, got:\n<$out>'
		);
		Assert.isTrue(out.indexOf('\n\t\t\tfor (k in') == -1, 'comprehension `[` must reflow flat (no own-line for), got:\n<$out>');
		Assert.equals(out, triviaWrite(out));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CFG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
