package unit.lowering;

import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * The generated writer SHARES the cond-fit group body and the opt-fanout shims instead of copying them per site.
 *
 * Both are size contracts the written text cannot show: a shim inlined at every call, or a body spliced into each
 * arm of the cond-fit dispatch, writes the same bytes from a larger writer. So each row reads the generated code
 * itself — the js source of the `if` statement's rule method, the one rule that carries both shapes.
 */
@:nullSafety(Strict)
final class GeneratedWriterSharingTest extends Test {

	/** The generated rule method whose source both rows read. */
	private static inline final IF_STMT_RULE: String = 'writeHxIfStmtT';

	/** The call that writes an `if`'s then- or else-body statement. */
	private static inline final STATEMENT_WRITE: String = 'writeHxStatementT(';

	/** The then-body, the else-body, and the else separator's own semicolon probe of the then-body. */
	private static inline final MAX_STATEMENT_WRITES: Int = 3;

	/** The local the body-policy wrap binds the body's value to. */
	private static inline final BODY_VALUE_LOCAL: String = '_bpVal';

	/** An opt-fanout shim stays a call in the rule that uses it, not a copy of its body at each site. */
	@:pin('control')
	@:killer('M-FANOUT-SHIM-INLINE')
	public function testAnOptFanoutShimIsCalledNotInlined(): Void {
		Assert.isTrue(
			ifStmtRuleSource().indexOf('._clearElseIfBranch(') >= 0,
			'$IF_STMT_RULE no longer calls `_clearElseIfBranch` - the opt-fanout shims are inlined again'
		);
	}

	/** Both arms of the cond-fit dispatch wrap one bound body rather than a re-spliced copy of it. */
	@:pin('control')
	@:killer('M-FITGROUP-RESPLICE')
	public function testTheCondFitGroupBindsItsBodyOnce(): Void {
		Assert.isTrue(
			ifStmtRuleSource().indexOf('BodyGroup(_fgInner)') >= 0,
			'$IF_STMT_RULE wraps no bound `_fgInner` in its BodyGroup arm - the cond-fit body is spliced per arm again'
		);
	}

	/** The body-policy wrap renders its body once and every policy arm reads that Doc, so the rule calls the body writer once per body. */
	@:pin('control')
	@:killer('M-BODYPOLICY-BODY-RESPLICE')
	public function testTheBodyPolicyWrapWritesItsBodyOnce(): Void {
		final calls: Int = ifStmtRuleSource().split(STATEMENT_WRITE).length - 1;
		Assert.isTrue(
			calls <= MAX_STATEMENT_WRITES,
			'$IF_STMT_RULE calls `$STATEMENT_WRITE` $calls times - the body-policy arms splice their own copy of the body write again'
		);
	}

	/** The body write reads the de-braced value the wrap bound for its arms instead of computing its own copy. */
	@:pin('control')
	@:killer('M-BODYPOLICY-VALUE-RESPLICE')
	public function testTheBodyWriteReadsTheBoundValue(): Void {
		Assert.isTrue(
			ifStmtRuleSource().indexOf('$STATEMENT_WRITE${BODY_VALUE_LOCAL},') >= 0,
			'$IF_STMT_RULE writes no `$BODY_VALUE_LOCAL` - the body write de-braces its value a second time'
		);
	}

	private static function ifStmtRuleSource(): String {
		final rule: Null<haxe.Constraints.Function> = Reflect.field(HaxeModuleTriviaWriter, IF_STMT_RULE);
		Assert.isTrue(Reflect.isFunction(rule), 'HaxeModuleTriviaWriter has no generated rule method $IF_STMT_RULE');
		return js.Syntax.code('String({0})', rule);
	}

}
