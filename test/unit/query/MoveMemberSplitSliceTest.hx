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
 * `MoveMember.move` on the shapes splitting a god type meets: a moved body naming a sub-module type of its own module,
 * a group of moved members sharing one private-access need, bare static callers kept bare through a module-static
 * wildcard, the fields a moved group alone owns, and receiver-qualified instance callers routed through the field that
 * holds the destination. Pure and in-memory, like `MoveMemberSliceTest`; every result shape is compile-proved on Haxe
 * 4.3.7 in its own test's doc.
 */
class MoveMemberSplitSliceTest extends Test {

	/**
	 * A moved body that names a SUB-module type of the source module (`typedef Pair` beside `class A`) reaches it with no
	 * statement: inside its own module it is visible bare, from any other file — a sibling of the same package included —
	 * it is `Type not found`. The move refused with "no import to carry"; the destination now gains `import pkg.A.Pair;`.
	 * Compile-proved on 4.3.7: the moved `sum` returns 3 from `pkg.B` as it did from `pkg.A`.
	 */
	@:pin('control')
	@:killer('M-CARRY-OWN-SUB-UNCARRIED')
	public function testASourceSubModuleTypeIsImportedAtTheDestination(): Void {
		final a: String = 'package pkg;\n\ntypedef Pair = {\n\tvar a:Int;\n\tvar b:Int;\n}\n\nclass A {\n'
			+ '\tpublic static function sum(p:Pair):Int return p.a + p.b;\n}';
		final newB: String = okSource(move('pkg/A.hx', 'A', 'sum', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		]), 'pkg/B.hx');
		Assert.isTrue(newB.contains('import pkg.A.Pair;'), newB);
		Assert.isTrue(newB.contains('public static function sum(p:Pair):Int'), newB);
	}

	private static function move(
		srcFile: String, srcType: String, members: String, destType: String, scopeFiles: Array<{ file: String, source: String }>,
		?via: String
	): MoveResult {
		return MoveMember.move(
			srcFile, srcType, members.split(','), destType, via, false, false, scopeFiles, new HaxeQueryPlugin(),
			new HaxeQueryPlugin().typeRefShape()
		);
	}

	/** The new source of `file` in an `Ok` result — every rewritten file re-parsed first — or a failed assertion. */
	private static function okSource(result: MoveResult, file: String): String {
		switch result {
			case Ok(changes, _):
				for (c in changes) {
					var parsed: Bool = true;
					try
						new HaxeQueryPlugin().parseFile(c.newSource)
					catch (_: haxe.Exception)
						parsed = false;
					Assert.isTrue(parsed, 'rewritten ${c.file} should re-parse');
				}
				final change: Null<MoveChange> = changes.find(c -> c.file == file);
				if (change != null) return change.newSource;
				Assert.fail('no change for file $file');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
		return '';
	}

}
