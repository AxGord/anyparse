package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedPrivate;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `unused-private` check: a `private` field / method with no reference is flagged.
 * Confinement is occurrence-based — a subtype / @:access / @:allow keeps a member only
 * when it NAMES it (zero occurrences project-wide is dead regardless of structure); a
 * skip-parse in report scope still keeps the member (a reference could be hidden).
 * Referenced, public, and implicitly-reachable (constructor / accessor / annotated)
 * members are not flagged. The autofix deletes a dead method or side-effect-free field
 * and keeps a side-effecting one.
 */
class UnusedPrivateCheckTest extends Test {

	public function testDeadPrivateMethodFlagged(): Void {
		final vs: Array<Violation> = one('class C {\n\tprivate function dead() {}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('unused-private', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("'dead'"));
	}

	public function testDeadPrivateFieldFlagged(): Void {
		Assert.equals(1, one('class C {\n\tprivate var _x:Int;\n}').length);
	}

	public function testDeadStaticFinalFlagged(): Void {
		final vs: Array<Violation> = one('class C {\n\tprivate static final GONE = 5;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'GONE'"));
	}

	public function testReferencedMethodNotFlagged(): Void {
		Assert.equals(0, one('class C {\n\tprivate function used() {}\n\tpublic function f() { used(); }\n}').length);
	}

	public function testReferencedFieldNotFlagged(): Void {
		Assert.equals(0, one('class C {\n\tprivate var _x:Int = 0;\n\tpublic function f() { return _x; }\n}').length);
	}

	public function testPublicMemberNotFlagged(): Void {
		Assert.equals(0, one('class C {\n\tpublic function pub() {}\n\tpublic var v:Int;\n}').length);
	}

	public function testConstructorNotFlagged(): Void {
		Assert.equals(0, one('class C {\n\tprivate function new() {}\n}').length);
	}

	public function testAccessorNotFlagged(): Void {
		// get_x is reached via the property's (get, never), not a textual `get_x` reference.
		Assert.equals(0, one('class C {\n\tpublic var x(get, never):Int;\n\tprivate function get_x() return 1;\n}').length);
	}

	public function testAnnotatedMemberNotFlagged(): Void {
		// @:keep (or any annotation) may be referenced by a framework / macro.
		Assert.equals(0, one('class C {\n\t@:keep private function dead() {}\n}').length);
	}

	/**
	 * Occurrence-based confinement (project-owner decision): a subtype that NAMES the
	 * private member reaches it, so the member is kept. Replaces the old structure-only
	 * `testSubtypeKeepsMember` invariant — a subtype no longer keeps a member unconditionally.
	 */
	public function testSubtypeKeepsREFERENCEDMember(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: 'package pkg;\nclass C {\n\tprivate var _x:Int;\n}' },
			{ file: 'pkg/D.hx', source: 'package pkg;\nclass D extends C {\n\tpublic function f() { return _x; }\n}' }
		];
		Assert.equals(0, violations(files).filter(v -> v.file == 'pkg/C.hx').length);
	}

