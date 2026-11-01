package unit.format;

import unit.grammar.haxe.HxWriteFixture;

/**
 * A paren group operand of an `&&` / `||` chain whose own `||` / `&&` content does not fit on the line lays out as a
 * container: `(` ends the line, the inner chain one indent deeper with its continuation lines co-indented, `)` on its
 * own line; a group that fits stays whole. Every expected shape is also a fix-point of the writer.
 */
@:nullSafety(Strict)
final class BoolChainParenGroupTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "opBoolChain": {"defaultWrap": "noWrap", "rules": ['
		+ '{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
		+ '{"conditions": [{"cond": "totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": '
		+ '"noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, '
		+ '"conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": '
		+ '"exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", '
		+ '"rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": '
		+ '"itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	/**
	 * A lambda body `a && (<chain that does not fit>)` stays on the `->` line: the paren group opens as a container, its `||`
	 * chain fills one indent deeper with co-indented continuation lines, `)` on its own line. The container shape is a fix-point.
	 */
	public function testLambdaBodyKeepsTheContainerShape(): Void {
		assertLaidOut(
			'class C {\n\tfunction lambda(key:String, prefix:String):Bool {\n'
			+ '\t\treturn items.exists((item:Item) -> item.enabled && (accepts(item, key) || item.children.exists((child:String) '
			+ '-> child.startsWith(prefix)) || item.aliases.exists((alias:String) -> alias.startsWith(prefix))));\n\t}\n}',
			'class C {\n\tfunction lambda(key:String, prefix:String):Bool {\n\t\treturn items.exists(\n\t\t\t(item:Item) '
			+ '-> item.enabled && (\n\t\t\t\taccepts(item, key) || item.children.exists((child:String) -> child.startsWith(prefix))\n'
			+ '\t\t\t\t|| item.aliases.exists((alias:String) -> alias.startsWith(prefix))\n\t\t\t)\n\t\t);\n\t}\n}'
		);
	}

	/**
	 * The same shape as a `return` value: `x && (` ends the `return` line
	 * instead of the inner chain starting on the outer `&&` seam line.
	 */
	public function testReturnValueOpensTheParenGroup(): Void {
		assertLaidOut(
			'class C {\n\tfunction ret(item:Item, key:String, prefix:String):Bool {\n'
			+ '\t\treturn item.enabled && (accepts(item, key) || item.children.exists((child:String) -> child.startsWith(prefix)) '
			+ '|| item.aliases.exists((alias:String) -> alias.startsWith(prefix)));\n\t}\n}',
			'class C {\n\tfunction ret(item:Item, key:String, prefix:String):Bool {\n\t\treturn item.enabled && (\n'
			+ '\t\t\taccepts(item, key) || item.children.exists((child:String) -> child.startsWith(prefix))\n'
			+ '\t\t\t|| item.aliases.exists((alias:String) -> alias.startsWith(prefix))\n\t\t);\n\t}\n}'
		);
	}

	/** The same shape as an `if` condition: the condition paren opens, and inside it the group opens as a container again. */
	public function testIfConditionOpensTheParenGroup(): Void {
		assertLaidOut(
			'class C {\n\tfunction cond(item:Item, key:String, prefix:String):Void {\n'
			+ '\t\tif (item.enabled && (accepts(item, key) || item.children.exists((child:String) -> child.startsWith(prefix)) '
			+ '|| item.aliases.exists((alias:String) -> alias.startsWith(prefix)))) trace(item);\n\t}\n}',
			'class C {\n\tfunction cond(item:Item, key:String, prefix:String):Void {\n\t\tif (\n\t\t\titem.enabled && (\n'
			+ '\t\t\t\taccepts(item, key) || item.children.exists((child:String) -> child.startsWith(prefix))\n'
			+ '\t\t\t\t|| item.aliases.exists((alias:String) -> alias.startsWith(prefix))\n\t\t\t)\n\t\t)\n\t\t\ttrace(item);\n\t}\n}'
		);
	}

	/** `||` outside with an `&&` chain inside the group lays out the same way. */
	public function testOrOutsideAndInsideOpensTheParenGroup(): Void {
		assertLaidOut(
			'class C {\n\tfunction swapped(item:Item, key:String, prefix:String):Bool {\n'
			+ '\t\treturn item.enabled || (accepts(item, key) && item.children.exists((child:String) -> child.startsWith(prefix)) '
			+ '&& item.aliases.exists((alias:String) -> alias.startsWith(prefix)));\n\t}\n}',
			'class C {\n\tfunction swapped(item:Item, key:String, prefix:String):Bool {\n\t\treturn item.enabled || (\n'
			+ '\t\t\taccepts(item, key) && item.children.exists((child:String) -> child.startsWith(prefix))\n'
			+ '\t\t\t&& item.aliases.exists((alias:String) -> alias.startsWith(prefix))\n\t\t);\n\t}\n}'
		);
	}

	/** When the outer chain glued up to `(` would overflow, the outer seams break first and the group opens on its own seam line. */
	public function testOuterSeamsBreakBeforeTheGroupOpens(): Void {
		assertLaidOut(
			'class C {\n\tfunction outerFirst():Bool {\n'
			+ '\t\treturn firstConditionHoldsForThisItem && secondConditionHoldsForThisItemAsWellAsTheOtherOnes && '
			+ 'thirdConditionHoldsForThisItemTooAndMore && (alphaChoiceIsAvailable || betaChoiceIsAvailableForThisItem || '
			+ 'gammaChoiceIsAvailableForThisItemToo || deltaChoiceIsAvailableForThisItemAsWell);\n\t}\n}',
			'class C {\n\tfunction outerFirst():Bool {\n'
			+ '\t\treturn firstConditionHoldsForThisItem && secondConditionHoldsForThisItemAsWellAsTheOtherOnes\n\t\t\t&& '
			+ 'thirdConditionHoldsForThisItemTooAndMore\n\t\t\t&& (\n\t\t\t\talphaChoiceIsAvailable || betaChoiceIsAvailableForThisItem || '
			+ 'gammaChoiceIsAvailableForThisItemToo\n\t\t\t\t|| deltaChoiceIsAvailableForThisItemAsWell\n\t\t\t);\n\t}\n}'
		);
	}

	/**
	 * A mixed chain whose glued head up to `(` overflows only when counted flat (its natural first line would end
	 * early at the `==` operand's own break) breaks its seams first; the group still opens on its seam line.
	 */
	public function testMixedChainCountsTheGluedHeadFlat(): Void {
		assertLaidOut(
			'class C {\n\tfunction mixed():Bool {\n\t\treturn switch kind {\n\t\t\tcase _:\n\t\t\t\t!hasOwner && '
			+ 'TextTools.lastSegment(entry.raw) == name || split != null && TextTools.isUpperInitial(TextTools.lastSegment(entry.raw)) && ('
			+ 'types == null || carriesValue(types, name) || split.rest.length == 0 && index.filesOfModule(split.module).exists(f -> '
			+ 'f.fields.exists(m -> m.name == name)));\n\t\t}\n\t}\n}',
			'class C {\n\tfunction mixed():Bool {\n\t\treturn switch kind {\n\t\t\tcase _:\n\t\t\t\t!hasOwner\n'
			+ '\t\t\t\t\t&& TextTools.lastSegment(entry.raw) == name\n\t\t\t\t\t|| split != null\n'
			+ '\t\t\t\t\t&& TextTools.isUpperInitial(TextTools.lastSegment(entry.raw))\n\t\t\t\t\t&& (\n\t\t\t\t\t\ttypes == null\n'
			+ '\t\t\t\t\t\t|| carriesValue(types, name)\n\t\t\t\t\t\t|| split.rest.length == 0\n\t\t\t\t\t\t&& '
			+ 'index.filesOfModule(split.module).exists(f -> f.fields.exists(m -> m.name == name))\n\t\t\t\t\t);\n\t\t}\n\t}\n}',
			'{"wrapping": {"maxLineLength": 140}}'
		);
	}

	/** A paren group that fits on the line stays whole. */
	public function testFittingGroupStaysWhole(): Void {
		final src: String = 'class C {\n\tfunction fits(item:Item, key:String):Bool {\n'
			+ '\t\treturn item.enabled && (accepts(item, key) || item.children.length > 0 || item.aliases.length > 0);\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, CONFIG));
	}

	private function assertLaidOut(flat: String, expected: String, ?config: String): Void {
		final json: String = config ?? CONFIG;
		Assert.equals(expected, HxWriteFixture.triviaWrite(flat, json));
		Assert.equals(expected, HxWriteFixture.triviaWrite(expected, json));
	}

}
