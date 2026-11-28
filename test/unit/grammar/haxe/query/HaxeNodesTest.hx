package unit.grammar.haxe.query;

import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.query.HaxeNodes;
import anyparse.grammar.haxe.trivia.Pairs.HxClassMemberT;
import anyparse.grammar.haxe.trivia.Pairs.HxMemberDeclT;
import anyparse.grammar.haxe.trivia.Pairs.HxTypeT;
import utest.Assert;
import utest.Test;

/**
 * `HaxeNodes`: a member and a statement built as typed nodes and written alone through the generated writer's per-type
 * entries read as the canonical text of that construct.
 */
@:nullSafety(Strict)
class HaxeNodesTest extends Test {

	private static final CONSTANT: String = 'private static final byX:(Item, Item) -> Int = Cmp.asc(a -> a.x);';

	/** A constant built of its parts is written as the declaration a hand would write. */
	@:pin('control')
	@:killer('M-NODES-CONSTANT-AS-VARIABLE')
	public function testABuiltConstantIsWrittenAsItsCanonicalText(): Void {
		Assert.equals(CONSTANT, HaxeModuleTriviaWriter.writeHxMemberDeclNode(constant()));
	}

	/** A method and a statement built of their parts are written as their canonical text, each with its own terminator. */
	@:pin('control')
	@:killer('M-NODES-RETURN-UNTERMINATED')
	public function testABuiltMethodAndStatementAreWrittenAsTheirCanonicalText(): Void {
		final item: HxTypeT = sure(HaxeNodes.typeOf('Item'));
		final method: HxClassMemberT = HaxeNodes.method(
			'byX', [{ name: 'a', type: item }, { name: 'b', type: item }],
			HaxeNodes.typeOf('Int'), sure(HaxeNodes.bodyOf('return a.x - b.x;'))
		);
		Assert.equals(
			'public function byX(a:Item, b:Item):Int\n\treturn a.x - b.x;',
			HaxeModuleTriviaWriter.writeHxMemberDeclNode(HaxeNodes.memberDecl([Public], method))
		);
		Assert.equals(
			'return a.x - b.x;', HaxeModuleTriviaWriter.writeHxStatementNode(HaxeNodes.returnStmt(sure(HaxeNodes.valueOf('a.x - b.x'))))
		);
	}

	@:pin('control')
	@:killer('M-PARSER-ENTRY-UNCHECKED-TAIL')
	public function testATypeTextMakingASecondDeclaratorIsNoType(): Void {
		Assert.isNull(HaxeNodes.typeOf('Int, _w: String'));
		Assert.notNull(HaxeNodes.typeOf('Int'));
	}

	@:pin('control')
	@:killer('M-PARSER-ENTRY-UNCHECKED-TAIL')
	public function testAValueTextMakingASecondDeclaratorIsNoValue(): Void {
		Assert.isNull(HaxeNodes.valueOf('1, _w = 2'));
		Assert.notNull(HaxeNodes.valueOf('1'));
	}

	/** A part whose text carries a comment outside the node it spells is no part, so an op building with it refuses. */
	@:pin('control')
	@:killer('M-PARSER-ENTRY-COMMENT-DROPPED')
	public function testAPartCarryingAnOuterCommentIsNoPart(): Void {
		Assert.isNull(HaxeNodes.valueOf('x // c'));
		Assert.isNull(HaxeNodes.typeOf('Int // c'));
		Assert.isNull(HaxeNodes.importOf('a.b.C // c'));
		Assert.isNull(HaxeNodes.bodyOf('{ a(); }\n// c'));
		Assert.notNull(HaxeNodes.valueOf('x'));
	}

	private static function constant(): HxMemberDeclT {
		return HaxeNodes.memberDecl(
			[Private, Static], HaxeNodes.constant('byX', HaxeNodes.typeOf('(Item, Item) -> Int'), HaxeNodes.valueOf('Cmp.asc(a -> a.x)'))
		);
	}

	private static function sure<T>(value: Null<T>): T {
		if (value == null) throw 'the part was refused';
		return value;
	}

}
