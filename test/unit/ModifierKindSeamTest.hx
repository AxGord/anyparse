package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.CheckScan;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HxCondModPrefix;
import anyparse.grammar.haxe.HxMemberModifier;
import anyparse.grammar.haxe.HxModifier;
import anyparse.query.GrammarPlugin;

/**
 * The drift guard between the Haxe modifier ENUMS and the seams that publish them.
 *
 * `overload` was declared by all three modifier enums and carried by no seam at all, so every
 * walk that answers "is this preceding sibling a modifier?" stopped at it: `@:keep overload
 * function f` read as un-annotated and `unused-private --fix` deleted the member, leaving a bare
 * `@:keep overload` prefix behind. Nothing failed — the sets simply disagreed, and no test
 * compared them.
 *
 * So compare them here, against the enums rather than against a second list: every constructor
 * of `HxMemberModifier`, `HxModifier` and `HxCondModPrefix` must be CLAIMED by a declared seam —
 * `RefShape.modifierKinds` for a modifier, `MetaShape.metaKinds` for an annotation,
 * `conditionalMemberKind` for the `#if` region, `condDeclPrefixKeywordKinds` for a keyword a
 * region merely contributes. A new constructor added to a grammar enum and to nothing else fails
 * here, whichever of the four it belongs in.
 */
class ModifierKindSeamTest extends Test {

	/** Every member-position modifier reaches a check. This is the set `overload` was missing from. */
	public function testMemberModifierEnumIsFullyClaimed(): Void {
		assertClaimed('HxMemberModifier', Type.getEnumConstructs(HxMemberModifier));
	}

	/** The top-level twin: `private`/`extern`/`overload` in front of a `class` / `typedef` / `enum`. */
	public function testTopLevelModifierEnumIsFullyClaimed(): Void {
		assertClaimed('HxModifier', Type.getEnumConstructs(HxModifier));
	}

	/**
	 * The element type of a `#if ... #end` modifier region, which is widened: alongside the plain
	 * modifiers it admits `Meta` and the bare `enum` keyword, each claimed by its own seam.
	 */
	public function testCondRegionModifierEnumIsFullyClaimed(): Void {
		assertClaimed('HxCondModPrefix', Type.getEnumConstructs(HxCondModPrefix));
	}

	/**
	 * Membership is not ranking. A modifier the language documents no canonical position for is
	 * absent from `modifierOrderKinds` BY DESIGN — ranking it would invent an order `modifier-order`
	 * would then rewrite code to satisfy — and it still precedes the declaration it modifies. Reading
	 * the membership set off the ranking is what lost `overload` and `abstract`.
	 */
	public function testUnrankedModifiersAreStillModifierKinds(): Void {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		final kinds: Array<String> = CheckScan.modifierKinds(shape);
		final order: Array<String> = shape.modifierOrderKinds ?? [];
		for (kind in ['Overload', 'Abstract', 'Dynamic', 'Macro', 'Extern']) {
			Assert.isTrue(kinds.contains(kind), '$kind is not a modifier kind');
			Assert.isFalse(order.contains(kind), '$kind gained a canonical rank - the two sets answer one question again');
		}
	}

	/**
	 * Assert every constructor of one grammar modifier enum is claimed by a declared seam. A
	 * constructor claimed by none is invisible to every leading-run walk; `ctors` being empty would
	 * pass vacuously, so the reflection itself is asserted first.
	 */
	private function assertClaimed(enumName: String, ctors: Array<String>): Void {
		Assert.isTrue(ctors.length > 1, '$enumName exposed no constructors - the guard would pass vacuously');
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		final modifiers: Array<String> = CheckScan.modifierKinds(shape);
		final metas: Array<String> = plugin.metaShape().metaKinds;
		final region: Null<String> = shape.conditionalMemberKind;
		final contributed: Array<String> = shape.condDeclPrefixKeywordKinds ?? [];
		for (ctor in ctors)
			Assert.isTrue(
				modifiers.contains(ctor) || metas.contains(ctor) || ctor == region || contributed.contains(ctor),
				'$enumName.$ctor is claimed by no RefShape seam'
			);
	}

}
