package unit.query;

import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.MoveSymbol;

using StringTools;
using Lambda;

/**
 * Where a moved type is seated in a destination whose whole body sits in one `#if` region.
 *
 * The carried import lands inside the region, so the declaration must share it: seated after the closing `#end` it
 * references a type no import binds in the builds where the region is off.
 */
@:nullSafety(Strict)
final class MoveTypeIntoGuardedDestTest extends Test {

	private static final SRC: String =
		'package a;\n\nimport haxe.Json;\n\nclass Src {\n\tpublic static function read(s: String): Dynamic return Json.parse(s);\n}\n';

	@:pin('control')
	@:killer('M-MOVE-TYPE-GUARDED-DEST-SEATS-AT-EOF')
	public function testTheMovedTypeSharesTheGuardWithItsImport(): Void {
		final dest: String = movedInto('package b;\n\n#if foo\nimport haxe.Json;\n\nclass Keep {\n\tpublic function new() {}\n}\n#end\n');
		final end: Int = dest.lastIndexOf('#end');
		Assert.isTrue(dest.indexOf('class Src') < end, 'the declaration should sit before the closing #end, got:\n$dest');
		Assert.isTrue(dest.indexOf('import haxe.Json;') < end, 'the import should sit before the closing #end, got:\n$dest');
	}

	@:pin('guard')
	public function testAnUnguardedDestinationAppendsAtTheEnd(): Void {
		final dest: String = movedInto('package b;\n\nclass Keep {\n\tpublic function new() {}\n}\n');
		Assert.isTrue(dest.indexOf('class Src') > dest.indexOf('class Keep'), 'the declaration should follow Keep, got:\n$dest');
		Assert.isFalse(dest.contains('#if'), 'no guard should appear, got:\n$dest');
	}

	private function movedInto(dest: String): String {
		final changes: Array<MoveChange> = switch MoveSymbol.moveType(
			'a/Src.hx', 5, 7, 'b/Src.hx', [{ file: 'a/Src.hx', source: SRC }, { file: 'b/Src.hx', source: dest }],
			new HaxeQueryPlugin(), typeRefShape()
		) {
			case Ok(changes, _): changes;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				[];
		};
		final change: Null<MoveChange> = changes.find(c -> c.file == 'b/Src.hx');
		if (change != null) return change.newSource;
		Assert.fail('no change for b/Src.hx');
		return '';
	}

	private static function typeRefShape(): TypeRefShape {
		return new HaxeQueryPlugin().typeRefShape();
	}

}
