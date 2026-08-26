package unit;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.MemberOrder;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * A declaration's SLOT must cover its own modifiers and metadata and must not
 * cover the next declaration's - the one invariant `member-order --fix` rests on
 * that nothing mechanical checks. Every breach of it produces code that still
 * COMPILES: the reorder moves the declaration and leaves (or drags) a modifier,
 * and the result is a silent visibility change, a duplicated `inline`, or an
 * `@:from` re-attached to an unrelated member.
 *
 * Three shapes, all measured on `Pony`, breaching it in two different layers:
 *
 *  - PARSE. `function get_touchScreen():Bool return #if ios true; #else false; #end`
 *    (`pony/ui/touch/TouchableBase.hx:313`) reached `HxExpr.CondSpliceExpr`, whose
 *    MANDATORY `tail` parses whatever follows the `#end` - at a member boundary the
 *    NEXT member's leading `public`, read as an `IdentExpr` INSIDE the function.
 *    `HxExpr.CondSpliceReturnExpr` ends the region at its own `#end`.
 *  - SLOT. `#if !flash inline #end public function ret(...)` (`pony/TypedPool.hx:23`)
 *    and `@:from #if (haxe_ver >= 4.2) extern #else @:extern #end`
 *    (`pony/events/Listener0.hx:24`) spell a modifier inside a `#if ... #end` region,
 *    which projects as a `Conditional` SIBLING; `RefactorSupport.declGroupSpan`
 *    stopped its walk-back there, so the guard stayed behind on a reorder
 *    (`Duplicate access modifier inline`, `@:from cast functions must be static`).
 *
 * Each fix layer is pinned on its own: a span assertion for the slot, an autofix
 * assertion for what a reorder then does with it.
 */
class MemberOrderModifierSpanSliceTest extends Test {

	/**
	 * The parse-level half of the `TouchableBase` shape: the `public` opening the
	 * NEXT member must be a direct child of the container, not a node inside the
	 * `return #if ... #end` member above it.
	 */
	public function testConditionalReturnRegionLeavesNextMemberModifierAlone(): Void {
		final src: String = returnRegionSource();
		final at: Int = src.indexOf('public static final');
		Assert.isTrue(at > 0, 'fixture holds the following member');
		final container: QueryNode = containerOf(src);
		final owners: Array<String> = [for (c in container.children) if (covers(c, at)) c.kind];
		Assert.equals('Public', owners.join(','), 'the modifier is its own sibling slot, not part of the member above it');
	}

	/** The same shape through the autofix: the reordered field keeps its `public`, and no orphan modifier line is left. */
	public function testConditionalReturnRegionReorderKeepsFieldPublic(): Void {
		final fixed: String = canonicalizedFix(returnRegionSource());
		Assert.isTrue(fixed.indexOf('public static final NAME') >= 0, 'NAME keeps its `public`: $fixed');
		Assert.isTrue(fixed.indexOf('NAME') < fixed.indexOf('get_touchScreen'), 'the constant moved above the accessor: $fixed');
		Assert.isNull(fixed.split('\n').find(line -> line.trim() == 'public'), 'no modifier left dangling on its own line: $fixed');
	}

	/** `declGroupSpan` starts a declaration's group at the `#if` of a region that guards only its modifiers. */
	public function testDeclGroupSpanCoversTheConditionalModifierRegion(): Void {
		final src: String = 'class C {\n\t#if !flash\n\tinline\n\t#end\n\tpublic function ret(): Void {}\n}';
		final container: QueryNode = containerOf(src);
		final fn: Null<QueryNode> = childNamed(container, 'ret');
		Assert.notNull(fn);
		if (fn == null) return;
		final span: Null<Span> = fn.span;
		Assert.notNull(span);
		if (span == null) return;
		Assert.equals(src.indexOf('#if !flash'), RefactorSupport.declGroupSpan(fn, container, span).from);
	}

