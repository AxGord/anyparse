package unit.macro;

import anyparse.macro.BlockStarPlan;
import anyparse.macro.SepStarPlan;
import anyparse.macro.StarPlan.StarMeta;
import anyparse.macro.TryparseStarPlan;

/**
 * A Star's plan answers its grammar metadata without a macro context: each method reads its own flag, argument list,
 * single string or annotation through the `StarMeta` it is given, so a plan is checked here on plain maps.
 */
class StarPlanTest extends Test {

	/** A flag answers by its own name and only by it. */
	@:pin('control')
	@:killer('M-STAR-PLAN-FLAG-NAME')
	public function testAFlagIsReadByItsOwnName(): Void {
		final plan: TryparseStarPlan = new TryparseStarPlan(meta(['nestBody'], [], [], []));
		Assert.isTrue(plan.nestBody());
		Assert.isFalse(plan.padLeading());
	}

	/** A knob is the first argument of its flag; the flag with no argument list names none. */
	public function testAKnobIsTheFirstArgumentOfItsFlag(): Void {
		final knobbed: BlockStarPlan = new BlockStarPlan(meta([], ['emptyCurlyBreak' => ['emptyCurly', 'x']], [], []));
		Assert.equals('emptyCurly', knobbed.emptyCurlyBreakKnob());
		Assert.isNull(new BlockStarPlan(meta(['emptyCurlyBreak'], [], [], [])).emptyCurlyBreakKnob());
	}

	/** `blockEnded` holds for the annotation `true` alone, not for any other value stored under its key. */
	@:pin('control')
	@:killer('M-STAR-PLAN-BLOCK-ENDED-TRUTHY')
	public function testBlockEndedHoldsOnlyForTrue(): Void {
		final none: StarMeta = meta([], [], [], []);
		Assert.isTrue(new SepStarPlan({
			flag: none.flag,
			args: none.args,
			string: none.string,
			annotation: _ -> true
		}).blockEnded());
		Assert.isFalse(new SepStarPlan({
			flag: none.flag,
			args: none.args,
			string: none.string,
			annotation: _ -> 'true'
		}).blockEnded());
		Assert.isFalse(new SepStarPlan(none).blockEnded());
	}

	/** A single-string knob and the separator text come back as written, null when absent. */
	public function testAStringKnobAndTheSeparatorText(): Void {
		final plan: SepStarPlan = new SepStarPlan(meta([], [], ['wrapRules' => 'objectLiteralWrap'], ['lit.sepText' => ',']));
		Assert.equals('objectLiteralWrap', plan.wrapRules());
		Assert.equals(',', plan.sepText());
		Assert.isNull(plan.trailingComma());
	}

	/** A knob list is null when its flag is absent and empty when the flag is bare, so the emitter refuses a bare one. */
	@:pin('control')
	@:killer('M-STAR-PLAN-BARE-KNOB-LIST')
	public function testAKnobListIsNullWhenAbsentAndEmptyWhenBare(): Void {
		final listed: BlockStarPlan = new BlockStarPlan(meta(['beginEndType'], ['beginEndType' => ['a', 'b']], [], []));
		Assert.same(['a', 'b'], listed.beginEndTypeKnobs());
		final bare: BlockStarPlan = new BlockStarPlan(meta(['existingBetweenFields'], [], [], []));
		Assert.same([], bare.existingBetweenFields());
		Assert.isNull(bare.beginEndTypeIfDoc());
	}

	/** A plan's reader over plain maps, standing in for a grammar Star node and its string annotations. */
	private static function meta(
		flags: Array<String>, args: Map<String, Array<String>>, strings: Map<String, String>, annotations: Map<String, String>
	): StarMeta {
		return {
			flag: name -> flags.contains(name),
			args: name -> args[name],
			string: name -> strings[name],
			annotation: key -> annotations[key]
		};
	}

}
