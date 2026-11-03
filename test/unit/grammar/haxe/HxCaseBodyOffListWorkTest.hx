package unit.grammar.haxe;

import anyparse.grammar.haxe.AstPredsT;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * What an off `caseSiblings` costs the writer per branch: the facts a body below its head hands over are read only
 * by the hook, so a list that does not share never asks them. Spied at the glue predicate, the one fact that is a call.
 */
final class HxCaseBodyOffListWorkTest extends Test {

	/** Both bodies are held below their labels by a comment, so neither reaches the fit arm, which reads the predicate for itself. */
	private static final HELD_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n'
		+ '\t\t\tcase 1:\n\t\t\t\t// a\n\t\t\t\taa(bb);\n\t\t\tcase 2:\n\t\t\t\t// b\n\t\t\t\tcc(dd);\n\t\t}\n\t}\n}\n';

	/** `bodySlot` is inline: an ordinary call would evaluate its plain arguments before the policy test. */
	@:pin('control')
	@:killer('M-SIBLING-BODY-SLOT-NOT-INLINE')
	public function testAnOffListAsksNoFactOfABodyBelowItsHead(): Void {
		Assert.equals(0, glueReads('off', 'fitLine'));
		Assert.equals(0, glueReads('off', 'next'));
	}

	/** The spy sees the predicate when a list does share, so the zeros above measure something. */
	public function testASharingListAsksTheFact(): Void {
		Assert.isTrue(glueReads('anyBreak', 'fitLine') > 0);
	}

	private static function glueReads(siblings: String, caseBody: String): Int {
		final name: String = 'caseBodyControlFlowRoot';
		final original: Any = Reflect.field(AstPredsT, name);
		var reads: Int = 0;
		final spy: Any = Reflect.makeVarArgs(args -> {
			reads++;
			return Reflect.callMethod(AstPredsT, original, args);
		});
		final config: String = '{"sameLine": {"caseSiblings": "$siblings", "caseBody": "$caseBody", "expressionCase": "$caseBody"}}';
		Reflect.setField(AstPredsT, name, spy);
		HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(HELD_SRC), HaxeFormatConfigLoader.loadHxFormatJson(config));
		Reflect.setField(AstPredsT, name, original);
		return reads;
	}

}
