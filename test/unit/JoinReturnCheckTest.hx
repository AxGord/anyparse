package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.JoinReturn;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `join-return` check: a local declaration whose value is IMMEDIATELY returned is flagged
 * `Info`, and `fix` collapses the pair to a single `return`. An unannotated decl always
 * collapses to `return e;`; an annotated decl keeps its annotation as a type-check ascription
 * `return (e : T);` UNLESS the enclosing function's explicit return type already equals it
 * (then plain `return e;`). A non-adjacent return, a return of a different name or of an
 * expression, a bare `return;`, a local used elsewhere, a multi-declarator and a comment in a
 * dropped region are all safe misses.
 */
class JoinReturnCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('final x = g();\n\t\treturn x;'));
		Assert.equals(1, vs.length);
		Assert.equals('join-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this declaration and its next-line return can be joined into a single return', vs[0].message);
	}

	/** An unannotated declaration collapses to a plain `return e;`. */
	public function testFixUnannotated(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final x = g();\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return g();', es[0].text);
	}

	/** A `var` local collapses just like a `final`. */
	public function testFixVar(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('var x = g();\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return g();', es[0].text);
	}

	/**
	 * An annotated decl in a function with NO explicit return type keeps its annotation as an
	 * ascription -- the annotation can be load-bearing (an implicit `@:from` conversion).
	 */
	public function testAnnotatedInferredReturnAscribes(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final x:Int = g();\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return (g() : Int);', es[0].text);
	}

	/** When the function's explicit return type equals the annotation, the conversion happens at the boundary -- plain `return e;`. */
	public function testAnnotatedEqualReturnTypeCollapsesPlain(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrapRet('Int', 'final x:Int = g();\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return g();', es[0].text);
	}

	/** A differing explicit return type does not re-state the annotation, so it survives as an ascription. */
	public function testAnnotatedDifferingReturnTypeAscribes(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrapRet('String', 'final x:Int = g();\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return (g() : Int);', es[0].text);
	}

	/** The load-bearing case (mirrors `types.Color`): a qualified annotation driving an implicit `@:from` is preserved. */
	public function testQualifiedAnnotationAscribed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final color:types.Color = str;\n\t\treturn color;'));
		Assert.equals(1, es.length);
		Assert.equals('return (str : types.Color);', es[0].text);
	}

	// --- `new T(...)`-matches-annotation ascription skip ---

	/**
	 * A constructor call whose class name matches the annotation, under a DIFFERING explicit
	 * return type, needs no ascription: `new Row(a, b)` already fixes its own type, so the
	 * dropped `Row` annotation has nothing left to pin.
	 */
	public function testFixNewMatchingAnnotationDropsAscription(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrapRet('Null<DisplayObject>', 'final customLabel:Row = new Row(a, b);\n\t\treturn customLabel;')
		);
		Assert.equals(1, es.length);
		Assert.equals('return new Row(a, b);', es[0].text);
	}

	/** A generic annotation still ascribes even when the initializer is a matching `new` call -- its type parameters pin `new Map()`'s otherwise inference-open key/value types. */
	public function testFixNewGenericAnnotationKeepsAscription(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final m:Map<String,Int> = new Map();\n\t\treturn m;'));
		Assert.equals(1, es.length);
		Assert.equals('return (new Map() : Map<String,Int>);', es[0].text);
	}

	/** A non-`new` initializer keeps its ascription even when it happens to share the annotation's name (e.g. a factory function) -- only a literal constructor call is exempted. */
	public function testFixNonNewInitializerKeepsAscription(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrapRet('Null<DisplayObject>', 'final row:Row = makeRow();\n\t\treturn row;'));
		Assert.equals(1, es.length);
		Assert.equals('return (makeRow() : Row);', es[0].text);
	}

	/** The assignment arm gets the same skip: `row = new Row(a, row); return row;` needs no ascription for the param's `Row` type. */
	public function testAssignFixNewMatchingAnnotationDropsAscription(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(row:Row):Null<DisplayObject> {\n\t\trow = new Row(a, row);\n\t\treturn row;\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return new Row(a, row);', es[0].text);
	}

	/** A statement between the declaration and the return blocks the join (only the immediate next return qualifies). */
	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final x = g();\n\t\tside();\n\t\treturn x;')).length);
	}

	public function testReturnDifferentNameNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final x = g();\n\t\treturn y;')).length);
	}

	/** The return must be exactly the bare identifier, not an expression using it. */
	public function testReturnExpressionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final x = g();\n\t\treturn x + 1;')).length);
	}

	/** A bare `return;` is a distinct node kind and never joins. */
	public function testBareReturnNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final x = g();\n\t\treturn;')).length);
	}

	/** The local must be referenced ONLY by the return -- a use in (unreachable) trailing code disqualifies. */
	public function testLocalUsedElsewhereNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final x = g();\n\t\treturn x;\n\t\tafter(x);')).length);
	}

	/** A multi-declarator (`final a = 1, b = 2;`) is never joined. */
	public function testMultiDeclaratorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final a = 1, b = 2;\n\t\treturn a;')).length);
	}

	/** A comma INSIDE a generic type is not a second declarator -- a typed single-var decl still joins (ascribed). */
	public function testTypeCommaStillFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final m:Map<Int, String> = null;\n\t\treturn m;'));
		Assert.equals(1, es.length);
		Assert.equals('return (null : Map<Int, String>);', es[0].text);
	}

	/** A comment between the declaration and the return would be dropped by the join. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final x = g();\n\t\t// note\n\t\treturn x;')).length);
	}

	/** A comment INSIDE the initializer is kept verbatim, so the pair still joins. */
	public function testCommentInInitializerStillFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final x = g(/* k */);\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return g(/* k */);', es[0].text);
	}

	/** End-to-end through the canonical writer: the emitted file holds the single return and no declaration line. */
	public function testFixOutputJoins(): Void {
		final out: String = applyFixOnce(wrap('final x = g();\n\t\treturn x;'));
		Assert.isTrue(out.indexOf('return g();') != -1);
		Assert.equals(-1, out.indexOf('final x = g();'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('join-return'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('join-return'));
	}

	/** Wrap a statement body in a minimal parseable class + method with an inferred return type. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	/** Wrap a statement body in a method with an explicit return type. */
	private function wrapRet(retType: String, body: String): String {
		return 'class C {\n\tfunction f():$retType {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new JoinReturn().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: JoinReturn = new JoinReturn();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer -- the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}


	// --- assignment arm: `x = e; return x;` where `x` is a pre-existing param / local ---

	/** The assignment arm: `str = e;` before `return str;` (param `str`) is flagged Info with the assignment message. */
	public function testAssignParamFlagged(): Void {
		final vs: Array<Violation> = violations(wrapAssignRet('String', 'str = g(str);\n\t\treturn str;'));
		Assert.equals(1, vs.length);
		Assert.equals('join-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this assignment and its next-line return can be joined into a single return', vs[0].message);
	}

	/** Function return type equal to the param type -> plain `return e;`. */
	public function testAssignParamExplicitReturnPlainFix(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrapAssignRet('String', 'str = g(str);\n\t\treturn str;'));
		Assert.equals(1, es.length);
		Assert.equals('return g(str);', es[0].text);
	}

	/** An inferred function return type does not re-state the param type, so it survives as an ascription. */
	public function testAssignParamInferredReturnAscribesFix(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrapAssign('str = g(str);\n\t\treturn str;'));
		Assert.equals(1, es.length);
		Assert.equals('return (g(str) : String);', es[0].text);
	}

	/** A pre-existing (untyped) local joins just like a param -- plain collapse, `x` survives via the r-value read. */
	public function testAssignLocalFix(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('var s = "x";\n\t\ts = g(s);\n\t\treturn s;'));
		Assert.equals(1, es.length);
		Assert.equals('return g(s);', es[0].text);
	}

	/** A bare field write (`field = e; return field;`) must NOT join -- the store is observable on the object. */
	public function testAssignFieldNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tvar field:Int = 0;\n\tfunction m():Int {\n\t\tfield = g();\n\t\treturn field;\n\t}\n}').length
		);
	}

	/** A param / local captured by a lambda anywhere in the function is a conservative escape -- not joined. */
	public function testAssignCapturedByLambdaNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var y = 0;\n\t\tvar cb = () -> y;\n\t\tuse(cb);\n\t\ty = g();\n\t\treturn y;')).length);
	}

	/** A read of `str` after the assignment (even in unreachable trailing code) disqualifies. */
	public function testAssignReadAfterNotFlagged(): Void {
		Assert.equals(0, violations(wrapAssignRet('String', 'str = g(str);\n\t\treturn str;\n\t\tafter(str);')).length);
	}

	/** When `e` does not reference `str` and `str` has no earlier read, the collapse would orphan it -- not joined. */
	public function testAssignNoSurvivingReadNotFlagged(): Void {
		Assert.equals(0, violations(wrapAssignRet('String', 'str = "c";\n\t\treturn str;')).length);
	}

	/** A compound assignment (`+=`) is a distinct node kind and never joins. */
	public function testAssignCompoundNotFlagged(): Void {
		Assert.equals(0, violations(wrapAssignRet('String', 'str += "x";\n\t\treturn str;')).length);
	}

	/** A statement between the assignment and the return blocks the join. */
	public function testAssignNonAdjacentNotFlagged(): Void {
		Assert.equals(0, violations(wrapAssignRet('String', 'str = g(str);\n\t\tside();\n\t\treturn str;')).length);
	}

	/** The return must return exactly the assigned identifier. */
	public function testAssignReturnDifferentNameNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f(str:String, y:String):String {\n\t\tstr = g(str);\n\t\treturn y;\n\t}\n}').length
		);
	}

	/** A comment between the assignment and the return would be dropped by the join. */
	public function testAssignDroppedCommentNotFlagged(): Void {
		Assert.equals(0, violations(wrapAssignRet('String', 'str = g(str);\n\t\t// note\n\t\treturn str;')).length);
	}

	/** End-to-end through the canonical writer: the assignment arm emits the single return and drops the assignment line. */
	public function testAssignFixOutputJoins(): Void {
		final out: String = applyFixOnce(wrapAssignRet('String', 'str = g(str);\n\t\treturn str;'));
		Assert.isTrue(out.indexOf('return g(str);') != -1);
		Assert.equals(-1, out.indexOf('str = g(str);'));
	}

	/** A declaration and its return wholly inside one `#if` branch join — the branch is its own statement list. */
	public function testPairInsideConditionalBranchFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('#if A\n\t\tfinal x = g();\n\t\treturn x;\n\t\t#end'));
		Assert.equals(1, es.length);
		Assert.equals('return g();', es[0].text);
	}

	/** The declaration ends one branch and the return opens the next — not one statement list, no join. */
	public function testPairStraddlingTwoBranchesNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if A\n\t\tfinal x = g();\n\t\t#else\n\t\treturn x;\n\t\t#end')).length);
	}

	// --- conditional-compilation branch scoping ---

	/**
	 * Two sibling `#if` branches, each declaring the SAME name and returning it: BOTH join. The
	 * branches are mutually exclusive, so the declaration in one is not a second reference to the
	 * declaration in the other. Before `Refs` kept a branch-local frame, the enclosing block's
	 * first-wins binding pointed every branch's read at branch 1's declaration, so branch 1 read
	 * as twice-referenced and branch 2 as unreferenced -- and the sole-reference gate silenced
	 * both.
	 */
	public function testSiblingBranchSameNameBothFlagged(): Void {
		Assert.equals(2, violations(wrapRet('Int', branchPair())).length);
	}

	/** Each branch's join is built from its OWN initializer -- the fix must not cross the branch boundary. */
	public function testSiblingBranchSameNameFixTexts(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrapRet('Int', branchPair()));
		Assert.equals(2, es.length);
		Assert.equals('return g();', es[0].text);
		Assert.equals('return h();', es[1].text);
	}

	/** Exclusivity is per branch, not two-way: a third `#elseif` branch reusing the name joins as well. */
	public function testThreeSiblingBranchesSameNameAllFlagged(): Void {
		final body: String =
			'#if A\n\t\tvar x:Int = g();\n\t\treturn x;\n\t\t#elseif B\n\t\tvar x:Int = h();\n\t\treturn x;\n\t\t#else\n\t\tvar x:Int = k();\n\t\treturn x;\n\t\t#end';
		Assert.equals(3, violations(wrapRet('Int', body)).length);
	}

	/**
	 * A REdeclaration inside ONE branch is a genuine same-scope collision and stays vetoed: the
	 * first declaration carries two references and the second none, so neither is sole-referenced.
	 * The branch-local frame must not turn a within-branch shadow into a join.
	 *
	 * CONTROL, not a discrimination: it holds with the branch frame reverted too. It pins that
	 * relaxing the SIBLING-branch case did not relax the same-branch one.
	 */
	public function testSameBranchRedeclarationNotFlagged(): Void {
		final body: String = '#if A\n\t\tvar x:Int = g();\n\t\tuse(x);\n\t\tvar x:Int = h();\n\t\treturn x;\n\t\t#end';
		Assert.equals(0, violations(wrapRet('Int', body)).length);
	}

	/**
	 * A declaration written inside a branch stays visible AFTER `#end` -- the branch frame is a
	 * resolution preference, not a scope. The trailing read is therefore a second reference and
	 * the pair does not join.
	 *
	 * CONTROL, not a discrimination: it holds with the branch frame reverted too. What it guards
	 * is the other direction -- making `CondBranch` a real `scopeKinds` member would stop the
	 * enclosing frame from pre-collecting the branch declaration, `use(x)` would resolve to
	 * nothing, and this pair WOULD join.
	 */
	public function testBranchDeclReadAfterRegionNotFlagged(): Void {
		final body: String = '#if A\n\t\tvar x:Int = g();\n\t\treturn x;\n\t\t#end\n\t\tuse(x);';
		Assert.equals(0, violations(wrapRet('Int', body)).length);
	}

	/**
	 * The name is declared in TWO sibling branches AND read after `#end`. That read refers to
	 * whichever branch the configuration activates, so it references BOTH declarations and neither
	 * is sole-referenced -- joining either one away would leave the read unbound in that branch's
	 * configuration, `--fix` output that does not compile. The branch-local resolution frame is
	 * exact only INSIDE a region; `escapesConditionalRegion` restores the conservative verdict for
	 * exactly this shape.
	 */
	public function testSiblingBranchDeclsReadAfterRegionNotFlagged(): Void {
		final body: String =
			'#if A\n\t\tvar x:Int = g();\n\t\tuse(x);\n\t\t#else\n\t\tvar x:Int = h();\n\t\treturn x;\n\t\t#end\n\t\treturn x;';
		Assert.equals(0, violations(wrapRet('Int', body)).length);
	}

	/** Control for the escape gate: the same two-branch shape with NO reference past `#end` still joins in both branches. */
	public function testSiblingBranchDeclsWithoutEscapeStillFlagged(): Void {
		Assert.equals(2, violations(wrapRet('Int', branchPair())).length);
	}

	// --- the annotation is only dropped when the function return type re-states it ---
	// PINS of the pre-existing `buildReturn` gate, not new behaviour: they pass with the branch
	// slice reverted. They exist because collapsing a `var b:T = cast e; return b;` pair hands the
	// unchecked cast to whatever types the return position, so the "annotation survives unless the
	// return type re-states it" rule is what keeps that retype from changing meaning.

	/**
	 * An UNCHECKED cast initializer under an annotation the function's return type re-states
	 * collapses plainly: the cast is then typed by the return annotation, which is byte-identical
	 * to the dropped one, so the retype is a no-op.
	 */
	public function testCastAnnotationEqualReturnTypeCollapsesPlain(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrapRet('Bytes', 'var b:Bytes = cast x;\n\t\treturn b;'));
		Assert.equals(1, es.length);
		Assert.equals('return cast x;', es[0].text);
	}

	/**
	 * The hazard case: a DIFFERING function return type would retype the unchecked cast, so the
	 * annotation survives as an ascription and the cast keeps its written target type.
	 */
	public function testCastAnnotationDifferingReturnTypeAscribes(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrapRet('Dynamic', 'var b:Bytes = cast x;\n\t\treturn b;'));
		Assert.equals(1, es.length);
		Assert.equals('return (cast x : Bytes);', es[0].text);
	}

	/** An INFERRED function return type states nothing, so an annotated cast keeps its ascription too. */
	public function testCastAnnotationInferredReturnTypeAscribes(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('var b:Bytes = cast x;\n\t\treturn b;'));
		Assert.equals(1, es.length);
		Assert.equals('return (cast x : Bytes);', es[0].text);
	}

	/** Two sibling `#if` branches declaring the same name, each returning it. */
	private inline function branchPair(): String {
		return '#if A\n\t\tvar x:Int = g();\n\t\treturn x;\n\t\t#else\n\t\tfinal x:Int = h();\n\t\treturn x;\n\t\t#end';
	}

	/** Wrap an assignment-arm body in a method with a pre-existing `str` param and an inferred return type. */
	private function wrapAssign(body: String): String {
		return 'class C {\n\tfunction f(str:String) {\n\t\t$body\n\t}\n}';
	}

	/** Wrap an assignment-arm body in a method with a pre-existing `str` param and an explicit return type. */
	private function wrapAssignRet(retType: String, body: String): String {
		return 'class C {\n\tfunction f(str:String):$retType {\n\t\t$body\n\t}\n}';
	}

}
