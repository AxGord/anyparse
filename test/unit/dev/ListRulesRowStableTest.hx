package unit.dev;

import dev.Probe;
import utest.Assert;
import utest.Test;

/** The cli kit pins a rule list by its shape, so a slice that adds a rule leaves the kits row green. */
@:nullSafety(Strict)
final class ListRulesRowStableTest extends Test {

	public function testEveryListRulesRowOfTheCliKitPinsTheShapeNotTheList(): Void {
		final kit: Kit = Probe.load('test/probes/cli/kit.json');
		var rows: Int = 0;
		for (i in 0...kit.invocations.length) {
			if (kit.invocations[i].argv.contains('--list-rules') && kit.cases[i].expect?.exit == 0) {
				rows++;
				Assert.notNull(kit.cases[i].outShape, kit.invocations[i].name);
			}
		}
		Assert.isTrue(rows > 0);
	}

}
