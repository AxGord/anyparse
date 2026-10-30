package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A list a source trailing separator forces into the break-mode cascade, where a `noWrap` rule shadowing a break
 * default answers it flat, still breaks when that flat layout does not fit its line.
 *
 * Under `trailingCommas.objectLiteralDefault: yes` the first write breaks a literal by the probe the cascade puts on a
 * shadowing `noWrap` rule (`WrapList.emitZeroThresholdAgree`) and adds the trailing comma. The next write reads that
 * comma back, which forces the break-mode cascade (`forceExceeds`), and that path had no probe: the rule answered
 * `noWrap` and the literal went flat past the limit, a comprehension's filter body 150 columns wide at 160. The forced
 * path now keeps the probe, so the first write is the fixed point.
 */
@:nullSafety(Strict)
final class HxObjectLitForcedNoWrapProbeTest extends Test {

	/** Columns a tab occupies under the compiled defaults. */
	private static inline final TAB_WIDTH: Int = 4;

	/** `maxLineLength` of the compiled defaults. */
	private static inline final LIMIT: Int = 160;

	/** The widest `k` the sweep writes. */
	private static inline final MAX_K: Int = 120;

	/** A `noWrap` object-literal rule shadowing a one-per-line default, and a trailing comma added to a broken literal. */
	private static final CFG: String = '{"wrapping": {"objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": '
		+ '[{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}}, "trailingCommas": {"objectLiteralDefault": "yes"}}';

	public function new(): Void {
		super();
	}

	/** One write is a fixed point within the limit at every width of a comprehension's filter body. */
	@:pin('control')
	@:killer('M-FORCED-NOWRAP-UNPROBED')
	public function testOneWriteIsAFixedPointAtEveryWidth(): Void {
		for (k in 1...MAX_K + 1) {
			final src: String = 'class M {\n\tfunction f() {\n\t\tvar y = [for (x in xs) if (x != null) {alpha: x.aaaaaaaaaaaaaaaaaaaaaa, '
				+ 'beta: x.bbbbbbbbbbbbbbbbbbbb, k: \''
				+ ''.lpad('k', k)
				+ '\'}];\n\t}\n}';
			final once: String = HxWriteFixture.triviaWrite(src, CFG);
			Assert.equals(once, HxWriteFixture.triviaWrite(once, CFG), 'k=$k\n$src');
			var widest: Int = 0;
			for (line in once.split('\n')) {
				final width: Int = line.replace('\t', ''.lpad(' ', TAB_WIDTH)).length;
				if (width > widest) widest = width;
			}
			Assert.isTrue(widest <= LIMIT, 'k=$k: a $widest-column line\n$once');
		}
	}

}
