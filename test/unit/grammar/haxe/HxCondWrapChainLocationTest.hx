package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * Operator placement of a `&&` chain, inside a wrapped `if` condition and outside one, read the way
 * haxe-formatter reads it: the FIRST rule whose conditions match supplies the location, a matched rule
 * that names none is `afterLast`, and `defaultLocation` answers only when no rule matches. The
 * condition wrap forces one mode on the chain but keeps that answer. Every expected text is the
 * fork's own output for the same source and config.
 */
@:nullSafety(Strict)
class HxCondWrapChainLocationTest extends Test {

	private static final SRC: String = 'class C {\n\tfunction f() {\n'
		+ '\t\tif (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && cccccccccccccccccccccccccccccccccc && '
		+ 'dddddddddddddddddddddddddddd) {}\n\t\tvar x = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && '
		+ 'cccccccccccccccccccccccccccccccccc && dddddddddddddddddddddddddddd;\n\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * The matched rule's `beforeLast` wins over `defaultLocation: afterLast` and over a later located rule that does not match.
	 */
	@:pin('control') @:killer('M-CHAIN-OVERRIDE-DROPS-RULES')
	public function testTheMatchedRuleLocationWins(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\tif (\n\t\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n\t\t\t&& '
			+ 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n\t\t\t&& cccccccccccccccccccccccccccccccccc\n\t\t\t&& dddddddddddddddddddddddddddd\n'
			+ '\t\t) {}\n\t\tvar x = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n\t\t\t&& bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
			+ '\t\t\t&& cccccccccccccccccccccccccccccccccc\n\t\t\t&& dddddddddddddddddddddddddddd;\n\t}\n}',
			HxWriteFixture.triviaWrite(
				SRC,
				config(
					'{"defaultWrap": "noWrap", "defaultLocation": "afterLast", "rules": [{"conditions": ['
					+ '{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}, {"conditions": ['
					+ '{"cond": "itemCount >= n", "value": 10}], "type": "onePerLine", "location": "afterLast"}]}'
				)
			)
		);
	}

	/**
	 * A located rule that does not match leaves the placement to `defaultLocation`, inside the condition as outside.
	 */
	@:pin('control') @:killer('M-CHAIN-OVERRIDE-DROPS-CONDITIONS')
	public function testAnUnmatchedLocatedRuleLeavesTheDefaultLocation(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\tif (\n\t\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &&\n'
			+ '\t\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\t\t\tcccccccccccccccccccccccccccccccccc && dddddddddddddddddddddddddddd\n'
			+ '\t\t) {}\n\t\tvar x = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &&\n\t\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n'
			+ '\t\t\tcccccccccccccccccccccccccccccccccc && dddddddddddddddddddddddddddd;\n\t}\n}',
			HxWriteFixture.triviaWrite(
				SRC,
				config(
					'{"defaultWrap": "fillLine", "defaultLocation": "afterLast", "rules": [{"conditions": ['
					+ '{"cond": "itemCount >= n", "value": 10}], "type": "onePerLine", "location": "beforeLast"}]}'
				)
			)
		);
	}

	/**
	 * A matched rule that names no location is `afterLast`, even when an earlier rule that does not match names one.
	 */
	@:pin('control') @:killer('M-CHAIN-OVERRIDE-DROPS-CONDITIONS')
	public function testAMatchedRuleWithoutALocationIsAfterLast(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\tif (\n\t\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &&\n'
			+ '\t\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\t\t\tcccccccccccccccccccccccccccccccccc && dddddddddddddddddddddddddddd\n'
			+ '\t\t) {}\n\t\tvar x = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &&\n\t\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n'
			+ '\t\t\tcccccccccccccccccccccccccccccccccc && dddddddddddddddddddddddddddd;\n\t}\n}',
			HxWriteFixture.triviaWrite(
				SRC,
				config(
					'{"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "itemCount >= n", "value": 10}], "type": "onePerLine", '
					+ '"location": "beforeLast"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine"}]}'
				)
			)
		);
	}

