package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.trivia.Pairs.HxStatementT;
import anyparse.runtime.ParseError;
import utest.Assert;
import utest.Test;

/**
 * The node entries of the generated trivia parser: each reads a text as exactly one node of its type, and refuses a
 * text that is anything more or anything else.
 */
@:nullSafety(Strict)
class HaxeTriviaParserEntryTest extends Test {

	/** Each entry reads the one node its text spells, with whitespace around it. */
	public function testEachEntryReadsTheOneNodeItsTextSpells(): Void {
		Assert.equals('Array<Int>', HaxeModuleTriviaWriter.writeHxTypeNode(HaxeModuleTriviaParser.parseHxTypeNode(' Array<Int> ')));
		Assert.equals('a + b', HaxeModuleTriviaWriter.writeHxExprNode(HaxeModuleTriviaParser.parseHxExprNode('a + b')));
		Assert.notNull(HaxeModuleTriviaParser.parseHxFnBodyNode('return a;'));
		Assert.notNull(HaxeModuleTriviaParser.parseHxLambdaParamNode('x: Int'));
		Assert.notNull(HaxeModuleTriviaParser.parseHxWildPathNode('a.b.*'));
		Assert.notNull(HaxeModuleTriviaParser.parseHxImportAliasNode('a.b.C as D'));
		Assert.notNull(HaxeModuleTriviaParser.parseHxImportAliasInNode('a.b.C in D'));
		Assert.notNull(HaxeModuleTriviaParser.parseHxTypeNameNode('a.b.C'));
		Assert.equals(2, statementsOf(HaxeModuleTriviaParser.parseHxStatementBlockStmtInterior('f();\ng();')));
	}

	/** A text that spells one node and then more is refused by every entry, never answered with its first node. */
	@:pin('control')
	@:killer('M-PARSER-ENTRY-UNCHECKED-TAIL')
	public function testATextMakingMoreThanOneNodeIsRefused(): Void {
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxTypeNode('Int, String'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxExprNode('a; b'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxFnBodyNode('{} {}'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxLambdaParamNode('x, y'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxWildPathNode('a.b.*; class X {}'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxImportAliasNode('a.b.C as D as E'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxImportAliasInNode('a.b.C in D;'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxTypeNameNode('a.b.C D'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxStatementBlockStmtInterior('f(); } {'), ParseError);
	}

	/** A text whose braces would make some other statement than a block, an object literal here, is no block interior. */
	@:pin('control')
	@:killer('M-PARSER-ENTRY-ANY-CTOR')
	public function testAnInteriorThatIsNoBlockIsRefused(): Void {
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxStatementBlockStmtInterior('a: 1'), ParseError);
		Assert.equals(1, statementsOf(HaxeModuleTriviaParser.parseHxStatementBlockStmtInterior('a = 1;')));
	}

	/** A comment before or after the one node, of either style, is refused: the node has no slot to keep it in. */
	@:pin('control')
	@:killer('M-PARSER-ENTRY-COMMENT-DROPPED')
	public function testACommentOutsideTheNodeIsRefused(): Void {
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxExprNode('x // c'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxExprNode('a\n// c'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxExprNode('x /* c */'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxExprNode('// c\nx'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxExprNode('/* c */ x'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxTypeNode('Int // c'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxTypeNameNode('a.b.C // c'), ParseError);
		Assert.raises(() -> HaxeModuleTriviaParser.parseHxFnBodyNode('{ a(); }\n// c'), ParseError);
		Assert.equals('x', HaxeModuleTriviaWriter.writeHxExprNode(HaxeModuleTriviaParser.parseHxExprNode(' \n\tx \n')));
	}

	private static function statementsOf(block: HxStatementT): Int {
		return switch block {
			case BlockStmt(stmts, _, _, _, _, _): stmts.length;
			case _: -1;
		};
	}

}
