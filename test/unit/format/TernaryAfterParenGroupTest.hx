package unit.format;

import unit.grammar.haxe.HxWriteFixture;

/**
 * A ternary whose condition ends in a paren group that opens as a container keeps its `? a : b` on the group's closing
 * line only while that line fits; past the limit the `?` / `:` seams break as the ternary's own. Every expected shape
 * is also a fix-point of the writer.
 */
@:nullSafety(Strict)
final class TernaryAfterParenGroupTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "opBoolChain": {"defaultWrap": "noWrap", "rules": ['
		+ '{"conditions": [{"cond": "itemCount <= n", "value": 3}, {'
		+ '"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": '
		+ '"totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": '
		+ '"noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", '
		+ '"location": "beforeLast"}]}, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", '
		+ '"rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, '
		+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"c'
		+ 'ond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": ['
		+ '{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], '
		+ '"type": "noWrap"}]}, "expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", '
		+ '"rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';

	/** A kept expression paren that never opens: what follows the ternary rides its tail line. */
	private static final GLUED_PAREN_CONFIG: String = '{"wrapping":{"maxLineLength":140,"opBoolChain":{"defaultWrap":"noWrap",'
		+ '"rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{'
		+ '"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditi'
		+ 'ons":[{"cond":"totalItemLength <= n","value":120},{"cond":"exceedsMaxLineLength","value":0}],'
		+ '"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine",'
		+ '"location":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},'
		+ '"callParameter":{"defaultWrap":"fillLin'
		+ 'eWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],'
		+ '"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{'
		+ '"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	/**
	 * The `? a : b` tail would overflow the closing `)` line, so the ternary breaks before `?` and `:` instead of
	 * gluing to `)` and breaking the else call's arguments.
	 */
	@:pin('control')
	@:killer('M-TERNARY-TAIL-GATE-OFF')
	public function testOverflowingTailBreaksTheTernarySeams(): Void {
		assertLaidOut(
			'class C {\n\tfunction pick(item:Item, key:String):String {\n'
			+ '\t\treturn (item.enabled && (accepts(item, key) || item.children.exists(child -> child.startsWit'
			+ 'h(key)) || item.aliases.exists(alias -> alias.startsWith(key))) ? describeEnabledItem(item.name, item.children.length, '
			+ 'item.aliases.length) : describeDisabledItem(item.name, key, item.reason));\n\t}\n}',
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (\n\t\t\titem.enabled && (\n'
			+ '\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n'
			+ '\t\t\t\t|| item.aliases.exists(alias -> alias.startsWith(key))\n\t\t\t)\n\t\t\t\t? describeEnabledItem(item.name, '
			+ 'item.children.length, item.aliases.length)\n\t\t\t\t: describeDisabledItem(item.name, key, item.reason)\n\t\t);\n\t}\n}'
		);
	}

	/**
	 * A tail that fits rides the closing `)` line.
	 */
	public function testFittingTailStaysOnTheClosingLine(): Void {
		assertLaidOut(
			'class C {\n\tfunction pick(item:Item, key:String):String {\n'
			+ '\t\treturn (item.enabled && (accepts(item, key) || item.children.exists(child -> child.startsWit'
			+ 'h(key)) || item.aliases.exists(alias -> alias.startsWith(key))) ? shownLabel : hiddenLabel);\n\t}\n}',
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (\n\t\t\titem.enabled && (\n'
			+ '\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n'
			+ '\t\t\t\t|| item.aliases.exists(alias -> alias.startsWith(key))\n\t\t\t) ? shownLabel : hiddenLabel\n\t\t);\n\t}\n}'
		);
	}

	/**
	 * The same check holds for a ternary nested in the branch of another whose paren opens: the inner ternary
	 * breaks its own seams rather than riding its condition's closing line past the limit.
	 */
	@:pin('control')
	@:killer('M-TERNARY-TAIL-GATE-NESTED-OFF')
	public function testNestedTernaryBreaksItsOwnSeams(): Void {
		assertLaidOut(
			'class C {\n\tfunction pick(item:Item, key:String):String {\n'
			+ '\t\treturn (item.visible ? (item.enabled && (accepts(item, key) || item.children.exists(child ->'
			+ ' child.startsWith(key)) || item.aliases.exists(alias -> alias.startsWith(key))) ? describeEnabledItem(item.name, '
			+ 'item.children.length, item.aliases.length) : describeDisabledItem(item.name, key, item.reason)) : hiddenLabel);\n\t}\n}',
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (\n\t\t\titem.visible ? (\n'
			+ '\t\t\t\titem.enabled && (\n\t\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n'
			+ '\t\t\t\t\t|| item.aliases.exists(alias -> alias.startsWith(key))\n\t\t\t\t)\n'
			+ '\t\t\t\t\t? describeEnabledItem(item.name, item.children.length, item.aliases.length)\n'
			+ '\t\t\t\t\t: describeDisabledItem(item.name, key, item.reason)\n\t\t\t) : hiddenLabel\n\t\t);\n\t}\n}'
		);
	}

	/**
	 * A closing line of exactly the limit still carries the tail.
	 */
	public function testTailAtTheLimitStays(): Void {
		assertLaidOut(
			'class C {\n\tfunction pick(item:Item, key:String):String {\n'
			+ '\t\treturn (item.enabled && (accepts(item, key) || item.children.exists(child -> child.startsWit'
			+ 'h(key)) || item.aliases.exists(alias -> alias.startsWith(key))) ? aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
			+ 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa : bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb);\n\t}\n}',
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (\n\t\t\titem.enabled && (\n'
			+ '\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n\t\t\t\t|| item.aliases.exists(alias -> '
			+ 'alias.startsWith(key))\n\t\t\t) ? aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa : bbbbbbbbbbbbbbbbbbbbbbb'
			+ 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n\t\t);\n\t}\n}'
		);
	}

	/**
	 * One column more and the tail breaks.
	 */
	@:pin('control')
	@:killer('M-TERNARY-TAIL-GATE-OFF-BY-ONE')
	public function testTailOnePastTheLimitBreaks(): Void {
		assertLaidOut(
			'class C {\n\tfunction pick(item:Item, key:String):String {\n'
			+ '\t\treturn (item.enabled && (accepts(item, key) || item.children.exists(child -> child.startsWit'
			+ 'h(key)) || item.aliases.exists(alias -> alias.startsWith(key))) ? aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
			+ 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa : bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb);\n\t}\n}',
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (\n\t\t\titem.enabled && (\n'
			+ '\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n\t\t\t\t|| item.aliases.exists(alias -> '
			+ 'alias.startsWith(key))\n\t\t\t)\n\t\t\t\t? aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
			+ '\t\t\t\t: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n\t\t);\n\t}\n}'
		);
	}

	/**
	 * Inside a paren that stays glued the `),` after the ternary shares its tail line and is charged: a line of
	 * exactly the limit keeps the tail, one column more breaks the seams.
	 */
	@:pin('control')
	@:killer('M-TERNARY-TAIL-REST-OFF')
	public function testRestOfTheLineIsCharged(): Void {
		assertLaidOut(
			'class C {\n\tfunction pick(item:Item, key:String):String {\n'
			+ '\t\treturn wrap((item.enabled && (accepts(item, key) || item.children.exists(child -> child.star'
			+ 'tsWith(key)) || item.aliases.exists(alias -> alias.startsWith(key))) ? aaaaaaaaaaaaaaaaaaaaaaaaa'
			+ 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa : bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb), other);\n\t}\n}',
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn wrap(\n\t\t\t(item.enabled && (\n'
			+ '\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n\t\t\t\t|| item.aliases.exists(alias -> '
			+ 'alias.startsWith(key))\n\t\t\t) ? aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa : bbbbbbbbbbbbbbbbbbbbbbb'
			+ 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb),\n\t\t\tother\n\t\t);\n\t}\n}',
			GLUED_PAREN_CONFIG
		);
		assertLaidOut(
			'class C {\n\tfunction pick(item:Item, key:String):String {\n'
			+ '\t\treturn wrap((item.enabled && (accepts(item, key) || item.children.exists(child -> child.star'
			+ 'tsWith(key)) || item.aliases.exists(alias -> alias.startsWith(key))) ? aaaaaaaaaaaaaaaaaaaaaaaaa'
			+ 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa : bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb), other);\n\t}\n}',
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn wrap(\n\t\t\t(item.enabled && (\n'
			+ '\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n\t\t\t\t|| item.aliases.exists(alias -> '
			+ 'alias.startsWith(key))\n\t\t\t)\n\t\t\t\t? aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
			+ '\t\t\t\t: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb),\n\t\t\tother\n\t\t);\n\t}\n}',
			GLUED_PAREN_CONFIG
		);
	}

	/**
	 * A branch that opens its own paren group follows the container rule: the group opens at the end of a line
	 * that fits, so `) ? item.enabled && (` stays glued and only that first line is measured.
	 */
	@:pin('control')
	@:killer('M-TERNARY-TAIL-FLAT-WIDTH')
	public function testBranchOpeningItsGroupStaysGlued(): Void {
		assertLaidOut(
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (item.ok && (accepts(item, key) '
			+ '|| item.children.exists(child -> child.startsWith(key)) || item.aliases.exists(alias -> alias.startsWith(key))) '
			+ '? item.enabled && (accepts(item, key) || item.children.exists(child -> child.startsWith(key)) || item.aliases.exists(alias '
			+ '-> alias.startsWith(key))) : bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb);\n\t}\n}',
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (\n\t\t\titem.ok && (\n'
			+ '\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n'
			+ '\t\t\t\t|| item.aliases.exists(alias -> alias.startsWith(key))\n\t\t\t) ? item.enabled && (\n'
			+ '\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n\t\t\t\t|| item.aliases.exists(alias -> '
			+ 'alias.startsWith(key))\n\t\t\t) : bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n\t\t);\n\t}\n}'
		);
	}

	/**
	 * When a branch breaks on the tail line, what follows the ternary lands on a later line: a first tail line of
	 * exactly the limit stays glued although `);` follows the ternary.
	 */
	@:pin('control')
	@:killer('M-TERNARY-TAIL-BREAKS-CHARGES-REST')
	public function testBreakingBranchLeavesTheRestUncharged(): Void {
		assertLaidOut(
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (item.ok && (accepts(item, key) '
			+ '|| item.children.exists(child -> child.startsWith(key)) || item.aliases.exists(alias -> alias.startsWith(key))) ? '
			+ 'item.eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee '
			+ '&& (accepts(item, key) || item.children.exists(child -> child.startsWith(key)) || item.aliases.exists(a'
			+ 'lias -> alias.startsWith(key))) : bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb);\n\t}\n}',
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (item.ok && (\n\t\t\taccepts(item, key) || '
			+ 'item.children.exists(child -> child.startsWith(key))\n\t\t\t|| item.aliases.exists(alias -> alias.startsWith(key))\n\t\t) ? '
			+ 'item.eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee '
			+ '&& (\n\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n\t\t\t|| item.aliases.exists(alias '
			+ '-> alias.startsWith(key))\n\t\t) : bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb);\n\t}\n}',
			GLUED_PAREN_CONFIG
		);
	}

	/**
	 * A first tail line ending where a branch opens its group glues at exactly the limit and breaks the seams one
	 * column past it.
	 */
	@:pin('control')
	@:killer('M-TERNARY-TAIL-BREAKS-OFF-BY-ONE')
	public function testBreakingBranchTailBreaksOnePastTheLimit(): Void {
		assertLaidOut(
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (item.ok && (accepts(item, key) '
			+ '|| item.children.exists(child -> child.startsWith(key)) || item.aliases.exists(alias -> alias.startsWith(key))) '
			+ '? item.eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee '
			+ '&& (accepts(item, key) || item.children.exists(child -> child.startsWith(key)) || item.aliases.exists(alias'
			+ ' -> alias.startsWith(key))) : bbb);\n\t}\n}',
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (\n\t\t\titem.ok && (\n'
			+ '\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n\t\t\t\t|| item.aliases.exists(alias -> '
			+ 'alias.startsWith(key))\n\t\t\t) ? item.eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
			+ 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee && (\n\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n'
			+ '\t\t\t\t|| item.aliases.exists(alias -> alias.startsWith(key))\n\t\t\t) : bbb\n\t\t);\n\t}\n}'
		);
		assertLaidOut(
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (item.ok && (accepts(item, key) '
			+ '|| item.children.exists(child -> child.startsWith(key)) || item.aliases.exists(alias -> alias.startsWith(key))) '
			+ '? item.eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee '
			+ '&& (accepts(item, key) || item.children.exists(child -> child.startsWith(key)) || item.aliases.exists(alia'
			+ 's -> alias.startsWith(key))) : bbb);\n\t}\n}',
			'class C {\n\tfunction pick(item:Item, key:String):String {\n\t\treturn (\n\t\t\titem.ok && (\n'
			+ '\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n'
			+ '\t\t\t\t|| item.aliases.exists(alias -> alias.startsWith(key))\n\t\t\t)\n\t\t\t\t? '
			+ 'item.eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n'
			+ '\t\t\t\t\t&& (\n\t\t\t\t\t\taccepts(item, key) || item.children.exists(child -> child.startsWith(key))\n'
			+ '\t\t\t\t\t\t|| item.aliases.exists(alias -> alias.startsWith(key))\n\t\t\t\t\t)\n\t\t\t\t: bbb\n\t\t);\n\t}\n}'
		);
	}

	private function assertLaidOut(flat: String, expected: String, ?config: String): Void {
		final json: String = config ?? CONFIG;
		Assert.equals(expected, HxWriteFixture.triviaWrite(flat, json));
		Assert.equals(expected, HxWriteFixture.triviaWrite(expected, json));
	}

}
