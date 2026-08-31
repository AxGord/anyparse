package unit;

import anyparse.check.CheckScan;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HxCondModPrefix;
import anyparse.grammar.haxe.HxMemberModifier;
import anyparse.grammar.haxe.HxModifier;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.RemoveElement;
import anyparse.query.ReplaceNode;
import utest.Assert;
import utest.Test;

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
	 * The THIRD list, and the one the guard above could not see: `RefactorSupport`'s own
	 * `MODIFIER_META_KINDS`, a hand-copy of the same grammar knowledge kept because
	 * `declGroupSpan` / `declRunStart` are statics with no `RefShape` at any call site. It
	 * had drifted in exactly the way this class was written about — `Overload` present in
	 * all three grammar enums, present in `RefShape.modifierKinds`, absent here — so the
	 * span every structural op folds STOPPED at an `overload` keyword. Ask the predicate,
	 * not the list: `isDeclPrefixSibling` is what every walk calls.
	 */
	public function testEveryModifierSeamKindIsADeclPrefixSibling(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		final kinds: Array<String> = CheckScan.modifierKinds(shape).concat(plugin.metaShape().metaKinds);
		Assert.isTrue(kinds.length > 1, 'the seams exposed no kinds - the guard would pass vacuously');
		for (kind in kinds)
			Assert.isTrue(
				RefactorSupport.isDeclPrefixSibling(new QueryNode(kind, null, [])),
				'$kind is a declared prefix seam but RefactorSupport does not fold it into the decl group'
			);
	}

	/**
	 * The same set inside a `#if … #end` region: a region whose entries are all modifiers is
	 * itself one prefix sibling, and `isConditionalModifierRegion` reads the SAME list — so a
	 * missing kind broke `#if cpp overload #end` too, not just the bare keyword.
	 */
	public function testAConditionalRegionOfAnyModifierIsADeclPrefixSibling(): Void {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		final region: Null<String> = shape.conditionalMemberKind;
		Assert.notNull(region, 'the plugin declares no conditional region kind - the guard would pass vacuously');
		final regionKind: String = region ?? '';
		for (kind in CheckScan.modifierKinds(shape))
			Assert.isTrue(
				RefactorSupport.isDeclPrefixSibling(new QueryNode(regionKind, null, [new QueryNode(kind, null, [])])),
				'a conditional region holding only $kind is not folded into the decl group'
			);
	}

	/**
	 * The FOURTH hand-copy in the same file, found by review of the third: `RefactorSupport`'s
	 * `COND_DECL_PREFIX_KEYWORD_KINDS` mirrors `RefShape.condDeclPrefixKeywordKinds` — the bare
	 * declaration-starting keywords a `#if … #end` region may contribute to the declaration after
	 * its `#end` — and carried no seam test at all. The slice's own argument, that a hand-copy
	 * drifts, applies to it verbatim.
	 */
	public function testEveryCondDeclPrefixKeywordIsADeclPrefixSibling(): Void {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		final region: Null<String> = shape.conditionalMemberKind;
		final keywords: Array<String> = shape.condDeclPrefixKeywordKinds ?? [];
		Assert.notNull(region, 'the plugin declares no conditional region kind - the guard would pass vacuously');
		Assert.isTrue(keywords.length > 0, 'the plugin declares no conditional decl-prefix keywords - the guard would pass vacuously');
		final regionKind: String = region ?? '';
		for (kind in keywords)
			Assert.isTrue(
				RefactorSupport.isDeclPrefixSibling(new QueryNode(regionKind, null, [new QueryNode(kind, null, [])])),
				'a conditional region contributing only $kind is not folded into the decl group'
			);
	}

	/**
	 * End to end, and the shape that found it: `overload` broke the fold, so removing the
	 * member cut only `public function f…` and left `extern overload` standing — which the
	 * NEXT declaration then silently absorbed (`extern overload public function keep`), at
	 * rc 0 with a file that still parses.
	 */
	public function testRemovingAnOverloadMemberTakesItsWholeModifierRun(): Void {
		final source: String = 'extern class C {\n\textern overload public function f(a:Int):Void;\n\tpublic function keep():Void;\n}\n';
		assertRemove(source, 2, 25, 'extern class C {\n\tpublic function keep():Void;\n}\n');
	}

	/**
	 * The mirror direction: a cursor ON the `overload` keyword. The forward walk stopped
	 * there too, so the op treated `overload` as the DECLARATION and removed
	 * `extern overload` — reporting a target of `Overload` while editing two keywords.
	 */
	public function testACursorOnOverloadStillTargetsTheMemberItPrecedes(): Void {
		final source: String = 'extern class C {\n\textern overload public function f(a:Int):Void;\n\tpublic function keep():Void;\n}\n';
		assertRemove(source, 2, 9, 'extern class C {\n\tpublic function keep():Void;\n}\n');
	}

	/** `replace-node` splices the same span — it duplicated the run instead of replacing it. */
	public function testReplacingAnOverloadMemberReplacesItsModifierRun(): Void {
		final source: String = 'extern class C {\n\tpublic overload function g(b:Int):Void;\n}\n';
		assertReplace(
			source, 'FnMember:g', 'public overload function g(b:Int, c:Int):Void;',
			'extern class C {\n\tpublic overload function g(b:Int, c:Int):Void;\n}\n'
		);
	}

	private function assertRemove(source: String, line: Int, col: Int, expected: String): Void {
		switch RemoveElement.removeElement(source, line, col, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertReplace(source: String, selector: String, newSource: String, expected: String): Void {
		switch ReplaceNode.replaceNode(source, ReplaceTarget.BySelector(selector), newSource, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
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
