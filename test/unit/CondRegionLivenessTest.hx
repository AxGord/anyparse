package unit;

import anyparse.check.CondRegionLiveness;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import utest.Assert;
import utest.Test;

/**
 * `CondRegionLiveness` — whether a byte offset sits in code a compile with a given define
 * set actually TYPECHECKED, which is the half of the oracle-coverage question a file's
 * `Parsed` line cannot answer.
 *
 * The property every one of these tests is really about: the define list is
 * POSITIVE-ONLY. A listed flag is proved, an unlisted one is UNKNOWN, and unknown costs a
 * decline rather than a permission. `testUnlistedFlagIsUnknownNotFalse` and
 * `testNegatedUnlistedFlagIsNotProvablyTrue` are that property stated directly; without
 * them every other answer here would still hold under the unsound reading "absent means
 * undefined", which would let `#if !whatever` claim a region no compile ever produced.
 */
@:nullSafety(Strict)
final class CondRegionLivenessTest extends Test {

	/** `#if nodejs` / `#else`, the shape that motivated the class. */
	private static final BRANCHED: String = 'class C {\n\n\tpublic function new() {}\n\n\t#if nodejs\n\tvar live:Int = 1;\n'
		+ '\t#else\n\tvar dead:Int = 2;\n\t#end\n\n}\n';

	// --- evaluate: the three-valued condition reader ---

	public function testListedFlagIsTrue(): Void {
		Assert.equals(true, CondRegionLiveness.evaluate('nodejs', ['nodejs']));
	}

	/** The soundness property: absence of a flag is NOT evidence it is undefined. */
	public function testUnlistedFlagIsUnknownNotFalse(): Void {
		Assert.isNull(CondRegionLiveness.evaluate('sys', ['nodejs']));
	}

	public function testNegatedListedFlagIsFalse(): Void {
		Assert.equals(false, CondRegionLiveness.evaluate('!nodejs', ['nodejs']));
	}

	/** The same property one operator down — `!unlisted` must never come out TRUE. */
	public function testNegatedUnlistedFlagIsNotProvablyTrue(): Void {
		Assert.isNull(CondRegionLiveness.evaluate('!sys', ['nodejs']));
	}

	/** `||` needs only one proved operand, which is what keeps `#if (sys || nodejs)` covered on a js build. */
	public function testDisjunctionNeedsOneProvedOperand(): Void {
		Assert.equals(true, CondRegionLiveness.evaluate('(sys || nodejs)', ['nodejs']));
	}

	public function testConjunctionNeedsBothProved(): Void {
		Assert.isNull(CondRegionLiveness.evaluate('(sys && nodejs)', ['nodejs']));
		Assert.equals(true, CondRegionLiveness.evaluate('(js && nodejs)', ['js', 'nodejs']));
	}

	/** A proved-false operand refutes the whole conjunction even when the other is unknown. */
	public function testConjunctionIsFalseFromOneRefutedOperand(): Void {
		Assert.equals(false, CondRegionLiveness.evaluate('(!nodejs && whatever)', ['nodejs']));
	}

	/** A comparison parses — so the condition around it is not refused as malformed — and answers unknown. */
	public function testComparisonIsUnknown(): Void {
		Assert.isNull(CondRegionLiveness.evaluate('haxe_ver >= 4.0', ['haxe_ver']));
		Assert.isNull(CondRegionLiveness.evaluate('(haxe_ver >= "4.0.0" && nodejs)', ['haxe_ver', 'nodejs']));
	}

	/** A dotted define is ONE flag — cutting it at the dot would compare against a name no compiler prints. */
	public function testDottedFlagIsOneName(): Void {
		Assert.equals(true, CondRegionLiveness.evaluate('target.unicode', ['target.unicode']));
		Assert.isNull(CondRegionLiveness.evaluate('target.unicode', ['target']));
	}

	/** A condition this cannot parse answers unknown — never the value of the part it did read. */
	public function testTrailingGarbageIsUnknown(): Void {
		Assert.isNull(CondRegionLiveness.evaluate('nodejs &&', ['nodejs']));
		Assert.isNull(CondRegionLiveness.evaluate('nodejs )', ['nodejs']));
	}

