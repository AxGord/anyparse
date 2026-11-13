package unit.runtime;

import anyparse.grammar.haxe.HxPpCondScan;
import anyparse.runtime.CondCondition;
import anyparse.runtime.Input;

/**
 * `CondCondition` — where a `#if` condition ends, read once for the query side and the generated
 * splice predicates. Every expected offset is spelled from the fixture text, never from the reader.
 */
@:nullSafety(Strict)
final class CondConditionTest extends Test {

	/** The Haxe grammar's condition reader: the pins below read Haxe conditions through the generic span helper. */
	private static final READER: (input: Input, at: Int) -> Int = HxPpCondScan.endAt;

	@:pin('control')
	@:killer('M-COND-ATOM-ENDS-AT-WS')
	public function testTheConditionAtomEndsAtWhitespaceOutsideParentheses(): Void {
		final fragment: String = '  !(a || b) else x';
		Assert.equals(fragment.indexOf('else'), CondCondition.skipConditionAtom(fragment, 0, READER));
		final quoted: String = "(a == ')' && b)\n\telse x";
		Assert.equals(quoted.indexOf('else'), CondCondition.skipConditionAtom(quoted, 0, READER));
		final unbalanced: String = '(a b else';
		Assert.equals(unbalanced.length, CondCondition.skipConditionAtom(unbalanced, 0, READER));
		final strayClose: String = 'a) else';
		Assert.equals(strayClose.indexOf(')'), CondCondition.skipConditionAtom(strayClose, 0, READER));
		final noOperand: String = ') else';
		Assert.equals(noOperand.length, CondCondition.skipConditionAtom(noOperand, 0, READER));
	}

	/**
	 * A byte glued to the operand (`,`, `!`, `&&`) ends the atom as it ends the condition: the
	 * splice predicate and the query side read one condition, not a whitespace-delimited run.
	 */
	@:pin('control')
	@:killer('M-COND-ATOM-IS-CONDITION-OPERAND')
	public function testTheConditionAtomIsTheConditionOperand(): Void {
		final comma: String = '(haxe_ver >= 4.2), AExtern';
		Assert.equals(comma.indexOf(','), CondCondition.skipConditionAtom(comma, 0, READER));
		Assert.equals(comma.indexOf(','), CondCondition.conditionAt(comma, 0, READER)?.to);
		final bang: String = 'flag! image';
		Assert.equals(bang.indexOf('!'), CondCondition.skipConditionAtom(bang, 0, READER));
		final glued: String = 'a&&b else';
		Assert.equals(1, CondCondition.skipConditionAtom(glued, 0, READER));
	}

}
