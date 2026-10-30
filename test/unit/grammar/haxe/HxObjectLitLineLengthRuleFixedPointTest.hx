package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * An object literal broken by a `lineLength` wrap rule takes its Allman place in the first write, as the next write
 * reads it back.
 *
 * A `lineLength >= n` rule is emitted as `Group(IfWidthExceeds(n, brk, flat))`. The shared width-decision reader
 * (`BreakCommits.decisionMapped`) knew `IfFirstLineExceeds` and `GroupWithRestProbe(IfBreak)` only, so a comprehension
 * body breaking by that rule stayed glued to `for (…)` and the list never got its Allman alternative
 * (`BodyAllman.tailBreak`); the next write read the literal multi-line, moved `{` to its own line and cuddled the
 * bracket. This shape is the whole `thr` harness family (a config with object literal and array width rules).
 */
@:nullSafety(Strict)
final class HxObjectLitLineLengthRuleFixedPointTest extends Test {

	/** Columns a tab occupies under the config here. */
	private static inline final TAB_WIDTH: Int = 4;

	/** `maxLineLength` of the config here. */
	private static inline final LIMIT: Int = 140;

	/** The widest `k` the sweep writes. */
	private static inline final MAX_K: Int = 100;

	/** An object literal goes one field per line once its line reaches 110 columns; a comprehension cuddles its `for`. */
	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"comprehensionCuddledOpen": true, "objectLiteral": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": '
		+ '"lineLength >= n", "value": 110}], "type": "onePerLine"}]}}}';

	public function new(): Void {
		super();
	}

	/** One write is a fixed point within the limit at every width. */
	@:pin('control')
	@:killer('M-WIDTH-RULE-DECISION-UNREAD')
	@:killer('M-WIDTH-RULE-TAIL-UNREAD')
	public function testAWidthRuleLiteralInAComprehensionSettlesInOneWrite(): Void {
		for (k in 1...MAX_K + 1) {
			final src: String = 'class M {\n\tfunction f() {\n\t\tvar y = [for (t in xs) {alpha: t.aaaaaaaaaaaaaaaaaaaaaaa, '
				+ 'beta: t.bbbbbbbbbbbbbbbbbbbbbbb, kind: \''
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
