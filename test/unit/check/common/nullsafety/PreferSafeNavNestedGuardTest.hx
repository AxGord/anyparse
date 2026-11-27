package unit.check.common.nullsafety;

import anyparse.check.common.nullsafety.PreferSafeNav;

class PreferSafeNavNestedGuardTest extends Test {

	private static final SOURCE: String = 'class Bar {\n\tpublic function new() {}\n\n\tpublic function on():Void {}\n}\n\nclass Axis {\n'
		+ '\tpublic var bar(default, null):Null<Bar> = null;\n\n\tpublic function new() {}\n}\n\nclass C {\n'
		+ '\tprivate final _axis:Null<Axis> = null;\n\n\tpublic function new() {}\n\n\tpublic function a():Void {\n\t\tif (_axis != null '
		+ '&& _axis.bar != null) _axis.bar.on();\n\t}\n\n\tpublic function b():Void {\n\t\tif (_axis != null) _axis.bar?.on();\n\t}\n}';

	@:pin('control')
	@:killer('M-PSN-RUN-LAST-ONLY')
	public function testNestedGuardAndHalfFoldedFormBothReachFullChain(): Void {
		final fixed: String = CheckFixture.fixedSource(new PreferSafeNav(), SOURCE);
		Assert.equals(2, fixed.split('_axis?.bar?.on();').length - 1);
	}

}
