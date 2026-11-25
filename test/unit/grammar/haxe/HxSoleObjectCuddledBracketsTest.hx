package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `wrapping.soleObjectCuddledBrackets` (default `false`): an array literal whose ONLY element is an
 * object literal that breaks hugs its brackets — `[{` on the opening line, the fields one indent deeper
 * than the array's line, `}]` together on the closing line — in every host position, a call argument
 * among others included. A fitting list stays on one line; a comment beside the element, a second
 * element, a block expression or any non-object element keeps the exploded layout.
 */
@:nullSafety(Strict)
final class HxSoleObjectCuddledBracketsTest extends Test {

	/** The call-parameter cascade of this repository's own config, with the knob off. */
	private static final OFF: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140,'
		+ ' "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength",'
		+ ' "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n",'
		+ ' "value": 100}], "type": "noWrap"}]}}}';

	/** The same config with `wrapping.soleObjectCuddledBrackets` on. */
	private static final ON: String = '${OFF.substr(0, OFF.length - 2)}, "soleObjectCuddledBrackets": true}}';

	/** The same config with the wider `wrapping.soleItemCuddledBrackets` on and the object-only knob off. */
	private static final ITEM: String = '${OFF.substr(0, OFF.length - 2)}, "soleItemCuddledBrackets": true}}';

	/** The fields of an object literal too wide for one line. */
	private static final FIELDS: Array<String> = [
		"path: 'p.Cccccccccccccccccccccccccccccccccccccccccccc',",
		"name: 'q.Dddddddddddddddddddddddddddddddddddddddddddddddddddd',",
		"other: 'r.Eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'"
	];

	public function new(): Void {
		super();
	}

