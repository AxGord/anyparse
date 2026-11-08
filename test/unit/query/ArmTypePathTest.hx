package unit.query;

import anyparse.query.ArmTypePath;

/**
 * `ArmTypePath` reads an arm record's `type` as a module and, when it names one, a type declared beside the module's main
 * type: `pack.Module.Sub` cuts a member of `Sub` inside the file `pack/Module.hx`.
 */
class ArmTypePathTest extends Test {

	/** A module's own main type is its module and names no inner type, with or without a package. */
	@:pin('control')
	@:killer('M-ARM-TYPE-SUB-ALWAYS')
	public function testAModuleTypeIsItsOwnModule(): Void {
		Assert.equals('dev.SuiteImpact', ArmTypePath.moduleOf('dev.SuiteImpact'));
		Assert.isNull(ArmTypePath.subTypeOf('dev.SuiteImpact'));
		Assert.equals('Bare', ArmTypePath.moduleOf('Bare'));
		Assert.isNull(ArmTypePath.subTypeOf('Bare'));
		Assert.equals('a.b.C', ArmTypePath.moduleOf('a.b.C'));
	}

	/** The segment after the module is the type inside it, wherever the package ends. */
	@:pin('control')
	@:killer('M-ARM-TYPE-SUB-NEVER')
	public function testTheSegmentAfterTheModuleIsASubModuleType(): Void {
		Assert.equals('dev.SuiteImpact', ArmTypePath.moduleOf('dev.SuiteImpact.ImpactGraph'));
		Assert.equals('ImpactGraph', ArmTypePath.subTypeOf('dev.SuiteImpact.ImpactGraph'));
		Assert.equals('Mod', ArmTypePath.moduleOf('Mod.Side'));
		Assert.equals('Side', ArmTypePath.subTypeOf('Mod.Side'));
	}

	/** A member of a sub-module type is selected inside that type; a module's own member keeps the plain selector. */
	@:pin('control')
	@:killer('M-ARM-TYPE-SELECT-UNSCOPED')
	public function testASubModuleMemberIsSelectedInsideItsType(): Void {
		Assert.equals('FnMember:reach', ArmTypePath.select('dev.SuiteImpact', 'FnMember:reach'));
		Assert.equals('ClassForm:ImpactGraph >> FnMember:reach', ArmTypePath.select('dev.SuiteImpact.ImpactGraph', 'FnMember:reach'));
	}

	/** `hxq graph` names a sub-module type's member by the package and the sub-type; a module's own member by its type path. */
	@:pin('control')
	@:killer('M-ARM-TYPE-GRAPH-MEMBER-MODULE-SPELLING')
	public function testTheGraphNamesASubModuleMemberBySubType(): Void {
		Assert.equals('dev.ImpactGraph.reach', ArmTypePath.graphMember('dev.SuiteImpact.ImpactGraph', 'reach'));
		Assert.equals('dev.SuiteImpact.reach', ArmTypePath.graphMember('dev.SuiteImpact', 'reach'));
		Assert.equals('Side.go', ArmTypePath.graphMember('Mod.Side', 'go'));
	}

}
