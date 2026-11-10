package unit.query;

import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.MoveSymbol;

using StringTools;
using Lambda;

/**
 * The dependency-import carry into a destination that already spells the import under `#if`.
 *
 * A module whose whole body sits in one `#if` holds its imports inside that region, so the import is in scope for every
 * declaration the module has — the carry must see it as present. It wrote a second copy into the same region instead, and
 * no rule reported it (`duplicate-import` sees only what the index lets through, `import-order` judges order alone).
 */
@:nullSafety(Strict)
final class MoveIntoGuardedBodyImportCarryTest extends Test {

	private static final SRC: String =
		'package a;\n\nimport haxe.Json;\n\nclass Src {\n\tpublic static function read(s: String): Dynamic return Json.parse(s);\n}\n';

	@:pin('control')
	@:killer('M-CARRY-WHOLE-BODY-GUARD-HOLDS-NOTHING')
	public function testAnImportTheWholeBodyGuardHoldsIsNotCarriedASecondTime(): Void {
		final dest: String = movedInto('package b;\n\n#if macro\nimport haxe.Json;\n\nclass Keep {\n\tpublic function new() {}\n}\n#end\n');
		Assert.equals(1, countOf(dest, 'import haxe.Json;'), 'the region already binds Json, got:\n$dest');
		Assert.isTrue(dest.contains('class Src'), 'the declaration itself should arrive, got:\n$dest');
	}

	/** An import under a further `#if` inside the whole-body guard holds in fewer builds than the arriving declaration: carried. */
	@:pin('control')
	@:killer('M-CARRY-NESTED-GUARD-HOLDS')
	public function testAnImportOnlyANestedGuardHoldsIsStillCarried(): Void {
		final dest: String = movedInto(
			'package b;\n\n#if foo\n#if bar\nimport haxe.Json;\n#end\n\nclass Keep {\n\tpublic function new() {}\n}\n#end\n'
		);
		Assert.equals(2, countOf(dest, 'import haxe.Json;'), 'the import must also arrive outside the inner guard, got:\n$dest');
	}

	/** A guard over part of the module does not cover the arriving declaration, so the carry stays unconditional. */
	@:pin('guard')
	public function testAnImportOnlyAPartialRegionHoldsIsStillCarried(): Void {
		final dest: String = movedInto('package b;\n\n#if macro\nimport haxe.Json;\n#end\n\nclass Keep {\n\tpublic function new() {}\n}\n');
		Assert.equals(2, countOf(dest, 'import haxe.Json;'), 'the unconditional import should arrive, got:\n$dest');
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

	private static function countOf(text: String, needle: String): Int {
		var count: Int = 0;
		var at: Int = text.indexOf(needle);
		while (at >= 0) {
			count++;
			at = text.indexOf(needle, at + needle.length);
		}
		return count;
	}

	private static function typeRefShape(): TypeRefShape {
		return new HaxeQueryPlugin().typeRefShape();
	}

}