	// --- unproven: the region walk ---

	/** No conditional region at all: every offset is live, and the walk says so without a define set. */
	public function testUnconditionalSourceIsLive(): Void {
		final source: String = 'class C {\n\n\tvar n:Int = 1;\n\n}\n';
		Assert.isNull(CondRegionLiveness.unproven(source, shape(), [source.indexOf('var n')], []));
	}

	/** The motivating pair: the taken branch is live, the `#else` beside it is provably dead. */
	public function testTakenBranchIsLiveAndItsElseIsNot(): Void {
		Assert.isNull(CondRegionLiveness.unproven(BRANCHED, shape(), [BRANCHED.indexOf('var live')], ['nodejs']));
		Assert.equals(
			'`#else` of `#if nodejs`', CondRegionLiveness.unproven(BRANCHED, shape(), [BRANCHED.indexOf('var dead')], ['nodejs'])
		);
	}

	/** With the flag unlisted NEITHER branch is provable — the conservative answer, not the inverted one. */
	public function testUnknownConditionRefusesBothBranches(): Void {
		Assert.equals('`#if nodejs`', CondRegionLiveness.unproven(BRANCHED, shape(), [BRANCHED.indexOf('var live')], []));
		Assert.notNull(CondRegionLiveness.unproven(BRANCHED, shape(), [BRANCHED.indexOf('var dead')], []));
	}

	/** ONE offset in a dead branch condemns the whole set — the caller writes them as one candidate. */
	public function testOneDeadOffsetCondemnsTheSet(): Void {
		Assert.notNull(
			CondRegionLiveness.unproven(BRANCHED, shape(), [BRANCHED.indexOf('var live'), BRANCHED.indexOf('var dead')], ['nodejs'])
		);
	}

	/** An `#elseif` is live only when its own flag holds AND every earlier branch is refuted. */
	public function testElseIfNeedsItsPredecessorsRefuted(): Void {
		final source: String = 'class C {\n\n\t#if js\n\tvar a:Int = 1;\n\t#elseif nodejs\n\tvar b:Int = 2;\n\t#else\n'
			+ '\tvar c:Int = 3;\n\t#end\n\n}\n';
		Assert.isNull(CondRegionLiveness.unproven(source, shape(), [source.indexOf('var a')], ['js', 'nodejs']));
		Assert.equals(
			'`#elseif nodejs` of `#if js`', CondRegionLiveness.unproven(source, shape(), [source.indexOf('var b')], ['js', 'nodejs'])
		);
		Assert.equals('`#else` of `#if js`', CondRegionLiveness.unproven(source, shape(), [source.indexOf('var c')], ['js', 'nodejs']));
	}

	/** A dead OUTER region is reported, not the inner one it makes moot. */
	public function testOutermostUnprovenRegionIsReported(): Void {
		final source: String = 'class C {\n\n\t#if nodejs\n\t#else\n\t#if js\n\tvar deep:Int = 1;\n\t#end\n\t#end\n\n}\n';
		Assert.equals(
			'`#else` of `#if nodejs`', CondRegionLiveness.unproven(source, shape(), [source.indexOf('var deep')], ['nodejs', 'js'])
		);
	}

	/** Code after `#end` is outside the region again — a walk that forgot to pop would condemn the rest of the file. */
	public function testRegionEndsAtItsCloser(): Void {
		final source: String = 'class C {\n\n\t#if nodejs\n\t#else\n\tvar dead:Int = 1;\n\t#end\n\tvar after:Int = 2;\n\n}\n';
		Assert.isNull(CondRegionLiveness.unproven(source, shape(), [source.indexOf('var after')], ['nodejs']));
	}

	/** An empty offset list has nothing to refuse — the caller asking about no edits gets no decline. */
	public function testNoOffsetsIsLive(): Void {
		Assert.isNull(CondRegionLiveness.unproven(BRANCHED, shape(), [], []));
	}

	/** The Haxe grammar's directive vocabulary, which is where every keyword spelling here comes from. */
	private function shape(): RefShape {
		return new HaxeQueryPlugin().refShape();
	}

}
