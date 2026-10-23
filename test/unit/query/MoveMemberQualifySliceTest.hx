package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.MoveMember;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * `MoveMember.move` — the qualifier a moved static's references gain or lose: a sibling read
 * through a braceless interpolation is braced rather than prefixed, and a qualified reference
 * that lands inside the destination type is spelled bare unless a binder of the same name would
 * capture it.
 */
class MoveMemberQualifySliceTest extends Test {

	/**
	 * A sibling read through a braceless `$name` interpolation is braced, not prefixed: `$` binds a
	 * bare identifier only, so the prefix spliced as TEXT before it (`'A.$PKG.Map'`) changed the
	 * string's value in a file that still compiles.
	 */
	@:pin('control')
	@:killer('M-MOVE-MEMBER-INTERP-SIBLING-PREFIXED')
	public function testInterpolatedSiblingReadIsBraced(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static final PKG:String = \'x.y\';\n\n'
			+ '\tpublic static function name():String {\n\t\treturn \'$$PKG.Map\';\n\t}\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final newB: String = movedSource('A', 'name', [{ file: 'pkg/A.hx', source: a }, { file: 'pkg/B.hx', source: b }], 'pkg/B.hx');
		Assert.isTrue(newB.contains('return \'$${A.PKG}.Map\';'), 'the interpolation should be braced:\n$newB');
		Assert.isFalse(newB.contains('A.$$PKG'), 'a prefix outside the `$$` changes the value:\n$newB');
	}

	/**
	 * Inside the destination the moved member is the type's own: a qualified caller there, and a
	 * qualified call between two moved members, land bare instead of as `B.util(...)` inside `B`.
	 */
	public function testQualifiedCallerInsideDestinationLandsBare(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return A.helper(x) + 1;\n\n'
			+ '\tpublic static function helper(x:Int):Int return x * 2;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic static function go():Int return A.util(1);\n}';
		final newB: String = movedSource(
			'A', 'util,helper', [{ file: 'pkg/A.hx', source: a }, { file: 'pkg/B.hx', source: b }], 'pkg/B.hx'
		);
		Assert.isTrue(newB.contains('return util(1);'), 'the destination caller should land bare:\n$newB');
		Assert.isTrue(newB.contains('return helper(x) + 1;'), 'the moved-to-moved call should land bare:\n$newB');
		Assert.isFalse(newB.contains('B.'), 'no self-qualification inside B:\n$newB');
	}

	/**
	 * A destination caller whose scope binds the member's name keeps the qualifier: bare, `util`
	 * would read the parameter.
	 */
	@:pin('control')
	@:killer('M-MOVE-MEMBER-DEST-SHADOW-UNCHECKED')
	public function testQualifiedCallerUnderAShadowStaysQualified(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic static function go(util:Int):Int return A.util(util);\n}';
		final newB: String = movedSource('A', 'util', [{ file: 'pkg/A.hx', source: a }, { file: 'pkg/B.hx', source: b }], 'pkg/B.hx');
		Assert.isTrue(newB.contains('return B.util(util);'), 'the shadowed caller must stay qualified:\n$newB');
	}

	private static function movedSource(
		srcType: String, members: String, scopeFiles: Array<{ file: String, source: String }>, file: String
	): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final result: MoveResult = MoveMember.move(
			'pkg/$srcType.hx', srcType, members.split(','), 'B', null, false, false, scopeFiles, plugin, plugin.typeRefShape()
		);
		return switch result {
			case Ok(changes, _):
				final change: Null<MoveChange> = changes.find(c -> c.file == file);
				Assert.notNull(change, 'no change for $file');
				change?.newSource ?? '';
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				'';
		}
	}

}
