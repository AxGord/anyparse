package unit.check.common.members;

import anyparse.check.LintConfig;
import anyparse.check.common.members.MemberOrder;
import anyparse.query.CanonicalEdit;

/**
 * The review budget of `member-order`'s reorder as a RUN can set it: `MemberOrder.withBudget` is what
 * `lint --fix --review-budget` overlays on every config the run resolves, and the fix reads it back like any rule option.
 */
@:nullSafety(Strict)
final class MemberOrderBudgetTest extends Test {

	/** The same oversized type the default budget declines reorders under a raised one, into the canonical order. */
	@:killer('M-MO-BUDGET-OPTION-IGNORED', 'M-MO-BUDGET-OVERLAY-KEY')
	@:pin('control')
	public function testARaisedBudgetReordersTheTypeTheDefaultDeclines(): Void {
		final src: String = oversized();
		Assert.equals(src, CanonicalEdit.applyEdits(src, fixRunUnder(src, null).edits), 'the default budget leaves the order alone');
		final raised: FixRun = fixRunUnder(src, 100000);
		final fixed: String = CanonicalEdit.applyEdits(src, raised.edits);
		Assert.notEquals(src, fixed, 'a raised budget reorders it');
		Assert.isTrue(fixed.indexOf('function s0') > fixed.indexOf('function m79'), 'public methods now lead the static ones');
		Assert.same([null], raised.violations.map(v -> v.declineReason), 'and nothing is declined');
	}

	/** The decline names the budget in force, so a run that lowered it reads its own number and not the default. */
	@:killer('M-MO-BUDGET-REASON-DEFAULT')
	@:pin('control')
	public function testTheDeclineNamesTheBudgetInForce(): Void {
		final reason: Null<String> = fixRunUnder(oversized(), 1).violations[0].declineReason;
		Assert.isTrue(reason != null && reason.indexOf('more than 1 lines') != -1, 'the reason names the run budget: $reason');
	}

	/**
	 * The overlay is a COPY: `LintConfig.discover` shares one config per directory, so the receiver must not learn the budget,
	 * and the copy keeps what the project wrote for the rule beside it.
	 */
	@:killer('M-CONFIG-OPTION-SHARES-RULES', 'M-CONFIG-OPTION-DROPS-PROPS')
	@:pin('control')
	public function testTheOverlayLeavesTheReceiverAloneAndKeepsTheRest(): Void {
		final base: LintConfig = LintConfig.parse('{"rules":{"member-order":{"enabled":false,"movableArglessNew":true}}}');
		final lifted: LintConfig = MemberOrder.withBudget(base, 7);
		Assert.equals(7, lifted.intOption('member-order', 'maxRelocatedLines'));
		Assert.isNull(base.intOption('member-order', 'maxRelocatedLines'), 'the receiver is unchanged');
		Assert.equals(true, lifted.boolOption('member-order', 'movableArglessNew'), 'the other option stays');
		Assert.isFalse(lifted.enabledFor('member-order'), 'and so does the switch');
	}

	/** A type whose canonical order moves every member: 80 public/private-static pairs, far over the default budget. */
	private static function oversized(): String {
		final filler: String = '\t\tvar v: Int = 0;';
		final pairs: Array<String> = [
			for (i in 0...80) '\tpublic function m$i(): Void {\n$filler\n\t}\n\n\tprivate static function s$i(): Void {\n$filler\n\t}'
		];
		final body: String = pairs.join('\n\n');
		return 'class C {\n\n$body\n\n}\n';
	}

	/** The fix of `src` under `lines` as the run's budget, or under the default when null. */
	private static function fixRunUnder(src: String, lines: Null<Int>): FixRun {
		final config: LintConfig = lines == null ? LintConfig.parse('{}') : MemberOrder.withBudget(LintConfig.parse('{}'), lines);
		return CheckFixture.fixRun(new MemberOrder(), [{ file: 'Probe.hx', source: src }], 'Probe.hx', new HaxeQueryPlugin(), _ -> config);
	}

}
