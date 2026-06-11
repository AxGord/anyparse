package unit;

import utest.Test;
import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.CommentEmptyLinesPolicy;

/**
 * Regression guard for `emptylines/issue_147_between_fields_with_comments`
 * — extern class with split-leading on the last member (line-comment run
 * sandwiched between two `/**` doc comments). With
 * `externExistingBetweenFields=Remove`, the engine must strip the
 * inter-member source blank AND suppress the
 * `beforeDocCommentEmptyLines` add at that slot, leaving only the
 * intra-leading blank from `blankBeforeFinalDocCommentInLeading`.
 */
class Probe147 extends Test {

	private static final _forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	public function testIssue147(): Void {
		final src: String = 'extern class Selection {\n' + '\t/**\n\t * A.\n\t */\n\tvar isReversed:Bool;\n\n'
			+ '\t/**\n\t * B.\n\t */\n\t// foo\n\tfunction new():Void;\n\n'
			+ '\t/**\n\t * C.\n\t */\n\t// foo\n\t// foo\n\tfunction main():Void;\n\n'
			+ '\t/**\n\t * D.\n\t */\n\t// foo\n\t// foo\n\t/**\n\t * E.\n\t */\n\tfunction main2():Void;\n}\n';
		final expected: String = 'extern class Selection {\n' + '\t/**\n\t * A.\n\t */\n\tvar isReversed:Bool;\n\n'
			+ '\t/**\n\t * B.\n\t */\n\t// foo\n\tfunction new():Void;\n\n'
			+ '\t/**\n\t * C.\n\t */\n\t// foo\n\t// foo\n\tfunction main():Void;\n'
			+ '\t/**\n\t * D.\n\t */\n\t// foo\n\t// foo\n\n\t/**\n\t * E.\n\t */\n\tfunction main2():Void;\n}\n';
		final m: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(src);
		final opt: HxModuleWriteOptions = Reflect.copy(HaxeFormat.instance.defaultWriteOptions);
		opt.afterFieldsWithDocComments = CommentEmptyLinesPolicy.Ignore;
		opt.externExistingBetweenFields = KeepEmptyLinesPolicy.Remove;
		final out: String = HaxeModuleTriviaWriter.write(m, opt);
		Assert.equals(expected, out);
	}

}
