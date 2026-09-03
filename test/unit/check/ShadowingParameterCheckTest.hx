package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.ShadowingParameter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `shadowing-parameter` check: a nested function's PARAMETER whose name an enclosing frame
 * already binds — the same trap `shadowing-local` names, one spelling over, and silent in every
 * spelling until this rule existed.
 *
 * It shares `ShadowingLocal.collect` — one ancestor-chain walk, one set of gates, one definition
 * of the outer side — so the pins here cover only what differs: which declaration family is
 * reported, and the two false-positive classes the parameter side brings with it.
 *
 * The DECISION, pinned by name: this is a separate rule id and it is `DefaultOff`. Measured on the
 * same two trees before it shipped — the Pony tree, 869 files: `shadowing-local` 29, this 6; this
 * project's `src test`, 1554 files: `shadowing-local` 0, this 0 (44 before the anonymous-structure
 * gate). Both existing bars stay byte-identical, which is the point of the separate id.
 */
class ShadowingParameterCheckTest extends Test {

	public function testBareArrowParameterFlagged(): Void {
		final found: Array<Violation> = violations('class C { function f(a:Array<Int>) { var q:Int = 1; a.map(q -> q + 1); trace(q); } }');
		Assert.equals(1, found.length);
		Assert.equals('shadowing-parameter', found[0].rule);
		Assert.equals(Severity.Warning, found[0].severity);
		Assert.isTrue(found[0].message.indexOf('shadowing parameter') == 0, 'the message must name the INNER binder: ${found[0].message}');
	}

	public function testAnonymousFunctionParameterFlagged(): Void {
		Assert.equals(
			1, violations('class C { function f(a:Array<Int>) { var q:Int = 1; a.map(function(q) return q); trace(q); } }').length
		);
	}

	public function testLocalFunctionParameterFlagged(): Void {
		Assert.equals(1, violations('class C { function f() { var q:Int = 1; function nm(q:Int) return q; trace(q + nm(2)); } }').length);
	}

	/**
	 * The two spellings whose host kind the grammar keeps out of `RefShape.functionKinds` — they
	 * reach the walk through `RefactorSupport.nestedFunctionKinds` like every other function value.
	 */
	public function testInlineLocalAndNamedLiteralParametersFlagged(): Void {
		Assert.equals(
			1, violations('class C { function f() { var q:Int = 1; inline function li(q:Int) return q; trace(q + li(2)); } }').length
		);
		Assert.equals(
			1, violations('class C { function f() { var q:Int = 1; var g = function nn(q:Int) return q; trace(q + g(2)); } }').length
		);
	}

	/** An enclosing PARAMETER is an outer side like any other — the message says which it found. */
	public function testEnclosingParameterIsTheOuterSide(): Void {
		final found: Array<Violation> = violations('class C { function f(q:Int, a:Array<Int>) { a.map(q -> q + 1); } }');
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('already a parameter') != -1, 'expected a parameter outer side: ${found[0].message}');
	}

	/**
	 * An anonymous STRUCTURE type projects its fields with the very kind a parameter uses —
	 * `{ node: Int, width: Int }` is `Anon(Required node …, Required width …)` — so without the
	 * parent-is-a-function gate a return type's field name reads as a binding. This project types
	 * its edit lists as `Array<{ span: Span, text: String }>` and its inputs as
	 * `{ file: String, source: String }`, so that class was ALL 44 of its 44 raw findings.
	 */
	public function testAnonymousStructureFieldIsNotAParameter(): Void {
		Assert.equals(
			0, violations('class C { function f(node:Int):{ node:Int, width:Int } { return { node: node, width: 1 }; } }').length
		);
	}

	/**
	 * A leading `_` is this project's declared-unused marker, exempted by `unused-parameter` on
	 * exactly the same test: a binding the body never reads cannot be mistaken for the one it hides.
	 * It is also what keeps the `_` shadowing `_` pair out — 15 of 22 raw findings on the Pony tree.
	 */
	public function testUnderscoreParameterExempt(): Void {
		Assert.equals(0, violations('class C { function f(_:Int, a:Array<Int>) { a.map(_ -> 1); } }').length);
	}

	/**
	 * A METHOD's own parameters are never findings: the frame walk stops at the first class-like
	 * container, so a parameter sharing its name with a FIELD is the ordinary Haxe idiom — the same
	 * rule, for the same reason, as for a local declaration.
	 */
	public function testMethodParameterOverFieldNotFlagged(): Void {
		Assert.equals(0, violations('class C { var q:Int = 0; function f(q:Int) { trace(q); } }').length);
	}

	/** A local DECLARATION stays `shadowing-local`'s finding — the two families are disjoint. */
	public function testLocalDeclarationNotReportedHere(): Void {
		Assert.equals(0, violations('class C { function f() { var q:Int = 1; { var q:Int = 2; trace(q); } } }').length);
	}

	/**
	 * The DECISION, as a gate rather than as prose: this rule is a registered builtin AND it is off
	 * until a project asks for it. `shadowing-local`'s bar was 29 findings on the Pony tree and 0 on
	 * this project's own sources before this rule shipped, and both stay exactly there because this
	 * half never enters a default report.
	 */
	public function testRegisteredInBuiltinsAndOffByDefault(): Void {
		Assert.notNull(Linter.byId('shadowing-parameter'));
		final src: String = 'class C { function f(a:Array<Int>) { var q:Int = 1; a.map(q -> q + 1); trace(q); } }';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final off: LintConfig = LintConfig.parse('{}');
		Assert.equals(
			0, Linter.run(files, new HaxeQueryPlugin(), null, _ -> off, true).filter(v -> v.rule == 'shadowing-parameter').length,
			'the parameter half is OFF until a project opts in'
		);
		final on: LintConfig = LintConfig.parse('{"rules": {"shadowing-parameter": {"enabled": true}}}');
		Assert.equals(
			1, Linter.run(files, new HaxeQueryPlugin(), null, _ -> on, true).filter(v -> v.rule == 'shadowing-parameter').length,
			'and ON once the project opts in'
		);
	}

	/**
	 * `shadowing-local` must not move when the parameter half is enabled: the two families are
	 * disjoint by construction — one walk, two reported declaration kinds, never both for one node.
	 */
	public function testLocalHalfUnaffectedByTheParameterHalf(): Void {
		final src: String = 'class C { function f(a:Array<Int>) { var q:Int = 1; a.map(q -> q + 1); { var q:Int = 2; trace(q); } } }';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final on: LintConfig = LintConfig.parse('{"rules": {"shadowing-parameter": {"enabled": true}}}');
		final found: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), null, _ -> on, true);
		Assert.equals(1, found.filter(v -> v.rule == 'shadowing-local').length);
		Assert.equals(1, found.filter(v -> v.rule == 'shadowing-parameter').length);
	}

	private function violations(src: String): Array<Violation> {
		return new ShadowingParameter().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
