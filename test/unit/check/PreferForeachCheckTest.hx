package unit.check;

import anyparse.check.Check;
import anyparse.check.PreferForeach;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-foreach` check: a manual all-match `for` loop
 * `for (x in xs) if (cond) return false; return true;` is flagged `Info`, suggesting
 * `xs.foreach(x -> !(cond))` — the inversion a WRAP, never De Morgan, except that an
 * already-negated condition drops its `!` instead of gaining a second one. The GUARDED
 * variant is deliberately NOT claimed (negating the guard is what would lose a null
 * narrowing), and so are the `exists` direction and every shape gate the twin refuses.
 *
 * ## The FLAG form
 *
 * The second sink, in this direction's polarity: `var f:Bool = true;` immediately followed
 * by `for (x in xs) if (cond) f = false;`, folding to
 * `final f:Bool = xs.foreach(x -> !(cond));` — with the same `!`-dropping relief the
 * `return` form gets. `Lambda.foreach` short-circuits on the first `false` exactly as
 * `exists` does on the first `true`, so the PURITY gate is load-bearing here too and gets
 * its own refusal fixture.
 */
class PreferForeachCheckTest extends Test {

	public function testBareFormFlagged(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return false;\n\t\treturn true;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-foreach', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('xs.foreach(x -> !(x > 2))') != -1, vs[0].message);
	}

	public function testNegatedConditionDropsItsNot(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (!keep(x)) return false;\n\t\treturn true;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('xs.foreach(x -> keep(x))') != -1, vs[0].message);
	}

	public function testGuardedFormNotClaimed(): Void {
		// `if (g) for … return false; return true;` needs `!g`, and negating a null-test guard is
		// exactly what strands the narrowing the rest of the expression needs.
		Assert.equals(0, violations(fn('if (n != null) for (x in n) if (x > 2) return false;\n\t\treturn true;')).length);
	}

	public function testExistsDirectionNotClaimed(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return true;\n\t\treturn false;')).length);
	}

	public function testSameLiteralTrailingReturnNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return false;\n\t\treturn false;')).length);
	}

	public function testNonLiteralFallbackNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return false;\n\t\treturn xs.length == 0;')).length);
	}

	public function testKeyValueLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (k => v in m) if (v > 2) return false;\n\t\treturn true;')).length);
	}

	public function testCallIterableNotFlagged(): Void {
		// `Map.keys` lives in a std this index does not see, so the type stays UNRESOLVED and is refused.
		Assert.equals(0, violations(fn('for (k in m.keys()) if (m[k] > 2) return false;\n\t\treturn true;')).length);
	}

	public function testCallIterableResolvingToArrayFlagged(): Void {
		final vs: Array<Violation> = violations(typedFn('for (x in b.items()) if (x > 2) return false;\n\t\treturn true;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('b.items().foreach(x -> !(x > 2))') != -1, vs[0].message);
	}

	public function testCallIterableResolvingToIteratorNotFlagged(): Void {
		// The TYPED refusal, not the unresolved one: `Iterator<T>` is not an `Iterable<T>`.
		Assert.equals(0, violations(typedFn('for (x in b.walker()) if (x > 2) return false;\n\t\treturn true;')).length);
	}

	public function testRangeLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (i in 0...xs.length) if (xs[i] > 2) return false;\n\t\treturn true;')).length);
	}

	public function testNonAdjacentTrailingReturnNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return false;\n\t\tfinal q = xs.length;\n\t\treturn true;')).length);
	}

	public function testFallThroughFromElseBranchFlagged(): Void {
		final vs: Array<Violation> = violations(
			fn('if (a) {\n\t\t\ttrace(b);\n\t\t} else {\n\t\t\tfor (x in xs) if (x > 2) return false;\n\t\t}\n\t\treturn true;')
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('xs.foreach(x -> !(x > 2))') != -1, vs[0].message);
	}

	public function testFallThroughStopsAtALoopBody(): Void {
		Assert.equals(0, violations(fn('while (a) {\n\t\t\tfor (x in xs) if (x > 2) return false;\n\t\t}\n\t\treturn true;')).length);
	}

	public function testFixWrapsCondition(): Void {
		final out: String = fixResult(file('for (x in xs) if (x > 2) return false;\n\t\treturn true;', false));
		Assert.isTrue(out.indexOf('return xs.foreach(x -> !(x > 2));') != -1, out);
		Assert.isTrue(out.indexOf('using Lambda;') != -1, out);
	}

	public function testFixDropsExistingNot(): Void {
		final out: String = fixResult(file('for (x in xs) if (!keep(x)) return false;\n\t\treturn true;', true));
		Assert.isTrue(out.indexOf('return xs.foreach(x -> keep(x));') != -1, out);
	}

	public function testFixParenthesizesLooseIterable(): Void {
		final out: String = fixResult(file('for (x in a ? xs : xs) if (x > 2) return false;\n\t\treturn true;', true));
		Assert.isTrue(out.indexOf('return (a ? xs : xs).foreach(x -> !(x > 2));') != -1, out);
	}

	/**
	 * The static-extension arm: `S` declares no `items`, so `using ExtArray` is what supplies it
	 * and the call resolves to `Array<Int>` — the same proof an ordinary member return gives.
	 */
	public function testStaticExtensionCallIterableFlagged(): Void {
		final vs: Array<Violation> = extViolations('using ExtArray;', '');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('s.items().foreach(x -> !(x > 2))') != -1, vs[0].message);
	}

	/**
	 * A real MEMBER beats an in-scope extension of the same name, and the extension is not
	 * consulted at all — verified against the compiler: under `using E`, `d.tag()` on a `D`
	 * declaring `tag():Void` binds to the member and fails as `Void should be Dynamic`, never to
	 * `E.tag(d:D):String`. A `Void` return has no readable nominal, so this is exactly the shape
	 * where the member answer (unknown) and the extension answer (`Array`) differ.
	 */
	public function testReceiverMemberBeatsStaticExtension(): Void {
		Assert.equals(0, extViolations('using ExtArray;', '\n\tpublic function items() {}\n').length);
	}

	/** Haxe resolves static extensions in REVERSE declaration order — the LATER `using` wins. */
	@:pin('control')
	@:killer('M-BINDER-EXTENSION-LAST-USING')
	public function testLaterUsingWinsOverEarlierOne(): Void {
		Assert.equals(0, extViolations('using ExtArray;\nusing ExtIter;', '').length);
		Assert.equals(1, extViolations('using ExtIter;\nusing ExtArray;', '').length);
	}

	/**
	 * An extension applies only to a receiver its FIRST PARAMETER accepts. `ExtInt.items(n:Int)`
	 * does not accept an `S`, so it supplies nothing — declared alone it leaves the call
	 * unresolved, and declared LAST it does not displace the earlier `using` that does apply.
	 */
	public function testFirstParameterMustAcceptTheReceiver(): Void {
		Assert.equals(0, extViolations('using ExtInt;', '').length);
		Assert.equals(0, extViolations('using ExtIter;\nusing ExtInt;', '').length);
	}

	/** No `using` brings `items` into scope, so the call stays unresolved and keeps the blanket refusal. */
	public function testNoUsingKeepsTheCallRefused(): Void {
		Assert.equals(0, extViolations('', '').length);
	}

	public function testReceiverDeclaringForeachTakesTheQualifiedForm(): Void {
		// A real MEMBER always beats a `using` static extension: on a receiver whose own type
		// declares `foreach`, `m.foreach(x -> …)` binds to THAT member and the lambda lands in its
		// parameter slot. No stdlib container declares the name — a PROJECT type is the live case.
		// The fold survives in the QUALIFIED spelling, which never consults the receiver's members,
		// and the `foreach` inversion rides on it unchanged.
		final vs: Array<Violation> = violations(memberFn('for (x in m) if (x > 2) return false;\n\t\treturn true;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('Lambda.foreach(m, x -> !(x > 2))') != -1, vs[0].message);
	}

	public function testQualifiedFixEmitsTheStaticCallAndInsertsNoUsing(): Void {
		// The `using Lambda;` the extension form needs buys the qualified call nothing.
		final out: String = fixResult('package p;\n\n' + memberFn('for (x in m) if (x > 2) return false;\n\t\treturn true;'));
		Assert.isTrue(out.indexOf('return Lambda.foreach(m, x -> !(x > 2));') != -1, out);
		Assert.equals(-1, out.indexOf('using Lambda;'));
	}

	public function testReceiverDeclaringExistsStillFlagged(): Void {
		// The gate is about the ONE name this direction rewrites to: a receiver declaring `exists`
		// (the `Map` shape the twin refuses) is still rewritten by `foreach`.
		Assert.equals(1, violations(existsMemberFn('for (x in m) if (x > 2) return false;\n\t\treturn true;')).length);
	}

	public function testFlagFormFlagged(): Void {
		// The rule id and severity ride on the shared violation builder, which `testBareFormFlagged`
		// already pins — what is this arm's own is the SINK the message names.
		final vs: Array<Violation> = violations(flagFn('var all:Bool = true;\n\t\tfor (b in bs) if (!b) all = false;\n\t\treturn all;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('final all = bs.foreach(b -> b)') != -1, vs[0].message);
	}

	public function testFlagFormWrapsAnUnnegatedCondition(): Void {
		final vs: Array<Violation> = violations(flagFn('var all:Bool = true;\n\t\tfor (x in xs) if (x > 2) all = false;\n\t\treturn all;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('final all = xs.foreach(x -> !(x > 2))') != -1, vs[0].message);
	}

	public function testFlagFormEffectfulConditionNotFlagged(): Void {
		// ★ `Lambda.foreach` stops at the first `false` where the loop visits every element, so a
		// condition that DOES work cannot be folded — the same gate the twin direction carries.
		Assert.equals(0, violations(flagFn('var all:Bool = true;\n\t\tfor (x in xs) if (!keep(x)) all = false;\n\t\treturn all;')).length);
	}

	public function testFlagFormGuardReadingTheFlagNotClaimed(): Void {
		// The measured corpus shape (`if (ordered) for (…) if (mismatch) ordered = false;`): the
		// statement after the declaration is the guard, not the loop, so the pair is not this shape.
		Assert.equals(
			0, violations(flagFn('var all:Bool = true;\n\t\tif (all) for (b in bs) if (!b) all = false;\n\t\treturn all;')).length
		);
	}

	public function testFlagFormInitializerMatchingTheLoopLiteralNotFlagged(): Void {
		// The loop's literal is this direction's, but the declaration already opens at it — the loop
		// can never change the value, so the fold would not be an identity.
		Assert.equals(0, violations(flagFn('var all:Bool = false;\n\t\tfor (b in bs) if (!b) all = false;\n\t\treturn all;')).length);
	}

	public function testExistsDirectionFlagFormNotClaimed(): Void {
		Assert.equals(0, violations(flagFn('var all:Bool = false;\n\t\tfor (x in xs) if (x > 2) all = true;\n\t\treturn all;')).length);
	}

	public function testFlagFormFixFoldsDeclarationAndLoop(): Void {
		final out: String = fixResult(
			'package p;\n\nusing Lambda;\n\n' + flagFn('var all:Bool = true;\n\t\tfor (b in bs) if (!b) all = false;\n\t\treturn all;')
		);
		Assert.isTrue(out.indexOf('final all:Bool = bs.foreach(b -> b);') != -1, out);
		Assert.equals(-1, out.indexOf('for (b in bs)'));
	}

	public function testIteratorIterableNotFlagged(): Void {
		// `for` accepts an `Iterator`, `Lambda.foreach` does not, and this fix is TRUSTED — so a
		// proven `Iterator` identifier is refused by type, not left to a compiler to catch.
		final src: String =
			'class C {\n\tfunction f(it:Iterator<Int>):Bool {\n\t\tfor (x in it) if (x > 2) return false;\n\t\treturn true;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testFlagFormConditionReadingTheFlagNotFlagged(): Void {
		// The fold moves the condition into the flag's own initializer, where `all` is not bound yet.
		Assert.equals(
			0, violations(flagFn('var all:Bool = true;\n\t\tfor (b in bs) if (!b || !all) all = false;\n\t\treturn all;')).length
		);
	}

	public function testFlagFormLoopBinderShadowingTheFlagNotFlagged(): Void {
		// The loop writes its own binder `all`; the declared flag never changes.
		Assert.equals(0, violations(flagFn('var all:Bool = true;\n\t\tfor (all in bs) if (a) all = false;\n\t\treturn all;')).length);
	}

	public function testFlagFormMemberTailNamedLikeTheFlagFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(ps:Array<P>):Bool {\n\t\tvar visible:Bool = true;\n\t\tfor (p in ps) if (!p.visible) '
			+ 'visible = false;\n\t\treturn visible;\n\t}\n}\n\nclass P {\n\tpublic var visible:Bool = false;\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testFlagFormIterableMentioningTheFlagNotFlagged(): Void {
		Assert.equals(
			0, violations(flagFn('var all:Bool = true;\n\t\tfor (b in (all ? bs : bs)) if (!b) all = false;\n\t\treturn all;')).length
		);
	}

	public function testSuperInTheConditionNotFlagged(): Void {
		// The condition becomes a lambda body: `Cannot access super inside a local function`.
		final src: String = 'class Base {\n\tfunction ok(x:Int):Bool {\n\t\treturn x > 0;\n\t}\n}\n\nclass S extends Base {\n'
			+ '\tfunction f(xs:Array<Int>):Bool {\n\t\tfor (x in xs) if (super.ok(x)) return false;\n\t\treturn true;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testIteratorClassIterableNotFlagged(): Void {
		// Structural, not by name: a class with `hasNext` / `next` and no `iterator()` is an Iterator.
		final src: String = 'class C {\n\tvar ai:Walker;\n\n\tfunction f():Bool {\n\t\tfor (x in ai) if (x > 2) return false;\n'
			+ '\t\treturn true;\n\t}\n}\n\nclass Walker {\n\tpublic function hasNext() {\n\t\treturn false;\n\t}\n\n'
			+ '\tpublic function next() {\n\t\treturn 0;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * `using <module>` brings the statics of EVERY type the module declares (4.3.7), so an `items` declared on a SUB-type of
	 * the used module supplies the call exactly as one on its main type does.
	 */
	public function testUsedModuleSubTypeSuppliesTheExtension(): Void {
		Assert.equals(1, extViolations('using ModArr;', '', extensionModules()).length);
		Assert.equals(1, extViolations('using ModArr.Inner;', '', extensionModules()).length);
	}

	/**
	 * A LATER `using` whose module declares `items` on a sub-type binds the call (4.3.7), so the earlier `ExtArray` must not
	 * answer for it: the sub-type's `Iterator` return is the one the rule refuses.
	 */
	public function testUsedModuleSubTypeShadowsAnEarlierUsing(): Void {
		Assert.equals(0, extViolations('using ExtArray;\nusing ModIter;', '', extensionModules()).length);
	}

	/**
	 * Two types of one used module both declaring `items`: 4.3.7 binds the LAST-declared one that accepts the receiver, which
	 * a nominal index cannot always prove, so the module answers nothing rather than its main type's `Array`.
	 */
	@:pin('control')
	@:killer('M-EXT-DECL-TWO-HOSTS')
	public function testTwoTypesOfOneModuleDeclaringTheNameRefuse(): Void {
		Assert.equals(0, extViolations('using ModTwo;', '', extensionModules()).length);
	}

	/**
	 * A type's own `@:using` — on the receiver's type or on a supertype — binds ahead of every `using` of the file (4.3.7:
	 * `@:using(SupExt) class Sup` beats `using Sup.Plain` on a `Sub extends Sup`), so the file's `ExtArray` must not answer.
	 */
	@:pin('control')
	@:killer('M-BINDER-EXTENSION-ATUSING')
	public function testReceiverUsingMetaBeatsTheFileUsing(): Void {
		Assert.equals(0, extViolations('using ExtArray;', '', [], '@:using(ExtIter) class S').length);
		Assert.equals(
			0,
			extViolations('using ExtArray;', '', [
				{
					file: 'Base.hx',
					source: '@:using(ExtIter) class Base {}'
				}
			], 'class S extends Base').length
		);
	}

	/**
	 * A later `using` that declares `items` with a first parameter this layer cannot PROVE accepts the receiver — a method type
	 * parameter, `Dynamic` — may still bind it (4.3.7: `C.tag<T>(s:T)` and `C.tag(s:Dynamic)` both beat an earlier
	 * `A.tag(s:String)`), so the walk stops there instead of falling back to the earlier `ExtArray`.
	 */
	public function testUnprovenFirstParameterStopsTheWalk(): Void {
		Assert.equals(0, extViolations('using ExtArray;\nusing ExtGen;', '', extensionModules()).length);
		Assert.equals(0, extViolations('using ExtArray;\nusing ExtDyn;', '', extensionModules()).length);
	}

	/**
	 * A later `using` binds ahead of the earlier `ExtArray`: a module the index does not hold may declare `items` itself,
	 * so the earlier one proves nothing; and one whose type is an ALIAS brings the statics of the type it names — 4.3.7
	 * binds `using AliasHost;` (`typedef AliasHost = ExtIter`) to `ExtIter.items`, whose `Iterator` the rule refuses.
	 */
	@:pin('control')
	@:killer('M-USING-HOSTS-ALIAS')
	public function testUnindexedLaterUsingStopsTheWalk(): Void {
		Assert.equals(0, extViolations('using ExtArray;\nusing Missing;', '').length);
		Assert.equals(
			0,
			extViolations('using ExtArray;\nusing AliasHost;', '', [
				{
					file: 'AliasHost.hx',
					source: 'typedef AliasHost = ExtIter;'
				}
			]).length
		);
	}

	/**
	 * A `using` under a `#if` is in scope in some builds only, where — declared later — it binds the call, so a file carrying
	 * one answers no extension at all; and a module whose `items` sits under a `#if` supplies it in some builds only, where
	 * the earlier `using` binds instead.
	 */
	@:pin('control')
	@:killer('M-EXT-DECL-GUARDED-MEMBER', 'M-BINDER-EXTENSION-GUARDED-USING')
	public function testGuardedUsingOrDeclarationRefuses(): Void {
		Assert.equals(0, extViolations('using ExtIter;\n#if x\nusing ExtArray;\n#end', '').length);
		Assert.equals(0, extViolations('using ExtIter;\nusing ExtGuard;', '', extensionModules()).length);
	}

	/**
	 * The walk passes over a later `using` only for a module offering no extension `items` (4.3.7): one declaring none, one
	 * whose `items` is an instance method, and one whose static is `@:noUsing` all leave the call to the earlier `ExtArray`.
	 */
	@:pin('control')
	@:killer('M-EXT-DECL-PASS-OVER', 'M-EXT-DECL-STATIC', 'M-EXT-DECL-NOUSING')
	public function testALaterUsingOfferingNoExtensionIsPassedOver(): Void {
		Assert.equals(1, extViolations('using ExtArray;\nusing Empty;', '', extensionModules()).length);
		Assert.equals(1, extViolations('using ExtArray;\nusing InstItems;', '', extensionModules()).length);
		Assert.equals(1, extViolations('using ExtArray;\nusing NoUse;', '', extensionModules()).length);
	}

	/**
	 * A later `using` that may offer `items` in some build stops the walk: a module whose `@:build` macro may add the static,
	 * and one whose type declaring it sits under a `#if` (4.3.7 binds `Inner.items` under `-D x`, the earlier `using` without).
	 */
	@:pin('control')
	@:killer('M-EXT-DECL-BUILT', 'M-EXT-DECL-GUARDED-HOST')
	public function testALaterUsingThatMayOfferTheExtensionStopsTheWalk(): Void {
		Assert.equals(0, extViolations('using ExtArray;\nusing Built;', '', extensionModules()).length);
		Assert.equals(0, extViolations('using ExtIter;\nusing GuardHost;', '', extensionModules()).length);
	}

	/**
	 * The compiler's `using` order (`fields.ml`, Haxe 4.3.7, FU14): a later `using` whose first parameter REJECTS the receiver
	 * is passed over to the earlier `ExtArray`; one module's types are tried last declared first; the receiver type's own
	 * `@:using` binds with no `using` in the file; and a private static (reached from its class only) or a module-level
	 * function of a used module (whose signature the index does not record) proves nothing.
	 */
	@:pin('control')
	@:killer('M-BINDER-EXTENSION-FIRST-PARAM', 'M-EXT-DECL-TWO-HOSTS', 'M-BINDER-EXTENSION-ATUSING', 'M-EXT-PRIVATE-OPEN',
		'M-EXT-MODULE-FIELDS-OPEN')
	public function testTheCompilersUsingOrder(): Void {
		final order: Array<{ file: String, source: String }> = [
			{ file: 'Other.hx', source: 'class Other {}' },
			{
				file: 'ExtOther.hx',
				source: 'class ExtOther {\n\tpublic static function items(o:Other):Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}'
			},
			{
				file: 'ModRev.hx',
				source: 'class ModRev {\n\tpublic static function items(s:S):Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}\n\n'
					+ 'class Last {\n\tpublic static function items(s:S):Array<Int> {\n\t\treturn [];\n\t}\n}'
			},
			{ file: 'ExtPriv.hx', source: 'class ExtPriv {\n\tstatic function items(s:S):Array<Int> {\n\t\treturn [];\n\t}\n}' },
			{ file: 'ModFn.hx', source: 'function items(s:S):Iterator<Int> {\n\treturn [].iterator();\n}\n\nclass ModFn {}' }
		];
		Assert.equals(1, extViolations('using ExtArray;\nusing ExtOther;', '', order).length, 'a rejecting first parameter is passed over');
		Assert.equals(1, extViolations('using ModRev;', '', order).length, 'the module\'s last declared type first');
		Assert.equals(1, extViolations('', '', [], '@:using(ExtArray) class S').length, 'the receiver type\'s own `@:using`');
		Assert.equals(0, extViolations('using ExtIter;\nusing ExtPriv;', '', order).length, 'a private static proves nothing');
		Assert.equals(0, extViolations('using ExtArray;\nusing ModFn;', '', order).length, 'a module-level function proves nothing');
	}

	/** A receiver whose OWN type declares `foreach` — the name this direction rewrites to. */
	private function memberFn(body: String): String {
		return 'class C {\n\tfunction f(m:M):Bool {\n\t\t$body\n\t}\n}\n\nclass M {\n\tpublic function foreach(key:Int):Bool {\n'
			+ '\t\treturn false;\n\t}\n\n\tpublic function iterator():Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}';
	}

	/** The FLAG form's fixture: `bs` carries the already-negated condition, `keep` the effectful one. */
	private function flagFn(body: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, bs:Array<Bool>, a:Bool):Bool {\n\t\t$body\n\t}\n\n'
			+ '\tfunction keep(x:Int):Bool {\n\t\treturn x > 0;\n\t}\n}';
	}

	/** A receiver declaring the TWIN direction's name and not this one — the gate must not fire. */
	private function existsMemberFn(body: String): String {
		return 'class C {\n\tfunction f(m:M):Bool {\n\t\t$body\n\t}\n}\n\nclass M {\n\tpublic function exists(key:Int):Bool {\n'
			+ '\t\treturn false;\n\t}\n\n\tpublic function iterator():Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}';
	}

	private function fn(body: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, m:Map<String, Int>, n:Null<Array<Int>>, a:Bool, b:Bool):Bool {\n\t\t$body\n\t}\n\n'
			+ '\tfunction keep(x:Int):Bool {\n\t\treturn x > 0;\n\t}\n}';
	}

	/** A fixture whose CALL iterables are RESOLVABLE: `B` is indexed alongside `C`, so its members' written return types answer. */
	private function typedFn(body: String): String {
		return 'class C {\n\tfunction f(b:B, a:Bool):Bool {\n\t\t$body\n\t}\n}\n\nclass B {\n\tpublic function items():Array<Int> {\n'
			+ '\t\treturn [];\n\t}\n\n\tpublic function walker():Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}';
	}

	private function file(body: String, withUsing: Bool): String {
		return 'package p;\n\n' + (withUsing ? 'using Lambda;\n\n' : '') + fn(body);
	}

	/**
	 * The static-extension fixture: `C` iterates `s.items()` under `usings`, `S` carries `sBody`,
	 * and three modules declare `items` with returns that read DIFFERENTLY through this rule's
	 * accept list — `ExtArray` an `Array<Int>` (claimed), `ExtIter` an `Iterator<Int>` (refused),
	 * `ExtInt` an `Array<Int>` off an `Int` receiver (not applicable to an `S` at all). Which
	 * candidate won is therefore legible from the finding COUNT alone.
	 */
	private function extViolations(
		usings: String, sBody: String, ?extra: Array<{ file: String, source: String }>, sHead: String = 'class S'
	): Array<Violation> {
		return CheckFixture.violationsIn(new PreferForeach(), (extra ?? []).concat([
			{
				file: 'C.hx',
				source: '$usings\nclass C {\n\tfunction f(s:S):Bool {\n'
				+ '\t\tfor (x in s.items()) if (x > 2) return false;\n\t\treturn true;\n\t}\n}'
			},
			{ file: 'S.hx', source: '$sHead {$sBody}' },
			{ file: 'ExtArray.hx', source: 'class ExtArray {\n\tpublic static function items(s:S):Array<Int> {\n\t\treturn [];\n\t}\n}' },
			{
				file: 'ExtIter.hx',
				source: 'class ExtIter {\n\tpublic static function items(s:S):Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}'
			},
			{ file: 'ExtInt.hx', source: 'class ExtInt {\n\tpublic static function items(n:Int):Array<Int> {\n\t\treturn [];\n\t}\n}' }
		]));
	}

	private function violations(source: String): Array<Violation> {
		return CheckFixture.violations(new PreferForeach(), source);
	}

	private function fixResult(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferForeach = new PreferForeach();
		final vs: Array<Violation> = CheckFixture.violations(check, src, plugin);
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, vs, plugin, CheckFixture.index([{ file: 'C.hx', source: src }], plugin)
		);
		switch CanonicalEdit.canonicalize(src, edits, true, plugin) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

	/**
	 * The extra static-extension modules: `items` on a SUB-type (`ModArr.Inner` an `Array`, `ModIter.Other` an `Iterator`), on
	 * two types of one module (`ModTwo`), behind a first parameter no nominal proof accepts (`ExtGen`, `ExtDyn`), and under a
	 * `#if` (`ExtGuard`).
	 */
	private function extensionModules(): Array<{ file: String, source: String }> {
		return [
			{
				file: 'ModArr.hx',
				source: 'class ModArr {}\n\nclass Inner {\n\tpublic static function items(s:S):Array<Int> {\n\t\treturn [];\n\t}\n}'
			},
			{
				file: 'ModIter.hx',
				source: 'class ModIter {}\n\nclass Other {\n\tpublic static function items(s:S):Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}'
			},
			{
				file: 'ModTwo.hx',
				source: 'class ModTwo {\n\tpublic static function items(s:S):Array<Int> {\n\t\treturn [];\n\t}\n}\n\n'
					+ 'class Second {\n\tpublic static function items(s:S):Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}'
			},
			{
				file: 'ExtGen.hx',
				source: 'class ExtGen {\n\tpublic static function items<T>(s:T):Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}'
			},
			{
				file: 'ExtDyn.hx',
				source: 'class ExtDyn {\n\tpublic static function items(s:Dynamic):Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}'
			},
			{
				file: 'ExtGuard.hx',
				source: 'class ExtGuard {\n\t#if x\n\tpublic static function items(s:S):Array<Int> {\n\t\treturn [];\n\t}\n\t#end\n}'
			},
			{
				file: 'GuardHost.hx',
				source: 'class GuardHost {}\n\n#if x\nclass Inner {\n\tpublic static function items(s:S):Array<Int> {\n\t\treturn [];\n\t}\n}\n#end'
			},
			{ file: 'Empty.hx', source: 'class Empty {}' },
			{
				file: 'InstItems.hx',
				source: 'class InstItems {\n\tpublic function new() {}\n\n'
					+ '\tpublic function items(s:S):Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}'
			},
			{
				file: 'NoUse.hx',
				source: 'class NoUse {\n\t@:noUsing public static function items(s:S):Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}'
			},
			{ file: 'Built.hx', source: '@:build(Macro.build())\nclass Built {}' }
		];
	}

}
