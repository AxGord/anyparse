package unit.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.ShapeVocab;

/**
 * `ShapeVocab` — the derived vocabulary every check reads instead of respelling a union of `RefShape` seams: a
 * hand-built shape for the union's own contract (each kind once, in seam order, an unset seam adding nothing), and the
 * Haxe grammar's answers spelled out, so a seam that moves changes one visible line here.
 */
@:nullSafety(Strict)
class ShapeVocabTest extends Test {

	/** A kind that two seams both name is answered once, where it first appears. */
	@:pin('control') @:killer('M-VOCAB-UNION-DUPLICATES')
	public function testAKindTwoSeamsNameIsAnsweredOnce(): Void {
		final shape: RefShape = bare();
		shape.loopStatementKinds = ['ForStmt', 'WhileStmt'];
		shape.doWhileLoopKinds = ['DoWhileStmt'];
		shape.iterationBindingKinds = ['ForStmt', 'ForExpr'];
		Assert.same(['ForStmt', 'WhileStmt', 'DoWhileStmt', 'ForExpr'], ShapeVocab.loopKinds(shape));
	}

	/** A single seam the grammar leaves unset adds nothing — not a null, not an empty name. */
	@:pin('control') @:killer('M-VOCAB-UNSET-SEAM-ADDED')
	public function testAnUnsetSeamAddsNothing(): Void {
		final shape: RefShape = bare();
		shape.ifStatementKinds = ['IfStmt'];
		Assert.same(['IfStmt'], ShapeVocab.conditionalKinds(shape));
		Assert.same([], ShapeVocab.returnKinds(bare()));
		Assert.same([], ShapeVocab.switchArmKinds(bare()));
	}

	/** A condition loop is a statement loop no iteration binding names: `while` and `do … while`, never `for`. */
	@:pin('control') @:killer('M-VOCAB-CONDITION-LOOP-KEEPS-FOR')
	public function testConditionLoopsDropTheIteratingOnes(): Void {
		Assert.same(['WhileStmt', 'DoWhileStmt', 'DoWhileExpr'], ShapeVocab.conditionLoopKinds(new HaxeQueryPlugin().refShape()));
		final shape: RefShape = bare();
		shape.loopStatementKinds = ['ForStmt', 'WhileStmt'];
		Assert.same(['ForStmt', 'WhileStmt'], ShapeVocab.conditionLoopKinds(shape));
	}

	/** The Haxe grammar's loops and functions, each union spelled out. */
	@:pin('control') @:killer('M-VOCAB-NESTED-NO-NAMED-FN') @:killer('M-VOCAB-DOWHILE-EXPR-NOT-LOOP')
	public function testHaxeLoopAndFunctionVocabulary(): Void {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		Assert.same(['ForStmt', 'WhileStmt', 'DoWhileStmt', 'DoWhileExpr', 'ForExpr', 'WhileExpr'], ShapeVocab.loopKinds(shape));
		Assert.same(['ForStmt', 'WhileStmt', 'DoWhileStmt', 'DoWhileExpr'], ShapeVocab.statementLoopKinds(shape));
		Assert.same([
			'ThinArrow',
			'ThinParenLambdaExpr',
			'ParenLambdaExpr',
			'FnExpr',
			'NamedFnExpr',
			'LocalFnStmt',
			'LocalInlineFnStmt'
		], ShapeVocab.nestedFunctionKinds(shape));
		Assert.same([
			'FnMember',
			'FinalModifiedMember',
			'FnDecl',
			'LocalFnStmt',
			'ThinArrow',
			'ThinParenLambdaExpr',
			'ParenLambdaExpr',
			'FnExpr',
			'NamedFnExpr',
			'LocalInlineFnStmt'
		], ShapeVocab.functionLikeKinds(shape));
		Assert.same(['LocalFnStmt', 'LocalInlineFnStmt'], ShapeVocab.localFunctionScopeKinds(shape));
	}

	/** The Haxe grammar's returns, conditionals, `try`s and `switch` arms, each union spelled out. */
	public function testHaxeControlFlowVocabulary(): Void {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		Assert.same(['ReturnStmt', 'VoidReturnStmt'], ShapeVocab.returnStatementKinds(shape));
		Assert.same(['ReturnStmt', 'VoidReturnStmt', 'ReturnExpr'], ShapeVocab.returnKinds(shape));
		Assert.same(['TryCatchStmt', 'TryCatchStmtBare', 'TryExpr'], ShapeVocab.tryKinds(shape));
		Assert.same(['IfStmt', 'IfExpr'], ShapeVocab.ifKinds(shape));
		Assert.same(['IfStmt', 'IfExpr', 'Ternary'], ShapeVocab.conditionalKinds(shape));
		Assert.same(['CaseBranch', 'DefaultBranch'], ShapeVocab.switchArmKinds(shape));
	}

	/**
	 * Every loop and every two-armed conditional of the Haxe grammar is a decision point (`branchKinds`): the
	 * hand-kept list missed `WhileExpr` (a `while` comprehension or lambda body) while `ForExpr` was there.
	 */
	@:pin('control')
	@:killer('M-VOCAB-WHILE-EXPR-NOT-BRANCH')
	public function testEveryHaxeLoopAndConditionalIsABranch(): Void {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		final branches: Array<String> = shape.branchKinds ?? [];
		for (kind in ShapeVocab.loopKinds(shape).concat(ShapeVocab.conditionalKinds(shape)))
			Assert.isTrue(branches.contains(kind), '$kind is not in branchKinds');
	}

	/** A shape naming only the seams `RefShape` requires. */
	private static function bare(): RefShape {
		return new RefShape('IdentExpr', [], [], [], [], []);
	}

}
