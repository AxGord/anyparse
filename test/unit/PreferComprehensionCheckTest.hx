package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferComprehension;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-comprehension` check: an empty-array local `final a = []` immediately followed by a
 * push-only `for (x in xs) a.push(e);` is flagged `Info` and rewritten to
 * `final a = [for (x in xs) e];`. Key-value and nested `for`s and a single trailing `if` guard
 * transfer verbatim; a self-reference, an unread array, a `break`, a non-adjacent loop, a comment in
 * the decl-to-loop gap or in a transcribed header, and a non-empty initializer are all safe misses.
 * The raw fix emits tight brackets (`[...]`); the linter's canonicalizing `--fix` spaces them.
 *
 * A braced body holding a CHAIN of single-use `final` locals feeding the push is admitted too, each
 * link inlined into its one use. The refusals around that arm carry most of the fixtures here: a
 * `var` link, a multi-declarator, a use that is not exactly one, a use off the eager-host spine, a
 * `?.` or an impure node in the host's value region, a `macro`, and a `$name` interpolation the plain
 * identifier scan cannot see.
 *
 * An inlined link keeps its declaration's annotation as an ASCRIPTION unless the array declaration's
 * own ELEMENT type textually restates it at the whole-push-argument position — `Array<Cmd>` around a
 * `c:Cmd` link drops it, `Array<Dynamic>` around a `m:Map<String, Int>` link does not.
 */
class PreferComprehensionCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) out.push(x * 2);'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-comprehension', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('array comprehension') != -1);
	}

	public function testTypedDeclKeepsAnnotation(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) x * 2];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) out.push(x * 2);'))
		);
	}

	public function testGuardFormFlaggedAndFixed(): Void {
		Assert.equals(1, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) if (x > 0) out.push(x);')).length);
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) if (x > 0) x];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) if (x > 0) out.push(x);'))
		);
	}

	public function testGuardBracedBodyFixed(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) if (x > 0) x];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) if (x > 0) { out.push(x); }'))
		);
	}

	public function testKeyValueFormFixed(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (k => v in m) v];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (k => v in m) out.push(v);'))
		);
	}

	public function testNestedForsFixed(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (a in xs) for (b in xs) a + b];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (a in xs) for (b in xs) out.push(a + b);'))
		);
	}

	public function testVarBecomesFinalInFix(): Void {
		Assert.equals(fnRet('final out = [for (x in xs) x];'), applyFix(fnRet('var out = [];\n\t\tfor (x in xs) out.push(x);')));
	}

	public function testBracedBodyFixed(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) x];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) { out.push(x); }'))
		);
	}

	public function testSecondStatementNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) { out.push(x); trace(x); }')).length);
	}

	public function testSelfReferenceNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) out.push(out.length);')).length);
	}

	public function testUnreadArrayNotFlagged(): Void {
		final source: String =
			'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\tfinal out:Array<Int> = [];\n\t\tfor (x in xs) out.push(x);\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testBreakInBodyNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) { out.push(x); break; }')).length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(
			0, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) if (x > 0) out.push(x) else out.push(0);')).length
		);
	}

	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [];\n\t\tfinal n = xs.length;\n\t\tfor (x in xs) out.push(x);')).length);
	}

	public function testCommentInGapNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = []; // seed\n\t\tfor (x in xs) out.push(x);')).length);
	}

	public function testNonEmptyInitNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [0];\n\t\tfor (x in xs) out.push(x);')).length);
	}

	public function testNewArrayInitNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = new Array();\n\t\tfor (x in xs) out.push(x);')).length);
	}

	public function testApplyFixByteExact(): Void {
		final input: String = 'class C {\n\tfunction f(xs:Array<Int>):Array<Int> {\n\t\tfinal out:Array<Int> = [];\n'
			+ '\t\tfor (x in xs) out.push(x * 2);\n\t\treturn out;\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f(xs:Array<Int>):Array<Int> {\n\t\tfinal out:Array<Int> = [for (x in xs) x * 2];\n'
			+ '\t\treturn out;\n\t}\n}';
		Assert.equals(expected, applyFix(input));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-comprehension'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-comprehension'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { final out = []; for (x in xs) out.push(').length);
	}

	public function testSelfReferenceInIterableNotFlagged(): Void {
		// The self-reference gate scans the WHOLE iterable subtree, not just the pushed value —
		// `out` in the loop's iterable disqualifies the comprehension.
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in [out.length]) out.push(x);')).length);
	}

	public function testFinalChainInlinedAndFixed(): Void {
		// The unchecked `cast x` is typed BY its annotation, so that annotation survives as an
		// ascription; `cmd`'s is dropped because the array's own `Array<Cmd>` restates it at the
		// whole-argument position, and the body comment is hoisted.
		Assert.equals(
			fnRet('// note\n\t\tfinal out:Array<Cmd> = [for (x in xs) if (isKind(x)) new MakeCmd((cast x : ToolBase), m)];'),
			applyFix(fnRet(chainBody()))
		);
	}

	public function testSingleFinalChainFixed(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) f(x)];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal a = f(x);\n\t\t\tout.push(a);\n\t\t}'))
		);
	}

	public function testVarInChainNotFlagged(): Void {
		// A `var` link may be reassigned between its declaration and the push, so its value at the
		// push is not its initializer.
		Assert.equals(
			0, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tvar a = f(x);\n\t\t\tout.push(a);\n\t\t}')).length
		);
	}

	public function testMultiUseLocalNotFlagged(): Void {
		// Inlining a twice-used local would evaluate its initializer twice.
		Assert.equals(
			0,
			violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal a = f(x);\n\t\t\tout.push(a + a);\n\t\t}'))
				.length
		);
	}

	public function testOutOfOrderUsesNotFlagged(): Void {
		// `b` is used before `a`, so inlining would run `g` before `f` — the reverse of the source.
		Assert.equals(
			0,
			violations(fnRet(
				'final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal a = f(x);\n\t\t\tfinal b = g(x);\n\t\t\tout.push(h(b, a));\n\t\t}'
			)).length
		);
	}

	public function testIfGuardBoundaryNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal a = f(x);\n\t\t\tif (a > 0) out.push(a);\n\t\t}')
			).length
		);
		// Single-use variant: only the "last statement is not a push" gate can reject this one, so
		// it is what proves the guard boundary is refused rather than the multi-use count.
		Assert.equals(
			0,
			violations(
				fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal a = f(x);\n\t\t\tif (x > 0) out.push(a);\n\t\t}')
			).length
		);
	}

	public function testLambdaCaptureNotFlagged(): Void {
		// The use sits under a lambda, so the initializer would run when the lambda is called.
		Assert.equals(
			0,
			violations(
				fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal k = f(x);\n\t\t\tout.push(m.map(y -> k));\n\t\t}')
			).length
		);
	}

	public function testMultiDeclaratorNotFlagged(): Void {
		// A Haxe multi-declarator projects its continuation as a CHILD of the declaration, so the
		// refusal here is the single-child requirement; the continuation KIND gate is cross-grammar
		// defence, for a grammar that projects the continuation as a SIBLING instead.
		Assert.equals(
			0,
			violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal a = 1, b = 2;\n\t\t\tout.push(a + b);\n\t\t}'))
				.length
		);
	}

	public function testOperandInliningParenthesised(): Void {
		// The use is an operand of `*`, which binds tighter than the inlined `+`.
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) (x + 1) * 2];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal a = x + 1;\n\t\t\tout.push(a * 2);\n\t\t}'))
		);
	}

	public function testUnannotatedCastNotAscribed(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) g(cast x)];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal t = cast x;\n\t\t\tout.push(g(t));\n\t\t}'))
		);
	}

	public function testCommentInsideDeclNotFlagged(): Void {
		// Dissolving the declaration would strand the comment inside an expression.
		Assert.equals(
			0,
			violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal a = f(/* why */ x);\n\t\t\tout.push(a);\n\t\t}'))
				.length
		);
	}

	public function testBodyCommentHoistedAboveComprehension(): Void {
		Assert.equals(
			fnRet('// note\n\t\tfinal out:Array<Int> = [for (x in xs) x];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\t// note\n\t\t\tout.push(x);\n\t\t}'))
		);
	}

	public function testChainSelfReferenceNotFlagged(): Void {
		// A chain link's initializer reads the array being built, so it is a self-reference too.
		Assert.equals(
			0,
			violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal n = out.length;\n\t\t\tout.push(n);\n\t\t}'))
				.length
		);
	}

	public function testNestedChainOperandParenthesised(): Void {
		// `b` renders `a`'s text, and the declaration `a` sat in is DISSOLVED by the same fix — so
		// the parentheses must come from `a`'s own position, which `b`'s atom kind cannot supply.
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) (x + 1) * 2];'),
			applyFix(fnRet(
				'final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal a = x + 1;\n\t\t\tfinal b = a;\n\t\t\tout.push(b * 2);\n\t\t}'
			))
		);
	}

	public function testNestedChainFieldAccessParenthesised(): Void {
		// The same defect one link deeper, where the unparenthesised text does not even parse as
		// intended: `x + 1.foo` reads the field off the literal.
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) (x + 1).foo];'),
			applyFix(fnRet(
				'final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal a = x + 1;\n\t\t\tfinal b = a;\n\t\t\tfinal c = b.foo;\n\t\t\tout.push(c);\n\t\t}'
			))
		);
	}

	public function testUseInsideComprehensionNotFlagged(): Void {
		// The `for` EXPRESSION on the spine would run the initializer once per inner iteration. The
		// inner iterable is a bare identifier on purpose: a `0...3` would put an `Interval` before
		// the use, and the preceding-purity gate — not the spine gate — would be what refuses.
		Assert.equals(
			0,
			violations(
				fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal k = f(x);\n\t\t\tout.push([for (i in ys) k]);\n\t\t}')
			).length
		);
	}

	public function testUseUnderRebindingLoopNotFlagged(): Void {
		// The inner `for` REBINDS `k`, so that identifier is not the link at all — the use scan
		// matches on NAME, with no scope awareness.
		Assert.equals(
			0,
			violations(
				fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal k = f(x);\n\t\t\tout.push([for (k in m) k]);\n\t\t}')
			).length
		);
	}

	public function testUseUnderSafeNavCallNotFlagged(): Void {
		// `obj?.m` makes a whole argument list conditional, and the `?.` is a SIBLING of the use,
		// not an ancestor — neither the spine walk nor the preceding-purity walk reaches it when it
		// sits AFTER the use, so only the region-wide kind scan refuses this one. Conservative,
		// which is the safe direction for a conditional operand.
		Assert.equals(
			0,
			violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal k = f(x);\n\t\t\tout.push([k, obj?.m]);\n\t\t}'))
				.length
		);
	}

	public function testImpureCodeBeforeUseNotFlagged(): Void {
		// Inlining moves `f(x)` to the use position, so `g(x)` — which the declaration used to run
		// AFTER — would run first.
		Assert.equals(
			0,
			violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal a = f(x);\n\t\t\tout.push(g(x) + a);\n\t\t}'))
				.length
		);
	}

	public function testContextTypedLinkAscribed(): Void {
		// `x` alone does not type as `Dynamic`, so dropping the annotation would change the type of
		// the argument — and break compilation at `d.name`-style uses.
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) g((x : Dynamic))];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal d:Dynamic = x;\n\t\t\tout.push(g(d));\n\t\t}'))
		);
	}

	public function testWholeArgumentAnnotationDropped(): Void {
		// The array declaration's annotation is preserved verbatim and its ELEMENT type is textually
		// the link's own, so the link's annotation is restated at this exact position and drops.
		Assert.equals(
			fnRet('final out:Array<Cmd> = [for (x in xs) new MakeCmd()];'),
			applyFix(
				fnRet('final out:Array<Cmd> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal c:Cmd = new MakeCmd();\n\t\t\tout.push(c);\n\t\t}')
			)
		);
	}

	public function testWholeArgumentAnnotationKeptWhenArrayUntyped(): Void {
		// Same position, but no array annotation restates the element type — so the link's own
		// annotation is load-bearing and survives as an ascription.
		Assert.equals(
			fnRet('final out = [for (x in xs) (new MakeCmd() : Cmd)];'),
			applyFix(fnRet('var out = [];\n\t\tfor (x in xs) {\n\t\t\tfinal c:Cmd = new MakeCmd();\n\t\t\tout.push(c);\n\t\t}'))
		);
	}

	public function testPushStatementCommentHoisted(): Void {
		// The comment sits inside the push CALL but outside its ARGUMENT, so the verbatim element
		// text cannot carry it — it is hoisted like a statement-list gap comment.
		Assert.equals(
			fnRet('/* why */\n\t\tfinal out:Array<Int> = [for (x in xs) x];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) out.push(/* why */ x);'))
		);
	}

	public function testNonRestatingArrayAnnotationAscribed(): Void {
		// `Array<Dynamic>` does not restate `Map<String, Int>`, so dropping the link's annotation
		// leaves a bare `new Map()` whose type parameters are unknown — which does not compile.
		Assert.equals(
			fnRet('final out:Array<Dynamic> = [for (x in xs) (new Map() : Map<String, Int>)];'),
			applyFix(fnRet(
				'final out:Array<Dynamic> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal m:Map<String, Int> = new Map();\n\t\t\tout.push(m);\n\t\t}'
			))
		);
	}

	public function testInterpolatedUseNotFlagged(): Void {
		// A simple `$t` projects as the string-interpolation identifier kind, NOT as a plain
		// identifier, so a scan that matches only the latter counts `t` as single-use and inlines
		// both links — emitting `compute(x) + 'got $t'`, where `t` is no longer declared.
		Assert.equals(
			0,
			violations(fnRet(
				"final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal t = f(x);\n\t\t\tfinal msg = 'got $t';\n\t\t\tout.push(t + msg);\n\t\t}"
			)).length
		);
	}

	public function testMacroInLaterSiblingNotFlagged(): Void {
		// A reification subtree is exactly the region where nothing can be proven, so the chain
		// REFUSES rather than skipping it: `k` is used inside the `macro`, and inlining its
		// declaration away would leave that use unbound. TWO scans enforce this — the use scan and
		// the self-reference scan — and this fixture is behind both, so it flips only when both are
		// reverted.
		Assert.equals(
			0,
			violations(fnRet(
				"final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal k = f(x);\n\t\t\tfinal e = macro trace($v{k});\n\t\t\tout.push(g(k, e));\n\t\t}"
			)).length
		);
	}

	public function testSelfReferenceThroughInterpolationNotFlagged(): Void {
		// `$out` reads the array being built from inside a string literal — the same blind spot on
		// the SELF-REFERENCE gate, which is live on the single-statement arm too.
		Assert.equals(0, violations(fnRet("final out:Array<Int> = [];\n\t\tfor (x in xs) out.push('$out-$x');")).length);
	}

	public function testImpurePropertyReadBeforeUseNotFlagged(): Void {
		// A field access is not pure in Haxe — `b.counter` may be a property getter, and the
		// `b.bump()` the link defers to the use position may be what changes what it returns.
		Assert.equals(
			0,
			violations(
				fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal t = b.bump();\n\t\t\tout.push(b.counter + t);\n\t\t}')
			).length
		);
	}

	public function testCheckedCastBeforeUseNotFlagged(): Void {
		// `cast(y, T)` THROWS on a non-null mismatch, so it is not pure either — moving the link's
		// initializer in front of it reorders which effect happens first. The operand is BARE on
		// purpose: in `cast(y, T).n` the field access wrapping it would already refuse, so only
		// this shape discriminates the checked cast.
		Assert.equals(
			0,
			violations(
				fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal t = f(x);\n\t\t\tout.push(cast(y, T) + t);\n\t\t}')
			).length
		);
	}

	public function testCommentInTranscribedHeaderNotFlagged(): Void {
		// A `for` / `if` header is transcribed VERBATIM, so a `//` comment inside one would comment
		// out the rest of the comprehension. The reparse validator catches the result, but it then
		// skips the WHOLE FILE — discarding every other rule's fix in it too.
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) // note\n\t\t\tout.push(x);')).length);
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) if (x > 0) // note\n\t\t\tout.push(x);')).length);
	}

	public function testCommentOnEarlierHeaderLineFixed(): Void {
		// Only the header's LAST line can swallow what the comprehension appends to it; an earlier
		// line's comment is followed by a newline inside the copied text and transfers intact.
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in [\n\t\t\t1, // one\n\t\t\t2\n\t\t]) x];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in [\n\t\t\t1, // one\n\t\t\t2\n\t\t]) out.push(x);'))
		);
	}

	private inline function chainBody(): String {
		return 'final out:Array<Cmd> = [];\n\t\tfor (x in xs) if (isKind(x)) {\n\t\t\tfinal tool:ToolBase = cast x;'
			+ '\n\t\t\tfinal cmd:Cmd = new MakeCmd(tool, m);\n\t\t\t// note\n\t\t\tout.push(cmd);\n\t\t}';
	}

	private function fnRet(stmts: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, m:Map<String, Int>):Array<Int> {\n\t\t$stmts\n\t\treturn out;\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferComprehension().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		final check: PreferComprehension = new PreferComprehension();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = source;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
