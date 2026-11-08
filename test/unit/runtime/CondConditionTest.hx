package unit.runtime;

import anyparse.runtime.CondCondition;

/**
 * `CondCondition` — where a `#if` condition ends, read once for the query side and the generated
 * splice predicates. Every expected offset is spelled from the fixture text, never from the reader.
 */
@:nullSafety(Strict)
final class CondConditionTest extends Test {

	@:pin('control')
	@:killer('M-COND-ATOM-ENDS-AT-WS')
	public function testTheConditionAtomEndsAtWhitespaceOutsideParentheses(): Void {
		final fragment: String = '  !(a || b) else x';
		Assert.equals(fragment.indexOf('else'), CondCondition.skipConditionAtom(fragment, 0));
		final quoted: String = "(a == ')' && b)\n\telse x";
		Assert.equals(quoted.indexOf('else'), CondCondition.skipConditionAtom(quoted, 0));
		final unbalanced: String = '(a b else';
		Assert.equals(unbalanced.length, CondCondition.skipConditionAtom(unbalanced, 0));
		final strayClose: String = 'a) else';
		Assert.equals(strayClose.indexOf(')'), CondCondition.skipConditionAtom(strayClose, 0));
		final noOperand: String = ') else';
		Assert.equals(noOperand.length, CondCondition.skipConditionAtom(noOperand, 0));
	}

	/**
	 * A byte glued to the operand (`,`, `!`, `&&`) ends the atom as it ends the condition: the
	 * splice predicate and the query side read one condition, not a whitespace-delimited run.
	 */
	@:pin('control')
	@:killer('M-COND-ATOM-IS-CONDITION-OPERAND')
	public function testTheConditionAtomIsTheConditionOperand(): Void {
		final comma: String = '(haxe_ver >= 4.2), AExtern';
		Assert.equals(comma.indexOf(','), CondCondition.skipConditionAtom(comma, 0));
		Assert.equals(comma.indexOf(','), CondCondition.conditionAt(comma, 0)?.to);
		final bang: String = 'flag! image';
		Assert.equals(bang.indexOf('!'), CondCondition.skipConditionAtom(bang, 0));
		final glued: String = 'a&&b else';
		Assert.equals(1, CondCondition.skipConditionAtom(glued, 0));
	}

}
