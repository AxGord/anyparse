package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.JoinReturn;
import anyparse.check.JoinSingleUseLocal;
import anyparse.check.Linter;
import anyparse.check.PreferSafeNav;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `join-single-use-local` check: a single-use `final` local whose initializer is a
 * TRIVIAL PURE READ (a bare identifier or a dotted field-read chain) and whose sole
 * reference sits in the immediately following sibling statement is flagged `Info`, and
 * `fix` drops the declaration line and substitutes the initializer at the read.
 */
class JoinSingleUseLocalCheckTest extends Test {

	/** The count of builtin checks -- bumped by one when a new check is registered. */
	private static inline final BUILTIN_CHECK_COUNT: Int = 152;

	// --- positive: the motivating shape and its fix ---

	/**
	 * The `VideoWatermark` site the rule was written for: an annotated capture of a
	 * `Null<T>` field, read once by a safe-nav call on the next line.
	 */
	public function testMotivatingSiteFlagged(): Void {
		final vs: Array<Violation> = violations(wrapField('final logoBmd:Null<T> = _f;\n\t\tlogoBmd?.dispose();'));
		Assert.equals(1, vs.length);
		Assert.equals('join-single-use-local', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('inlined') != -1, 'unexpected message: ${vs[0].message}');
	}

	public function testFixInlinesIntoNextStatement(): Void {
		final out: String = applyFixOnce(wrapField('final logoBmd:Null<T> = _f;\n\t\tlogoBmd?.dispose();'));
		Assert.isTrue(out.indexOf('_f?.dispose();') != -1, 'expected inlined receiver in: $out');
		Assert.equals(-1, out.indexOf('logoBmd'));
	}

	public function testUnannotatedFlagged(): Void {
		Assert.equals(1, violations(wrapField('final x = _f;\n\t\tuse(x);')).length);
	}

	/** `this.f` is a field-access chain over a bare ident -- still a trivial pure read. */
	public function testFieldAccessInitFlagged(): Void {
		Assert.equals(1, violations(wrapField('final x = this._f;\n\t\tuse(x);')).length);
	}

	public function testDottedChainInitFlagged(): Void {
		Assert.equals(1, violations(wrapField('final x = a.b.c;\n\t\tuse(x);')).length);
	}

	/** The read in receiver position: nothing is evaluated before it. */
	public function testReceiverPositionFix(): Void {
		final out: String = applyFixOnce(wrapField('final x = _f;\n\t\tx.m();'));
		Assert.isTrue(out.indexOf('_f.m();') != -1, 'expected inlined receiver in: $out');
	}

	/** The callee `_obj.m` precedes the read and is itself a trivial pure read -- the G6 union arm. */
	public function testCalleeChainPrecedingReadFlagged(): Void {
		Assert.equals(1, violations(wrapField('final x = _f;\n\t\t_obj.m(x);')).length);
	}

	/** A call AFTER the read cannot change the value the read produces. */
	public function testImpureAfterReadFlagged(): Void {
		Assert.equals(1, violations(wrapField('final x = _f;\n\t\tlog(x, reset());')).length);
	}

	// --- negative: one gate each ---