	/**
	 * Occurrence-based confinement: a subtype EXISTS but never names the private member, so
	 * the name has zero occurrences project-wide — provably dead, reported AND deleted (the
	 * lifted `hasSubtype` arm; the four dead PlayerBase fields motivating this change).
	 */
	public function testSubtypeDeadMemberDeletes(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var _x:Int;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/D.hx', source: 'package pkg;\nclass D extends C {}' }
		];
		final check: UnusedPrivate = new UnusedPrivate();
		final cViol: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.equals(1, cViol.length);
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.equals(1, check.fix(cSrc, cViol, new HaxeQueryPlugin(), index).length);
	}

	/** Occurrence-based: an `@:access` grantee that NAMES the member reaches it -> kept. */
	public function testAccessGrantKeepsMember(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: 'package pkg;\nclass C {\n\tprivate var _x:Int;\n}' },
			{ file: 'pkg/E.hx', source: 'package pkg;\n@:access(pkg.C)\nclass E {\n\tpublic function f(c:C) { return c._x; }\n}' }
		];
		Assert.equals(0, violations(files).filter(v -> v.file == 'pkg/C.hx').length);
	}

	/** Occurrence-based: an `@:allow`ed type that NAMES the member reaches it -> kept. */
	public function testAllowKeepsMember(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: 'package pkg;\n@:allow(pkg.X)\nclass C {\n\tprivate var _x:Int;\n}' },
			{ file: 'pkg/X.hx', source: 'package pkg;\nclass X {\n\tpublic function f(c:C) { return c._x; }\n}' }
		];
		Assert.equals(0, violations(files).filter(v -> v.file == 'pkg/C.hx').length);
	}

	public function testSkipParseKeepsMemberOnlyWhenItMentionsIt(): Void {
		// A file the grammar cannot read can only reference a member it SPELLS, so the veto is
		// per-name. It used to be per-PROJECT: one unparseable file silenced the rule everywhere.
		Assert.equals(0, skipParseViolations('package pkg;\nclass Bad { function f() { _x = 1;'));
		Assert.equals(1, skipParseViolations('package pkg;\nclass Bad { function f() { other = 1;'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations([{ file: 'Bad.hx', source: 'class Bad { function f() { ' }]).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unused-private'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unused-private'));
	}

	public function testFixDeletesDeadMethod(): Void {
		Assert.equals(1, fixEdits('class C {\n\tprivate function dead() {}\n}').length);
	}

	/**
	 * A dead private takes its doc comment with it. Kept behind, the block becomes the
	 * documentation of whatever declaration follows — silently, since a single orphan
	 * stacks with nothing and no check reports it.
	 */
	public function testFixTakesTheDeadMemberDoc(): Void {
		// The doc must not NAME the member: `unused-private` keeps a member whose name
		// occurs in a comment, so a self-naming doc would make this pass vacuously.
		final src: String = 'class C {\n\t/** Explains the helper. */\n\tprivate function dead() {}\n\n\tpublic function keep() {}\n}';
		final edits: Array<{ span: Span, text: String }> = fixEdits(src);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('Explains the helper') == -1, text);
				Assert.isTrue(text.indexOf('dead') == -1, text);
				Assert.isTrue(text.indexOf('keep') >= 0, text);
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
	}

	public function testFixDeletesSideEffectFreeField(): Void {
		Assert.equals(1, fixEdits('class C {\n\tprivate var _x:Int = 5;\n}').length);
	}

	public function testFixSkipsSideEffectingField(): Void {
		// _x is dead (flagged) but its initializer has a side effect — report-only, no edit.
		final src: String = 'class C {\n\tprivate var _x:Int = sideEffect();\n}';
		final vs: Array<Violation> = one(src);
		Assert.equals(1, vs.length);
		Assert.equals(0, new UnusedPrivate().fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixAppliedRemovesDeadMethodKeepsRest(): Void {
		final src: String = 'class C {\n\tprivate function dead() {}\n\tpublic function keep() {}\n}';
		final check: UnusedPrivate = new UnusedPrivate();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('dead') == -1);
				Assert.isTrue(text.indexOf('keep') >= 0);
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
	}

	/** A utest test method (`test*`) is invoked by utest's macro, not by an in-source reference — not flagged. */
	public function testUtestMethodNotFlagged(): Void {
		Assert.equals(0, one('class C extends Test {\n\tfunction testX() {}\n}').length);
	}

	/** A non-test-named private helper in a Test subclass is still flagged (the name gate). */
	public function testNonTestHelperInTestClassFlagged(): Void {
		Assert.equals(1, one('class C extends Test {\n\tprivate function helper() {}\n}').length);
	}

	/** A `test*`-named private method NOT in a Test subclass is flagged (the extends gate). */
	public function testTestNamedOutsideTestClassFlagged(): Void {
		Assert.equals(1, one('class C {\n\tprivate function testX() {}\n}').length);
	}

	/** A macro-force field (`static final _x: Class<Marker> = Marker;`) is load-bearing — not flagged. */
	public function testMacroForceFieldNotFlagged(): Void {
		Assert.equals(0, one('class C {\n\tprivate static final _f: Class<Marker> = Marker;\n}').length);
	}

	/** A `static final` with a lowercase-ident initializer is not a type reference — still flagged. */
	public function testStaticFinalLowercaseInitFlagged(): Void {
		Assert.equals(1, one('class C {\n\tprivate static final _dead = value;\n}').length);
	}

	/** A test method in a class extending an INTERMEDIATE base that extends Test is exempt (transitive). */
	public function testUtestMethodViaIntermediateBaseNotFlagged(): Void {
		Assert.equals(0, one('class Base extends Test {}\nclass C extends Base {\n\tfunction testX() {}\n}').length);
	}

	/**
	 * (a) A private member referenced ONLY inside a `#if…#end` region's text is
	 * live — the raw-text usage scan sees inside Conditional interiors, which an
	 * AST-span scan would not. Regression guard for the raw-text veto.
	 */
	public function testMemberUsedOnlyInConditionalNotFlagged(): Void {
		Assert.equals(0, one('class C {\n\tprivate function dead() {}\n\t#if debug\n\tpublic function f() { dead(); }\n\t#end\n}').length);
	}

	/**
	 * (b) An `extern class` member carries no visibility keyword yet is PUBLIC by
	 * the extern rule — it is reached from outside the file and must never be
	 * flagged or deleted (deleting native bindings breaks the link).
	 */
	public function testExternClassMemberNotFlagged(): Void {
		Assert.equals(0, one('extern class C {\n\tfunction lock():Void;\n\tfunction unlock():Void;\n}').length);
	}

	/**
	 * (c) An `override` member — even one with NO visibility modifier — inherits
	 * the base's visibility and is not private; it is invoked polymorphically
	 * from code a single-file scan cannot see. Never flagged.
	 */
	public function testOverrideMemberNotFlagged(): Void {
		Assert.equals(0, one('class C extends B {\n\toverride function commit() {}\n}').length);
	}

	/**
	 * (d) A `get_`/`set_` accessor linked to a `var X(get, …)` / `(…, set)`
	 * property is referenced implicitly through the property — never flagged.
	 */
	public function testPropertyAccessorNotFlagged(): Void {
		Assert.equals(0, one('class C {\n\tpublic var count(get, null):Int;\n\tprivate function get_count() return 1;\n}').length);
	}

	/**
	 * (e) An unreferenced private method in a class that `extends` a base may
	 * implement one of the base's abstract methods (Haxe abstract-method impls
	 * carry no `override`, and the base's call is invisible to a single-file
	 * scan). It is still REPORTED, but `--fix` must not auto-delete it.
	 */
	public function testAbstractImplInSubclassReportedNotDeleted(): Void {
		final src: String = 'class C extends Base {\n\tprivate function render() {}\n}';
		final vs: Array<Violation> = one(src);
		Assert.equals(1, vs.length);
		Assert.equals(0, new UnusedPrivate().fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testUnprojectedEnumAbstractValuesNotFlagged(): Void {
		// A value of an enum abstract written `@:enum` — or through the `#if` version guard — projects
		// as an unmodified, so private, field of a plain abstract, while it is in fact public API.
		// Read as private, `--fix` deleted 15 of one real file's 17 colour constants.
		Assert.equals(0, one('@:enum abstract E(Int) {\n\tfinal X = 0;\n\tfinal Y = 1;\n}').length);
		final guarded: String = '#if (haxe_ver >= 4.2) enum #else @:enum #end abstract E(Int) {\n\tfinal X = 0;\n\tfinal Y = 1;\n}';
		Assert.equals(0, one(guarded).length);
	}

	public function testMetaOnlyCondRegionLeavesAbstractMemberFlagged(): Void {
		// The exemption is the declaration-prefix KEYWORD the region contributes, not the region
		// itself: a leading region carrying only metadata leaves a plain abstract's member reported.
		Assert.equals(1, one('#if js @:native("F") #end abstract F(Int) {\n\tfunction g():Void {}\n}').length);
	}

	public function testAnnotationBehindCondRegionStillExempts(): Void {
		// `@:op(A << B) #if (haxe_ver >= 4.2) extern #else @:extern #end private inline function` puts a
		// REGION between the annotation and the declaration, and the grammar's run walk stops there — so
		// every member of the cross-version `extern` idiom read as unannotated. Nothing NAMES an operator
		// overload or a `@:from` conversion, so the reference scan cannot save one: `--fix` deleted six of
		// `pony/events/Signal0.hx`'s and `signal << listener` became the builtin integer shift.
		final guard: String = '#if (haxe_ver >= 4.2) extern #else @:extern #end';
		Assert.equals(0, one('abstract S(Int) {\n\t@:op(A << B) $guard\n\tprivate inline function shl(b:Int):S return this;\n}').length);
		Assert.equals(0, one('abstract S(Int) {\n\t@:from $guard\n\tprivate static inline function of(b:Bool):S return 0;\n}').length);
	}

	public function testAnnotationBeforeRegionExemptsTheMemberInsideIt(): Void {
		// The run crosses the seam OUTWARD as well: a member declared INSIDE a region runs out of
		// siblings at the `#if`, and its run CONTINUES in the region's own leading run — so `@:keep`
		// written before `#if` annotates `a`. Without that step the grammar read `a` as unannotated
		// and `--fix` deleted a `@:keep`-ed member. Only `dead`, the unannotated sibling, is reported.
		final vs: Array<Violation> =
			one('class C {\n\t@:keep #if js private function a():Void {} #end\n\tprivate function dead():Void {}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('\'dead\'') >= 0);
	}

	/**
	 * A modifier the language documents no canonical position for is ranked by nothing and named by
	 * no single-modifier seam — and the leading-run walk derived "is this sibling a modifier?" from
	 * exactly those, so it stopped at `overload` and every member of the Haxe 4.2 overload idiom read
	 * as UNANNOTATED. `--fix` deleted the `@:keep`-ed member and left the bare `@:keep overload`
	 * prefix behind, a file that no longer parses. Only `dead`, the unannotated sibling, is reported.
	 */
	public function testAnnotationBeforeOverloadModifierExemptsTheMember(): Void {
		final vs: Array<Violation> = one('class C {\n\t@:keep overload private function a():Void {}\n\tprivate function dead():Void {}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('\'dead\'') >= 0);
	}

	public function testCondRegionAloneDoesNotExemptAndDoesNotCarryOver(): Void {
		// The region only stops ENDING the run; it grants nothing of its own, so an unannotated member
		// written in the same idiom stays reported. And a region that HOLDS a member ends the run: the
		// annotation above it belongs to that member, never to the next one.
		final guard: String = '#if (haxe_ver >= 4.2) extern #else @:extern #end';
		Assert.equals(1, one('class C {\n\t$guard\n\tprivate inline function dead():Void {}\n}').length);
		Assert.equals(1, one('class C {\n\t@:keep #if js private function a():Void {} #end\n\tprivate function dead():Void {}\n}').length);
	}

	public function testOpAnnotatedMemberNotFlagged(): Void {
		// An `@:op(A < B)` operator overload is invoked via the operator, never by name,
		// and projects as a `MetaCall` (argumented meta) sibling — the annotated-member skip
		// must recognize `MetaCall`, not only a bare `Meta`, else the operator method is a
		// false unused-private (surfaced by MemberRank's `@:op` in the member-order check).
		final src: String = 'enum abstract R(Int) {\n\tfinal A = 0;\n\tfinal B = 1;\n\t@:op(A < B) static function lt(a:R, b:R):Bool;\n}';
		Assert.equals(0, one(src).length);
	}

	/**
	 * A private method of a subclass whose base is not in the linted file set may
	 * implement one of the base's abstract methods (Haxe impls carry no `override`
	 * and the base's polymorphic call is invisible to a single-file scan); `--fix`
	 * must report it but never delete it (`mayImplementAbstractMethod`).
	 */
	public function testFixKeepsExtendsClassPrivateMethod(): Void {
		final src: String =
			'class Sub extends UnresolvableBase {\n\tprivate function needToGetSharedInternal():Bool {\n\t\treturn true;\n\t}\n}';
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run([{ file: 'Sub.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(0, edits.length);
	}

	/**
	 * The real regression: a private method inside a member-level `#if … #end`
	 * region of a subclass. Conditional-compilation projects the method as a child
	 * of a `Conditional` node, so the enclosing class's `ExtendsClause` is a sibling
	 * of that wrapper, not of the method — the extends carve-out must still spare it.
	 * Reported as unused, but `--fix` emits no edit.
	 */
	public function testFixKeepsExtendsClassMethodInConditional(): Void {
		final src: String =
			'class Sub extends UnresolvableBase {\n\t#if cpp\n\tprivate function abstractImpl():Bool {\n\t\treturn true;\n\t}\n\t#end\n}';
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run([{ file: 'Sub.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(0, edits.length);
	}

	/**
	 * Refined #if gate (member arm): a dead private FIELD in a `#if`-carrying file whose
	 * name occurs NOWHERE in scope outside its declaration is deleted — the raw
	 * report-UNION-resolution scan sees inside every `#if` branch, so zero hits proves it
	 * unreferenced and lifts the whole-file veto (the four provably-dead PlayerBase fields).
	 */
	public function testFixDeletesDeadMemberInConditionalFileWhenUnreferenced(): Void {
		final src: String = 'class C {\n\tprivate var _x:Int = 5;\n\t#if debug\n\tpublic function d() { trace(1); }\n\t#end\n}';
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(1, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	/**
	 * Refined #if gate (member arm, member INSIDE the region): a dead private member
	 * declared inside a `#if … #end` region with zero scope occurrences is deleted — the
	 * raw scan proves it unreferenced in every branch, so removing it is safe in every
	 * configuration (a PlayerBase field may itself sit inside a platform `#if`).
	 *
	 * The region carries a SECOND member on purpose: with `_dead` as its only one the deletion
	 * would empty the region, and `MemberBranchScan.survivingDeletions` declines that set — a
	 * different rule, covered by `testFixKeepsRegionWhoseEveryMemberIsDead`. Shrinking the
	 * fixture back to one member turns this into a test of that gate instead of this one.
	 */
	public function testFixDeletesDeadMemberDeclaredInsideConditional(): Void {
		final src: String = 'class C {\n\tpublic function keep() {}\n\t#if debug\n\tprivate var _dead:Int = 5;\n\n'
			+ '\tpublic function dbg():Void {\n\t\ttrace(1);\n\t}\n\t#end\n}';
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(1, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	/**
	 * Refined #if gate (member arm, cross-file): a dead private member flagged in a
	 * `#if`-carrying file whose name appears inside another scope file's `#if` region is
	 * KEPT — an occurrence in any branch of any indexed file keeps the whole-file veto.
	 */
	public function testFixKeepsConditionalFileMemberReferencedElsewhere(): Void {
		final cSrc: String =
			'package pkg;\nclass C {\n\tprivate function foo() {}\n\t#if debug\n\tpublic function dbg() { trace(1); }\n\t#end\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/D.hx', source: 'package pkg;\nclass D {\n\t#if debug\n\tpublic function bar() { foo(); }\n\t#end\n}' }
		];
		final check: UnusedPrivate = new UnusedPrivate();
		final cViol: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.equals(1, cViol.length);
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.equals(0, check.fix(cSrc, cViol, new HaxeQueryPlugin(), index).length);
	}

	/**
	 * Refined #if gate (member arm, comment mention): a dead private member flagged in a
	 * `#if`-carrying file whose name appears only in a COMMENT in another scope file is
	 * KEPT — the raw scan counts comment mentions, so the veto stands. Deletion through a
	 * comment mention is a deliberate non-goal (possible future refinement).
	 */
	public function testFixKeepsConditionalFileMemberMentionedInComment(): Void {
		final cSrc: String =
			'package pkg;\nclass C {\n\tprivate function foo() {}\n\t#if debug\n\tpublic function dbg() { trace(1); }\n\t#end\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/D.hx', source: 'package pkg;\nclass D {\n\t// once called foo here\n\tpublic function bar() {}\n}' }
		];
		final check: UnusedPrivate = new UnusedPrivate();
		final cViol: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.equals(1, cViol.length);
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.equals(0, check.fix(cSrc, cViol, new HaxeQueryPlugin(), index).length);
	}

	/**
	 * Refined #if gate does NOT bypass the @:rtti gate: an `@:rtti` class member in a
	 * `#if`-carrying file with zero scope occurrences lifts the whole-file veto but is
	 * still kept — field-name serialization reaches it reflectively (`transitivelyCarriesRtti`).
	 */
	public function testFixKeepsRttiMemberInConditionalFile(): Void {
		final src: String = '@:rtti class C {\n\tprivate var _x:Int;\n\t#if debug\n\tpublic function d() { trace(1); }\n\t#end\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	/**
	 * Empty-ctor arm (positive): a `private function new() {}` in a never-instantiated
	 * all-static utility class is pure instantiation-prevention boilerplate — reported
	 * and deleted. Reconstructs the pre-edit shape of TM's DashLineUtil (ctor since
	 * hand-removed) and asserts the rule deletes exactly that constructor.
	 */
	public function testEmptyCtorOfUtilityClassDeleted(): Void {
		final src: String = 'class DashLineUtil {\n\tpublic static var gap:Float = 4;\n\tprivate static var thickness:Float = 2;\n'
			+ '\tpublic static function draw() { thickness += gap; }\n\tprivate function new() {}\n}';
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run([{ file: 'DashLineUtil.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'new'"));
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(1, edits.length);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('function new') == -1);
				Assert.isTrue(text.indexOf('draw') >= 0);
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
	}

	/**
	 * Empty-ctor arm: a `new <Class>(` anywhere in scope (e.g. a static factory) means
	 * the class IS instantiated — the constructor is reachable and never flagged.
	 */
	public function testEmptyCtorKeptWhenInstantiated(): Void {
		Assert.equals(0, one('class U {\n\tpublic static function make():U { return new U(); }\n\tprivate function new() {}\n}').length);
	}

	/**
	 * Empty-ctor arm: the whole-file `#if` veto still applies to the constructor arm
	 * (unlike the member arm's zero-occurrence refinement) — a utility class in a
	 * conditionally-compiled file yields no constructor deletion. The `#if` region carries
	 * a referenced member so the only candidate edit is the constructor itself.
	 */
	public function testEmptyCtorKeptWhenFileHasConditional(): Void {
		final src: String = 'class U {\n\tpublic static function draw() { dbg(); }\n\tprivate function new() {}\n\t#if debug\n'
			+ '\tstatic function dbg() { trace(1); }\n\t#end\n}';
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run([{ file: 'U.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	/**
	 * Empty-ctor arm: a `@:build` macro class may generate an instantiation the scan
	 * cannot see, so its constructor is never flagged.
	 */
	public function testEmptyCtorNotFlaggedWhenClassHasBuild(): Void {
		final src: String = '@:build(M.b()) class U {\n\tpublic static function draw() {}\n\tprivate function new() {}\n}';
		Assert.equals(
			0,
			new UnusedPrivate().run([{ file: 'U.hx', source: src }], new HaxeQueryPlugin()).filter(v -> v.message.contains("'new'")).length
		);
	}

	/**
	 * Gate 3 (@:rtti / drill-Node): a private field of a class in an `@:rtti` hierarchy
	 * is serialized by reflecting on field NAMES — reported but never deleted; only the
	 * cross-file index reveals the rtti.
	 */
	public function testFixKeepsRttiClassMember(): Void {
		final src: String = '@:rtti class C {\n\tprivate var _x:Int;\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	/**
	 * Gate 5 (@:build): a private member of a `@:build` macro class may be referenced by
	 * generated code — reported but never deleted.
	 */
	public function testFixKeepsBuildClassMember(): Void {
		final src: String = '@:build(M.build()) class C {\n\tprivate function dead() {}\n}';
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	/**
	 * The build-macro question had TWO answers: this check's leading-run walk, which knew only
	 * `@:build`, and `MemberWriteScan.carriesBuildMacro`, which knows all three spellings. The walk
	 * now reads `RefShape.typeBuildMacroMetaNames` instead of a Haxe tag written into the check, so
	 * a type built per instantiation is protected exactly like a `@:build` one.
	 */
	public function testFixKeepsGenericBuildClassMember(): Void {
		assertReportedButNotDeleted('@:genericBuild(M.build()) class C {\n\tprivate function dead() {}\n}');
	}

	/** The third spelling, and the one that reaches a class through `implements` in the wild. */
	public function testFixKeepsAutoBuildClassMember(): Void {
		assertReportedButNotDeleted('@:autoBuild(M.build()) class C {\n\tprivate function dead() {}\n}');
	}

	/** The empty-constructor arm reads the same seam, through its own `typeStartsAny` call. */
	public function testEmptyCtorNotFlaggedWhenClassHasGenericBuild(): Void {
		final src: String = '@:genericBuild(M.b()) class U {\n\tpublic static function draw() {}\n\tprivate function new() {}\n}';
		Assert.equals(
			0,
			new UnusedPrivate().run([{ file: 'U.hx', source: src }], new HaxeQueryPlugin()).filter(v -> v.message.contains("'new'")).length
		);
	}

	/**
	 * Gate 3 (@:keep on the class): all members are retained for reflection / DCE — a
	 * private member is reported but never deleted.
	 */
	public function testFixKeepsKeepClassMember(): Void {
		final src: String = '@:keep class C {\n\tprivate function dead() {}\n}';
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	/**
	 * Gate 2 (reflection string-literal mention): a confined private member whose NAME
	 * appears in a string literal in ANOTHER file may be reached by reflection — reported
	 * but never deleted.
	 */
	public function testFixKeepsReflectionMentionedMember(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var _x:Int;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/D.hx', source: 'package pkg;\nclass D {\n\tpublic function f(o:Dynamic) { Reflect.setField(o, "_x", 1); }\n}' }
		];
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final cViol: Array<Violation> = vs.filter(v -> v.file == 'pkg/C.hx');
		Assert.equals(1, cViol.length);
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.equals(0, check.fix(cSrc, cViol, new HaxeQueryPlugin(), index).length);
	}

	public function testModuleInitMagicMethodNotFlagged(): Void {
		Assert.equals(0, one('class C {\n\tprivate static function __init__():Void {\n\t\ttrace(1);\n\t}\n}').length);
	}

	public function testAbstractClassDeadPrivateFlagged(): Void {
		Assert.equals(
			1, one('abstract class C {\n\tprivate function dead() {}\n}').length, 'an abstract class body is inspected like a plain class'
		);
	}

	public function testAbstractMethodDeclarationNotFlagged(): Void {
		Assert.equals(
			0, one('abstract class B {\n\tprivate abstract function tag():String;\n}').length,
			'an abstract member is a subclass contract, never dead in its declaring class'
		);
	}

	public function testPublicAbstractMethodNotFlagged(): Void {
		Assert.equals(
			0, one('abstract class B {\n\tpublic abstract function area():Float;\n}').length,
			'the Abstract modifier sibling must not break the public-modifier scan'
		);
	}

	public function testAbstractClassPrivateCtorNotFlagged(): Void {
		Assert.equals(
			0, one('abstract class B {\n\tpublic static var shared:Int = 0;\n\tprivate function new() {}\n}').length,
			'an abstract class is never instantiated by definition — its private empty ctor is the subclass-only idiom'
		);
	}

	public function testFixSkipsBodylessDeclaration(): Void {
		// A body-less declaration is reported (extern privates are not exempt) but
		// never deleted — its implementation lives outside the scanned source.
		Assert.equals(0, fixEdits('class C {\n\tprivate extern function ext():Void;\n}').length);
	}

	/**
	 * An implementation of an ABSTRACT supertype member carries neither `abstract` nor `override`
	 * — Haxe rejects `override` on one — so a carve-out reading only the declaration's modifiers
	 * misses it, while the base invokes it polymorphically through its own abstract declaration.
	 */
	public function testAbstractImplementationNotFlagged(): Void {
		final vs: Array<Violation> = violations([
			{
				file: 'Base.hx',
				source: 'abstract class Base {\n\tpublic function run():Void {\n\t\tstep();\n\t}\n\n'
				+ '\tabstract private function step():Void;\n}'
			},
			{ file: 'Impl.hx', source: 'class Impl extends Base {\n\tprivate function step():Void {\n\t\ttrace(1);\n\t}\n}' }
		]);
		Assert.equals(0, vs.length, 'the implementation is reachable through the base, not dead');
	}

	/**
	 * A member-position `#if … #end` region whose EVERY member is dead is left alone: deleting
	 * the set would leave `#if swc` standing over nothing, which is not a class body this
	 * grammar parses. The findings stay reported.
	 */
	public function testFixKeepsRegionWhoseEveryMemberIsDead(): Void {
		final src: String = 'class C {\n\tpublic function live():Void {\n\t\ttrace(1);\n\t}\n\n\t#if swc\n'
			+ '\tprivate function a():Void {}\n\n\tprivate function b():Void {}\n\t#end\n}';
		Assert.equals(2, new UnusedPrivate().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()).length);
		Assert.equals(0, fixEdits(src).length);
	}

	/**
	 * Both arms of a two-branch region are dead: the branches project as FLAT siblings of one
	 * region node, so the set accounts for the whole region and is declined. An `#else` whose
	 * members survive would keep the region populated instead — the emptiness is the region's
	 * property, never a branch's.
	 */
	public function testFixKeepsRegionWhoseEveryBranchMemberIsDead(): Void {
		final src: String = 'class C {\n\tpublic function live():Void {\n\t\ttrace(1);\n\t}\n\n\t#if swc\n'
			+ '\tprivate function a():Void {}\n\t#else\n\tprivate function b():Void {}\n\t#end\n}';
		Assert.equals(2, new UnusedPrivate().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()).length);
		Assert.equals(0, fixEdits(src).length);
	}

	/**
	 * A member of a NESTED region counts toward its outer region too, so both dead members go back
	 * together: the guard reads the outer region as losing everything it holds, not just its own
	 * direct child. Both `dead` and `alsoDead` are flagged and neither is deleted.
	 */
	public function testFixKeepsOuterRegionWhenNestedRegionEmptiesToo(): Void {
		final src: String = 'class C {\n\tpublic function live():Void {\n\t\ttrace(1);\n\t}\n\n\t#if swc\n'
			+ '\tprivate function dead():Void {}\n\n\t#if debug\n\tprivate function alsoDead():Void {}\n\t#end\n\t#end\n}';
		Assert.equals(2, new UnusedPrivate().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()).length);
		Assert.equals(0, fixEdits(src).length);
	}

	/**
	 * A MODULE-position region is stepped through, not treated as a member region: emptying a class
	 * declared inside `#if flash … #end` of its members leaves `#if flash class C {} #end`, which
	 * parses. Handing that region to the guard as a container would read the class's members as the
	 * region's own and decline a deletion that is fine.
	 */
	public function testFixDeletesInsideModuleLevelConditional(): Void {
		final src: String = '#if flash\nclass C {\n\tprivate function dead():Void {}\n}\n#end';
		Assert.equals(1, fixEdits(src).length);
	}

	/**
	 * A region's `#else` branch is covered by the annotation before the region too. The projection
	 * flattens every branch into ONE child list with no branch marker, so `b` reads as a member
	 * PRECEDED by `a` inside the region - and treating that as the run's end left the `#else` twin of
	 * an `@:keep`-ed member unannotated, after which `--fix` deleted it. Inside a region nothing ends
	 * the run: it runs out and continues in the region's own leading run.
	 */
	public function testElseBranchMemberOfAnnotatedRegionExempt(): Void {
		Assert.equals(0, one('class C {\n\t@:keep #if js private function a():Void {} #else private function b():Void {} #end\n}').length);
	}

	/**
	 * The class-level `@:keep` deletion guard reaches its members across a member-free
	 * conditional-compilation region, the same seam the member-level run crosses. Its own walk had no
	 * seam at all and stopped at the region, so `#if js @:native("C") #end` between the annotation and
	 * the class dropped the whole class's protection and `--fix` deleted its privates. Report-only,
	 * like the region-free twin above.
	 */
	public function testFixKeepsKeepClassMemberAcrossMemberFreeRegion(): Void {
		final src: String = '@:keep #if js @:native("C") #end\nclass C {\n\tprivate function dead() {}\n}';
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	/** `run` reports the dead member and `fix` declines it — the shape every class-annotation gate has. */
	private function assertReportedButNotDeleted(src: String): Void {
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length, 'the member is still reported');
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length, 'and not deleted');
	}

	/** `unused-private` findings for `pkg/C.hx` with one unparseable sibling carrying `badSrc`. */
	private function skipParseViolations(badSrc: String): Int {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: 'package pkg;\nclass C {\n\tprivate var _x:Int;\n}' },
			{ file: 'pkg/Bad.hx', source: badSrc }
		];
		return violations(files).filter(v -> v.file == 'pkg/C.hx').length;
	}

	private function one(source: String): Array<Violation> {
		return violations([{ file: 'C.hx', source: source }]);
	}

	private function violations(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new UnusedPrivate().run(files, new HaxeQueryPlugin());
	}

	private function fixEdits(source: String): Array<{ span: Span, text: String }> {
		final check: UnusedPrivate = new UnusedPrivate();
		return check.fix(source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
