package unit.check.common.design;

import anyparse.check.common.design.RuleDeclaration;

using StringTools;

/** `RuleDeclaration.armRegistry`: the arms by name, a registry's other keys skipped, and a line in `problems` for what it cannot use. */
class RuleDeclarationArmRegistryTest extends Test {

	private static inline final LABEL: String = 'arm registry a.json';

	public function testTheArmsByName(): Void {
		final problems: Array<String> = [];
		final arms: Map<String, ArmTarget> = RuleDeclaration.armRegistry(
			'{"$$comment": ["c"], "arms": [{"name": "M-A", "type": "a.T", "method": "m", "find": ["x"], "replace": ["y"], "note": "n"}]}',
			LABEL, problems
		);
		Assert.equals('a.T', arms['M-A']?.type);
		Assert.equals('m', arms['M-A']?.method);
		Assert.same([], problems);
	}

	public function testWhatIsNoRegistryIsNamedAndReadsAsNoArms(): Void {
		final problems: Array<String> = [];
		Assert.isFalse(RuleDeclaration.armRegistry('{"other": []}', LABEL, problems).iterator().hasNext());
		Assert.same(['arm registry a.json holds no "arms" array'], problems);
		final notJson: Array<String> = [];
		Assert.isFalse(RuleDeclaration.armRegistry('not json', LABEL, notJson).iterator().hasNext());
		Assert.equals(1, notJson.length);
		Assert.isTrue(notJson[0].startsWith('arm registry a.json is not JSON: '), notJson[0]);
	}

	public function testAWrongShapedArmIsNamedWithItsFieldAndTheOthersStay(): Void {
		final problems: Array<String> = [];
		final arms: Map<String, ArmTarget> = RuleDeclaration.armRegistry(
			'{"arms": [{"name": "M-A", "type": "a.T", "method": "m"}, {"name": "M-B", "method": 1}, {"type": "a.T", "method": "m"}, 5]}',
			LABEL, problems
		);
		Assert.equals('a.T', arms['M-A']?.type);
		Assert.isFalse(arms.exists('M-B'));
		Assert.same([
			'arm registry a.json arm #2 "M-B": "type" is not a string — dropped',
			'arm registry a.json arm #2 "M-B": "method" is not a string — dropped',
			'arm registry a.json arm #3: "name" is not a string — dropped',
			'arm registry a.json arm #4: "name" is not a string — dropped',
			'arm registry a.json arm #4: "type" is not a string — dropped',
			'arm registry a.json arm #4: "method" is not a string — dropped'
		], problems);
	}

}
