package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.MoveSymbol;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * The LEXICAL POLICY of `NameMentionScan` — the one raw-text question the move family asks of a
 * file — pinned through the op that consumes it.
 *
 * The module answers "does this source spell this name where the compiler would bind it" in three
 * shapes, and until S81 each shape assembled its own exclusion set and drifted on its own
 * schedule: S80 taught `qualifiedPathRefusal` and `namesAnyOf` to skip comment interiors and left
 * the destination collision scan counting them, so ONE doc line naming a dependency refused a
 * legitimate carry (T535). The policy the module now states once is that the mask is a property
 * of the LANGUAGE, not of the caller: a comment is never compiled, so it never counts, whether the
 * answer WRITES an import or REFUSES the move; a string CAN be read back by `Reflect` or a macro
 * and nothing rewrites one, so it always counts.
 *
 * Every test here is end-to-end through `MoveSymbol.moveType` on purpose — that is the only entry
 * point the policy has, and it is what lets these pins run unchanged against a base engine that
 * has no such module. Each carries its CONTROL in the same fixture: the arms differ in exactly one
 * thing, the lexical context the name sits in.
 */
@:nullSafety(Strict)
final class NameMentionScanTest extends Test {

	/**
	 * The DESTINATION collision scan, comment-INTERIOR against a real reference and against a string
	 * — T535 and the two controls that say why it is not simply "count less".
	 *
	 * The gate exists because a carried `import q.Dep;` outranks whatever the destination's own
	 * ambient scope binds `Dep` to, so its own references silently change meaning. Compile-proved on
	 * 4.3.7 for the middle arm: a root-package `Dep.x()` returning 2, moved past a carried
	 * `import c.Dep;`, returned 1 at rc 0 with nothing said. And compile-proved for the first arm
	 * that there is nothing to protect: the same carry past a destination whose only `Dep` is a doc
	 * line left every observable value unchanged, so the refusal was pure loss — a move a user asked
	 * for, declined with advice ("alias the import, or qualify the references") that names nothing
	 * in the file.
	 *
	 * The STRING arm is the half that must NOT move with it. A literal can be a by-name lookup and
	 * nothing in the repair walk rewrites one, so it stays a reference on both sides of the question
	 * — the same split S80 fixed `qualifiedPathRefusal` to.
	 */
	public function testACommentOnlyDestinationMentionDoesNotContestTheCarry(): Void {
		inline function moveInto(destBody: String): MoveResult {
			return MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', [
				{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {\n\n\tpublic static function tag(): Int return 1;\n\n}\n' },
				{
					file: 'p/Mover.hx',
					source: 'package p;\n\nimport q.Dep;\n\nclass Mover {\n\n\tpublic static function m(): Int return Dep.tag();\n\n}\n'
				},
				{
					file: 'p/Host.hx',
					source: 'package p;\n\nclass Host {\n\n\tpublic function new() {}\n\n\tpublic function h(): Int {\n$destBody'
					+ '\t\treturn 1;\n\t}\n\n}\n'
				}
			], plugin(), typeRefShape());
		}
		assertCarried(moveInto('\t\t// Nothing here reaches Dep any more.\n'), 'a comment-only mention does not contest the carry');
		assertRefused(moveInto('\t\tDep.tag();\n'), 'references "Dep" while nothing in the indexed scope binds it there');
		assertRefused(moveInto('\t\tfinal s: String = "Dep";\n'), 'references "Dep" while nothing in the indexed scope binds it there');
	}

	/**
	 * The FULLY-QUALIFIED path refusal, same two lexical contexts — the pin that keeps S81's rewrite
	 * of that scan (a hand-rolled `indexOf` loop, now the shared `qualifiedPathMention`) from
	 * quietly changing the policy S80 chose.
	 *
	 * A move repoints every code reference it can name and leaves a string alone, so a file spelling
	 * `p.Mover` inside `Type.resolveClass` is broken by the move and nothing repairs it: refusing is
	 * the right answer, and it is the OPPOSITE direction from the comment control beside it.
	 */
	public function testAStringSpellingTheQualifiedPathStillRefusesWhileACommentDoesNot(): Void {
		inline function moveOver(docBody: String): MoveResult {
			return MoveSymbol.moveType('p/Mover.hx', 3, 7, 'q/Host.hx', [
				{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {\n\n\tpublic static function tag(): Int return 3;\n\n}\n' },
				{ file: 'q/Host.hx', source: 'package q;\n\nclass Host {\n\n\tpublic function new() {}\n\n}\n' },
				{ file: 'r/Doc.hx', source: 'package r;\n\nclass Doc {\n\n$docBody\n}\n' }
			], plugin(), typeRefShape());
		}
		assertRefused(
			moveOver('\tpublic static function key(): String return "p.Mover";\n'), 'references "p.Mover" by its fully-qualified path'
		);
		switch moveOver('\t// Once produced by p.Mover, and by nothing since.\n\tpublic static function key(): Int return 0;\n') {
			case Ok(changes, _):
				Assert.equals(2, changes.length, 'a comment-only mention leaves r/Doc.hx out of the change list');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/** Require `result` to be `Ok` and the destination to have gained the carried `import q.Dep;`. */
	private function assertCarried(result: MoveResult, why: String): Void {
		switch result {
			case Ok(changes, _):
				final change: Null<MoveChange> = changes.find(c -> c.file == 'p/Host.hx');
				if (change == null)
					Assert.fail('no change for p/Host.hx');
				else
					Assert.isTrue(change.newSource.contains('import q.Dep;'), why);
			case Err(message):
				Assert.fail('$why — got Err: $message');
		}
	}

	/** Require `result` to be `Err` whose message contains `fragment`. */
	private function assertRefused(result: MoveResult, fragment: String): Void {
		switch result {
			case Ok(_, _):
				Assert.fail('expected Err containing "$fragment", got Ok');
			case Err(message):
				Assert.isTrue(message.contains(fragment), 'Err message must contain "$fragment", got: $message');
		}
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	private static function typeRefShape(): TypeRefShape {
		return new HaxeQueryPlugin().typeRefShape();
	}

}
