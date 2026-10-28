package unit.dev;

import dev.GateLint;
import haxe.Json;
import utest.Assert;
import utest.Test;

/** `dev.GateLint`: a moved file's findings at the base are filed under the path the lint row compares them at. */
@:nullSafety(Strict)
final class GateLintTest extends Test {

	@:pin('control')
	@:killer('M-GATE-REBASE-NONE')
	public function testAMovedFilesBaseFindingsTakeItsNewPath(): Void {
		final report: String = '[{"file":"old/C.hx","rule":"r"},{"file":"a/B.hx","rule":"r"}]';
		final records: Array<{ file: String, rule: String }> = Json.parse(
			GateLint.rebased(report, ['old/C.hx' => 'new/C.hx', 'a/B.hx' => 'a/B.hx'])
		);
		Assert.same(['new/C.hx', 'a/B.hx'], [for (r in records) r.file]);
	}

	public function testAReportWithNothingMovedIsAnsweredAsItIs(): Void {
		final report: String = '[{"file":"a/B.hx"}]';
		Assert.equals(report, GateLint.rebased(report, ['a/B.hx' => 'a/B.hx']));
	}

}
