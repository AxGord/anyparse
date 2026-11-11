package unit.check.common.members;

import anyparse.check.LintConfig;
import anyparse.check.common.members.MemberOrder;
import anyparse.query.CanonicalEdit;

using StringTools;

/**
 * `member-order` on an `enum abstract`. The values of one stand first, in source order and apart from visibility and
 * initializer, because their order is the auto-numbering of an `Int` abstract; the other members sort as in a class.
 */
@:nullSafety(Strict)
final class MemberOrderEnumAbstractTest extends Test {

	/** A function, a property, a `static` member and two values, in the order a class would be flagged for. */
	private static final MIXED: String = 'public function f():Bool { return true; } final B; public var v(get, never):Bool; final A; '
		+ 'static inline var K:Int = 1; private function get_v():Bool { return false; } public function g():Bool { return true; }';

	private final _plugin: HaxeQueryPlugin = new HaxeQueryPlugin();

	/** An enum abstract holding more than values is flagged the way the same members in a class are. */
	@:pin('control')
	@:killer('M-MO-ENUM-ABSTRACT-WALK-OFF')
	public function testAnEnumAbstractWithMembersIsFlagged(): Void {
		Assert.equals(1, violations('class C { ${asClass(MIXED)} }').length, 'the class form is flagged');
		Assert.equals(1, violations('enum abstract E(Int) { $MIXED }').length, 'and so is the enum abstract');
	}

	/** The fix puts the values first with `B` still before `A`, the other members after, and the result is a fixed point. */
	@:pin('control')
	@:killer('M-MO-ENUM-VALUE-RANK-OFF')
	public function testTheFixKeepsTheValuesFirstInSourceOrder(): Void {
		final fixed: String = fixedSource('enum abstract E(Int) { $MIXED }');
		final at: Array<Int> = [
			'final B',
			'final A',
			'static inline var K',
			'var v(get',
			'function get_v(',
			'function f(',
			'function g('
		].map(needle -> fixed.indexOf(needle));
		Assert.isFalse(at.contains(-1), 'every member survives: $fixed');
		for (i in 1...at.length) Assert.isTrue(at[i - 1] < at[i], 'member $i follows member ${i - 1}: $fixed');
		Assert.equals(0, violations(fixed).length, 'the fix converges: $fixed');
	}

	/** A value written without an initializer stays ahead of the initialized ones: the class sub-order does not reach values. */
	@:pin('control')
	@:killer('M-MO-ENUM-VALUE-KEEPS-SOURCE-ORDER-OFF')
	public function testValuesKeepTheirOrderWhateverTheirInitializers(): Void {
		final src: String = 'enum abstract E(Int) { public function f():Bool { return true; } final A; final B = 5; final C = 6; }';
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('final A') < fixed.indexOf('final B') && fixed.indexOf('final B') < fixed.indexOf('final C'), fixed);
		Assert.isTrue(fixed.indexOf('final C') < fixed.indexOf('function f'), fixed);
	}

	/** A list of values alone has nothing to report, whatever visibility or initializer each carries. */
	@:pin('control')
	@:killer('M-MO-ENUM-VALUE-RANK-OFF')
	public function testAPlainValueListHasNoFinding(): Void {
		Assert.equals(0, violations('enum abstract E(Int) { final A; final B = 5; private var C = 6; public final D = 7; }').length);
	}

	/** A value inside an `#if` region keeps its place among the values. */
	@:pin('control')
	@:killer('M-MO-ENUM-VALUE-RANK-OFF')
	public function testAConditionalValueKeepsItsPlace(): Void {
		final src: String = 'enum abstract E(Int) {\n\tpublic function f():Bool { return true; }\n\n\tfinal A;\n\n\t#if foo\n\tfinal B;\n'
			+ '\t#end\n\n\tfinal C;\n}';
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('final A') < fixed.indexOf('final B') && fixed.indexOf('final B') < fixed.indexOf('final C'), fixed);
		Assert.isTrue(fixed.indexOf('final C') < fixed.indexOf('function f'), fixed);
	}

	/** Other rules read `visibilityContainerKinds` for what a visibility container is, so an enum abstract is not added to it. */
	@:pin('guard')
	public function testTheVisibilityContainersLeaveEnumAbstractsOut(): Void {
		Assert.isFalse((_plugin.refShape().visibilityContainerKinds ?? []).contains(_plugin.refShape().enumAbstractDeclKind ?? ''));
	}

	/** A legacy `@:enum abstract` is an enum abstract too: a list of its values has nothing to report. */
	@:pin('control')
	@:killer('M-MO-ENUM-LEGACY-REPORT-OFF')
	public function testALegacyValueListHasNoFinding(): Void {
		Assert.equals(0, violations('@:enum abstract E(Int) { var B; public var A; var C = 5; var D; }').length);
	}

	/** The legacy spelling keeps `B` before `A` under the fix, though `A` is the public one a class would lead with. */
	@:pin('control')
	@:killer('M-MO-ENUM-LEGACY-FIX-OFF')
	public function testTheFixKeepsLegacyValuesInSourceOrder(): Void {
		final fixed: String = fixedSource(
			'@:enum abstract E(Int) { public function f():Bool { return true; } var B; public var A; static inline var K:Int = 1; }'
		);
		Assert.isTrue(fixed.indexOf('var B') >= 0 && fixed.indexOf('var B') < fixed.indexOf('var A'), fixed);
		Assert.isTrue(fixed.indexOf('var A') < fixed.indexOf('static inline var K'), fixed);
		Assert.isTrue(fixed.indexOf('static inline var K') < fixed.indexOf('function f'), fixed);
	}

	private function asClass(members: String): String {
		return members.replace('final B;', 'final B:Int = 1;').replace('final A;', 'final A:Int = 2;');
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(checkOf(), src, _plugin);
	}

	private function fixedSource(src: String): String {
		return CanonicalEdit.applyEdits(src, CheckFixture.edits(checkOf(), src, _plugin));
	}

	private function checkOf(): MemberOrder {
		final check: MemberOrder = new MemberOrder();
		check.setConfigResolver(_ -> LintConfig.parse('{}'));
		return check;
	}

}
