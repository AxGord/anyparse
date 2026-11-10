package unit.check.common.members;

import anyparse.check.common.members.PreferInline;

/**
 * `prefer-inline` on a thin forward whose callee is a MACRO: the macro expands at the call site, so
 * inlining the forwarder copies the expansion into every caller. The rule must read the callee's
 * declaration, not only the forwarder's own shape.
 */
class PreferInlineMacroCallTest extends Test {

	private static final MACROS: String = 'package pkg;\n\nimport haxe.macro.Expr;\n\nclass Macros {\n'
		+ '\tpublic static macro function table(): Expr return macro [1, 2, 3];\n'
		+ '\tpublic static function plain(): Array<Int> return [1, 2, 3];\n}';
	private static final SAME_CLASS_MACRO: String =
		'import haxe.macro.Expr;\n\nclass M {\n\tpublic static macro function table(): Expr return macro [1, 2, 3];\n';

	@:pin('control')
	@:killer('M-INLINE-FORWARD-TO-MACRO')
	public function testForwardToImportedStaticMacroIsNotFlagged(): Void {
		final vs: Array<Violation> = flaggedIn(
			'import pkg.Macros;\n\nclass C {\n\tpublic static function t(): Array<Int> return Macros.table();\n}'
		);
		Assert.equals(0, vs.length, 'the body call is a macro; inlining would copy its expansion to every caller');
	}

	@:pin('control')
	@:killer('M-INLINE-FORWARD-TO-MACRO')
	public function testForwardToQualifiedStaticMacroIsNotFlagged(): Void {
		final vs: Array<Violation> = flaggedIn('class C {\n\tpublic static function t(): Array<Int> return pkg.Macros.table();\n}');
		Assert.equals(0, vs.length);
	}

	public function testForwardToPlainStaticStaysFlagged(): Void {
		final vs: Array<Violation> = flaggedIn(
			'import pkg.Macros;\n\nclass C {\n\tpublic static function t(): Array<Int> return Macros.plain();\n}'
		);
		Assert.equals(1, vs.length, 'the same shape over a non-macro callee keeps its finding');
	}

	@:pin('control')
	@:killer('M-INLINE-FORWARD-TO-MACRO')
	public function testForwardToInheritedMacroThroughImplicitThisIsNotFlagged(): Void {
		final base: String = 'package pkg;\n\nimport haxe.macro.Expr;\n\nclass Base {\n\tpublic function new() {}\n'
			+ '\tpublic macro function expand(): Expr return macro 1;\n}';
		final vs: Array<Violation> = CheckFixture.violationsIn(new PreferInline(), [
			{ file: 'pkg/Base.hx', source: base },
			{ file: 'D.hx', source: 'class D extends pkg.Base {\n\tpublic function t(): Int return expand();\n}' }
		])
			.filter(v -> v.file == 'D.hx');
		Assert.equals(0, vs.length);
	}

	public function testForwardToUnresolvedCalleeStaysFlagged(): Void {
		Assert.equals(
			1, flaggedIn('class C {\n\tpublic static function t(): Array<Int> return Elsewhere.table();\n}').length,
			'a callee no declaration of the scope holds is not proven a macro, so today\'s finding stands'
		);
	}

	@:pin('control')
	@:killer('M-INLINE-FORWARD-TO-MACRO')
	public function testBareForwardToMacroOfTheSameClassIsNotFlagged(): Void {
		final vs: Array<Violation> = CheckFixture.violationsIn(new PreferInline(), [
			{ file: 'M.hx', source: '$SAME_CLASS_MACRO\tpublic static function bare(): Array<Int> return table();\n}' }
		]);
		Assert.equals(0, vs.length, 'a bare call binds the class member, which is the macro');
	}

	public function testParameterNamedLikeTheMacroStillShadowsIt(): Void {
		final vs: Array<Violation> = CheckFixture.violationsIn(new PreferInline(), [
			{
				file: 'M.hx',
				source: '$SAME_CLASS_MACRO\tpublic static function viaParam(table: () -> Array<Int>): Array<Int> return table();\n}'
			}
		]);
		Assert.equals(1, vs.length, 'the call goes through the parameter, not the macro member');
	}

	@:pin('control')
	@:killer('M-INLINE-FORWARD-TO-MACRO')
	public function testForwardToMacroOnAnInstanceReceiverIsNotFlagged(): Void {
		final base: String = 'package pkg;\n\nimport haxe.macro.Expr;\n\nclass Base {\n\tpublic function new() {}\n'
			+ '\tpublic macro function expand(): Expr return macro 1;\n}';
		final vs: Array<Violation> = CheckFixture.violationsIn(new PreferInline(), [
			{ file: 'pkg/Base.hx', source: base },
			{
				file: 'D.hx',
				source: 'class D extends pkg.Base {\n\tpublic function viaThis(): Int return this.expand();\n'
				+ '\tpublic function viaValue(b: pkg.Base): Int return b.expand();\n}'
			}
		])
			.filter(v -> v.file == 'D.hx');
		Assert.equals(0, vs.length, 'both `this.expand()` and `b.expand()` call the macro');
	}

	private function flaggedIn(consumer: String): Array<Violation> {
		return CheckFixture.violationsIn(
			new PreferInline(), [{ file: 'pkg/Macros.hx', source: MACROS }, { file: 'C.hx', source: consumer }]
		)
			.filter(v -> v.file == 'C.hx');
	}

}
