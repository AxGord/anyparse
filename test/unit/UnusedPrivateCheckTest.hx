package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedPrivate;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

using StringTools;

import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;

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

	public function testSkipParseKeepsMember(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: 'package pkg;\nclass C {\n\tprivate var _x:Int;\n}' },
			{ file: 'pkg/Bad.hx', source: 'package pkg;\nclass Bad { function f() { ' }
		];
		Assert.equals(0, violations(files).filter(v -> v.file == 'pkg/C.hx').length);
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
		final src: String = 'class Sub extends UnresolvableBase {\n\tprivate function needToGetSharedInternal():Bool {\n\t\treturn true;\n\t}\n}';
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
		final src: String = 'class Sub extends UnresolvableBase {\n\t#if cpp\n\tprivate function abstractImpl():Bool {\n\t\treturn true;\n\t}\n\t#end\n}';
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
	 */
	public function testFixDeletesDeadMemberDeclaredInsideConditional(): Void {
		final src: String = 'class C {\n\tpublic function keep() {}\n\t#if debug\n\tprivate var _dead:Int = 5;\n\t#end\n}';
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
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate function foo() {}\n\t#if debug\n\tpublic function dbg() { trace(1); }\n\t#end\n}';
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
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate function foo() {}\n\t#if debug\n\tpublic function dbg() { trace(1); }\n\t#end\n}';
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
		final src: String = 'class DashLineUtil {\n\tpublic static var gap:Float = 4;\n\tprivate static var thickness:Float = 2;\n\tpublic static function draw() { thickness += gap; }\n\tprivate function new() {}\n}';
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
		final src: String = 'class U {\n\tpublic static function draw() { dbg(); }\n\tprivate function new() {}\n\t#if debug\n\tstatic function dbg() { trace(1); }\n\t#end\n}';
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


	public function testModuleInitMagicMethodNotFlagged(): Void {
		Assert.equals(0, one('class C {\n\tprivate static function __init__():Void {\n\t\ttrace(1);\n\t}\n}').length);
	}

}
