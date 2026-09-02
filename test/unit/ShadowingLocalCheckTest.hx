package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.ShadowingLocal;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `shadowing-local` check: a local declaration whose name an enclosing frame already binds.
 *
 * The positive fixtures cover each frame a binding can come from — an enclosing block, a `switch`
 * arm's enclosing block, the same statement list (a redeclaration), a parameter, and a local
 * function's body over its host's local. The negative ones are the discriminators: two SIBLING
 * `switch` arms and two sibling blocks each declaring the same name are mutually invisible, and a
 * subtree scan of the enclosing function — the shape `CasePatternScan.declaresBefore` uses, which
 * is why this check does not reuse it — would report both. A local sharing its name with a FIELD
 * is the ordinary Haxe idiom and is not a finding; neither is a declaration inside a
 * conditional-compilation region, whose arms are mutually exclusive.
 */
class ShadowingLocalCheckTest extends Test {

	public function testEnclosingBlockLocalFlagged(): Void {
		Assert.equals(1, violations('class C { function f() { var q:Int = 1; { var q:Int = 2; } } }').length);
	}

	public function testSwitchArmOverEnclosingLocalFlagged(): Void {
		Assert.equals(1, violations('class C { function f(v:Int) { var q:Int = 0; switch v { case 1: var q:Int = 1; } } }').length);
	}

	public function testSameBlockRedeclarationFlagged(): Void {
		Assert.equals(1, violations('class C { function f() { var q:Int = 1; var q:Int = 2; } }').length);
	}

