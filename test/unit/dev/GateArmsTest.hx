package unit.dev;

import dev.GateArms;
import dev.MergeArms;
import dev.MergeArms.RecordFile;
import utest.Assert;
import utest.Test;

/** The arms row of a slice gate: which arms get the kill run and which only have to still apply. */
@:nullSafety(Strict)
final class GateArmsTest extends Test {

	private static final REGISTRY: String = '{"arms": [{"name": "M-SAME", "type": "a.Untouched", "method": "f", "force": "1"},'
		+ '{"name": "M-LAYOUT", "type": "a.Reflowed", "method": "f", "force": "1"},{"name": "M-LAYOUT-SUB", "type": "a.Reflowed.Inner", '
		+ '"method": "f", "force": "1"},{"name": "M-EDITED", "type": "a.Edited", "method": "f", "force": "1"},{"name": "M-PINNED", "type": '
		+ '"a.Reflowed", "method": "g", "force": "1"},{"name": "M-ASKED", "type": "a.Untouched", "method": "g", "force": "1"}]}';

	public function testAnArmOnAFileOfLayoutOnlyChangesOnlyHasToStillApply(): Void {
		final picked: ArmSelection = select(['a.Edited'], ['a.Reflowed'], ['M-PINNED'], ['M-ASKED']);
		Assert.same(['M-EDITED', 'M-PINNED', 'M-ASKED'], picked.fast);
		Assert.same(['M-LAYOUT', 'M-LAYOUT-SUB'], picked.applyOnly, 'a sub-type of the file counts, a pinned or asked arm does not');
	}

	public function testWithoutLayoutOnlyFilesEveryArmOnATouchedFileGetsTheKillRun(): Void {
		final picked: ArmSelection = select(['a.Edited', 'a.Reflowed'], [], [], []);
		Assert.same(['M-LAYOUT', 'M-LAYOUT-SUB', 'M-EDITED', 'M-PINNED'], picked.fast);
		Assert.same([], picked.applyOnly);
	}

	public function testAnArmNewSinceTheBaseGetsTheKillRunOnAnyFile(): Void {
		final base: String = '{"arms": [{"name": "M-SAME", "type": "a.Untouched", "method": "f", "force": "1"}]}';
		final picked: ArmSelection = GateArms.select(MergeArms.parse(REGISTRY).records, MergeArms.parse(base), [], ['a.Reflowed'], [], []);
		Assert.same(['M-LAYOUT', 'M-LAYOUT-SUB', 'M-EDITED', 'M-PINNED', 'M-ASKED'], picked.fast);
		Assert.same([], picked.applyOnly);
	}

	public function testTheFilesOfAChangedReportThatAreLayoutOnly(): Void {
		final report: String = [
			'changed against main: 5 file(s) — declarations 1, layout 3',
			'M tools/src/dev/A.hx  layout',
			'M tools/src/dev/B.hx  declarations  +4 -1',
			'    ~ FnMember:layout  +1 -1',
			'R100 tools/src/dev/C.hx  <- tools/src/dev/Old.hx  layout',
			'M docs/with space.hx  layout',
			''
		].join('\n');
		Assert.same(['tools/src/dev/A.hx', 'tools/src/dev/C.hx', 'docs/with space.hx'], GateArms.layoutOf(report));
		Assert.same([], GateArms.layoutOf(''));
	}

	private static function select(
		touched: Array<String>, layout: Array<String>, killers: Array<String>, extra: Array<String>
	): ArmSelection {
		final same: RecordFile = MergeArms.parse(REGISTRY);
		return GateArms.select(same.records, same, touched, layout, killers, extra);
	}

}
