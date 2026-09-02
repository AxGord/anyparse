package unit;

import anyparse.check.CondRegionLiveness;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;
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

	/** The Haxe grammar's directive vocabulary, which is where every keyword spelling here comes from. */
	private static final SHAPE: RefShape = new HaxeQueryPlugin().refShape();

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

	/**
	 * A condition this cannot parse answers unknown — never the value of the part it did read.
	 *
	 * Both cases have a PROVED prefix, which is what makes them discriminate: drop the parser's
	 * end-of-input check and each returns the prefix's `true`, granting a region on a condition
	 * that was never read to the end.
	 */
	public function testTrailingGarbageIsUnknown(): Void {
		Assert.isNull(CondRegionLiveness.evaluate('nodejs @@', ['nodejs']));
		Assert.isNull(CondRegionLiveness.evaluate('nodejs )', ['nodejs']));
	}

	// --- unproven: the region walk ---

	/** No conditional region at all: every offset is live, and the walk says so without a define set. */
	public function testUnconditionalSourceIsLive(): Void {
		final source: String = 'class C {\n\n\tvar n:Int = 1;\n\n}\n';
		Assert.isNull(CondRegionLiveness.unproven(source, SHAPE, [at(source, 'var n')], [], new HaxeQueryPlugin().lexicalRegions(source)));
	}

	/** The motivating pair: the taken branch is live, the `#else` beside it is provably dead. */
	public function testTakenBranchIsLiveAndItsElseIsNot(): Void {
		Assert.isNull(CondRegionLiveness.unproven(
			BRANCHED, SHAPE,
			[at(BRANCHED, 'var live')],
			['nodejs'], new HaxeQueryPlugin().lexicalRegions(BRANCHED)
		));
		Assert.equals(
			'`#else` of `#if nodejs`',
			CondRegionLiveness.unproven(
				BRANCHED, SHAPE,
				[at(BRANCHED, 'var dead')],
				['nodejs'], new HaxeQueryPlugin().lexicalRegions(BRANCHED)
			)
		);
	}

	/** With the flag unlisted NEITHER branch is provable — the conservative answer, not the inverted one. */
	public function testUnknownConditionRefusesBothBranches(): Void {
		Assert.equals(
			'`#if nodejs`',
			CondRegionLiveness.unproven(BRANCHED, SHAPE, [at(BRANCHED, 'var live')], [], new HaxeQueryPlugin().lexicalRegions(BRANCHED))
		);
		Assert.notNull(
			CondRegionLiveness.unproven(BRANCHED, SHAPE, [at(BRANCHED, 'var dead')], [], new HaxeQueryPlugin().lexicalRegions(BRANCHED))
		);
	}

	/** ONE span in a dead branch condemns the whole set — the caller writes them as one candidate. */
	public function testOneDeadOffsetCondemnsTheSet(): Void {
		Assert.notNull(CondRegionLiveness.unproven(
			BRANCHED, SHAPE,
			[at(BRANCHED, 'var live'), at(BRANCHED, 'var dead')],
			['nodejs'], new HaxeQueryPlugin().lexicalRegions(BRANCHED)
		));
	}

	/**
	 * A span that STRADDLES a region is condemned by its interior, though both its ends are in
	 * live code.
	 *
	 * The shape a two-point sample cannot see, and the one a risky rewrite of a whole member or
	 * loop containing a `#if` actually produces: the endpoints prove nothing about the bytes
	 * between them, and the whole range is what gets rewritten.
	 */
	public function testASpanStraddlingADeadBranchIsCondemned(): Void {
		final head: Int = BRANCHED.indexOf('public function new');
		final tail: Int = BRANCHED.indexOf('}\n', BRANCHED.indexOf('#end'));
		Assert.isNull(
			CondRegionLiveness.unproven(
				BRANCHED, SHAPE,
				[new Span(head, head), new Span(tail, tail)],
				['nodejs'], new HaxeQueryPlugin().lexicalRegions(BRANCHED)
			),
			'both ENDS of the straddle are in live code, which is what makes the interior invisible to a two-point check'
		);
		Assert.equals(
			'`#else` of `#if nodejs`',
			CondRegionLiveness.unproven(BRANCHED, SHAPE, [new Span(head, tail)], ['nodejs'], new HaxeQueryPlugin().lexicalRegions(BRANCHED))
		);
	}

	/** An `#elseif` is live only when its own flag holds AND every earlier branch is refuted. */
	public function testElseIfNeedsItsPredecessorsRefuted(): Void {
		final source: String = 'class C {\n\n\t#if js\n\tvar a:Int = 1;\n\t#elseif nodejs\n\tvar b:Int = 2;\n\t#else\n'
			+ '\tvar c:Int = 3;\n\t#end\n\n}\n';
		Assert.isNull(CondRegionLiveness.unproven(
			source, SHAPE,
			[at(source, 'var a')],
			['js', 'nodejs'], new HaxeQueryPlugin().lexicalRegions(source)
		));
		Assert.equals(
			'`#elseif nodejs` of `#if js`',
			CondRegionLiveness.unproven(
				source, SHAPE,
				[at(source, 'var b')],
				['js', 'nodejs'], new HaxeQueryPlugin().lexicalRegions(source)
			)
		);
		Assert.equals(
			'`#else` of `#if js`',
			CondRegionLiveness.unproven(
				source, SHAPE,
				[at(source, 'var c')],
				['js', 'nodejs'], new HaxeQueryPlugin().lexicalRegions(source)
			)
		);
	}

	/**
	 * A branch keyword whose condition the reader could NOT delimit is unknown, not an `#else`.
	 *
	 * `CondDirective.condition` is null for two different facts — a keyword that takes none, and
	 * a condition-bearing keyword whose tail was undelimitable — and reading the second as the
	 * first declares the branch live whenever the opener is refuted, granting a region the
	 * compiler compiles only under a condition nobody read. This source parses and is
	 * writer-canonical, so it reaches the gate.
	 */
	public function testUndelimitableBranchConditionIsUnknownNotAnElse(): Void {
		final undelimitable: String = 'class C {\n\n\t#if !nodejs\n\tvar a:Int = 1;\n\t#elseif (\n\t\tjs || sys\n\t)\n'
			+ '\tvar b:Int = 2;\n\t#end\n\n}\n';
		Assert.notNull(
			CondRegionLiveness.unproven(
				undelimitable, SHAPE,
				[at(undelimitable, 'var b')],
				['nodejs', 'js'], new HaxeQueryPlugin().lexicalRegions(undelimitable)
			),
			'the opener is provably false, so an `#else` reading would call this branch live'
		);
		// The one variable: the same region with a condition the reader CAN delimit is granted,
		// so the refusal above is about the undelimitable tail and not about the shape.
		final delimitable: String = 'class C {\n\n\t#if !nodejs\n\tvar a:Int = 1;\n\t#elseif (js || sys)\n'
			+ '\tvar b:Int = 2;\n\t#end\n\n}\n';
		Assert.isNull(
			CondRegionLiveness.unproven(
				delimitable, SHAPE,
				[at(delimitable, 'var b')],
				['nodejs', 'js'], new HaxeQueryPlugin().lexicalRegions(delimitable)
			),
			'a delimitable `#elseif` after a refuted opener IS live'
		);
	}

	/** A dead OUTER region is reported, not the inner one it makes moot. */
	public function testOutermostUnprovenRegionIsReported(): Void {
		final source: String = 'class C {\n\n\t#if nodejs\n\t#else\n\t#if sys\n\tvar deep:Int = 1;\n\t#end\n\t#end\n\n}\n';
		// BOTH frames are unproven here, and they carry different text — so the assertion fails
		// if the innermost were reported instead, which a same-text fixture could not discriminate.
		Assert.equals(
			'`#else` of `#if nodejs`',
			CondRegionLiveness.unproven(source, SHAPE, [at(source, 'var deep')], ['nodejs'], new HaxeQueryPlugin().lexicalRegions(source))
		);
	}

	/** Code after `#end` is outside the region again — a walk that forgot to pop would condemn the rest of the file. */
	public function testRegionEndsAtItsCloser(): Void {
		final source: String = 'class C {\n\n\t#if nodejs\n\t#else\n\tvar dead:Int = 1;\n\t#end\n\tvar after:Int = 2;\n\n}\n';
		Assert.isNull(
			CondRegionLiveness.unproven(source, SHAPE, [at(source, 'var after')], ['nodejs'], new HaxeQueryPlugin().lexicalRegions(source))
		);
	}

	/**
	 * A stray branch or closer with no open region is IGNORED, and the code beside it stays
	 * live rather than becoming a branch of nothing.
	 *
	 * The permissive direction of the two ignore paths in `apply`: a stray `#else` that pushed a
	 * frame would make everything after it a branch whose guard nothing constrains.
	 */
	public function testStrayDirectivesDoNotOpenARegion(): Void {
		final source: String = 'class C {\n\n\t#end\n\tvar loose:Int = 1;\n\t#else\n\tvar after:Int = 2;\n\n}\n';
		Assert.isNull(
			CondRegionLiveness.unproven(source, SHAPE, [at(source, 'var loose')], [], new HaxeQueryPlugin().lexicalRegions(source))
		);
		Assert.isNull(
			CondRegionLiveness.unproven(source, SHAPE, [at(source, 'var after')], [], new HaxeQueryPlugin().lexicalRegions(source))
		);
	}

	/**
	 * An empty span list has nothing to refuse.
	 *
	 * It also guards the walk's own last sweep, which reads `sorted[sorted.length - 1]`: on js
	 * that index is `undefined` and the answer stays null by accident, but on a static target it
	 * throws — so the early return is load-bearing where this assertion cannot see it.
	 */
	public function testNoOffsetsIsLive(): Void {
		Assert.isNull(CondRegionLiveness.unproven(BRANCHED, SHAPE, [], [], new HaxeQueryPlugin().lexicalRegions(BRANCHED)));
	}

	/** A zero-length span at `needle`'s first occurrence — the shape an insertion has. */
	private static function at(source: String, needle: String): Span {
		final from: Int = source.indexOf(needle);
		return new Span(from, from);
	}

}
