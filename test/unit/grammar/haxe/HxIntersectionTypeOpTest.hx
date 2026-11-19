package unit.grammar.haxe;

import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.query.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The intersection type `A & B` is one `HxType` operator: it reads at every type position, leaves an expression
 * `&&` after an `is` operand alone, and is written as one chain — its spacing knob, the operand that follows a
 * multi-line brace-closed one, and the comments on either side of `&`.
 */
final class HxIntersectionTypeOpTest extends Test {

	private static final DEFAULTS: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {});
	private static final NO_SPACE_AFTER: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited ->
		edited.typedefIntersection = WhitespacePolicy.None
	);

	/** A structure with enough fields that its body is one field per line whatever the width. */
	private static final LONG_BODY: String = '{\n\tvar a:Int;\n\tvar b:Int;\n\tvar c:Int;\n\tvar d:Int;\n\tvar e:Int;\n}';

	@:pin('control')
	@:killer('M-INTERSECTION-OP-OFF')
	public function testEveryTypePositionReadsAnIntersection(): Void {
		assertFixedPoint(
			'class C<T:A & B> {\n\tvar f:A & B;\n\n\tfunction g(x:A & B):A & B {\n\t\tvar v:Array<A & B> = null;\n'
			+ '\t\tvar w:(A & B) -> Void = null;\n\t\tvar z = cast(a, A & B);\n\t}\n}'
		);
		assertFixedPoint('typedef T = A & B & C;');
	}

	@:pin('control')
	@:killer('M-INTERSECTION-TAKES-LOGICAL-AND')
	public function testIsOperandEndsBeforeALogicalAnd(): Void {
		assertFixedPoint('class C {\n\tfunction g() {\n\t\tvar b = x is Int && y;\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-OPERAND-CHAIN-KNOB-IGNORED')
	public function testTheKnobDropsTheSpaceAfterTheOperator(): Void {
		Assert.equals('typedef T = A &B &C;', HxWriteFixture.triviaWrite('typedef T = A & B & C;', NO_SPACE_AFTER));
	}

	@:pin('control')
	@:killer('M-OPERAND-CHAIN-BREAK-OFF')
	public function testAnOperandAfterAMultiLineBraceOperandStartsItsOwnLine(): Void {
		assertFixedPoint('typedef T = A & $LONG_BODY &\n\tB & C;');
	}

	@:pin('control')
	@:killer('M-OPERAND-CHAIN-HEAD-BREAKS')
	public function testTheOperandAfterAHeadBodyStaysOnItsClosingLine(): Void {
		assertFixedPoint('typedef T = $LONG_BODY & B;');
	}

	/**
	 * The break belongs to the chain a typedef holds as its whole right-hand side: an argument, a bound and a member
	 * type keep the operand on the closing line.
	 */
	@:pin('control')
	@:killer('M-OPERAND-CHAIN-BREAK-UNGATED')
	public function testOutsideATypedefRightHandSideTheOperandStaysOnTheClosingLine(): Void {
		assertFixedPoint('typedef T = Array<A & $LONG_BODY & B>;');
		assertFixedPoint('class K<T:A & $LONG_BODY & B> {}');
		assertFixedPoint('class C {\n\tvar f:A & ${LONG_BODY.replace('\n', '\n\t')} & B;\n}');
	}

	/** A chain inside an operand of the typedef's chain is not the typedef's own. */
	@:pin('control')
	@:killer('M-OPERAND-CHAIN-BREAK-INHERITED')
	public function testAChainNestedInAnOperandDoesNotInheritTheBreak(): Void {
		final inner: String = LONG_BODY.replace('\n', '\n\t');
		assertFixedPoint('typedef T = A & {\n\tvar f:X & $inner & Y;\n\tvar b:Int;\n\tvar c:Int;\n\tvar d:Int;\n\tvar e:Int;\n} &\n\tZ;');
	}

	@:pin('control')
	@:killer('M-OPERAND-CHAIN-LEAD-LINE-OFF')
	public function testACommentBeforeTheOperatorRidesItsOperand(): Void {
		assertFixedPoint('typedef T = A /* l */ & B;');
		assertFixedPoint('typedef T = A // l\n\t& B;');
	}

	@:pin('control')
	@:killer('M-OPERAND-CHAIN-AFTER-COMMENT-DROPPED')
	public function testACommentAfterTheOperatorPrecedesItsOperand(): Void {
		assertFixedPoint('typedef T = A & /* c */ B;');
		assertFixedPoint('typedef T = A & // c\n\tB;');
		assertFixedPoint('class C {\n\tvar f:A & /* c */ B;\n}');
	}

	/** A structure operand is still the declaration host its typedef or member holds, and the chain adds no node beside it. */
	@:pin('control')
	@:killer('M-QUERY-TYPE-OPERAND-HOST-LOST')
	public function testAStructureOperandIsStillADeclarationHost(): Void {
		final root: QueryNode = new HaxeQueryPlugin().parseFile(
			'typedef T = A & { var q: Int; };\nclass C { var f: { var r: Int; } & B; }'
		);
		Assert.same(['Anon'], root.children[0].children.map(child -> child.kind));
		Assert.same(['Anon'], root.children[1].children[0].children.map(child -> child.kind));
		Assert.equals('Intersection', root.children[0].type?.kind);
	}

	/** `source` is what the writer produces for it. */
	private function assertFixedPoint(source: String): Void {
		Assert.equals(source, HxWriteFixture.triviaWrite(source, DEFAULTS));
	}

}