	/**
	 * A matched rule that names no location is `afterLast` whatever `defaultLocation` says, outside a condition too.
	 */
	@:pin('control') @:killer('M-RULE-LOCATION-FALLS-TO-DEFAULT')
	public function testAMatchedRuleWithoutALocationIgnoresTheDefaultLocation(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\tif (\n\t\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &&\n'
			+ '\t\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\t\t\tcccccccccccccccccccccccccccccccccc && dddddddddddddddddddddddddddd\n'
			+ '\t\t) {}\n\t\tvar x = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &&\n\t\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n'
			+ '\t\t\tcccccccccccccccccccccccccccccccccc && dddddddddddddddddddddddddddd;\n\t}\n}',
			HxWriteFixture.triviaWrite(
				SRC,
				config(
					'{"defaultWrap": "noWrap", "defaultLocation": "beforeLast", "rules": [{"conditions": ['
					+ '{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine"}]}'
				)
			)
		);
	}

	/** With no rule matching and no rules at all, `defaultLocation` places the operator. */
	@:pin('guard')
	public function testADefaultLocationStillPlacesARulelessCascade(): Void {
		final out: String = HxWriteFixture.triviaWrite(
			SRC, config('{"defaultWrap": "fillLine", "defaultLocation": "afterLast", "rules": []}')
		);
		Assert.stringContains('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &&\n', out);
	}

	/**
	 * Inside a wrapped condition the line overflowed — that is why it wrapped — so a nested `||` chain
	 * is judged as on an overflowing line: the `exceedsMaxLineLength` rule matches and its `beforeLast`
	 * leads the continuation, not the `afterLast` of the "fits" rules ahead of it.
	 */
	@:pin('control') @:killer('M-CHAIN-OVERRIDE-REJUDGES-EXCEEDS')
	public function testAWrappedConditionJudgesItsChainsAsOverflowing(): Void {
		final config: String = '{"indentation": {"character": "tab", "tabWidth": 4, "trailingWhitespace": false}, "wrapping": {'
			+ '"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": ['
			+ '{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {'
			+ '"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, "opBoolChain": {"defaultWrap": "noWrap", "rules": ['
			+ '{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {'
			+ '"conditions": [{"cond": "totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": '
			+ '"noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, '
			+ '"conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", '
			+ '"value": 0}], "type": "noWrap"}]}, "expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, "sameLine": {'
			+ '"ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine", "functionBody": "fitLine", "expressionIf": "next"}}';
		Assert.equals(
			'class Main {\n\tstatic function test():Void {\n\t\tif (\n\t\t\t!actionItem.folder && timeKey > actionItem.timeKey && (\n'
			+ '\t\t\t\ttimeKey != actionTimeKey\n'
			+ '\t\t\t\t|| _someContainer_.localItemBankExt.findLastActionAndDataForItem(actionItem.filePath, true)\n'
			+ '\t\t\t\t\t== LongTypeActionKindEnum.ACTION_LOCAL_DATA_UPDATE_X1\n\t\t\t)\n\t\t) {\n\t\t\tdoX();\n\t\t}\n\t}\n}',
			HxWriteFixture.triviaWrite(
				'class Main {\n\tstatic function test():Void {\n\t\tif (\n\t\t\t!actionItem.folder && timeKey > actionItem.timeKey && (\n'
				+ '\t\t\t\ttimeKey != actionTimeKey\n'
				+ '\t\t\t\t|| _someContainer_.localItemBankExt.findLastActionAndDataForItem(actionItem.filePath, true) '
				+ '== LongTypeActionKindEnum.ACTION_LOCAL_DATA_UPDATE_X1\n\t\t\t)) {\n\t\t\tdoX();\n\t\t}\n\t}\n}',
				config
			)
		);
	}

	private static function config(opBoolChain: String): String {
		return '{"wrapping": {"maxLineLength": 80, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, "opBoolChain": $opBoolChain}}';
	}

}
