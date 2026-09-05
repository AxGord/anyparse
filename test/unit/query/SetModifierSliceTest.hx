package unit.query;

import anyparse.check.CheckScan;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SetModifier;
import haxe.Exception;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * Probe for `apq set-modifier` — the safe modifier flip (replacing the
 * `replace-node --at <modifier>` footgun that overwrote the whole decl). Drives
 * `SetModifier.setModifier` directly on in-memory sources (pure, JS-native,
 * `reformat = true`): visibility flips, a boolean modifier is added / removed,
 * a bare declaration gains a visibility, and a `final` / unknown change is an
 * `Err`. The declaration body must survive every flip.
 */
class SetModifierSliceTest extends Test {

	private static inline final PRIVATE_FN: String = 'package p;\nclass C {\n\tprivate function f(): Int return 1;\n}';

	/**
	 * A module-level `private typedef`, the T577 fixture: `class C` and a module-private helper type
	 * beside it. Line 4 column 1 is the `private` keyword, which the cursor convention reads as the
	 * declaration's first token.
	 */
	private static inline final MODULE_PRIVATE_TYPEDEF: String = 'package p;\nclass C {}\n\nprivate typedef Helper = {\n\tvar n:Int;\n}';

	/** private → public, body intact, old visibility gone. */
	public function testFlipVisibility(): Void {
		final text: String = okText(SetModifier.setModifier(PRIVATE_FN, 3, 2, ['public'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('public function f'));
		Assert.isFalse(text.contains('private'));
		Assert.isTrue(text.contains('return 1'));
	}

	/** Visibility flip + a boolean modifier added in one call. */
	public function testFlipAndAddStatic(): Void {
		final text: String = okText(SetModifier.setModifier(PRIVATE_FN, 3, 2, ['public', '+static'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('public static function f'));
	}

	/** A boolean modifier is removed. */
	public function testRemoveInline(): Void {
		final src: String = 'package p;\nclass C {\n\tpublic inline function f(): Int return 1;\n}';
		final text: String = okText(SetModifier.setModifier(src, 3, 2, ['-inline'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('public function f'));
		Assert.isFalse(text.contains('inline'));
	}

	/** A bare (no-modifier) declaration gains a visibility. */
	public function testAddVisibilityToBare(): Void {
		final src: String = 'package p;\nclass C {\n\tfunction f(): Int return 1;\n}';
		final text: String = okText(SetModifier.setModifier(src, 3, 2, ['public'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('public function f'));
	}

	/** A `final` change is rejected (it wraps the declaration). */
	public function testFinalChangeRejected(): Void {
		Assert.isTrue(isErr(SetModifier.setModifier(PRIVATE_FN, 3, 2, ['+final'], true, new HaxeQueryPlugin())));
	}

	/** An unknown modifier is rejected. */
	public function testUnknownRejected(): Void {
		Assert.isTrue(isErr(SetModifier.setModifier(PRIVATE_FN, 3, 2, ['+frobnicate'], true, new HaxeQueryPlugin())));
	}

	/**
	 * The run walk stops at any keyword it does not recognise, and then the op INSERTS a
	 * visibility in front of the declaration instead of replacing the one already there:
	 * `public overload function g` came back `public overload private function g`, which parses,
	 * passes the re-parse gate, and which Haxe rejects with `Conflicting access modifier`.
	 */
	public function testFlippingAnOverloadMembersVisibilityDoesNotEmitASecondOne(): Void {
		assertFlipToPrivateKeeps('package p;\nclass C {\n\tpublic overload function g(): Int return 1;\n}', 'overload');
	}

	/** The `abstract` twin. */
	public function testFlippingAnAbstractMembersVisibilityDoesNotEmitASecondOne(): Void {
		assertFlipToPrivateKeeps('package p;\nabstract class C {\n\tpublic abstract function q(): Int;\n}', 'abstract function');
	}

	/**
	 * A `#if … #end` modifier region between the run and the declaration is the same defect read
	 * through `isConditionalModifierRegion`: the walk stopped at the region, so the flip landed
	 * BELOW it and left the old visibility above. The region itself must survive verbatim — the
	 * splice ends at the last bare keyword, not at the declaration.
	 */
	public function testAConditionalModifierRegionIsNeitherSwallowedNorDuplicated(): Void {
		final src: String = 'package p;\nclass C {\n\tprivate\n\t#if cpp\n\tinline\n\t#end\n\tfunction f(): Int return 1;\n}';
		for (line in [3, 7]) {
			final text: String = okText(SetModifier.setModifier(src, line, 2, ['public'], true, new HaxeQueryPlugin()));
			Assert.equals(1, occurrences(text, 'public'), 'cursor line $line: $text');
			Assert.equals(0, occurrences(text, 'private'), 'cursor line $line: $text');
			Assert.equals(1, occurrences(text, '#if cpp'), 'cursor line $line: $text');
			Assert.equals(1, occurrences(text, 'inline'), 'cursor line $line: $text');
		}
	}

	/**
	 * A modifier the grammar ranks no position for keeps the PHYSICAL slot it held — the rule
	 * `modifier-order`'s own fix states. Rendering the run by filtering `ORDER` instead drops it
	 * altogether, since `ORDER` cannot name it.
	 */
	public function testAnUnrankedModifierKeepsItsSlotAndIsNotDropped(): Void {
		final src: String = 'package p;\nclass C {\n\toverload function h(): Int return 1;\n}';
		final text: String = okText(SetModifier.setModifier(src, 3, 2, ['public'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('overload public function h'), 'got: $text');
	}

	/**
	 * The seam guard, over the GRAMMAR's own modifier set rather than a second list: every
	 * modifier the plugin declares must be a change this op accepts, and must reach the output.
	 * The eight-entry hand-copy that stood in this class refused `overload` / `abstract` as
	 * unknown while the tree projected both.
	 */
	public function testEveryDeclaredModifierIsAnAcceptedChange(): Void {
		final src: String = 'package p;\nclass C {\n\tfunction f(): Int return 1;\n}';
		final names: Array<String> = declaredBooleanModifiers();
		Assert.isTrue(names.length > 1, 'the plugin declared no boolean modifiers - the guard would pass vacuously');
		for (name in names) {
			final text: String = okText(SetModifier.setModifier(src, 3, 2, ['+$name'], true, new HaxeQueryPlugin()));
			Assert.equals(1, occurrences(text, name), '+$name did not reach the output: $text');
		}
	}

	/**
	 * The other direction of the same seam: a member ALREADY carrying the modifier must keep it,
	 * exactly once, across a visibility flip — the walk that could not see the keyword left it
	 * standing beside a second visibility instead.
	 */
	public function testEveryDeclaredModifierSurvivesAVisibilityFlipExactlyOnce(): Void {
		final names: Array<String> = declaredBooleanModifiers();
		Assert.isTrue(names.length > 1, 'the plugin declared no boolean modifiers - the guard would pass vacuously');
		for (name in names) {
			final src: String = 'package p;\nclass C {\n\tpublic $name function f(): Int;\n}';
			for (col in [2, declCursorCol(src, 3)]) {
				final text: String = okText(SetModifier.setModifier(src, 3, col, ['private'], true, new HaxeQueryPlugin()));
				Assert.equals(1, occurrences(text, name), '$name was lost or doubled at col $col: $text');
				Assert.equals(1, occurrences(text, 'private'), 'a second visibility joined $name at col $col: $text');
				Assert.equals(0, occurrences(text, 'public'), 'the old visibility survived beside $name at col $col: $text');
			}
		}
	}

	/**
	 * The FOURTH list read through the same walk: a `#if … #end` region contributing a bare
	 * DECLARATION keyword (`RefShape.condDeclPrefixKeywordKinds` — the `enum` of `enum abstract`).
	 * It is neither a modifier sibling nor an annotation, so the old walk stopped at it too and the
	 * recomputed run came back spliced BELOW the `#end`, beside the visibility still standing above it.
	 *
	 * The change is `-private` and not the visibility FLIP this test used to drive: the shape is a
	 * module-level type, and S92 measured that Haxe rejects `public` on every module-level kind, so the
	 * flip pinned a splice position with an edit whose output does not compile. The insertion arm — no
	 * keyword to splice over, so the new one goes in FRONT of the region — is pinned separately by
	 * `testAVisibilityAddedBeforeAConditionalDeclKeywordRegion`, which adds the one visibility a
	 * module-level declaration can carry.
	 */
	public function testAConditionalDeclKeywordRegionIsNeitherSwallowedNorDuplicated(): Void {
		final src: String = 'package p;\n\nprivate\n#if (haxe_ver >= 4.2)\nenum\n#end\nabstract E(Int) {\n\tfinal X = 1;\n}\n';
		final text: String = okText(SetModifier.setModifier(src, 7, 1, ['-private'], true, new HaxeQueryPlugin()));
		Assert.equals(0, occurrences(text, 'private'), text);
		Assert.equals(1, occurrences(text, '#if (haxe_ver >= 4.2)'), text);
		Assert.equals(1, occurrences(text, 'enum'), text);
		Assert.equals(1, occurrences(text, 'abstract E(Int)'), text);
	}

	/**
	 * A run SPLIT by a conditional region is REFUSED, and the source is left untouched. The splice
	 * spans the first keyword to the last, so emitting the recomputed run over
	 * `public #if cpp inline #end static function f` would delete the region — a silent semantic
	 * change on the guarded target. Base wrote a second visibility BELOW the region instead, which
	 * at least fails to compile; deleting the region does not, which is why this is a refusal
	 * rather than a best effort. It was found by a review probe, not by any pin the fix shipped
	 * with.
	 */
	public function testASplitModifierRunIsRefusedRatherThanSplicedOverTheRegion(): Void {
		final src: String = 'package p;\nclass C {\n\tpublic\n\t#if cpp\n\tinline\n\t#end\n\tstatic function f(): Int return 1;\n}';
		for (line in [7, 3])
			assertErrContains(SetModifier.setModifier(src, line, 2, ['private'], true, new HaxeQueryPlugin()), 'other than whitespace');
	}

	/**
	 * CONTROL for the refusal's edge: a region BEFORE the whole run, and a region BETWEEN the run
	 * and the declaration, are both outside the splice and stay served. Widening the refusal to
	 * "any conditional region in the run" flips exactly this — and would take with it the shape
	 * every one of Pony's ten conditional modifier regions actually has.
	 */
	public function testAConditionalRegionOutsideTheKeywordRunIsStillServed(): Void {
		final before: String = 'package p;\nclass C {\n\t#if cpp\n\tinline\n\t#end\n\tpublic function f(): Int return 1;\n}';
		Assert.isTrue(okText(SetModifier.setModifier(before, 6, 2, ['private'], true, new HaxeQueryPlugin())).contains('#if cpp'));
		final between: String = 'package p;\nclass C {\n\tprivate\n\t#if cpp\n\tinline\n\t#end\n\tfunction f(): Int return 1;\n}';
		final text: String = okText(SetModifier.setModifier(between, 7, 2, ['public'], true, new HaxeQueryPlugin()));
		Assert.equals(1, occurrences(text, '#if cpp'), text);
		Assert.equals(1, occurrences(text, 'public'), text);
	}

	/**
	 * `ORDER` is the canonical EMIT order, and this is what guards it: a run of every ranked
	 * keyword, scrambled, must come back in `ORDER` — each ranked SLOT receives the next surviving
	 * keyword, so the run is sorted by construction. Dropping any entry from `ORDER` makes that
	 * keyword unranked, which keeps it in its physical slot and changes this string. The two
	 * `testEveryDeclaredModifier…` guards above cannot see that: they count occurrences, not
	 * positions.
	 */
	public function testTheRankedRunIsEmittedInCanonicalOrder(): Void {
		final src: String = 'package p;\nextern class C {\n\tdynamic inline static public override extern macro function f(): Int;\n}';
		final text: String = okText(SetModifier.setModifier(src, 3, 2, ['private'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('macro extern override private static inline dynamic function f'), 'not in ORDER: $text');
	}

	/**
	 * With NO bare keyword to splice over, the insertion point is the declaration's start — except
	 * in front of a region contributing a declaration-starting KEYWORD, which is part of the
	 * declaration's own head. `#if (haxe_ver >= 4.2) enum #end abstract E(Int)` took the modifier
	 * AFTER the `#end` and produced `enum private abstract E(Int)`: anyparse re-parses it happily
	 * and Haxe rejects it with `Unexpected keyword "private"`, at rc 0. Found by review, not by any
	 * pin the first cut shipped with — the fixture that WAS pinned carried a leading `private`,
	 * which gave the splice a keyword and hid this.
	 */
	public function testAModifierGoesInFrontOfADeclKeywordRegionNotAfterIt(): Void {
		final src: String = 'package p;\n\n#if (haxe_ver >= 4.2)\nenum\n#end\nabstract E(Int) {\n\tfinal X = 1;\n}\n';
		final text: String = okText(SetModifier.setModifier(src, 6, 1, ['private'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.indexOf('private') < text.indexOf('#if'), 'the modifier landed inside the declaration head: $text');
		Assert.equals(1, occurrences(text, 'private'), text);
	}

	/**
	 * A modifier the declaration carries INSIDE a conditional region is not in the run this op
	 * rewrites, so a change naming it lands beside it instead of on it: `+static` emitted a second
	 * `static` that only the guarded branch sees, and `-static` reported success while the region's
	 * own still stood. Both directions refuse now. A change naming something else is unaffected.
	 */
	public function testAChangeCollidingWithAGuardedModifierIsRefused(): Void {
		final src: String = 'package p;\nclass C {\n\tprivate\n\t#if cpp\n\tstatic\n\t#end\n\tfunction f(): Int return 1;\n}';
		for (change in ['+static', '-static'])
			assertErrContains(SetModifier.setModifier(src, 7, 2, [change], true, new HaxeQueryPlugin()), 'inside a conditional region');
		Assert.isTrue(okText(SetModifier.setModifier(src, 7, 2, ['+inline'], true, new HaxeQueryPlugin())).contains('inline'));
	}

	/**
	 * A guarded VISIBILITY collides with any visibility change, not only with its own spelling: a
	 * flip removes the visibility from the run and cannot remove it from the branch.
	 */
	public function testAVisibilityFlipCollidingWithAGuardedVisibilityIsRefused(): Void {
		final src: String = 'package p;\nclass C {\n\t#if cpp\n\tpublic\n\t#end\n\tstatic function f(): Int return 1;\n}';
		assertErrContains(SetModifier.setModifier(src, 6, 2, ['private'], true, new HaxeQueryPlugin()), 'inside a conditional region');
	}

	/**
	 * A COMMENT between two keywords is trivia, so it is no sibling and set no flag — but the
	 * first-to-last splice covers it, and re-emitting the run over it DELETED it silently:
	 * `canonicalize`'s comment-loss gate cannot see it either, because the comment is gone from the
	 * source text before the writer ever runs. Refused on the same rule as a region.
	 */
	public function testACommentBetweenTwoModifierKeywordsIsNotDeleted(): Void {
		final src: String = 'package p;\nclass C {\n\tpublic /* why */ static function f(): Int return 1;\n}';
		assertErrContains(SetModifier.setModifier(src, 3, 2, ['private'], true, new HaxeQueryPlugin()), 'other than whitespace');
	}

	/**
	 * The `public` entry of `ORDER` that `testTheRankedRunIsEmittedInCanonicalOrder` cannot cover:
	 * its fixture flips TO `private`, so `public` is already out of the surviving set and dropping
	 * its entry changes nothing. Flipping TO `public` beside two other ranked keywords does.
	 */
	public function testAFlipToPublicKeepsTheRankedRunInOrder(): Void {
		final src: String = 'package p;\nclass C {\n\tprivate static inline function f(): Int return 1;\n}';
		final text: String = okText(SetModifier.setModifier(src, 3, 2, ['public'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('public static inline function f'), 'not in ORDER: $text');
	}

	/**
	 * `public` on a MODULE-LEVEL declaration is refused, and the refusal names the only spelling
	 * that works.
	 *
	 * The op used to write it: `wrote src/M.hx` at rc 0, a file anyparse re-parses, and
	 * `haxe -cp src --no-output M` answering `public modifier is not supported for enums`. Measured
	 * on 4.3.7 across all seven module-level shapes — five type kinds plus a module-level function
	 * and var — `public` is rejected on every one, so the refusal needs no per-kind carve-out.
	 *
	 * The leading assertion is the fixture's reachability proof: `-private` on the SAME address
	 * succeeds on the base engine and on this one, so a failure below is the claim failing, not the
	 * address missing.
	 */
	public function testModuleLevelPublicIsRefusedNamingTheRemoval(): Void {
		final dropped: String = okText(SetModifier.setModifier(MODULE_PRIVATE_TYPEDEF, 4, 1, ['-private'], true, new HaxeQueryPlugin()));
		Assert.isTrue(dropped.contains('typedef Helper'), 'the address must reach the module-level declaration');
		Assert.isFalse(dropped.contains('private'), 'and -private must drop the keyword');
		final refused: EditResult = SetModifier.setModifier(MODULE_PRIVATE_TYPEDEF, 4, 1, ['public'], true, new HaxeQueryPlugin());
		assertErrContains(refused, 'MODULE level');
		assertErrContains(refused, '-private');
	}

	/**
	 * `+public` is the same change with the other spelling, and is refused the same way — the guard
	 * reads the change's NAME, not whether it carries a `+`. The fixture's reachability is proved by
	 * `testModuleLevelPublicIsRefusedNamingTheRemoval`, which serves `-private` at the same address.
	 */
	public function testModuleLevelPlusPublicIsRefusedToo(): Void {
		assertErrContains(SetModifier.setModifier(MODULE_PRIVATE_TYPEDEF, 4, 1, ['+public'], true, new HaxeQueryPlugin()), 'MODULE level');
	}

	/**
	 * A module-level declaration that carries NO visibility is already public, so the refusal says
	 * so instead of naming a keyword to drop. The base engine wrote `public typedef Helper` here —
	 * the same invalid file, from a call that changed nothing semantically.
	 */
	public function testModuleLevelPublicOnABareDeclarationIsRefused(): Void {
		final bare: String = 'package p;\nclass C {}\n\ntypedef Helper = {\n\tvar n:Int;\n}';
		// Reachability first, and it passes on the base engine: a change this address CAN serve.
		Assert.isTrue(
			okText(SetModifier.setModifier(bare, 4, 1, ['-private'], true, new HaxeQueryPlugin())).contains('typedef Helper'),
			'the address must reach the module-level declaration'
		);
		final refused: EditResult = SetModifier.setModifier(bare, 4, 1, ['public'], true, new HaxeQueryPlugin());
		assertErrContains(refused, 'MODULE level');
		assertErrContains(refused, 'it already is');
	}

	/**
	 * A module-level declaration wrapped in `#if … #end` is still module-level: the region node is
	 * the one ancestor kind `isModuleLevel` sees through. A predicate written as "the declaration's
	 * parent is the parsed root" passes every other fixture here and fails this one.
	 */
	public function testModuleLevelPublicIsRefusedThroughAConditionalRegion(): Void {
		final guarded: String = 'package p;\nclass C {}\n\n#if js\nprivate typedef Helper = {\n\tvar n:Int;\n}\n#end';
		// Reachability first, and it passes on the base engine: the guarded declaration IS addressable
		// and `-private` serves it, so what fails below is the module-level claim and not the address.
		final dropped: String = okText(SetModifier.setModifier(guarded, 5, 1, ['-private'], true, new HaxeQueryPlugin()));
		Assert.isTrue(dropped.contains('typedef Helper'), 'the guarded declaration is addressable');
		Assert.isTrue(dropped.contains('#if js'), 'and its region survives');
		assertErrContains(SetModifier.setModifier(guarded, 5, 1, ['public'], true, new HaxeQueryPlugin()), 'MODULE level');
	}

	/**
	 * A member of an `enum abstract` DOES take `public`, and must not be caught by the module-level
	 * refusal. The discriminating control for how `isModuleLevel` is written: `RefShape.typeDeclKinds`
	 * — the kind list that looks like the answer — does not list `EnumAbstractDecl`, so a predicate
	 * built on it calls this member module-level and refuses a change Haxe accepts.
	 */
	public function testAnEnumAbstractMemberStillTakesPublic(): Void {
		final src: String = 'package p;\n\nenum abstract E(Int) {\n\tprivate static final X:Int = 1;\n}';
		final text: String = okText(SetModifier.setModifier(src, 4, 2, ['public'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('public static final X'), 'an enum-abstract member takes public');
	}

	/**
	 * `-public` at module level is a REMOVAL, and removals stay allowed — the refusal is about
	 * adding a keyword that has no spelling there, not about naming it. Guards the ADD-only
	 * boundary the refusal's doc claims; the behaviour itself predates this slice.
	 */
	public function testMinusPublicStaysAllowedAtModuleLevel(): Void {
		final text: String = okText(SetModifier.setModifier(MODULE_PRIVATE_TYPEDEF, 4, 1, ['-public'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('typedef Helper'), 'the declaration survives');
		Assert.isFalse(text.contains('private'), '-public clears the visibility run');
	}

	/**
	 * THE user-facing answer behind both halves of T577: how a module-level `private` is removed.
	 * `-private` does it on every module-level kind Haxe has, and has always done so — this test
	 * guards PRE-EXISTING behaviour, and passes unchanged on the base engine. It is here because
	 * the refusal above points every caller at it, so a regression would silently turn that
	 * refusal into a dead end.
	 */
	public function testMinusPrivateRemovesTheKeywordOnEveryModuleLevelKind(): Void {
		final bodies: Array<String> = [
			'private class Helper {}',
			'private interface Helper {}',
			'private enum Helper {\n\tA;\n}',
			'private typedef Helper = {\n\tvar n:Int;\n}',
			'private abstract Helper(Int) {}'
		];
		for (body in bodies) {
			final text: String = okText(
				SetModifier.setModifier('package p;\nclass C {}\n\n$body', 4, 1, ['-private'], true, new HaxeQueryPlugin())
			);
			Assert.isTrue(text.contains('Helper'), 'the declaration survives: $body');
			Assert.isFalse(text.contains('private'), 'the keyword is gone: $body');
		}
	}

	/**
	 * The INSERTION arm of the same region shape: with no modifier keyword to splice over, the new
	 * visibility goes in FRONT of the `#if … enum #end` the declaration's head begins with. Written
	 * after the `#end` it produced `enum private abstract E(Int)`, which anyparse re-parses happily
	 * and Haxe rejects with `Unexpected keyword "private"`.
	 *
	 * The order assertion is what discriminates: every occurrence count stays 1 either way, so a
	 * regression that moves the keyword past the region satisfies all of them.
	 */
	public function testAVisibilityAddedBeforeAConditionalDeclKeywordRegion(): Void {
		final src: String = 'package p;\n\n#if (haxe_ver >= 4.2)\nenum\n#end\nabstract E(Int) {\n\tfinal X = 1;\n}\n';
		final text: String = okText(SetModifier.setModifier(src, 6, 1, ['private'], true, new HaxeQueryPlugin()));
		Assert.equals(1, occurrences(text, 'private'), text);
		Assert.equals(1, occurrences(text, 'enum'), text);
		Assert.isTrue(text.indexOf('private') < text.indexOf('#if'), 'the insertion goes in FRONT of the region: $text');
	}

	private function okText(res: EditResult): String {
		return switch res {
			case Ok(text): text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				'';
		};
	}

	private function isErr(res: EditResult): Bool {
		return switch res {
			case Ok(_): false;
			case Err(_): true;
		};
	}

	/** The plugin's own modifier vocabulary minus its visibility keywords, lower-cased. */
	private function declaredBooleanModifiers(): Array<String> {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		final visibility: Array<String> = [for (kind in shape.visibilityModifierKinds ?? []) kind.toLowerCase()];
		return [
			for (kind in CheckScan.modifierKinds(shape)) if (!visibility.contains(kind.toLowerCase())) kind.toLowerCase()
		];
	}

	/**
	 * Flip line 3 of `src` to `private` from BOTH cursor columns and require the member to come
	 * back with one visibility, the new one, and `keyword` still there once.
	 */
	private function assertFlipToPrivateKeeps(src: String, keyword: String): Void {
		for (col in [2, declCursorCol(src, 3)]) {
			final text: String = okText(SetModifier.setModifier(src, 3, col, ['private'], true, new HaxeQueryPlugin()));
			Assert.equals(1, occurrences(text, 'private'), 'cursor col $col: $text');
			Assert.equals(0, occurrences(text, 'public'), 'cursor col $col: $text');
			Assert.equals(1, occurrences(text, keyword), 'cursor col $col: $text');
		}
	}

	/**
	 * The 1-based column of the DECLARATION keyword on `line` of `src` — the second entry path
	 * into this op. With the cursor on a modifier the run walk starts INSIDE the run and cannot
	 * miss it; from the declaration it walks BACKWARD and stops at the first keyword it does not
	 * know, which is where the duplicate visibility was emitted. Both are addressed the same way
	 * by `--select`, so both must answer the same.
	 */
	private function declCursorCol(src: String, line: Int): Int {
		final at: Int = src.split('\n')[line - 1].indexOf('function');
		if (at < 0) throw new Exception('line $line of the fixture carries no `function` keyword to put a declaration cursor on');
		return at + 1;
	}

	/** Non-overlapping occurrences of `needle` in `text`. */
	private function occurrences(text: String, needle: String): Int {
		var count: Int = 0;
		var at: Int = text.indexOf(needle);
		while (at >= 0) {
			count++;
			at = text.indexOf(needle, at + needle.length);
		}
		return count;
	}

	/** Assert `res` is an `Err` whose message names `fragment` — an `Err` alone would pass on any refusal. */
	private function assertErrContains(res: EditResult, fragment: String): Void {
		switch res {
			case Ok(text):
				Assert.fail('expected Err, got Ok: $text');
			case Err(message):
				Assert.isTrue(message.indexOf(fragment) >= 0, 'refusal did not name "$fragment": $message');
		}
	}

}