	/** The user's example: a sole object in the MIDDLE of a call's arguments hugs, and the arguments after it ride the `}]` line. */
	@:pin('control')
	@:killer('M-SOLE-OBJECT-CUDDLE-COMMIT')
	public function testMiddleCallArgumentCuddles(): Void {
		final src: String = body('return follow(LAYOUT, json, [\n${exploded(2)}\n\t\t], plugin);');
		final expected: String = body('return follow(LAYOUT, json, [{\n${fields(3)}\n\t\t}], plugin);');
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/** A sole object as the LAST call argument hugs without opening the call's parenthesis. */
	@:pin('control')
	@:killer('M-SOLE-OBJECT-CUDDLE-COMMIT')
	public function testLastCallArgumentCuddles(): Void {
		final src: String = body('foo(LAYOUT, json, [\n${exploded(2)}\n\t\t]);');
		final expected: String = body('foo(LAYOUT, json, [{\n${fields(3)}\n\t\t}]);');
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/** A var initializer hugs the same way. */
	@:pin('control')
	@:killer('M-SOLE-OBJECT-CUDDLE-GATE')
	public function testInitializerCuddles(): Void {
		final src: String = body('var z = [\n${exploded(2)}\n\t\t];');
		final expected: String = body('var z = [{\n${fields(3)}\n\t\t}];');
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/** A return value hugs the same way. */
	@:pin('control')
	@:killer('M-SOLE-OBJECT-CUDDLE-GATE')
	public function testReturnValueCuddles(): Void {
		final src: String = body('return [\n${exploded(2)}\n\t\t];');
		final expected: String = body('return [{\n${fields(3)}\n\t\t}];');
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/**
	 * An object that fits its own line inside a list the cascade already exploded hugs too: the break the list
	 * committed is carried into the element, so the call keeps its arguments on the call line.
	 */
	@:pin('control')
	@:killer('M-SOLE-OBJECT-CUDDLE-COMMIT')
	public function testCommittedListHugsFittingObject(): Void {
		final src: String = body(
			'return make(resolved, [\n\t\t\t{files: resolved, defines: definesValue, classPaths: classPathsValue.map(path -> '
			+ "canonical(rootValue, path))}\n\t\t], '');"
		);
		final expected: String = body(
			'return make(resolved, [{\n\t\t\tfiles: resolved,\n\t\t\tdefines: definesValue,\n'
			+ "\t\t\tclassPaths: classPathsValue.map(path -> canonical(rootValue, path))\n\t\t}], '');"
		);
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/** A ternary branch holding the list hugs it without breaking the ternary at `?` / `:`. */
	@:pin('control')
	@:killer('M-SOLE-OBJECT-CUDDLE-COMMIT')
	public function testTernaryBranchCuddles(): Void {
		final src: String = body('return patterns.length == 0 ? [] : [\n${exploded(2)}\n\t\t];');
		final expected: String = body('return patterns.length == 0 ? [] : [{\n${fields(3)}\n\t\t}];');
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/** A list nested in a call that is itself an argument hugs without opening the outer call. */
	@:pin('control')
	@:killer('M-SOLE-OBJECT-CUDDLE-FIRST-BREAK')
	public function testNestedCallArgumentCuddles(): Void {
		final src: String = body('check(\'\', planned(TREE.concat([\n${exploded(2)}\n\t\t])));');
		final expected: String = body('check(\'\', planned(TREE.concat([{\n${fields(3)}\n\t\t}])));');
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/** The hugged layout is a fixed point: writing it again changes nothing. */
	public function testCuddledLayoutIsIdempotent(): Void {
		final once: String = triviaWrite(body('return follow(LAYOUT, json, [\n${exploded(2)}\n\t\t], plugin);'), ON);
		Assert.equals(once, triviaWrite(once, ON));
	}

	/** Knob absent: the exploded layout is kept byte for byte. */
	public function testKnobOffKeepsExplodedLayout(): Void {
		final src: String = body('return follow(LAYOUT, json, [\n${exploded(2)}\n\t\t], plugin);');
		Assert.equals(src, triviaWrite(src, OFF));
	}

	/** A fitting sole object stays on one line with its brackets. */
	public function testFittingListStaysFlat(): Void {
		final src: String = body('var x = [{a: 1}];');
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** Under the wider knob a sole call element keeps the lazy glue: a ternary that fits its line stays on it. */
	@:pin('control')
	@:killer('M-SOLE-ITEM-CUDDLE-LAZY-GLUE')
	public function testWiderKnobFittingTernaryStaysFlat(): Void {
		final src: String = body("var t = cond ? [make('p.C', 'someLongMemberName', 'field', '" + ''.rpad('a', 61) + "')] : [];");
		Assert.equals(src, triviaWrite(src, ITEM));
	}

	/** A line comment before the element keeps the exploded layout. */
	public function testLeadingCommentNotCuddled(): Void {
		final src: String = body('var c = [\n\t\t\t// lead\n${exploded(2)}\n\t\t];');
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** A line comment after the element keeps the exploded layout. */
	public function testTrailingCommentNotCuddled(): Void {
		final src: String = body('var t = [\n${exploded(2)} // trail\n\t\t];');
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** Two object elements keep the exploded layout. */
	public function testTwoElementsNotCuddled(): Void {
		final src: String = body('var two = [\n${exploded(2)},\n${exploded(2)}\n\t\t];');
		Assert.equals(triviaWrite(src, OFF), triviaWrite(src, ON));
	}

	/** A sole BLOCK expression opens with `{` too, but is no object literal: it keeps the exploded layout. */
	@:pin('control')
	@:killer('M-SOLE-OBJECT-CUDDLE-KIND')
	public function testBlockElementNotCuddled(): Void {
		final src: String = body(
			'var blk = [\n\t\t\t{\n\t\t\t\ttrace(\'p.Cccccccccccccccccccccccccccccccccccccccccccc\');\n'
			+ '\t\t\t\ttrace(\'q.Dddddddddddddddddddddddddddddddddddddddddddddddddddd\');\n\t\t\t}\n\t\t];'
		);
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** A sole nested ARRAY is a container literal too, but not an object: the object knob leaves it as the knob-off layout. */
	@:pin('control')
	@:killer('M-SOLE-OBJECT-CUDDLE-BRACE')
	public function testNestedArrayElementNotCuddled(): Void {
		final src: String = body(
			'var n = [\n\t\t\t[\n\t\t\t\t'
			+ "'p.Cccccccccccccccccccccccccccccccccccccccccccc',\n\t\t\t\t'q.Dddddddddddddddddddddddddddddddddddddddddddddddddddd',\n"
			+ "\t\t\t\t'r.Eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'\n\t\t\t]\n\t\t];"
		);
		Assert.equals(triviaWrite(src, OFF), triviaWrite(src, ON));
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, HxWriteFixture.listsKeepSource(config));
	}

	/** `class C { function f() { <stmt> } }` with the statement at two tabs. */
	private static function body(stmt: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$stmt\n\t}\n}';
	}

	/** The object literal broken one field per line, its braces at `depth` tabs and its fields one deeper. */
	private static function exploded(depth: Int): String {
		final pad: String = ''.rpad('\t', depth + 1);
		return '$pad{\n${fields(depth + 2)}\n$pad}';
	}

	/** The fields one per line at `depth` tabs. */
	private static function fields(depth: Int): String {
		final pad: String = ''.rpad('\t', depth);
		return FIELDS.map(f -> pad + f).join('\n');
	}

}
