package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.MutationSchema;
import anyparse.query.QueryNode;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * Unit cover for `apq mutation-schema` — the composition `tools/mutation-arm.sh` compiles every arm a copy can stand
 * for into ONE build with.
 *
 * What a composed build has to keep is the per-arm build's meaning, so the cases pin the three ways it could lose it:
 * the switch has to call the copy with every argument the original received (a rest one spread), the copy must not
 * claim a role the original has (an override, an operator), and every original line has to stay where it was — a
 * position the compiler reports for the original code is read against the per-arm build's.
 */
@:nullSafety(Strict)
class MutationSchemaTest extends Test {

	private static final SOURCE: String = 'package p;\n\nclass C {\n\n\tpublic function f(a: Int, ?b: Int, ...c: Int): Int {\n'
		+ '\t\treturn a;\n\t}\n\n\tpublic function new() {}\n\n\tfunction g(): Int return 1;\n\n\tmacro static function m() {\n'
		+ '\t\treturn null;\n\t}\n}\n';

	public function testTheSwitchCallsTheCopyWithEveryArgument(): Void {
		final composed: SchemaFile = compose([arm(1, 'FnMember:f', 'return a;', 'return -a;')]);
		Assert.isNull(composed.placements[0].skip);
		Assert.isTrue(composed.text.contains('{ if (__mutOn(1)) return __mut1_f(a, b, ...c);'), composed.text);
		Assert.isTrue(composed.text.contains('public function __mut1_f(a: Int, ?b: Int, ...c: Int): Int {\n\t\treturn -a;'), composed.text);
		Assert.isTrue(composed.text.contains('\tprivate static function __mutOn(id: Int): Bool {'));
		Assert.notNull(new HaxeQueryPlugin().parseFile(composed.text));
	}

	public function testEveryOriginalLineKeepsItsNumber(): Void {
		final composed: SchemaFile = compose([arm(1, 'FnMember:f', 'return a;', 'return -a;')]);
		final before: Array<String> = SOURCE.split('\n');
		final after: Array<String> = composed.text.split('\n');
		// the last original line is the type's closing brace, which the copy goes in front of
		for (i in 0...before.length - 2) Assert.isTrue(after[i].startsWith(before[i]), 'line ${i + 1}: ${after[i]}');
		final at: SchemaPlacement = composed.placements[0];
		Assert.equals(5, at.dispatch);
		Assert.equals('public function __mut1_f(a: Int, ?b: Int, ...c: Int): Int {', after[at.copyFrom - 1].trim());
		Assert.equals('}', after[at.copyTo - 1].trim());
	}

	public function testTwoArmsOfOneMethodEachGetASwitchAndACopy(): Void {
		final composed: SchemaFile = compose([
			arm(1, 'FnMember:f', 'return a;', 'return -a;'),
			arm(2, 'FnMember:f', 'return a;', 'return 0;')
		]);
		Assert.isTrue(composed.text.contains('if (__mutOn(1)) return __mut1_f(a, b, ...c); if (__mutOn(2))'));
		Assert.isTrue(composed.text.contains('__mut2_f(a: Int, ?b: Int, ...c: Int): Int {\n\t\treturn 0;'));
		Assert.equals(1, composed.text.split('private static function __mutOn').length - 1);
	}

	public function testWhatACopyCannotStandForIsLeftOut(): Void {
		final composed: SchemaFile = compose([
			arm(1, 'FnMember:new', '{}', '{ trace(1); }'),
			arm(2, 'FnMember:g', 'return 1;', 'return 2;'),
			arm(3, 'FnMember:m', 'return null;', 'return macro 1;')
		]);
		Assert.equals('a constructor', composed.placements[0].skip);
		Assert.equals('its body is not a block', composed.placements[1].skip);
		Assert.equals('a macro method', composed.placements[2].skip);
		Assert.equals(SOURCE, composed.text);
	}

	public function testACutOutsideItsMethodIsLeftOut(): Void {
		final mutated: String = SOURCE.replace('return a;', 'return -a;').replace('package p;', 'package q;');
		final composed: SchemaFile = MutationSchema.compose(
			SOURCE, tree(SOURCE), plugin(), [{ id: 1, select: 'FnMember:f', mutated: mutated }]
		);
		Assert.equals('the cut reached outside the method', composed.placements[0].skip);
	}

	public function testACopyDropsOverrideAndOperatorMetadata(): Void {
		final source: String =
			'class D extends C {\n\t@:op(A + B) @:keep override public function f(a: Int): Int {\n\t\treturn a;\n\t}\n}\n';
		final mutated: String = source.replace('return a;', 'return 0;');
		final composed: SchemaFile = MutationSchema.compose(
			source, tree(source), plugin(), [{ id: 4, select: 'FnMember:f', mutated: mutated }]
		);
		Assert.isTrue(composed.text.contains('\t@:keep public function __mut4_f(a: Int): Int {\n\t\treturn 0;'), composed.text);
	}

	public function testAMethodInsideAConditionalIsCopiedInsideIt(): Void {
		final source: String = 'class E {\n\t#if js\n\tstatic function h(): Int {\n\t\treturn 1;\n\t}\n\t#end\n}\n';
		final mutated: String = source.replace('return 1;', 'return 2;');
		final composed: SchemaFile = MutationSchema.compose(
			source, tree(source), plugin(), [{ id: 7, select: 'FnMember:h', mutated: mutated }]
		);
		final copy: Int = composed.text.indexOf('static function __mut7_h');
		Assert.isTrue(copy > 0 && copy < composed.text.indexOf('#end'), composed.text);
	}

	/** A module whose types are all behind `#if macro` keeps contributing no type outside one: the switch is a field. */
	public function testTheSwitchIsAFieldOfTheTypeNotAModuleType(): Void {
		final source: String = 'package p;\n#if macro\nclass M {\n\tstatic function k(): Int {\n\t\treturn 1;\n\t}\n}\n#end\n';
		final mutated: String = source.replace('return 1;', 'return 2;');
		final composed: SchemaFile = MutationSchema.compose(
			source, tree(source), plugin(), [{ id: 3, select: 'FnMember:k', mutated: mutated }]
		);
		Assert.isTrue(composed.text.endsWith('\t}\n}\n#end\n'), composed.text);
		Assert.isTrue(composed.text.indexOf('__mutOn(id: Int)') < composed.text.lastIndexOf('#end'));
	}

	private static function compose(arms: Array<SchemaArm>): SchemaFile {
		return MutationSchema.compose(SOURCE, tree(SOURCE), plugin(), arms);
	}

	private static function arm(id: Int, select: String, find: String, replace: String): SchemaArm {
		return { id: id, select: select, mutated: SOURCE.replace(find, replace) };
	}

	private static function plugin(): GrammarPlugin {
		return new HaxeQueryPlugin();
	}

	private static function tree(source: String): QueryNode {
		return plugin().parseFile(source);
	}

}
