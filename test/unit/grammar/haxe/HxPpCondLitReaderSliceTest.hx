package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxClassDecl;
import utest.Assert;

/**
 * The `#if` condition terminal `HxPpCondLit` reads its extent through `HxPpCondScan.endAt`, generated from `HxPpCond`
 * and asked by the query side and the splice predicates too, instead of a regex of its own. Each test is a form the regex
 * read differently: it could not count a group past four levels, it closed a group on a quoted `)`, and it allowed
 * no blank after a `!`.
 */
@:nullSafety(Strict)
final class HxPpCondLitReaderSliceTest extends HxTestHelpers {

	/** A group nested five deep is one condition, and the region round-trips. */
	@:pin('control')
	@:killer('M-COND-GROUP-DEPTH-CAP')
	public function testDepthFiveGroupIsOneCondition(): Void {
		final source: String = 'class C {\n\t#if ((((( a )))))\n\tvar x:Int;\n\t#end\n}';
		Assert.equals('((((( a )))))', memberConditionCond(source));
		Assert.equals('$source\n', HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source)));
	}

	/** A `)` inside a quoted string does not close the group, so the whole comparison is the condition. */
	@:pin('control')
	@:killer('M-COND-GROUP-QUOTE-BLIND')
	public function testQuotedParenStaysInsideTheCondition(): Void {
		Assert.equals('(js_es == "a)")', memberConditionCond('class C { #if (js_es == "a)") var x:Int; #end }'));
	}

	/** A line break after `!` continues the condition: the operand on the next line is negated, not the region's body. */
	@:pin('control')
	@:killer('M-COND-NEGATION-OPERAND-SAME-LINE')
	public function testNegationThenLineBreakReadsTheOperand(): Void {
		Assert.equals('!\n\tsys', memberConditionCond('class C {\n\t#if !\n\tsys\n\tvar x:Int;\n\t#end\n}'));
	}

	/** A block comment inside a group is comment text: its apostrophe opens no string, and the region round-trips. */
	@:pin('control')
	@:killer('M-COND-GROUP-COMMENT-BLIND')
	public function testBlockCommentQuoteInsideGroupIsCommentText(): Void {
		final source: String = 'class C {\n\t#if (!js /* don\'t */ && !nodejs)\n\tvar x:Int;\n\t#end\n}';
		Assert.equals('(!js /* don\'t */ && !nodejs)', memberConditionCond(source));
		Assert.equals('$source\n', HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source)));
	}

	/** A `)` inside a block comment does not close the group, so the whole group is one condition. */
	@:pin('control')
	@:killer('M-COND-GROUP-COMMENT-BLIND')
	public function testBlockCommentParenInsideGroupIsCommentText(): Void {
		Assert.equals('(js /* a) */ && !nodejs)', memberConditionCond('class C { #if (js /* a) */ && !nodejs) var x:Int; #end }'));
	}

	private function memberConditionCond(source: String): String {
		final c: HxClassDecl = expectClassDecl(HaxeModuleParser.parse(source).decls[0]);
		return (expectConditionalMember(c.members[0].member).cond: String);
	}

}