	public function testParameterFlagged(): Void {
		final found: Array<Violation> = violations('class C { function f(q:Int) { var q:Int = 1; } }');
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('parameter') != -1, 'expected a parameter finding, got: ${found[0].message}');
	}

	public function testLocalFunctionBodyOverHostLocalFlagged(): Void {
		Assert.equals(1, violations('class C { function f() { var q:Int = 1; function g() { var q:Int = 2; } } }').length);
	}

	/**
	 * A `for` iterator binds into the frame it OPENS, so the name sits in the `ForStmt`s own slot
	 * and never among its children — which the direct-children walk could not see. With no outer
	 * binding at all this was silence, not a wrong message: the shadow went entirely unreported.
	 */
	public function testLoopIteratorShadowFlagged(): Void {
		final found: Array<Violation> = violations('class C { function f(xs:Array<Int>) { for (q in xs) { var q:Int = 1; trace(q); } } }');
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('loop iterator') != -1, 'expected a loop-iterator finding, got: ${found[0].message}');
	}

	/** The same for a catch clause, the other self-scoped binder. */
	public function testCatchBinderShadowFlagged(): Void {
		final found: Array<Violation> = violations(
			'class C { function f() { try { g(); } catch (e:String) { var e:Int = 1; trace(e); } } function g() {} }'
		);
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('catch binding') != -1, 'expected a catch-binding finding, got: ${found[0].message}');
	}

	/**
	 * With an outer local of the same name the finding was already reported — it named the WRONG
	 * binding. The iterator is the one in effect where the declaration sits, and it is nearer, so
	 * the walk must reach it first. This is the shape T95 measured: 9 haxelib findings gated on
	 * binding identity, 8 of them this misattribution.
	 */
	public function testLoopIteratorOutranksTheOuterLocalItAlsoHides(): Void {
		final found: Array<Violation> = violations(
			'class C { function f(xs:Array<Int>) { var q:Int = 1; for (q in xs) { var q:Int = 2; trace(q); } trace(q); } }'
		);
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('loop iterator') != -1, 'the nearer binding names the finding, got: ${found[0].message}');
	}

	/**
	 * One construct held both answers: `for (k => v in m)` puts the VALUE binder in a child node
	 * and the KEY binder in the frame's own name slot, so `var v` was reported (as a `local`) and
	 * `var k` was not reported at all. Both are loop binders and both now say so.
	 */
	public function testBothLoopBindersOfAKeyValueLoopAreFound(): Void {
		final found: Array<Violation> = violations(
			'class C { function f(m:Map<String,Int>) { for (k => v in m) { var k:Int = 1; var v:Int = 2; trace(k + v); } } }'
		);
		Assert.equals(2, found.length);
		for (v in found) Assert.isTrue(v.message.indexOf('loop iterator') != -1, 'both binders answer alike, got: ${v.message}');
	}

	/**
	 * The binder covers the BODY, not the header — `for (i in 0...i)` iterates the OUTER `i`,
	 * measured against the compiler, and `RefactorSupport.selfScopeBinderFloor` is the seam the
	 * resolver builds its own scope frame from. A declaration in the ITERABLE is outside it.
	 */
	public function testLoopBinderIsNotInScopeInItsOwnHeader(): Void {
		Assert.equals(0, violations('class C { function f() { for (q in { var q:Int = 1; [q]; }) trace(q); } }').length);
	}

	/** …and the floor is inclusive: a brace-less body IS the declaration, and IS inside the binding. */
	public function testBracelessLoopBodyIsInsideTheBinding(): Void {
		Assert.equals(1, violations('class C { function f(xs:Array<Int>) { for (q in xs) var q:Int = 1; } }').length);
	}

	public function testFinalDeclarationFlagged(): Void {
		Assert.equals(1, violations('class C { function f() { final q:Int = 1; { final q:Int = 2; } } }').length);
	}

	public function testSeverityIsWarning(): Void {
		Assert.equals(Severity.Warning, violations('class C { function f() { var q:Int = 1; var q:Int = 2; } }')[0].severity);
	}

	public function testSiblingSwitchArmsNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(v:Int) { switch v { case 1: var q:Int = 1; case 2: var q:Int = 2; } } }').length);
	}

	public function testSiblingBlocksNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { { var q:Int = 1; } { var q:Int = 2; } } }').length);
	}

	public function testFieldNotFlagged(): Void {
		Assert.equals(0, violations('class C { var q:Int = 0; function f() { var q:Int = 1; } }').length);
	}

	public function testSiblingMethodsNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { var q:Int = 1; } function g() { var q:Int = 2; } }').length);
	}

	public function testConditionalRegionNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { var q:Int = 1; #if debug var q:Int = 2; #end } }').length);
	}

	public function testNullSafetyRebindNotFlagged(): Void {
		// The narrowing re-bind the language's own null-safety guidance prescribes.
		Assert.equals(0, violations('class Foo {} class C { function f(v:Null<Foo>) { if (v == null) return; final v:Foo = v; } }').length);
	}

	public function testNormalisingRebindNotFlagged(): Void {
		// A parameter re-derived once under its own name — Haxe has no `final` parameter to assign into.
		Assert.equals(0, violations('class C { function f(p:String) { final p:String = p.substr(1); } }').length);
	}

	public function testRebindGateNeedsTheSameName(): Void {
		// The gate is a read of the SHADOWED name, not any read at all.
		Assert.equals(1, violations('class C { function f(p:String, o:String) { final p:String = o.substr(1); } }').length);
	}

	public function testRebindGateIgnoresNestedLambdaBinding(): Void {
		// The read is the LAMBDA's own `q`, a third declaration — not the shadowed local.
		Assert.equals(
			1,
			violations('class C { function f(xs:Array<Int>) { var q:Int = 0; { final q:Null<Int> = xs.filter(q -> q > 0)[0]; } } }').length
		);
	}

	public function testRebindGateRejectsContinuationOfOwnDeclaration(): Void {
		// `var q = 2, r = q;` — the continuation reads the SECOND binding (verified: `r` is 2), not
		// the shadowed one, so nothing the statement hides is consumed. An identifier walk over the
		// whole declaration subtree counts it and suppresses a genuine shadow.
		Assert.equals(1, violations('class C { function f() { var q:Int = 1; var q:Int = 2, r:Int = q; } }').length);
	}

	public function testRebindGateRejectsReadOfNestedDeclaration(): Void {
		// The only same-named read sits in a nested declaration inside the initializer and binds to IT,
		// so the outer parameter is hidden by accident after all. BOTH declarations shadow it; an
		// identifier walk over the whole subtree counts that read and reports only the inner one.
		Assert.equals(
			2, violations('class C { function f(q:Int, v:Int) { var q:Int = switch v { case 1: var q:Int = 2; q; case _: 0; }; } }').length
		);
	}

	public function testRebindGateSeesInterpolationRead(): Void {
		// A braceless `$q` binds like a bare identifier; `RefShape.identKind` does not name it, so an
		// identifier walk misses the read and reports a deliberate re-bind.
		Assert.equals(0, violations("class C { function f() { var q:Int = 1; var q:String = '$q!'; } }").length);
	}

	public function testRebindGateAcceptsShadowedLoopIterator(): Void {
		// `for (q in xs) { var q = h(q); }` — the read binds to the ITERATOR, which the declaration
		// also hides. When T95 wrote this the enclosing-frame walk NAMED the outer `q` instead, so
		// gating on that identity would have reported a declaration that consumes what it hides;
		// `bindsItself` has since closed that gap and the walk names the iterator. What the gate
		// asks is unchanged, and so is the answer: a containment test, not an identity one. Unlike
		// its three neighbours this one does NOT flip when the gate is reverted — the identifier
		// walk is silent here too, for its own reason.
		Assert.equals(
			0,
			violations(
				'class C { function h(v:Int):Int return v; function f(xs:Array<Int>) { var q:Int = 1; for (q in xs) {'
				+ ' var q:Int = h(q); } } }'
			).length
		);
	}

	public function testDistinctNamesNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { var q:Int = 1; { var r:Int = 2; } } }').length);
	}

	public function testReportOnly(): Void {
		final src: String = 'class C { function f() { var q:Int = 1; var q:Int = 2; } }';
		final check: ShadowingLocal = new ShadowingLocal();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('shadowing-local'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('shadowing-local'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new ShadowingLocal().run([{ file: 'Bad.hx', source: 'class Bad { function f() { var q:Int = ' }], new HaxeQueryPlugin()).length
		);
	}

	public function testRebindGateTreatsEverySpellingOfANestedFunctionAlike(): Void {
		// The re-bind gate does not count a read of the shadowed name that sits inside a NESTED
		// FUNCTION — that region is the one the resolver is not trusted in. Which spellings count as
		// one used to be a hand union of `functionKinds` + `lambdaKinds`, and neither names the
		// NAMED function literal: the identical re-declaration was therefore REPORTED when its
		// initializer read the outer name through `v -> …` and SILENT when it read it through
		// `function nm(v) …`. Both spellings, one assertion, so neither half can drift alone.
		final arrow: String = 'class C { static function p(f:Int -> Int):Int return f(1);'
			+ ' static function r():Void { var q = 0; var q = p(v -> q + v); trace(q); } }';
		final named: String = 'class C { static function p(f:Int -> Int):Int return f(1);'
			+ ' static function r():Void { var q = 0; var q = p(function nm(v) return q + v); trace(q); } }';
		Assert.equals(1, violations(arrow).length, 'the bare-arrow spelling must be reported');
		Assert.equals(1, violations(named).length, 'the named-function spelling must be reported the same way');
		// The control: the same re-declaration reading the outer name DIRECTLY is a deliberate
		// re-bind and stays unreported, so the pair above is not just "this check reports
		// everything".
		Assert.equals(0, violations('class C { static function r():Void { var q = 0; var q = q + 1; trace(q); } }').length);
	}

	private function violations(src: String): Array<Violation> {
		return new ShadowingLocal().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
