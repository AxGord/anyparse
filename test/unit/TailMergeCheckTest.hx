package unit;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.TailMerge;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `tail-merge` check: a branch of an `if` chain whose trailing statements
 * repeat the ENTIRE run that follows the chain is flagged `Info`, and `fix`
 * deletes that trailing run so control falls through onto the shared copy.
 * The gates covered here: the tail must be terminal (`return` / `throw`, never
 * `break` / `continue`), must cover the whole fall run, must leave a non-empty
 * branch remainder, must carry no conditional compilation and no branch-local
 * shadowing, and — for the FIX only — no unmatched or stranded comment.
 */
class TailMergeCheckTest extends Test {

	/** The reference shape: two inner branches whose tails repeat the run after the outer `if`. */
	private static final REFERENCE_SHAPE: String = 'class C {\n\tfunction set_p(v:String):String {\n\t\tif (cond1) {\n\t\t\tif (c2) {\n'
		+ '\t\t\t\twork();\n\t\t\t\thelper(v);\n\t\t\t\treturn v;\n\t\t\t} else if (c3) {\n'
		+ '\t\t\t\twork2();\n\t\t\t\thelper(v);\n\t\t\t\treturn v;\n\t\t\t}\n\t\t}\n\t\thelper(v);\n' + '\t\treturn v;\n\t}\n}';

	public function testReferenceShapeFlagsBothBranches(): Void {
		final vs: Array<Violation> = violations(REFERENCE_SHAPE);
		Assert.equals(2, vs.length);
		Assert.equals('tail-merge', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('these 2 statements repeat the tail that follows the if — drop them and fall through', vs[0].message);
		Assert.equals('these 2 statements repeat the tail that follows the if — drop them and fall through', vs[1].message);
	}

	public function testFixRemovesTailFromBothBranches(): Void {
		final es: Array<{ span: Span, text: String }> = edits(REFERENCE_SHAPE);
		Assert.equals(2, es.length);
		Assert.equals('', es[0].text);
		Assert.equals('', es[1].text);
		final result: String = RefactorSupport.applyEdits(REFERENCE_SHAPE, es);
		Assert.equals(
			'class C {\n\tfunction set_p(v:String):String {\n\t\tif (cond1) {\n\t\t\tif (c2) {\n\t\t\t\twork();\n\t\t\t} else if (c3) {\n'
			+ '\t\t\t\twork2();\n\t\t\t}\n\t\t}\n\t\thelper(v);\n\t\treturn v;\n\t}\n}',
			result
		);
		Assert.notNull(CheckScan.parseOrNull(new HaxeQueryPlugin(), result));
	}

	public function testSingleBranchIfFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\twork();\n\t\t\thelper(v);\n\t\t\treturn v;\n'
			+ '\t\t}\n\t\thelper(v);\n\t\treturn v;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(1, edits(src).length);
	}

	public function testPlainElseBranchFlagged(): Void {
		Assert.equals(
			2,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tif (a) {\n\t\t\tp();\n\t\t\tt();\n\t\t\treturn;\n\t\t} else {\n\t\t\tq();\n'
				+ '\t\t\tt();\n\t\t\treturn;\n\t\t}\n\t\tt();\n\t\treturn;\n\t}\n}'
			).length
		);
	}

