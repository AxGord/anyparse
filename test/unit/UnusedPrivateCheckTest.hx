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

/**
 * The `unused-private` check: a `private` field / method with no reference in
 * its (confined) declaring file is flagged; referenced, public, implicitly-
 * reachable (constructor / accessor / annotated), and cross-file-reachable
 * (subtype / @:access / @:allow / skip-parse) members are not. The autofix
 * deletes a dead method or side-effect-free field and keeps a side-effecting one.
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

	public function testSubtypeKeepsMember(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: 'package pkg;\nclass C {\n\tprivate var _x:Int;\n}' },
			{ file: 'pkg/D.hx', source: 'package pkg;\nclass D extends C {}' }
		];
		Assert.equals(0, violations(files).filter(v -> v.file == 'pkg/C.hx').length);
	}

	public function testAccessGrantKeepsMember(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: 'package pkg;\nclass C {\n\tprivate var _x:Int;\n}' },
			{ file: 'pkg/E.hx', source: 'package pkg;\n@:access(pkg.C)\nclass E {}' }
		];
		Assert.equals(0, violations(files).filter(v -> v.file == 'pkg/C.hx').length);
	}

	public function testAllowKeepsMember(): Void {
		Assert.equals(0, one('package pkg;\n@:allow(pkg.X)\nclass C {\n\tprivate var _x:Int;\n}').length);
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


	public function testOpAnnotatedMemberNotFlagged(): Void {
		// An `@:op(A < B)` operator overload is invoked via the operator, never by name,
		// and projects as a `MetaCall` (argumented meta) sibling — the annotated-member skip
		// must recognize `MetaCall`, not only a bare `Meta`, else the operator method is a
		// false unused-private (surfaced by MemberRank's `@:op` in the member-order check).
		final src: String = 'enum abstract R(Int) {\n\tfinal A = 0;\n\tfinal B = 1;\n\t@:op(A < B) static function lt(a:R, b:R):Bool;\n}';
		Assert.equals(0, one(src).length);
	}

}
