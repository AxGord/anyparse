package unit.query;

import anyparse.query.GrammarPlugin;
import anyparse.query.MoveMember;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.MoveToHelper;
import unit.check.haxe.expressions.RefusingConstructsPlugin;

using StringTools;

/**
 * A move that has to give the moved member a modifier (public for a private member with callers left behind, static for an
 * instance method moved into a helper) refuses where the grammar builds no such modifier, rather than moving it unchanged.
 */
@:nullSafety(Strict)
class MoveWithoutModifierTest extends Test {

	private static final A: String = 'package pkg;\n\nclass A {\n\tpublic static function run():Int return util(3);\n'
		+ '\tprivate static function util(x:Int):Int return x;\n}';
	private static final B: String = 'package pkg;\n\nclass B {}';
	private static final SRC: String = 'package a;\n\nclass Src {\n\tprivate var count: Int = 1;\n\n\tpublic function new() {}\n\n'
		+ '\tprivate function twice(v: Int): Int {\n\t\treturn v * 2 + count;\n\t}\n}\n';

	/** A private member with callers left behind needs `public` at the destination. */
	@:pin('control')
	@:killer('M-MOVE-MEMBER-PROMOTION-REFUSAL')
	public function testAPromotionTheGrammarCannotBuildRefusesTheMove(): Void {
		Assert.isTrue(moveMember(new HaxeQueryPlugin()).match(Ok(_, _)), 'the real grammar moves it');
		for (plugin in refusing()) switch moveMember(plugin) {
			case Ok(_, _):
				Assert.fail('expected a refusal');
			case Err(message):
				Assert.isTrue(message.contains('the grammar builds no public modifier'), message);
		}
	}

	/** An instance method moved into a helper becomes static. */
	@:pin('control')
	@:killer('M-MOVE-TO-HELPER-STATIC-REFUSAL')
	public function testAStaticTheGrammarCannotBuildRefusesTheMove(): Void {
		Assert.isTrue(moveToHelper(new HaxeQueryPlugin()).match(Ok(_, _)), 'the real grammar moves it');
		for (plugin in refusing()) switch moveToHelper(plugin) {
			case Ok(_, _):
				Assert.fail('expected a refusal');
			case Err(message):
				Assert.isTrue(message.contains('the grammar builds no static modifier'), message);
		}
	}

	private static function moveMember(plugin: GrammarPlugin): MoveResult {
		return MoveMember.move(
			'pkg/A.hx', 'A', ['util'],
			'B', null, false, false, [{ file: 'pkg/A.hx', source: A }, { file: 'pkg/B.hx', source: B }], plugin, plugin.typeRefShape()
		);
	}

	private static function moveToHelper(plugin: GrammarPlugin): MoveResult {
		return MoveToHelper.move(
			'a/Src.hx', 'Src', ['twice'], 'SrcMath', 'a/SrcMath.hx', 'g', [{ file: 'a/Src.hx', source: SRC }], plugin, plugin.typeRefShape()
		);
	}

	private static function refusing(): Array<GrammarPlugin> {
		return [
			new RefusingConstructsPlugin(_ -> null),
			new RefusingConstructsPlugin(c -> new RefusingConstructs(c, [], [], true))
		];
	}

}
