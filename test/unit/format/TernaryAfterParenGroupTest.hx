package unit.format;

import unit.grammar.haxe.HxWriteFixture;

using StringTools;

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

	/** A paren group whose `||` chain overflows the line, so it opens as a container. */
	private static final GROUP: String = '(accepts(item, key) || item.children.exists(child -> child.startsWith(key)) '
		+ '|| item.aliases.exists(alias -> alias.startsWith(key)))';

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

	/**
	 * The head up to the condition's own break overflows, so the ternary breaks its seams as its own instead of gluing
	 * `? a : b` behind a head line past the limit.
	 */
	@:pin('control')
	@:killer('M-TERNARY-HEAD-GATE-OFF')
	public function testOverflowingHeadBreaksTheTernarySeams(): Void {
		assertLaidOut(
			cls('\t\treturn (item.' + rep('a', 119) + ' && $GROUP ? shownLabel : hiddenLabel);'),
			cls(
				'\t\treturn (\n\t\t\titem.'
				+ rep('a', 119)
				+ '\n\t\t\t\t&& (\n${opened(5)}\t\t\t\t)\n\t\t\t\t? shownLabel\n\t\t\t\t: hiddenLabel\n\t\t);'
			)
		);
	}

	/**
	 * A head of exactly the limit stays glued.
	 */
	@:pin('control')
	@:killer('M-TERNARY-HEAD-LIMIT-LOW')
	public function testHeadAtTheLimitStaysGlued(): Void {
		assertLaidOut(
			cls('\t\treturn (item.' + rep('a', 118) + ' && $GROUP ? shownLabel : hiddenLabel);'),
			cls('\t\treturn (\n\t\t\titem.' + rep('a', 118) + ' && (\n${opened(4)}\t\t\t) ? shownLabel : hiddenLabel\n\t\t);')
		);
	}

	/**
	 * Outside a kept paren the ternary's pivot is rest-aware, and a fitting tail still rides the closing line of the
	 * group the condition opens, as a statement initializer and as a call argument.
	 */
	@:pin('control')
	@:killer('M-TERNARY-REST-AWARE-GLUE-OFF')
	public function testRestAwareTernaryGluesAfterAnOpenedGroup(): Void {
		assertLaidOut(
			cls('\t\tfinal y = item.enabled && $GROUP ? x : z;'), cls('\t\tfinal y = item.enabled && (\n${opened(3)}\t\t) ? x : z;')
		);
		assertLaidOut(cls('\t\tfoo(item.enabled && $GROUP ? x : z);'), cls('\t\tfoo(item.enabled && (\n${opened(3)}\t\t) ? x : z);'));
	}

	/**
	 * The rest-aware glue is width-checked as well, `;` included: a tail line of exactly the limit stays, one column
	 * more breaks the seams.
	 */
	public function testRestAwareTailIsWidthChecked(): Void {
		assertLaidOut(
			cls('\t\tfinal y = item.enabled && $GROUP ? ' + rep('a', 62) + ' : ' + rep('b', 62) + ';'),
			cls('\t\tfinal y = item.enabled && (\n${opened(3)}\t\t) ? ' + rep('a', 62) + ' : ' + rep('b', 62) + ';')
		);
		assertLaidOut(
			cls('\t\tfinal y = item.enabled && $GROUP ? ' + rep('a', 62) + ' : ' + rep('b', 63) + ';'),
			cls('\t\tfinal y = item.enabled && (\n${opened(3)}\t\t)\n\t\t\t? ' + rep('a', 62) + '\n\t\t\t: ' + rep('b', 63) + ';')
		);
	}

	/**
	 * A then-branch that opens its group leaves a `) : else` line: past the limit the seams break, at it they stay.
	 */
	@:pin('control')
	@:killer('M-TERNARY-CLOSING-GATE-OFF')
	public function testClosingLineOfAnOpenedThenBranchIsWidthChecked(): Void {
		final flat: String = '\t\treturn (item.ok && $GROUP ? item.enabled && $GROUP : ';
		assertLaidOut(
			cls(flat + rep('b', 124) + ');'),
			cls(
				'\t\treturn (\n\t\t\titem.ok && (\n${opened(4)}\t\t\t) ? item.enabled && (\n${opened(4)}\t\t\t) : '
				+ rep('b', 124)
				+ '\n\t\t);'
			)
		);
		assertLaidOut(
			cls(flat + rep('b', 125) + ');'),
			cls(
				'\t\treturn (\n\t\t\titem.ok && (\n${opened(4)}\t\t\t)\n\t\t\t\t? item.enabled && (\n${opened(5)}\t\t\t\t)\n\t\t\t\t: '
				+ rep('b', 125)
				+ '\n\t\t);'
			)
		);
	}

	/**
	 * Inside a paren that stays glued, what follows the else branch shares the `) : else` line and is charged: a line of
	 * exactly the limit keeps the seams, one column more breaks them.
	 */
	@:pin('control')
	@:killer('M-TERNARY-CLOSING-REST-OFF')
	public function testClosingLineChargesTheRestOfTheLine(): Void {
		final flat: String = '\t\treturn wrap((item.ok && $GROUP ? item.enabled && $GROUP : ';
		assertLaidOut(
			cls(flat + rep('b', 122) + '), other);'),
			cls(
				'\t\treturn wrap(\n\t\t\t(item.ok && (\n${opened(4)}\t\t\t) ? item.enabled && (\n${opened(4)}\t\t\t) : '
				+ rep('b', 122)
				+ '),\n\t\t\tother\n\t\t);'
			),
			GLUED_PAREN_CONFIG
		);
		assertLaidOut(
			cls(flat + rep('b', 123) + '), other);'),
			cls(
				'\t\treturn wrap(\n\t\t\t(item.ok && (\n${opened(4)}\t\t\t)\n\t\t\t\t? item.enabled && (\n${opened(5)}\t\t\t\t)\n'
				+ '\t\t\t\t: '
				+ rep('b', 123)
				+ '),\n\t\t\tother\n\t\t);'
			),
			GLUED_PAREN_CONFIG
		);
	}

	/**
	 * After a host that leaves a separator pending (`final y = `), the head line counts it: a head of exactly the
	 * limit stays glued, one column more breaks the ternary's seams.
	 */
	@:pin('control')
	@:killer('M-TERNARY-HEAD-PENDING-OFF')
	public function testInitializerHeadIsChargedItsSeparator(): Void {
		assertLaidOut(
			cls('\t\tfinal y = item.' + rep('a', 112) + ' && $GROUP ? x : z;'),
			cls('\t\tfinal y = item.' + rep('a', 112) + ' && (\n${opened(3)}\t\t) ? x : z;')
		);
		assertLaidOut(
			cls('\t\tfinal y = item.' + rep('a', 113) + ' && $GROUP ? x : z;'),
			cls('\t\tfinal y = item.' + rep('a', 113) + '\n\t\t\t&& (\n${opened(4)}\t\t\t)\n\t\t\t? x\n\t\t\t: z;')
		);
	}

	/**
	 * An else branch that opens its own group leaves the `) : else` line at its first break, and what follows lands
	 * later: a line of exactly the limit stays glued, one column more breaks the seams.
	 */
	@:pin('control')
	@:killer('M-TERNARY-CLOSING-ELSE-BREAKS-CHARGES-REST')
	@:killer('M-TERNARY-CLOSING-ELSE-BREAKS-OFF-BY-ONE')
	@:killer('M-TERNARY-ELSE-BREAKS-UNDETECTED')
	public function testOpeningElseLeavesTheClosingLineUncharged(): Void {
		// Inside a paren that stays glued the `),` that follows lands on a later line, so it is not charged to the closing line.
		assertLaidOut(
			cls('\t\treturn wrap((item.ok && $GROUP ? item.enabled && $GROUP : item.${rep('b', 114)} && $GROUP), other);'),
			cls(
				'\t\treturn wrap(\n\t\t\t(item.ok && (\n${opened(4)}\t\t\t) ? item.enabled && (\n${opened(4)}\t\t\t) : item.'
				+ rep('b', 114)
				+ ' && (\n${opened(4)}\t\t\t)),\n\t\t\tother\n\t\t);'
			),
			GLUED_PAREN_CONFIG
		);
		final flat: String = '\t\treturn (item.ok && $GROUP ? item.enabled && $GROUP : item.';
		assertLaidOut(
			cls((flat + rep('b', 114)) + ' && $GROUP);'),
			cls(
				'\t\treturn (\n\t\t\titem.ok && (\n${opened(4)}\t\t\t) ? item.enabled && (\n${opened(4)}\t\t\t) : item.'
				+ rep('b', 114)
				+ ' && (\n${opened(4)}\t\t\t)\n\t\t);'
			)
		);
		assertLaidOut(
			cls((flat + rep('b', 115)) + ' && $GROUP);'),
			cls(
				'\t\treturn (\n\t\t\titem.ok && (\n${opened(4)}\t\t\t)\n\t\t\t\t? item.enabled && (\n${opened(5)}\t\t\t\t)\n'
				+ '\t\t\t\t: item.'
				+ rep('b', 115)
				+ '\n\t\t\t\t\t&& (\n${opened(6)}\t\t\t\t\t)\n\t\t);'
			)
		);
	}

	/**
	 * The `) : else` line of a rest-aware ternary carries the `;`: a line of exactly the limit stays glued, one
	 * column more breaks the seams.
	 */
	public function testRestAwareClosingLineIsWidthChecked(): Void {
		final flat: String = '\t\tfinal y = item.ok && $GROUP ? item.enabled && $GROUP : ';
		assertLaidOut(
			cls(flat + rep('b', 127) + ';'),
			cls('\t\tfinal y = item.ok && (\n${opened(3)}\t\t) ? item.enabled && (\n${opened(3)}\t\t) : ' + rep('b', 127) + ';')
		);
		assertLaidOut(
			cls(flat + rep('b', 128) + ';'),
			cls(
				'\t\tfinal y = item.ok && (\n${opened(3)}\t\t)\n\t\t\t? item.enabled && (\n${opened(4)}\t\t\t)\n\t\t\t: '
				+ rep('b', 128)
				+ ';'
			)
		);
	}

	private function assertLaidOut(flat: String, expected: String, ?config: String): Void {
		final json: String = config ?? CONFIG;
		Assert.equals(expected, HxWriteFixture.triviaWrite(flat, json));
		Assert.equals(expected, HxWriteFixture.triviaWrite(expected, json));
	}

	private static function rep(c: String, n: Int): String {
		return ''.lpad(c, n);
	}

	/** The two lines of the group's content, `tabs` deep. */
	private static function opened(tabs: Int): String {
		final t: String = rep('\t', tabs);
		return '${t}accepts(item, key) || item.children.exists(child -> child.startsWith(key))\n$t'
			+ '|| item.aliases.exists(alias -> alias.startsWith(key))\n';
	}

	private static function cls(body: String): String {
		return 'class C {\n\tfunction pick(item:Item, key:String):String {\n$body\n\t}\n}';
	}

}
