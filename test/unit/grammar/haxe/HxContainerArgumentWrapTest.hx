package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * `callParameter.containerItemWrap` — the nested cascade that decides whether a call-bearing array / object literal
 * argument takes a line of its own when the argument list breaks, measured over the literal's own items.
 *
 * The built-in nested cascade packs a simple literal (at most three items, none a nested container, short) with its
 * neighbours and gives every other one its own line. `CONFIG` sets `callParameter` without the nested key, so these
 * fixtures also pin that a configured section inherits the built-in nested cascade.
 */
@:nullSafety(Strict)
final class HxContainerArgumentWrapTest extends Test {

	/** A project-style `callParameter` section that names no `containerItemWrap`. */
	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140,'
		+ '"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],'
		+ '"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],'
		+ '"type":"noWrap"}]}}}';

	/** `CONFIG` with a nested cascade that has no rule: every call-bearing literal argument on its own line. */
	private static final CONFIG_OWN_LINE: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140,'
		+ '"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],'
		+ '"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],'
		+ '"type":"noWrap"}],"containerItemWrap":{"defaultWrap":"onePerLine","rules":[]}}}}';

	/** A two-field object argument of a call and a three-call array argument of a `new`, both lists over the limit. */
	private static final SIMPLE_SRC: String = 'class S {\n\tfunction f() {\n\t\tregister(firstArgumentValue, {'
		+ ' name: nameValue, value: make(1) }, secondArgumentValue, thirdArgumentValue, '
		+ 'fourthArgumentValue, fifth);\n\t\tfinal built = new Builder(firstArgumentValue, [make(1), '
		+ 'make(2), make(3)], secondArgumentValue, thirdArgumentValue, fourthArgumentValue);\n\t}\n}';

	/** `SIMPLE_SRC` under `CONFIG`: each literal packs on the argument line. */
	private static final SIMPLE_OUT: String = 'class S {\n\tfunction f() {\n\t\tregister(\n\t\t\tfirstArgumentValue, {name: nameValue, '
		+ 'value: make(1)}, secondArgumentValue, thirdArgumentValue, fourthArgumentValue, fifth\n\t\t);\n'
		+ '\t\tfinal built = new Builder(\n\t\t\tfirstArgumentValue, [make(1), make(2), make(3)], '
		+ 'secondArgumentValue, thirdArgumentValue, fourthArgumentValue\n\t\t);\n\t}\n}';

	/** `SIMPLE_SRC` under `CONFIG_OWN_LINE`: each literal on a line of its own, the arguments around it packed. */
	private static final SIMPLE_OWN_LINE_OUT: String = 'class S {\n\tfunction f() {\n\t\tregister(\n\t\t\tfirstArgumentValue,\n\t\t\t'
		+ '{name: nameValue, value: make(1)},\n\t\t\tsecondArgumentValue, thirdArgumentValue, fourthArgumentValue, fifth\n\t\t);\n\t\t'
		+ 'final built = new Builder(\n\t\t\tfirstArgumentValue,\n\t\t\t[make(1), make(2), make(3)],\n\t\t\tsecondArgumentValue, '
		+ 'thirdArgumentValue, fourthArgumentValue\n\t\t);\n\t}\n}';

	/** Three literals past the simple bound: four items, a nested container, a long three-field object. */
	private static final COMPLEX_SRC: String = 'class X {\n\tfunction f() {\n'
		+ '\t\tregister(firstArgumentValue, [make(1), make(2), make(3), make(4)], secondArgumentValue, thirdArgumentValue, '
		+ 'fourthArgumentValue, fifth);\n\t\tregister(firstArgumentValue, [{ name: nameValue, value: make(1) }], secondArgumentValue, '
		+ 'thirdArgumentValue, fourthArgumentValue, fifth);\n\t\tregister(firstArgumentValue, { name: firstEntryName, value: '
		+ 'makeEntryValue(1), weight: heavyWeight }, secondArgumentValue, thirdArgument);\n\t}\n}';

	/** `COMPLEX_SRC` under `CONFIG`: every literal on a line of its own. */
	private static final COMPLEX_OUT: String = 'class X {\n\tfunction f() {\n\t\tregister(\n\t\t\tfirstArgumentValue,\n'
		+ '\t\t\t[make(1), make(2), make(3), make(4)],\n\t\t\tsecondArgumentValue, thirdArgumentValue, '
		+ 'fourthArgumentValue, fifth\n\t\t);\n\t\tregister(\n\t\t\tfirstArgumentValue,\n\t\t\t[{name: nameValue, '
		+ 'value: make(1)}],\n\t\t\tsecondArgumentValue, thirdArgumentValue, fourthArgumentValue, fifth\n\t\t);\n'
		+ '\t\tregister(\n\t\t\tfirstArgumentValue,\n\t\t\t{name: firstEntryName, value: makeEntryValue(1), '
		+ 'weight: heavyWeight},\n\t\t\tsecondArgumentValue, thirdArgument\n\t\t);\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** A simple call-bearing literal argument packs with its neighbours, in a call and in a `new`. */
	@:pin('control')
	@:killer('M-CONTAINER-ITEM-WRAP-OFF')
	public function testSimpleLiteralArgumentsFill(): Void {
		Assert.equals(SIMPLE_OUT, write(SIMPLE_SRC, CONFIG));
		Assert.equals(SIMPLE_OUT, write(SIMPLE_OUT, CONFIG));
	}

	/** Four items, a nested container, or a long literal keeps the argument on a line of its own. */
	@:pin('control')
	@:killer('M-CONTAINER-OWN-LINE-NEVER')
	public function testComplexLiteralArgumentsTakeTheirOwnLine(): Void {
		Assert.equals(COMPLEX_OUT, write(COMPLEX_SRC, CONFIG));
		Assert.equals(COMPLEX_OUT, write(COMPLEX_OUT, CONFIG));
	}

	/** A configured nested cascade replaces the built-in one: with no rule, the simple literals take their own line too. */
	@:pin('control')
	@:killer('M-CONTAINER-ITEM-WRAP-CONFIG-IGNORED')
	public function testConfiguredNestedCascadeReplacesTheDefault(): Void {
		Assert.equals(SIMPLE_OWN_LINE_OUT, write(SIMPLE_SRC, CONFIG_OWN_LINE));
		Assert.equals(SIMPLE_OWN_LINE_OUT, write(SIMPLE_OWN_LINE_OUT, CONFIG_OWN_LINE));
	}

	private inline function write(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

}
