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

	private static function ifStmtRuleSource(): String {
		final rule: Null<haxe.Constraints.Function> = Reflect.field(HaxeModuleTriviaWriter, IF_STMT_RULE);
		Assert.isTrue(Reflect.isFunction(rule), 'HaxeModuleTriviaWriter has no generated rule method $IF_STMT_RULE');
		return js.Syntax.code('String({0})', rule);
	}

}