	/** The `TypedPool` shape: the `#if !flash inline #end` guard stays in front of the member it qualifies when a sibling sorts past it. */
	public function testConditionalModifierRegionTravelsWithItsMember(): Void {
		final src: String = 'class C {\n\n\tpublic var isDestroy(get, never): Bool;\n\n\tpublic inline function new() {}\n\n'
			+ '\t#if !flash\n\tinline\n\t#end\n\tpublic function ret(obj: Int): Void {}\n\n'
			+ '\tpublic inline function get_isDestroy(): Bool return true;\n\n}';
		final fixed: String = canonicalizedFix(src);
		Assert.isTrue(fixed.indexOf('get_isDestroy') < fixed.indexOf('#if !flash'), 'the accessor moved above the guard: $fixed');
		Assert.isTrue(lineAfter(fixed, '#end').startsWith('public function ret'), 'the guard still leads `ret`: $fixed');
	}

	/** The `Listener0` shape: a `@:meta` plus guarded-modifier prefix is one group with the function under it. */
	public function testGuardedMetaPrefixTravelsWithItsFunction(): Void {
		final src: String = 'abstract A(Int) {\n\n\t@:from #if (haxe_ver >= 4.2) extern #else @:extern #end\n'
			+ '\tprivate static inline function f0(f: Int): A return cast f;\n\n\tpublic var isEvent(get, never): Bool;\n\n'
			+ '\tpublic inline function get_isEvent(): Bool return true;\n\n}';
		final fixed: String = canonicalizedFix(src);
		Assert.isTrue(fixed.indexOf('function f0') > fixed.indexOf('isEvent'), 'the private static helper sorted below: $fixed');
		Assert.isTrue(
			lineAfter(fixed, '@:from #if (haxe_ver >= 4.2) extern #else @:extern #end').startsWith('private static inline function f0'),
			'the guarded `@:from` prefix still leads `f0`: $fixed'
		);
	}

	/** The `TouchableBase.get_touchScreen` shape, with the member that used to be swallowed after it. */
	private inline function returnRegionSource(): String {
		return
			'class C {\n\n\tpublic function check(): Void {}\n\n\tprivate static inline function get_touchScreen(): Bool return #if ios '
				+ 'true; #else false; #end\n\n\tpublic static final NAME: String = "x";\n\n}';
	}

	/** The single type declaration in `src` as a query node - the container `member-order` walks. */
	private function containerOf(src: String): QueryNode {
		final root: QueryNode = new HaxeQueryPlugin().parseFile(src);
		return root.children.find(c -> c.name != null) ?? root;
	}

	/** The direct child of `container` declared as `name`. */
	private function childNamed(container: QueryNode, name: String): Null<QueryNode> {
		return container.children.find(c -> c.name == name);
	}

	/** Whether `node`'s own span contains the offset `at`. */
	private function covers(node: QueryNode, at: Int): Bool {
		final span: Null<Span> = node.span;
		return span != null && span.from <= at && at < span.to;
	}

	/** The line after the first one whose trimmed text is `needle`, trimmed, or `''` - keeps the assertion off whole-source substring order. */
	private function lineAfter(src: String, needle: String): String {
		final lines: Array<String> = src.split('\n');
		for (i in 0...lines.length - 1) if (lines[i].trim() == needle) return lines[i + 1].trim();
		return '';
	}

	/**
	 * Apply `member-order`'s fix edits through the production canonicalization
	 * (splice plus `writeRoundTrip`), the seam `lint --fix` itself writes through.
	 */
	private function canonicalizedFix(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: MemberOrder = new MemberOrder();
		final cfg: LintConfig = LintConfig.parse('{}');
		check.setConfigResolver(_ -> cfg);
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		return switch RefactorSupport.canonicalize(src, check.fix(src, vs, plugin), true, plugin) {
			case Ok(text): text;
			case Err(message):
				Assert.fail(message);
				src;
		};
	}

}