	public function testNonTerminalTailNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String):Void {\n\t\tif (b) {\n\t\t\twork();\n\t\t\thelper(v);\n\t\t\tmore();\n\t\t}\n'
				+ '\t\thelper(v);\n\t\tmore();\n\t}\n}'
			).length
		);
	}

	public function testBreakTailNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\twhile (c) {\n\t\t\tif (b) {\n\t\t\t\twork();\n\t\t\t\thelper();\n\t\t\t\tbreak;\n'
				+ '\t\t\t}\n\t\t\thelper();\n\t\t\tbreak;\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testStatementBetweenBranchAndTailNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String):String {\n\t\tif (a) {\n\t\t\tif (b) {\n\t\t\t\twork();\n\t\t\t\thelper(v);\n'
				+ '\t\t\t\treturn v;\n\t\t\t}\n\t\t\tmore();\n\t\t}\n\t\thelper(v);\n\t\treturn v;\n\t}\n}'
			).length
		);
	}

	public function testPartialSuffixNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\tp();\n\t\t\tr();\n\t\t\treturn v;\n\t\t}\n\t\tq();\n'
				+ '\t\tr();\n\t\treturn v;\n\t}\n}'
			).length
		);
	}

	public function testWholeBranchIsTailNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\thelper(v);\n\t\t\treturn v;\n\t\t}\n\t\thelper(v);\n'
				+ '\t\treturn v;\n\t}\n}'
			).length
		);
	}

	public function testDifferentArgumentNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String, w:String):String {\n\t\tif (b) {\n\t\t\twork();\n\t\t\thelper(w);\n\t\t\treturn v;\n'
				+ '\t\t}\n\t\thelper(v);\n\t\treturn v;\n\t}\n}'
			).length
		);
	}

	public function testConditionalCompilationNotFlagged(): Void {
		// The two `helper(...)` statements are token-identical, so the identity gate
		// passes; the `#if` / `#else` / `#end` in the removed region is what refuses.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\twork();\n\t\t\thelper(#if debug v #else null #end);\n'
				+ '\t\t\treturn v;\n\t\t}\n\t\thelper(#if debug v #else null #end);\n\t\treturn v;\n\t}\n}'
			).length
		);
	}

	public function testLoopBodyNotFlagged(): Void {
		// The tail follows the LOOP, not the `if` chain — the branch runs again.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String):Void {\n\t\twhile (c) {\n\t\t\tif (b) {\n\t\t\t\twork();\n\t\t\t\thelper(v);\n'
				+ '\t\t\t\treturn;\n\t\t\t}\n\t\t}\n\t\thelper(v);\n\t\treturn;\n\t}\n}'
			).length
		);
	}

	public function testSwitchCaseOutOfScope(): Void {
		// The `if` sits INSIDE a case body, so the fall reset at the switch is the only
		// thing standing between its branch and the run after the whole switch.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String):String {\n\t\tswitch (k) {\n\t\t\tcase 1:\n\t\t\t\tif (b) {\n\t\t\t\t\twork();\n'
				+ '\t\t\t\t\thelper(v);\n\t\t\t\t\treturn v;\n\t\t\t\t}\n\t\t\tcase _:\n\t\t\t\twork2();\n\t\t}\n\t\thelper(v);\n'
				+ '\t\treturn v;\n\t}\n}'
			).length
		);
	}

	public function testMacroReificationNotFlagged(): Void {
		// A reified block's statements may be spliced into a scope this walk never sees.
		Assert.equals(
			0,
			violations(
				'class C {\n\tmacro static function m(v:String):String {\n\t\treturn macro {\n\t\t\tif (b) {\n\t\t\t\twork();\n'
				+ '\t\t\t\thelper(v);\n\t\t\t\treturn v;\n\t\t\t}\n\t\t\thelper(v);\n\t\t\treturn v;\n\t\t};\n\t}\n}'
			).length
		);
	}

	public function testStructuralIdentityHalfNeeded(): Void {
		// `normalizeSpan` collapses the whitespace INSIDE the string literal, so only
		// `structurallyEqual` tells `helper("a  b")` from `helper("a b")`.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\twork();\n\t\t\thelper("a  b");\n\t\t\treturn v;\n\t\t}\n'
				+ '\t\thelper("a b");\n\t\treturn v;\n\t}\n}'
			).length
		);
	}

	public function testNormalizedSourceHalfNeeded(): Void {
		// The projected trees are identical — only the normalized source sees the comment
		// sitting INSIDE the statement span.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\twork();\n\t\t\thelper(v /* alpha */);\n\t\t\treturn v;\n'
				+ '\t\t}\n\t\thelper(v /* beta */);\n\t\treturn v;\n\t}\n}'
			).length
		);
	}

	public function testThrowTailFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\twork();\n\t\t\thelper(v);\n\t\t\tthrow "e";\n\t\t}\n'
				+ '\t\thelper(v);\n\t\tthrow "e";\n\t}\n}'
			).length
		);
	}

	public function testVoidReturnTailFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f(v:String):Void {\n\t\tif (b) {\n\t\t\twork();\n\t\t\thelper(v);\n\t\t\treturn;\n\t\t}\n'
				+ '\t\thelper(v);\n\t\treturn;\n\t}\n}'
			).length
		);
	}

	public function testThreeArmChainFlagsAllArms(): Void {
		Assert.equals(
			3,
			violations(
				'class C {\n\tfunction f(v:String):String {\n\t\tif (a) {\n\t\t\tp();\n\t\t\thelper(v);\n\t\t\treturn v;\n'
				+ '\t\t} else if (b) {\n\t\t\tq();\n\t\t\thelper(v);\n\t\t\treturn v;\n\t\t} else {\n\t\t\tr();\n\t\t\thelper(v);\n'
				+ '\t\t\treturn v;\n\t\t}\n\t\thelper(v);\n\t\treturn v;\n\t}\n}'
			).length
		);
	}

	public function testBraceLessOuterBranchFlagged(): Void {
		// The inner `if` is the un-braced body of the outer one, so it forwards the outer's
		// fall unchanged — falling out of the inner branch does reach the shared run.
		final src: String = 'class C {\n\tfunction f(v:String):String {\n\t\tif (a)\n\t\t\tif (b) {\n\t\t\t\twork();\n\t\t\t\thelper(v);\n'
			+ '\t\t\t\treturn v;\n\t\t\t}\n\t\thelper(v);\n\t\treturn v;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(
			'class C {\n\tfunction f(v:String):String {\n\t\tif (a)\n\t\t\tif (b) {\n\t\t\t\twork();\n\t\t\t}\n\t\thelper(v);\n'
			+ '\t\treturn v;\n\t}\n}',
			RefactorSupport.applyEdits(src, edits(src))
		);
	}

	public function testTwoLevelInheritedFallBothFixed(): Void {
		// The inner branch's fall is the outer block's own trailing run; the outer branch's
		// fall is inherited from the function body. Both edits apply in ONE pass.
		final src: String = 'class C {\n\tfunction f(v:String):String {\n\t\tif (a) {\n\t\t\tif (b) {\n\t\t\t\tp();\n\t\t\t\thelper(v);\n'
			+ '\t\t\t\treturn v;\n\t\t\t}\n\t\t\thelper(v);\n\t\t\treturn v;\n\t\t}\n\t\thelper(v);\n\t\treturn v;\n\t}\n}';
		Assert.equals(2, violations(src).length);
		Assert.equals(
			'class C {\n\tfunction f(v:String):String {\n\t\tif (a) {\n\t\t\tif (b) {\n\t\t\t\tp();\n\t\t\t}\n\t\t}\n\t\thelper(v);\n'
			+ '\t\treturn v;\n\t}\n}',
			RefactorSupport.applyEdits(src, edits(src))
		);
	}

	public function testFixIsIdempotent(): Void {
		final once: String = RefactorSupport.applyEdits(REFERENCE_SHAPE, edits(REFERENCE_SHAPE));
		Assert.equals(0, violations(once).length);
		Assert.equals(0, edits(once).length);
	}

	public function testShadowedLocalNotFlagged(): Void {
		// The branch tail reads the branch-local `t`, the shared copy the parameter `t`.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(t:String):String {\n\t\tif (b) {\n\t\t\tvar t = c();\n\t\t\thelper(t);\n\t\t\treturn t;\n\t\t}\n'
				+ '\t\thelper(t);\n\t\treturn t;\n\t}\n}'
			).length
		);
	}

	public function testShadowedLocalFunctionNotFlagged(): Void {
		// The branch tail calls the branch-LOCAL `helper`, the shared copy the member one.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(t:String):String {\n\t\tif (b) {\n\t\t\tfunction helper(x:String):String return x;\n'
				+ '\t\t\thelper(t);\n\t\t\treturn t;\n\t\t}\n\t\thelper(t);\n\t\treturn t;\n\t}\n}'
			).length
		);
	}

	public function testShadowedInlineLocalFunctionNotFlagged(): Void {
		// `inline function` is a distinct kind from a plain local function; it shadows too.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(t:String):String {\n\t\tif (b) {\n\t\t\tinline function helper(x:String):String return x;\n'
				+ '\t\t\thelper(t);\n\t\t\treturn t;\n\t\t}\n\t\thelper(t);\n\t\treturn t;\n\t}\n}'
			).length
		);
	}

	public function testMetaWrappedDeclarationNotFlagged(): Void {
		// `@:meta var t = …` is an expression statement around a `VarExpr`, not a `VarStmt`
		// — the declaration must still be seen through its metadata wrapper.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String, t:String):String {\n\t\tif (b) {\n\t\t\t@:nullSafety(Off) var t = v;\n'
				+ '\t\t\thelper(t);\n\t\t\treturn t;\n\t\t}\n\t\thelper(t);\n\t\treturn t;\n\t}\n}'
			).length
		);
	}

	public function testMultiDeclaratorLocalNotFlagged(): Void {
		// `var p = 1, t = v;` binds `t` too, but the projection names only `p` — the
		// shadowing gate would be blind, so the unenumerable declaration refuses outright.
		// Caught by the second-initializer tell (two children).
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String, t:String):String {\n\t\tif (b) {\n\t\t\tvar p = 1, t = v;\n\t\t\thelper(t);\n'
				+ '\t\t\treturn t;\n\t\t}\n\t\thelper(t);\n\t\treturn t;\n\t}\n}'
			).length
		);
	}

	public function testTypeAnnotatedMultiDeclaratorNotFlagged(): Void {
		// `var p:Int, t = v;` has ONE initializer, so only the declarator-separating comma
		// in the text before it tells the two declarations apart.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String, t:String):String {\n\t\tif (b) {\n\t\t\tvar p:Int, t = v;\n\t\t\thelper(t);\n'
				+ '\t\t\treturn t;\n\t\t}\n\t\thelper(t);\n\t\treturn t;\n\t}\n}'
			).length
		);
	}

	public function testUninitializedTrailingDeclaratorNotFlagged(): Void {
		// `var p = 1, t;` puts the separating comma AFTER the only initializer.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String, t:String):String {\n\t\tif (b) {\n\t\t\tvar p = 1, t;\n\t\t\tt = v;\n'
				+ '\t\t\thelper(t);\n\t\t\treturn t;\n\t\t}\n\t\thelper(t);\n\t\treturn t;\n\t}\n}'
			).length
		);
	}

	public function testUninitializedMultiDeclaratorNotFlagged(): Void {
		// `var p:Int, t:String;` has NO initializer at all — the whole statement is scanned.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(v:String, t:String):String {\n\t\tif (b) {\n\t\t\tvar p:Int, t:String;\n\t\t\tt = v;\n'
				+ '\t\t\thelper(t);\n\t\t\treturn t;\n\t\t}\n\t\thelper(t);\n\t\treturn t;\n\t}\n}'
			).length
		);
	}

	public function testFunctionTypeDeclStillFlagged(): Void {
		// The `>` of an `Int -> Int` type must not push the depth below zero and hide a
		// later comma — and on its own it is no declarator separator, so this stays in scope.
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\tvar g:Int -> Int = x -> x;\n\t\t\thelper(v);\n'
				+ '\t\t\treturn v;\n\t\t}\n\t\thelper(v);\n\t\treturn v;\n\t}\n}'
			).length
		);
	}

	public function testCommaInTypeOrCallDeclStillFlagged(): Void {
		// A comma inside a generic type or a call initializer is not a second declarator —
		// the head scan stops at the first `:` / `=`, so these stay in scope.
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\tvar m:Map<String, Int> = g(a, b);\n\t\t\thelper(v);\n'
				+ '\t\t\treturn v;\n\t\t}\n\t\thelper(v);\n\t\treturn v;\n\t}\n}'
			).length
		);
	}

	public function testTailOwnDeclarationStillFlagged(): Void {
		// The duplicated tail declares `q` itself and the shared copy declares it too, so
		// falling through re-binds it identically — the tail's own locals are not shadowing.
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\twork();\n\t\t\tvar q = h(v);\n\t\t\treturn q;\n\t\t}\n'
				+ '\t\tvar q = h(v);\n\t\treturn q;\n\t}\n}'
			).length
		);
	}

	public function testUnmatchedCommentReportOnlyNoFix(): Void {
		final src: String = 'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\twork();\n\t\t\t// cleanup\n\t\t\thelper(v);\n'
			+ '\t\t\treturn v;\n\t\t}\n\t\thelper(v);\n\t\treturn v;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testMatchedCommentFixApplies(): Void {
		final src: String = 'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\twork();\n\t\t\t// cleanup\n\t\t\thelper(v);\n'
			+ '\t\t\treturn v;\n\t\t}\n\t\t// cleanup\n\t\thelper(v);\n\t\treturn v;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(1, edits(src).length);
	}

	public function testTrailingCommentAfterTailReportOnly(): Void {
		final src: String = 'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\twork();\n\t\t\thelper(v);\n'
			+ '\t\t\treturn v; // done\n\t\t}\n\t\thelper(v);\n\t\treturn v;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testLongestSuffixMatched(): Void {
		final src: String = 'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\tp();\n\t\t\tq();\n\t\t\tr();\n'
			+ '\t\t\treturn v;\n\t\t}\n\t\tq();\n\t\tr();\n\t\treturn v;\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('these 3 statements repeat the tail that follows the if — drop them and fall through', vs[0].message);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals(
			'class C {\n\tfunction f(v:String):String {\n\t\tif (b) {\n\t\t\tp();\n\t\t}\n\t\tq();\n\t\tr();\n\t\treturn v;\n\t}\n}',
			RefactorSupport.applyEdits(src, es)
		);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('tail-merge'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('tail-merge'));
	}

	private static function violations(src: String): Array<Violation> {
		return new TailMerge().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private static function edits(src: String): Array<{ span: Span, text: String }> {
		final check: TailMerge = new TailMerge();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