	/** Two reads -- the strict-null-safety narrowing idiom this rule must never touch. */
	public function testTwoReadsNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = _f;\n\t\tif (x != null) x.dispose();')).length);
	}

	/** An intervening statement could mutate the source between the capture and the read. */
	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = _f;\n\t\tg();\n\t\tuse(x);')).length);
	}

	/** A lambda defers the read past the eager capture. */
	public function testReadInLambdaNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = _f;\n\t\trun(() -> use(x));')).length);
	}

	/** A named nested function defers it the same way. */
	public function testReadInNestedFunctionNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = _f;\n\t\tfunction h() {\n\t\t\tuse(x);\n\t\t}')).length);
	}

	/**
	 * A loop evaluates the substituted read once per iteration. The iterable is a bare identifier
	 * on purpose: an interval literal would ALSO trip the preceding-evaluation gate, and the
	 * fixture would then pass with the repetition gate removed.
	 */
	public function testReadInLoopNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final n = _f;\n\t\tfor (i in it) use(n);')).length);
	}

	/** A `while` condition is re-evaluated too, and the body may mutate the source. */
	public function testReadInWhileConditionNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final n = _f;\n\t\twhile (n < 5) _c++;')).length);
	}

	/**
	 * An array comprehension is a loop as much as a `for` statement is. The iterable is a bare
	 * identifier on purpose: an interval literal would ALSO trip the preceding-evaluation gate,
	 * and the fixture would then pass with the repetition gate removed.
	 */
	public function testReadInComprehensionNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final n = _f;\n\t\tfinal a = [for (i in it) use(n)];')).length);
	}

	/** The expression-position `while` of a comprehension repeats the read too. */
	public function testReadInComprehensionWhileNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final n = _f;\n\t\tfinal a = [while (n < 5) k()];')).length);
	}

	/** A `do ... while` runs its body before the first test, so the read repeats from iteration two. */
	public function testReadInDoWhileNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final n = _f;\n\t\tdo use(n) while (c);')).length);
	}

	/** A mutable local is out of scope: it can be written between the capture and the read. */
	public function testVarNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('var x = _f;\n\t\tuse(x);')).length);
	}

	public function testCallInitNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = h();\n\t\tuse(x);')).length);
	}

	public function testNewInitNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = new T();\n\t\tuse(x);')).length);
	}

	public function testIndexInitNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = arr[0];\n\t\tuse(x);')).length);
	}

	public function testArrayLiteralInitNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = [1];\n\t\tuse(x);')).length);
	}

	public function testIntLiteralInitNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = 1;\n\t\tuse(x);')).length);
	}

	/** Inlining `a?.b` into `x.c` would turn an NPE into a silent short-circuit. */
	public function testSafeNavInitNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = a?.b;\n\t\tuse(x);')).length);
	}

	/** The preceding argument is a call -- it runs before the read and may mutate the source. */
	public function testImpurePrecedingArgNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = _f;\n\t\tlog(reset(), x);')).length);
	}

	/**
	 * A local declared inside `#if A ... #end` stays visible AFTER `#end` -- the branch-aware
	 * projection's `CondBranch` is a resolution frame, not a Haxe scope. A braceless `$name` read
	 * past `#end` is invisible to `Refs` AND outside the statement list holding the declaration,
	 * so the scan must be scoped to the enclosing FUNCTION or the fix unbinds it.
	 */
	public function testInterpolationReadPastConditionalEndNotFlagged(): Void {
		final body: String = "#if A\n\t\tfinal x = _f;\n\t\tuse(x);\n\t\t#end\n\t\ttrace('got $x');";
		Assert.equals(0, violations(wrapField(body)).length);
	}

	/** Control: the same conditional-region shape with no unindexed read past `#end` still collapses. */
	public function testConditionalRegionWithoutStrayReadStillFlagged(): Void {
		final body: String = "#if A\n\t\tfinal x = _f;\n\t\tuse(x);\n\t\t#end\n\t\ttrace('plain');";
		Assert.equals(1, violations(wrapField(body)).length);
	}

	/**
	 * A macro reification `$name` (`DollarIdentExpr`) is a second read channel `Refs` does not
	 * index. `opaqueKinds` is a barrier only when the macro sits ON the path to the read, so an
	 * out-of-path reification needs the name-occurrence gate.
	 */
	public function testMacroReificationReadNotFlagged(): Void {
		final body: String = "final b = _f;\n\t\tuse(b);\n\t\tfinal w = macro function() $b;\n\t\tuse(w);";
		Assert.equals(0, violations(wrapField(body)).length);
	}

	/**
	 * An identifier the initializer READS is re-bound between the declaration and the read, so
	 * the copied text would resolve to the new binder: `use(x)` becomes `use(n)` reading the
	 * exception rather than the parameter -- output that COMPILES and is silently wrong.
	 */
	public function testInitIdentReboundNotFlagged(): Void {
		final body: String = 'final x = n;\n\t\ttry p catch (n:Dynamic) use(x);';
		Assert.equals(0, violations(wrapParams(body)).length);
	}

	/** Control for the re-binding gate: a catch binder under a DIFFERENT name captures nothing. */
	public function testInitIdentNotReboundStillFlagged(): Void {
		final body: String = 'final x = n;\n\t\ttry p catch (q:Dynamic) use(x);';
		Assert.equals(1, violations(wrapParams(body)).length);
	}

	/**
	 * A dotted field chain moved under a condition is observable in two ways the class doc's
	 * "the initializer is a pure read" argument does not cover: an eager null-deref stops
	 * throwing, and a property getter's side effect stops running. Only a BARE identifier may
	 * land on a conditional path.
	 */
	public function testConditionalFieldChainNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = _f.data;\n\t\tif (_on) use(x);')).length);
	}

	/** Control: the same field chain on an UNCONDITIONAL path is evaluated either way, so it collapses. */
	public function testUnconditionalFieldChainStillFlagged(): Void {
		Assert.equals(1, violations(wrapField('final x = _f.data;\n\t\tuse(x);')).length);
	}

	/** Control: a BARE identifier is safe on a conditional path -- reading it has no effect at all. */
	public function testConditionalBareIdentStillFlagged(): Void {
		Assert.equals(1, violations(wrapField('final x = _f;\n\t\tif (_on) use(x);')).length);
	}

	/**
	 * `final a, b;` (no initializer) projects as ONE child that IS the continuation, so the
	 * child-count check passes and `RefactorSupport.isMultiDeclarator` is what refuses it -- the
	 * gate `testMultiDeclaratorNotFlagged` names but cannot reach.
	 */
	public function testBareMultiDeclaratorNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final a, b;\n\t\tuse(a);')).length);
	}

	/**
	 * Capturing a MUTABLE local into a `final` is not noise: under strict null safety Haxe
	 * narrows an immutable binding but NOT a `var` a closure captures, so the inlined form does
	 * not compile. Found by running the rule over its OWN source.
	 */
	public function testMutableLocalCaptureNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('var best = null;\n\t\tfinal b = best;\n\t\tuse(b);')).length);
	}

	/** Control: capturing an immutable local is pure noise and still collapses. */
	public function testImmutableLocalCaptureStillFlagged(): Void {
		// Two findings, not one: the chain is `_f` -> `best` -> `b` and each link qualifies on its
		// own; `readSwallowed` is what keeps `fix` from applying both in the same pass.
		Assert.equals(2, violations(wrapField('final best = _f;\n\t\tfinal b = best;\n\t\tuse(b);')).length);
	}

	/** An upcast annotation changes the static type at the use site; the substitution would drop it. */
	public function testAnnotationMismatchNotFlagged(): Void {
		Assert.equals(0, violations(wrapTyped('private final _sub:Sub;', 'final x:Base = _sub;\n\t\tuse(x);')).length);
	}

	/** Control for the annotation gate: an annotation that re-states the source type is type-neutral. */
	public function testAnnotationRestatesSourceFlagged(): Void {
		Assert.equals(1, violations(wrapTyped('private final _sub:Sub;', 'final x:Sub = _sub;\n\t\tuse(x);')).length);
	}

	/** A field-access initializer has no ident binding, so an annotation on it can never be proven neutral. */
	public function testAnnotatedUnresolvableSourceNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x:Int = a.b.c;\n\t\tuse(x);')).length);
	}

	/**
	 * A multi-declarator carries its continuation as a second child, so it fails the
	 * single-child initializer shape before the named multi-declarator gate is even consulted;
	 * this pins the outcome, not one particular gate.
	 */
	public function testMultiDeclaratorNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final a = _f, b = _g;\n\t\tuse(a);')).length);
	}

	/** A trailing comment costs the declaration its own physical line, which the fix deletes whole. */
	public function testTrailingCommentOnDeclLineNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final x = _f; // why\n\t\tuse(x);')).length);
	}

	/** A comment INSIDE the declaration sits in the deleted region and would be lost. */
	public function testCommentInsideDeclNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('final /* why */ x = _f;\n\t\tuse(x);')).length);
	}

	/** Control for the comment gate: a comment between the two statements rides along untouched. */
	public function testCommentBetweenStatementsStillFlagged(): Void {
		Assert.equals(1, violations(wrapField('final x = _f;\n\t\t// note\n\t\tuse(x);')).length);
	}

	/** A declaration sharing its line with another statement cannot be deleted line-wise. */
	public function testDeclSharesLineNotFlagged(): Void {
		Assert.equals(0, violations(wrapField('g(); final x = _f;\n\t\tuse(x);')).length);
	}

	/**
	 * Two sibling `#if` branches declare the same name and a read follows `#end`: that read
	 * binds to whichever branch the configuration activates, so inlining either declaration
	 * away would leave it unbound in that branch's build.
	 */
	public function testSiblingBranchDeclsReadAfterRegionNotFlagged(): Void {
		final body: String = '#if A\n\t\tfinal x = _f;\n\t\tuse(x);\n\t\t#else\n\t\tfinal x = _f;\n\t\tuse(x);\n\t\t#end\n\t\tuse(x);';
		Assert.equals(0, violations(wrapField(body)).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('join-single-use-local'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('join-single-use-local'));
		Assert.equals(BUILTIN_CHECK_COUNT, Linter.builtins().length);
	}

	/**
	 * Two CHAINED captures each qualify on their own, but one `fix` pass may collapse only the
	 * outer link: the inner substitution would land on the very line the outer link deletes, and
	 * emitting both would leave `b.m()` rewritten to a name whose declaration is gone. The
	 * `--fix` driver's next pass picks the inner link up again.
	 */
	public function testChainedCapturesCollapseOneLinkPerPass(): Void {
		final src: String = wrapField('final a = _f;\n\t\tfinal b = a;\n\t\tb.m();');
		Assert.equals(2, violations(src).length);
		Assert.equals(2, edits(src).length);
		final once: String = applyFixOnce(src);
		Assert.isTrue(once.indexOf('a.m();') != -1, 'expected the outer link collapsed in: $once');
		Assert.isTrue(once.indexOf('final a = _f;') != -1, 'expected the inner capture kept in: $once');
		final twice: String = applyFixOnce(once);
		Assert.isTrue(twice.indexOf('_f.m();') != -1, 'expected the chain fully collapsed in: $twice');
	}

	// --- composition with its neighbours ---

	/**
	 * The cascade the rule exists for: `prefer-safe-nav` rewrites the null guard into `?.`,
	 * leaving the capture pointless, and a SUBSEQUENT pass of this rule inlines it away.
	 */
	public function testCascadesFromPreferSafeNav(): Void {
		final src: String = wrapField('final logoBmd:Null<T> = _f;\n\t\tif (logoBmd != null) logoBmd.dispose();');
		final nav: PreferSafeNav = new PreferSafeNav();
		final vs1: Array<Violation> = nav.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final es1: Array<{ span: Span, text: String }> = nav.fix(src, vs1, new HaxeQueryPlugin());
		final afterNav: String = canonicalize(src, es1);
		Assert.isTrue(afterNav.indexOf('logoBmd?.dispose();') != -1, 'expected safe-nav form in: $afterNav');
		final afterJoin: String = applyFixOnce(afterNav);
		Assert.isTrue(afterJoin.indexOf('_f?.dispose();') != -1, 'expected inlined form in: $afterJoin');
	}

	/**
	 * `final x = _f; return x;` is `join-return`'s shape, and that check emits the better text
	 * (it owns the annotation-ascription decision). This rule refuses it outright, so the pair
	 * is never claimed twice.
	 */
	public function testJoinReturnKeepsPriority(): Void {
		final src: String = wrapRet('final x = _f;\n\t\treturn x;');
		Assert.equals(0, violations(src).length);
		Assert.equals(1, new JoinReturn().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()).length);
	}

	/** A `return` of an EXPRESSION over the local is not `join-return`'s shape and stays this rule's. */
	public function testReturnOfExpressionStillFlagged(): Void {
		Assert.equals(1, violations(wrapRet('final x = _f;\n\t\treturn use(x);')).length);
	}

	/**
	 * A braceless `$name` string interpolation is a read `Refs` does not index, so the
	 * sole-reference count misses it and calls the local single-use when it is not. Deleting the
	 * declaration would leave the interpolation bound to nothing -- output that does not compile.
	 * Found on TM-Haxe4 `src/video/VideoExportController.hx:239`, where a captured `batchH` is
	 * passed to a call and re-read from a `trace` on the next line.
	 */
	public function testInterpolationReadNotFlagged(): Void {
		Assert.equals(0, violations(wrapField("final x = _f;\n\t\tuse(x);\n\t\ttrace('got $x');")).length);
	}

	/**
	 * Control for the interpolation gate: the identical shape whose trailing statement holds no
	 * `$x` still collapses, so the gate is not simply refusing anything with a trace after it.
	 */
	public function testTrailingStatementWithoutInterpolationStillFlagged(): Void {
		Assert.equals(1, violations(wrapField("final x = _f;\n\t\tuse(x);\n\t\ttrace('got it');")).length);
	}

	/**
	 * A BRACED `${x}` read IS indexed by `Refs`, so it raises the reference count and the
	 * sole-reference gate refuses the site on its own -- the interpolation gate is not what
	 * catches this one, and is not needed for it.
	 */
	public function testBracedInterpolationReadNotFlagged(): Void {
		Assert.equals(0, violations(wrapField("final x = _f;\n\t\tuse(x);\n\t\ttrace('got ${x}');")).length);
	}

	/** Wrap a statement body in a class carrying one typed field, so a field capture resolves a declared type. */
	private inline function wrapField(body: String): String {
		return wrapTyped('private final _f:Null<T>;', body);
	}

	/** Wrap a statement body in a class carrying `field`, so the G7 annotation fixtures have something to resolve. */
	private function wrapTyped(field: String, body: String): String {
		return 'class C {\n\t$field\n\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	/** Wrap a statement body in a method taking `n` / `p` params -- the initializer-re-binding fixtures. */
	private function wrapParams(body: String): String {
		return 'class C {\n\tprivate final _f:Null<T>;\n\n\tfunction f(n:Int, p:Int) {\n\t\t$body\n\t}\n}';
	}

	/** Wrap a statement body in a method with an explicit return type -- the `join-return` overlap fixtures. */
	private function wrapRet(body: String): String {
		return 'class C {\n\tprivate final _f:Null<T>;\n\n\tfunction f():Null<T> {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new JoinSingleUseLocal().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: JoinSingleUseLocal = new JoinSingleUseLocal();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer -- the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return canonicalize(src, edits(src));
	}

	private function canonicalize(src: String, es: Array<{ span: Span, text: String }>): String {
		return switch RefactorSupport.canonicalize(src, es, true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
