package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.MissingVisibility;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * The `missing-visibility` check: a class / abstract member without an explicit
 * `public` / `private` modifier is flagged `Warning`, and `--fix` inserts `private`
 * (the Haxe default) at the canonical position. Interface members (implicitly
 * public) and enum-abstract values are exempt; a modifier run carrying a visibility
 * keyword — even behind meta or other modifiers — is not flagged.
 */
class MissingVisibilityCheckTest extends Test {

	public function testBareFieldFlagged(): Void {
		final vs: Array<Violation> = violations('class C { var a:Int; }');
		Assert.equals(1, vs.length);
		Assert.equals('missing-visibility', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testPublicMemberNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var a:Int; }').length);
	}

	public function testPrivateMemberNotFlagged(): Void {
		Assert.equals(0, violations('class C { private function f():Void {} }').length);
	}

	public function testStaticWithoutVisibilityFlagged(): Void {
		// static / inline modifiers present, but no public / private.
		Assert.equals(1, violations('class C { static inline function f():Void {} }').length);
	}

	public function testConstructorWithoutVisibilityFlagged(): Void {
		Assert.equals(1, violations('class C { function new() {} }').length);
	}

	public function testInterfaceMembersNotFlagged(): Void {
		Assert.equals(0, violations('interface I { var a:Int; function f():Void; }').length);
	}

	public function testEnumAbstractValuesNotFlagged(): Void {
		Assert.equals(0, violations('enum abstract E(Int) { final X = 0; final Y = 1; }').length);
	}

	public function testMetaBeforeVisibilityNotFlagged(): Void {
		Assert.equals(0, violations('class C { @:keep public function f():Void {} }').length);
	}

	public function testMetaWithoutVisibilityFlagged(): Void {
		Assert.equals(1, violations('class C { @:keep function f():Void {} }').length);
	}

	public function testFinalClassMemberFlagged(): Void {
		Assert.equals(1, violations('final class C { function f():Void {} }').length);
	}

	public function testAbstractMemberFlagged(): Void {
		Assert.equals(1, violations('abstract A(Int) { function g():Void {} }').length);
	}

	public function testMultipleMembersOnlyUntypedFlagged(): Void {
		// public a + private f are fine; b + g lack visibility.
		Assert.equals(2, violations('class C { public var a:Int; var b:Int; private function f():Void {} function g():Void {} }').length);
	}

