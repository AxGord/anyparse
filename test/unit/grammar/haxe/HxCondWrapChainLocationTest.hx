package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * Operator placement of a `&&` chain inside a wrapped `if` condition. The condition wrap collapses
 * the chain to one mode, but the operator keeps the side the chain's own cascade gives it: a rule's
 * `location` wins over the section's `defaultLocation`, as it does outside a condition.
 */
@:nullSafety(Strict)
class HxCondWrapChainLocationTest extends Test {

	private static final SRC: String = 'class C {\n\tfunction f() {\n'
		+ '\t\tif (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && '
		+ 'cccccccccccccccccccccccccccccccccc && dddddddddddddddddddddddddddd) {}\n\t}\n}';
	private static final EXPECTED: String = 'class C {\n\tfunction f() {\n\t\tif (\n\t\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
		+ '\t\t\t&& bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n\t\t\t&& cccccccccccccccccccccccccccccccccc\n'
		+ '\t\t\t&& dddddddddddddddddddddddddddd\n\t\t) {}\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** A rule's own `location: beforeLast` keeps the `&&` leading under `defaultLocation: afterLast`. */
	@:pin('control') @:killer('M-CHAIN-LOC-DEFAULT-FIRST')
	public function testARuleLocationWinsOverTheDefaultLocation(): Void {
		Assert.equals(EXPECTED, HxWriteFixture.triviaWrite(SRC, config('"defaultLocation": "afterLast", ')));
	}

	/** Without a `defaultLocation` the rule's location is the one in force — the shape the first test must equal. */
	@:pin('guard')
	public function testWithoutADefaultLocationTheRuleLocationHolds(): Void {
		Assert.equals(EXPECTED, HxWriteFixture.triviaWrite(SRC, config('')));
	}

	/** With no rule carrying a location, `defaultLocation` is what places the operator. */
	@:pin('guard')
	public function testADefaultLocationStillPlacesARulelessCascade(): Void {
		final out: String = HxWriteFixture.triviaWrite(
			SRC,
			'{"wrapping": {"maxLineLength": 80, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, "opBoolChain": {'
			+ '"defaultWrap": "fillLine", "defaultLocation": "afterLast", "rules": []}}}'
		);
		Assert.stringContains('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &&\n', out);
	}

	private static function config(defaultLocation: String): String {
		return '{"wrapping": {"maxLineLength": 80, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, "opBoolChain": {'
			+ '"defaultWrap": "noWrap", $defaultLocation'
			+ '"rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}}}';
	}

}
