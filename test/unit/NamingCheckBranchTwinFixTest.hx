package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Naming;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;

/**
 * The `naming` autofix over a member REDECLARED in mutually exclusive conditional branches — one
 * logical member that `#if ios … #elseif android …` spells twice by design.
 *
 * The shape that found it, reduced from an incident: a private key constant declared once per
 * platform branch. The rename renamed the FIRST branch's declaration and, judging the second
 * against a whole-file scan that had just gained the new name, called it a collision and answered
 * with the rule's SECOND spelling — leaving the two branches on two different names while the one
 * reference (written outside both) had already been rewritten to the first. The build compiling the
 * untouched branch reached a name nothing declared, and the next `--fix` pass deleted the stranded
 * declaration as `unused-private`. On a release branch that silently removed a Play Store licence
 * key.
 *
 * Both halves of the repair are pinned here: the twin declaration RENAMES ALONG (one edit set, both
 * branches), and a name only an exclusive branch binds is no longer a collision. The last case is
 * the discriminator — inside ONE branch the collision is real and the alt-spelling arm still owns
 * it, so the exclusivity is not a blanket weakening of the gate.
 */
class NamingCheckBranchTwinFixTest extends NamingCheckTestBase {

	/** Both branch declarations of one member reach the same new name, in one edit set. */
	public function testFixRenamesBothExclusiveBranchDeclarations(): Void {
		final src: String = 'package pkg;\nclass C {\n\t#if ios\n\tprivate static final _key:String = \'i\';\n'
			+ '\t#elseif android\n\tprivate static final _key:String = \'a\';\n\t#end\n\n' + '\tpublic function f():String return _key;\n}';
		assertFixed(src, ['final key:String = \'i\'', 'final key:String = \'a\'', 'return key;'], '_key');
	}

	/**
	 * A twin the OTHER branch already spells correctly is the target name, not a collision with it.
	 * Without this arm the rename answered `KEY` — conformant, and unreachable from the reference the
	 * conformant branch shares.
	 */
	public function testFixMatchesTheSpellingTheExclusiveBranchAlreadyUses(): Void {
		final src: String = 'package pkg;\nclass C {\n\t#if ios\n\tprivate static final key:String = \'i\';\n'
			+ '\t#elseif android\n\tprivate static final _key:String = \'a\';\n\t#end\n\n' + '\tpublic function f():String return key;\n}';
		assertFixed(src, ['final key:String = \'a\''], '_key');
	}

	/**
	 * The same two declarations INSIDE one branch compile together, so the collision is real and the
	 * alt-spelling fallback still answers it. The exclusivity is per sibling branch, not per `#if`.
	 */
	public function testFixStillTreatsASameBranchTwinAsACollision(): Void {
		final src: String = 'package pkg;\nclass C {\n\t#if ios\n\tprivate static final key:String = \'i\';\n'
			+ '\tprivate static final _key:String = \'a\';\n\t#end\n\n' + '\tpublic function f():String return key + _key;\n}';
		assertFixed(src, ['final KEY:String = \'a\'', 'return key + KEY;'], 'final _key');
	}

	/**
	 * Fix every finding of `src` in one pass and assert on the canonicalized result: each of
	 * `present` occurs, `absent` does not.
	 *
	 * `NamingCheckTestBase.assertCanonicalized` takes ONE expected substring, and a joint rename is
	 * only proven by reading both branches plus the shared reference in the same output.
	 */
	private function assertFixed(src: String, present: Array<String>, absent: String): Void {
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.isTrue(vs.length >= 1);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin(), index);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				for (p in present) Assert.isTrue(text.indexOf(p) >= 0, 'expected `$p` in:\n$text');
				Assert.isTrue(text.indexOf(absent) == -1, 'expected no `$absent` in:\n$text');
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

}