	public function testFixInsertsPrivate(): Void {
		final fixed: String = fixedSource('class C { static inline function f():Void {} }');
		Assert.isTrue(fixed.indexOf('private static inline function f') >= 0);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('missing-visibility'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('missing-visibility'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/** An override inherits supertype visibility; it is still reported but the autofix must NOT force `private`. */
	public function testFixSkipsOverride(): Void {
		Assert.equals(1, violations('class C { override function f():Void {} }').length);
		Assert.equals(-1, fixedSource('class C { override function f():Void {} }').indexOf('private'));
	}

	/** An override of an indexed PUBLIC supertype member gets `public` — the base member's own keyword. */
	public function testFixOverridePublicFromIndexedSupertype(): Void {
		final sub: String = 'class C extends B { override function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, [{ file: 'B.hx', source: 'class B { public function f():Void {} }' }]);
		Assert.isTrue(fixed.indexOf('override public function f') >= 0);
	}

	/** An override of an indexed PRIVATE supertype member gets `private`. */
	public function testFixOverridePrivateFromIndexedSupertype(): Void {
		final sub: String = 'class C extends B { override function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, [{ file: 'B.hx', source: 'class B { private function f():Void {} }' }]);
		Assert.isTrue(fixed.indexOf('override private function f') >= 0);
	}

	/** The resolved keyword lands at the canonical slot: after `override`, before `inline`. */
	public function testFixOverrideInlineKeywordPosition(): Void {
		final sub: String = 'class C extends B { override inline function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, [{ file: 'B.hx', source: 'class B { public function f():Void {} }' }]);
		Assert.isTrue(fixed.indexOf('override public inline function f') >= 0);
	}

	/** A mid-chain unmarked override defers to ITS supertype: C → B (unmarked override) → A (public). */
	public function testFixOverrideResolvesThroughUnmarkedOverrideChain(): Void {
		final sub: String = 'class C extends B { override function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, [
			{ file: 'A.hx', source: 'class A { public function f():Void {} }' },
			{ file: 'B.hx', source: 'class B extends A { override function f():Void {} }' }
		]);
		Assert.isTrue(fixed.indexOf('override public function f') >= 0);
	}

	/** A simple-name collision whose bases DISAGREE on visibility stays report-only. */
	public function testFixOverrideCollisionDisagreementStaysReportOnly(): Void {
		final sub: String = 'class C extends B { override function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, [
			{ file: 'a/B.hx', source: 'class B { public function f():Void {} }' },
			{ file: 'b/B.hx', source: 'class B { private function f():Void {} }' }
		]);
		Assert.equals(-1, fixed.indexOf('override public'));
		Assert.equals(-1, fixed.indexOf('override private'));
	}

	/** An UNMARKED non-override base member is not provably private (public-default containers exist) — report-only. */
	public function testFixOverrideUnmarkedBaseStaysReportOnly(): Void {
		final sub: String = 'class C extends B { override function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, [{ file: 'B.hx', source: 'class B { function f():Void {} }' }]);
		Assert.equals(-1, fixed.indexOf('override public'));
		Assert.equals(-1, fixed.indexOf('override private'));
	}

	/** An override whose supertype is NOT in the index stays report-only. */
	public function testFixOverrideUnindexedSupertypeStaysReportOnly(): Void {
		final sub: String = 'class C extends B { override function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, []);
		Assert.equals(-1, fixed.indexOf('override public'));
		Assert.equals(-1, fixed.indexOf('override private'));
	}

	/**
	 * An extern class binds an external API: its unmodified members are already PUBLIC (probed:
	 * `e.foo()` typechecks off an `extern class`, and adding `private` makes it "Cannot access
	 * private field"), so the rule skips the container entirely rather than reporting a finding
	 * whose obvious remedy breaks callers.
	 */
	public function testExternClassMembersNotFlagged(): Void {
		Assert.equals(0, violations('extern class C { function f():Void; }').length);
	}

	/**
	 * The fix re-checks extern on its own, so a caller handing it a violation list detection would
	 * never have produced still cannot lower an extern member to `private`. Asserting this through
	 * `fixedSource` would be vacuous now that detection returns nothing to fix.
	 */
	public function testFixRefusesForcedExternViolation(): Void {
		final src: String = 'extern class C { function f():Void; }';
		Assert.equals(src, fixedSourceForced(src, src.indexOf('function f')));
	}

	/** The control for the refusal above: the same forced violation DOES insert in a plain class. */
	public function testFixAppliesForcedViolationInPlainClass(): Void {
		final src: String = 'class C { function f():Void {} }';
		Assert.equals('class C { private function f():Void {} }', fixedSourceForced(src, src.indexOf('function f')));
	}

	/** The extern skip survives the module-level `private extern class` form (a private TYPE, not a private member). */
	public function testPrivateExternClassMembersNotFlagged(): Void {
		Assert.equals(0, violations('private extern class C { function f():Void; }').length);
	}

	/** A non-extern container declared after an extern one still reports: the extern flag must not leak forward. */
	public function testExternSkipDoesNotLeakToNextClass(): Void {
		Assert.equals(1, violations('extern class E { function f():Void; }\nclass C { function g():Void {} }').length);
	}

	/**
	 * The declaration that consumes `extern` need not be one this check scans. An interface / enum
	 * ends the modifier run just as a class does — ending it only on a scanned CONTAINER left the
	 * flag alive and exempted the next class in the module.
	 */
	public function testExternSkipDoesNotLeakPastUnscannedDecl(): Void {
		Assert.equals(1, violations('extern interface I { function h():Void; }\nclass C { function g():Void {} }').length);
		Assert.equals(1, violations('extern enum E { A; }\nclass C { function g():Void {} }').length);
	}

	/** A `@:publicFields` class defaults its members to public; the autofix must NOT force `private`. */
	public function testFixSkipsPublicFieldsClass(): Void {
		Assert.equals(1, violations('@:publicFields class D { function g():Void {} }').length);
		Assert.equals(-1, fixedSource('@:publicFields class D { function g():Void {} }').indexOf('private'));
	}

	/** `final class` wraps the class in a decl node; the extern skip must carry into that wrapper to reach the members. */
	public function testExternFinalClassMembersNotFlagged(): Void {
		Assert.equals(0, violations('extern final class C { function f():Void; }').length);
	}

	/**
	 * The public-default meta ends its run on the interface, not on the next class the fix walk
	 * happens to visit — otherwise `g` is reported but never fixable, and `--fix` converges
	 * silently with the finding still standing.
	 */
	public function testFixPublicFieldsSkipDoesNotLeakToNextClass(): Void {
		final src: String = '@:publicFields\ninterface I { function h():Void; }\nclass C { function g():Void {} }';
		Assert.equals(1, violations(src).length);
		Assert.isTrue(fixedSource(src).indexOf('private function g') >= 0);
	}

	/** A `@:publicFields final class` (the project's house form) must also stay report-only, not get `private`. */
	public function testFixSkipsPublicFieldsFinalClass(): Void {
		Assert.equals(1, violations('@:publicFields final class D { function g():Void {} }').length);
		Assert.equals(-1, fixedSource('@:publicFields final class D { function g():Void {} }').indexOf('private'));
	}

	/** A plain `final class` still defaults members to private, so the autofix DOES insert `private`. */
	public function testFixInsertsPrivateInFinalClass(): Void {
		Assert.isTrue(fixedSource('final class F { function g():Void {} }').indexOf('private function g') >= 0);
	}

	/** A member written inside a member-position `#if` is a member of the class and must be flagged like any other. */
	public function testConditionalMemberFlagged(): Void {
		final src: String = 'class C {\n\t#if cpp\n\tvar a:Int;\n\t#end\n}';
		Assert.equals(1, violations(src).length);
	}

	/** A region with a member in each branch reports each of them. */
	public function testConditionalBothBranchesFlagged(): Void {
		final src: String = 'class C {\n\t#if cpp\n\tvar a:Int;\n\t#else\n\tvar b:Int;\n\t#end\n}';
		Assert.equals(2, violations(src).length);
	}

	/** An `#elseif` chain is branches all the way down, not a two-way split. */
	public function testConditionalElseIfBranchesAllFlagged(): Void {
		final src: String = 'class C {\n\t#if cpp\n\tvar a:Int;\n\t#elseif js\n\tvar b:Int;\n\t#else\n\tvar c:Int;\n\t#end\n}';
		Assert.equals(3, violations(src).length);
	}

	/**
	 * A visibility keyword written BEFORE the `#if` modifies whichever branch compiles, so it
	 * reaches into EVERY branch. The only fixture that discriminates the per-branch restart: a flat
	 * scan of the region's flattened children consumes the keyword on the first member and flags
	 * the second.
	 */
	public function testConditionalIncomingVisibilityReachesEveryBranch(): Void {
		final src: String = 'class C {\n\tpublic\n\t#if cpp\n\tvar a:Int;\n\t#else\n\tvar b:Int;\n\t#end\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A visibility keyword inside the region still exempts its own member; its unmarked neighbour is still flagged. */
	public function testConditionalMemberWithVisibilityNotFlagged(): Void {
		final src: String = 'class C {\n\t#if cpp\n\tpublic var a:Int;\n\tvar b:Int;\n\t#end\n}';
		Assert.equals(1, violations(src).length);
	}

	/** A conditional member coexists with members outside the region; both positions report. */
	public function testConditionalAndPlainMembersBothFlagged(): Void {
		final src: String = 'class C {\n\tvar out:Int;\n\t#if cpp\n\tvar inA:Int;\n\t#end\n}';
		Assert.equals(2, violations(src).length);
	}

	/** A region nested inside another region's branch is reached too. */
	public function testNestedConditionalMemberFlagged(): Void {
		final src: String = 'class C {\n\t#if cpp\n\t#if debug\n\tvar a:Int;\n\t#end\n\t#end\n}';
		Assert.equals(1, violations(src).length);
	}

	/** Nesting in ONE branch does not hide the sibling branch: the nested member and the plain one both report. */
	public function testNestedConditionalInOneBranchFlagged(): Void {
		final src: String = 'class C {\n\t#if cpp\n\t#if debug\n\tvar a:Int;\n\t#end\n\t#else\n\tvar b:Int;\n\t#end\n}';
		Assert.equals(2, violations(src).length);
	}

	/** An abstract is a visibility-requiring container too, `#if`-guarded members included. */
	public function testConditionalMemberInAbstractFlagged(): Void {
		final src: String = 'abstract A(Int) {\n\t#if cpp\n\tfunction g():Void {}\n\t#end\n}';
		Assert.equals(1, violations(src).length);
	}

	/** The keyword lands at the member's own declaration INSIDE the branch, not before the `#if`. */
	public function testFixConditionalMemberInsertsInsideBranch(): Void {
		final fixed: String = fixedSource('class C {\n\t#if cpp\n\tvar a:Int;\n\t#end\n}');
		Assert.equals('class C {\n\t#if cpp\n\tprivate var a:Int;\n\t#end\n}', fixed);
	}

	/** A two-branch region gets one keyword per branch, each at its own member. */
	public function testFixConditionalBothBranchesInsertInPlace(): Void {
		final fixed: String = fixedSource('class C {\n\t#if cpp\n\tvar a:Int;\n\t#else\n\tvar b:Int;\n\t#end\n}');
		Assert.equals('class C {\n\t#if cpp\n\tprivate var a:Int;\n\t#else\n\tprivate var b:Int;\n\t#end\n}', fixed);
	}

	/** The canonical slot rule (before `static` / `inline`) holds inside a branch as well. */
	public function testFixConditionalMemberKeywordPosition(): Void {
		final fixed: String = fixedSource('class C {\n\t#if cpp\n\tstatic inline function f():Void {}\n\t#end\n}');
		Assert.equals('class C {\n\t#if cpp\n\tprivate static inline function f():Void {}\n\t#end\n}', fixed);
	}

	/**
	 * A modifier before the `#if` claims ONE insert offset, and one offset cannot receive one
	 * keyword per branch: carrying it in emitted N identical zero-width inserts there, which
	 * `applyEdits` renders as `private private static`. Each branch's keyword goes at its own
	 * member instead.
	 */
	public function testFixConditionalDoesNotDuplicateAtSharedSlot(): Void {
		final src: String = 'class C {\n\tstatic\n\t#if cpp\n\tfunction a():Void {}\n\t#else\n\tfunction b():Void {}\n\t#end\n}';
		final want: String =
			'class C {\n\tstatic\n\t#if cpp\n\tprivate function a():Void {}\n\t#else\n\tprivate function b():Void {}\n\t#end\n}';
		Assert.equals(want, fixedSource(src));
	}

	/** Meta ranks at or below visibility, inside a branch as anywhere else — the keyword goes after it. */
	public function testFixConditionalMetaMemberKeywordPosition(): Void {
		final fixed: String = fixedSource('class C {\n\t#if cpp\n\t@:keep var a:Int;\n\t#end\n}');
		Assert.equals('class C {\n\t#if cpp\n\t@:keep private var a:Int;\n\t#end\n}', fixed);
	}

	/**
	 * A region holding ONLY the visibility keyword straddles into the member after `#end` — the
	 * modifier belongs to that member, so flagging it (and inserting a second keyword) is wrong.
	 */
	public function testStraddlingConditionalModifierNotFlagged(): Void {
		final src: String = 'class C {\n\t#if cpp\n\tpublic\n\t#else\n\tprivate\n\t#end\n\tfunction f():Void {}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** The carry-out is per branch, not "the first branch wins": a keyword in the LAST branch exempts too. */
	public function testStraddlingModifierInLaterBranchNotFlagged(): Void {
		final src: String = 'class C {\n\t#if cpp\n\tprivate\n\t#else\n\tpublic\n\t#end\n\tvar a:Int;\n}';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A straddling `override` governs the member after `#end` as well, so the fix must route it
	 * through the index rather than force `private` — which would lower visibility below the
	 * supertype, a compile error.
	 */
	public function testFixStraddlingOverrideStaysReportOnly(): Void {
		final src: String = 'class C extends B {\n\t#if cpp\n\toverride\n\t#end\n\tfunction f():Void {}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(-1, fixedSource(src).indexOf('private'));
	}

	/**
	 * An `override` written BEFORE the `#if` governs the member of whichever branch compiles, so
	 * every branch must start the fix run from it. The fix-side counterpart of
	 * `testConditionalIncomingVisibilityReachesEveryBranch`: a flat scan consumes the override on
	 * the first branch's member and forces `private` on the second, lowering visibility below the
	 * supertype — a compile error.
	 */
	public function testFixIncomingOverrideReachesEveryBranch(): Void {
		final src: String =
			'class C extends B {\n\toverride\n\t#if cpp\n\tfunction f():Void {}\n\t#else\n\tfunction g():Void {}\n\t#end\n}';
		Assert.equals(2, violations(src).length);
		Assert.equals(-1, fixedSource(src).indexOf('private'));
	}

	/** A straddling `static` does NOT claim the insert slot: the keyword lands at the member, after `#end`. */
	public function testFixStraddlingStaticInsertsAtMember(): Void {
		final fixed: String = fixedSource('class C {\n\t#if cpp\n\tstatic\n\t#end\n\tfunction f():Void {}\n}');
		Assert.equals('class C {\n\t#if cpp\n\tstatic\n\t#end\n\tprivate function f():Void {}\n}', fixed);
	}

	/** An extern container is skipped whatever its members look like — the region is never descended into at all. */
	public function testExternConditionalMembersNotFlagged(): Void {
		final src: String = 'extern class C {\n\t#if cpp\n\tfunction f():Void;\n\t#end\n}';
		Assert.equals(0, violations(src).length);
	}

	private function violations(src: String): Array<Violation> {
		return new MissingVisibility().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		final check: MissingVisibility = new MissingVisibility();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		return applyEdits(src, edits);
	}

	/**
	 * `fixedSource` driven by a violation SYNTHESIZED at `memberAt` rather than by `run` — the only
	 * way to reach a fix-side guard that detection now makes unreachable on its own.
	 */
	private function fixedSourceForced(src: String, memberAt: Int): String {
		final check: MissingVisibility = new MissingVisibility();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final forced: Array<Violation> = [
			{
				file: 'C.hx',
				span: new Span(memberAt, memberAt + 1),
				rule: 'missing-visibility',
				severity: Severity.Warning,
				message: 'forced'
			}
		];
		return applyEdits(src, check.fix(src, forced, plugin));
	}

	/** `fixedSource` with a `SymbolIndex` built over `others` + the fixed file itself — the production `--fix` shape. */
	private function fixedSourceIndexed(src: String, others: Array<{ file: String, source: String }>): String {
		final check: MissingVisibility = new MissingVisibility();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = others.concat([{ file: 'C.hx', source: src }]);
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final edits: Array<{ span: Span, text: String }> =
			check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin, index);
		return applyEdits(src, edits);
	}

	private static function applyEdits(src: String, edits: Array<{ span: Span, text: String }>): String {
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
