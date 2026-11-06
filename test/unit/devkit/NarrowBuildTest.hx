package unit.devkit;

import devkit.NarrowBuild;
import utest.Assert;
import utest.Test;

/** The define a narrow test build carries: what `dev mutation-check` writes is what the registry reads back. */
@:nullSafety(Strict)
final class NarrowBuildTest extends Test {

	public function testTheDefineCarriesTheClassListTheRegistryReadsBack(): Void {
		final define: String = NarrowBuild.define(['unit.b.B', 'unit.a.A']);
		Assert.equals('${NarrowBuild.DEFINE}=unit.b.B,unit.a.A', define);
		Assert.same(['unit.b.B', 'unit.a.A'], NarrowBuild.classes(define.substr(NarrowBuild.DEFINE.length + 1)));
	}

	public function testABlankOrRepeatedEntryNamesNoFurtherClass(): Void {
		Assert.same(['unit.b.B', 'unit.a.A'], NarrowBuild.classes(' unit.b.B, ,unit.a.A,unit.b.B '));
		Assert.same([], NarrowBuild.classes(null), 'no define: no class');
	}

}
