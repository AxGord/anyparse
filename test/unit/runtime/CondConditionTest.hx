package unit.runtime;

import anyparse.grammar.haxe.cond.HxPpCondBlankScan;
import anyparse.grammar.haxe.cond.HxPpCondScan;
import anyparse.runtime.CondCondition;
import anyparse.runtime.Input;
import anyparse.runtime.Span;

/**
 * `CondCondition` — where a `#if` condition ends, read once for the query side and the generated
 * splice predicates. Every expected offset is spelled from the fixture text, never from the reader.
 */
@:nullSafety(Strict)
final class CondConditionTest extends Test {

	/** The Haxe grammar's condition reader: the pins below read Haxe conditions through the generic span helper. */
	private static final READER: (input: Input, at: Int) -> Int = HxPpCondScan.endAt;

	/** The Haxe grammar's reader of the blank around a condition. */
	private static final BLANK: (input: Input, at: Int) -> Int = HxPpCondBlankScan.endAt;

	@:pin('control')
	@:killer('M-COND-ATOM-ENDS-AT-WS')
	public function testTheConditionAtomEndsAtWhitespaceOutsideParentheses(): Void {
		final fragment: String = '  !(a || b) else x';
		Assert.equals(fragment.indexOf('else'), CondCondition.skipConditionAtom(fragment, 0, READER, BLANK));
		final quoted: String = "(a == ')' && b)\n\telse x";
		Assert.equals(quoted.indexOf('else'), CondCondition.skipConditionAtom(quoted, 0, READER, BLANK));
		final unbalanced: String = '(a b else';
		Assert.equals(unbalanced.length, CondCondition.skipConditionAtom(unbalanced, 0, READER, BLANK));
		final strayClose: String = 'a) else';
		Assert.equals(strayClose.indexOf(')'), CondCondition.skipConditionAtom(strayClose, 0, READER, BLANK));
		final noOperand: String = ') else';
		Assert.equals(noOperand.length, CondCondition.skipConditionAtom(noOperand, 0, READER, BLANK));
	}

	/**
	 * A byte glued to the operand (`,`, `!`, `&&`) ends the atom as it ends the condition: the
	 * splice predicate and the query side read one condition, not a whitespace-delimited run.
	 */
	@:pin('control')
	@:killer('M-COND-ATOM-IS-CONDITION-OPERAND')
	public function testTheConditionAtomIsTheConditionOperand(): Void {
		final comma: String = '(haxe_ver >= 4.2), AExtern';
		Assert.equals(comma.indexOf(','), CondCondition.skipConditionAtom(comma, 0, READER, BLANK));
		Assert.equals(comma.indexOf(','), CondCondition.conditionAt(comma, 0, READER, BLANK)?.to);
		final bang: String = 'flag! image';
		Assert.equals(bang.indexOf('!'), CondCondition.skipConditionAtom(bang, 0, READER, BLANK));
		final glued: String = 'a&&b else';
		Assert.equals(1, CondCondition.skipConditionAtom(glued, 0, READER, BLANK));
	}

	/**
	 * The blank between a keyword and its condition is the grammar's: spaces, tabs, carriage returns and line feeds
	 * in any mix, each alone too, and the condition starts at its first other byte.
	 */
	@:pin('control')
	@:killer('M-COND-KEYWORD-BLANK-UNREAD')
	public function testTheBlankAfterTheKeywordIsSpacesTabsAndLineBreaks(): Void {
		for (gap in [' ', '\t', '\r', '\n', '\r\n', ' \t\r\n\t ']) {
			final text: String = '#if${gap}flag\nx';
			final condition: Null<Span> = CondCondition.conditionAt(text, '#if'.length, READER, BLANK);
			Assert.equals(text.indexOf('flag'), condition?.from);
			Assert.equals(text.indexOf('flag') + 'flag'.length, condition?.to);
		}
	}

	/** The blank after the condition is the same set, so the atom ends where the next word starts. */
	@:pin('control')
	@:killer('M-COND-ATOM-BLANK-UNREAD')
	public function testTheBlankAfterTheConditionIsSpacesTabsAndLineBreaks(): Void {
		final fragment: String = 'flag \t\r\n else';
		Assert.equals(fragment.indexOf('else'), CondCondition.skipConditionAtom(fragment, 0, READER, BLANK));
	}

	/** A comment is not blank: a condition the comment stands in front of is not read past it. */
	@:pin('control')
	@:killer('M-COND-ATOM-ENDS-AT-WS')
	public function testACommentIsNotPartOfTheBlank(): Void {
		final text: String = '#if /* c */ flag';
		Assert.isNull(CondCondition.conditionAt(text, '#if'.length, READER, BLANK));
		final fragment: String = 'flag // c\nelse';
		Assert.equals(fragment.indexOf('//'), CondCondition.skipConditionAtom(fragment, 0, READER, BLANK));
	}

}
