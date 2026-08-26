package unit;

import anyparse.check.Check.Violation;
import anyparse.check.UnusedLocal;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `unused-local` against a binding whose only occurrences belong to an inner
 * SELF-SCOPED declaration of the same name — the AS3-heritage
 * `var item; for (item in xs) use(item);`, where the `for` iterator is a fresh
 * binding scoped to the loop and the outer declaration is dead in every compile.
 *
 * The check's occurrence test is a raw text scan, so those occurrences used to read
 * as references and the declaration stayed silent. It now re-runs the SAME scan with the regions a self-scoped
 * binding owns (`RefShape.selfScopeDeclKinds` — the `for` iterator, the `catch` exception, plus a key-value
 * loop's VALUE binder via `RefShape.iterationValueBinderKinds`) excluded, and flags the declaration when nothing
 * textual survives outside them.
 *
 * The rest of these fixtures pin the refusals that bound the class: a post-loop read
 * (the loop scope is its body, so the name resolves to the outer declaration again),
 * a read in the loop's ITERATED EXPRESSION (evaluated in the enclosing scope), a
 * `#if` region on either side, a shared declaration line whose deletion would take a
 * live sibling with it, and every occurrence the scan cannot attribute — a comment, a
 * string interpolation, a lambda parameter's shadow.
 */
class UnusedLocalShadowTest extends Test {

	/**
	 * The reported shape: a bare declaration whose name is re-bound by the following
	 * loop. Both occurrences (the iterator's binder, the body's read) belong to the
	 * loop, so the declaration is flagged at its own line.
	 */
	public function testForLoopShadowFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\tfor (item in xs) trace(item);\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('unused-local', vs[0].rule);
		Assert.isTrue(vs[0].message.contains("'item'"));
	}

	/** The autofix deletes the shadowed declaration; the loop keeps its own binding. */
	public function testForLoopShadowFixDeletesDeclaration(): Void {
		final src: String = 'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\tfor (item in xs) trace(item);\n\t}\n}';
		Assert.equals('class C {\n\tfunction f(xs:Array<String>) {\n\t\tfor (item in xs) trace(item);\n\t}\n}', applyFix(src));
	}

	/**
	 * A `catch` exception is self-scoped the same way, so the same refinement reaches
	 * a declaration shadowed by a catch clause.
	 */
	public function testCatchClauseShadowFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f() {\n\t\tvar error:String;\n\t\ttry {\n\t\t\tg();\n\t\t} catch (error:String) {\n'
			+ '\t\t\ttrace(error);\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'error'"));
	}

	/** Nesting does not matter: the inner loop owns both of its occurrences. */
	public function testNestedLoopShadowFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f(rows:Array<Array<String>>) {\n\t\tvar item:String;\n'
			+ '\t\tfor (row in rows) for (item in row) trace(item);\n\t}\n}'
		);
		Assert.equals(1, vs.length);
	}

	/**
	 * The EXPRESSION-position loop (`ForExpr`, a comprehension) is a self-scoped
	 * declaration exactly like the statement form, and the grammar projects it under its
	 * own kind — so it needs its own fixture rather than inheriting the `ForStmt` one.
	 */
	public function testForExprComprehensionShadowFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\treturn [for (item in xs) item];\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'item'"));
	}

	/**
	 * The same comprehension written with spaced brackets. A construct's span absorbs the
	 * trailing whitespace before its closing delimiter, so an exact `body.to == span.to`
	 * shape test made the finding a property of FORMATTING — flagged unspaced, silent
	 * spaced. The gap is trivia and must not decide coverage.
	 */
	public function testForExprSpacedComprehensionShadowFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\treturn [ for (item in xs) item ];\n\t}\n}'
		);
		Assert.equals(1, vs.length);
	}

	/**
	 * Same class, different absorbed token: a stray `;` after a block-terminated loop is
	 * folded into the loop's own span (it projects no node of its own), which likewise must
	 * not decide whether the shadowed declaration is seen.
	 */
	public function testAbsorbedSemicolonAfterBodyShadowFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\tfor (item in xs) { trace(item); };\n\t}\n}'
		);
		Assert.equals(1, vs.length);
	}

	/** A trailing line comment after the body is trivia too — it never reached the loop's span, and must not start to. */
	public function testTrailingCommentAfterBodyShadowFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\tfor (item in xs) trace(item); // loop\n\t}\n}'
		);
		Assert.equals(1, vs.length);
	}

	/**
	 * The conditional-compilation refusal is a DIRECTIVE test, not a kind test: an
	 * expression-position `#if` projects under a different kind than the statement-position
	 * one, and a gate naming a single kind covers only whichever position the grammar
	 * happens to spell that way.
	 *
	 * The refusal here is conservatism, not a correctness requirement — the scan reads every
	 * branch of the region at once, so no wrong finding is constructible from this shape
	 * today. What the fixture pins is that both positions are treated ALIKE.
	 */
	public function testExpressionPositionConditionalRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n'
				+ '\t\tfinal ys = #if debug [for (item in xs) item] #else [] #end;\n\t\treturn ys;\n\t}\n}'
			).length
		);
	}

	/**
	 * The VALUE binder of `for (k => item in m)` shadows the declaration exactly as a plain
	 * iterator does. It was a documented MISS while the loop node carried only the KEY name;
	 * the binder is a node of its own now (`RefShape.iterationValueBinderKinds`), so the
	 * region model reaches it through the same self-scoped path.
	 *
	 * Both spacings, because what the model reads is the binder's SPAN: a tight `k=>item`
	 * puts it at different offsets than a padded `k => item`, and the region cut still has to
	 * land on the binder token.
	 */
	public function testKeyValueValueBinderShadowFlagged(): Void {
		for (header in ['k => item', 'k=>item']) {
			final vs: Array<Violation> = violations(
				'class C {\n\tfunction f(m:Map<String, String>) {\n\t\tvar item:String;\n\t\tfor ($header in m) trace(k + item);\n\t}\n}'
			);
			Assert.equals(1, vs.length, 'header "$header"');
			Assert.isTrue(vs[0].message.contains("'item'"), 'header "$header"');
		}
	}

	/** The autofix deletes the declaration the key-value VALUE binder shadowed, loop untouched. */
	public function testKeyValueValueBinderShadowFixDeletesDeclaration(): Void {
		final src: String =
			'class C {\n\tfunction f(m:Map<String, String>) {\n\t\tvar item:String;\n\t\tfor (k => item in m) trace(k + item);\n\t}\n}';
		Assert.equals('class C {\n\tfunction f(m:Map<String, String>) {\n\t\tfor (k => item in m) trace(k + item);\n\t}\n}', applyFix(src));
	}

	/**
	 * The KEY binder still shadows through the loop node's own name — the arm the value
	 * binder was ADDED to, not replaced in. Without this the value-binder test alone would
	 * pass over a model that had dropped the key.
	 */
	public function testKeyValueKeyBinderShadowFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f(m:Map<String, String>) {\n\t\tvar item:String;\n\t\tfor (item => v in m) trace(item + v);\n\t}\n}'
			).length
		);
	}

	/**
	 * A read of the OUTER binding after the loop keeps the declaration live even when the
	 * value binder shares its name — the excluded region is the binder token plus the body,
	 * never the whole enclosing scope.
	 */
	public function testKeyValueValueBinderPostLoopReadKeepsDeclaration(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(m:Map<String, String>) {\n\t\tvar item:String = "a";\n'
				+ '\t\tfor (k => item in m) trace(k + item);\n\t\ttrace(item);\n\t}\n}'
			).length
		);
	}

	/**
	 * A `for` iterator is scoped to the loop BODY, so a read after the loop resolves to
	 * the outer declaration again — live, and the region model must not swallow it.
	 */
	public function testPostLoopReadKeepsDeclaration(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String = "a";\n\t\tfor (item in xs) trace(item);\n'
				+ '\t\ttrace(item);\n\t}\n}'
			).length
		);
	}

	/**
	 * The loop's ITERATED EXPRESSION is evaluated in the enclosing scope: `for (item in
	 * item)` reads the outer binding. Only the body is excluded, never the whole
	 * construct, so this declaration stays live.
	 */
	public function testIteratedExpressionReadKeepsDeclaration(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f() {\n\t\tvar item:Array<String> = ["a"];\n\t\tfor (item in item) trace(item);\n\t}\n}')
				.length
		);
	}

	/** A write before the loop is a use of the outer binding — `dead-store`'s domain, not this check's. */
	public function testWriteBeforeLoopKeepsDeclaration(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\titem = "y";\n\t\ttrace(item);\n'
				+ '\t\tfor (item in xs) trace(item);\n\t}\n}'
			).length
		);
	}

	/**
	 * A shadowed binding that SHARES its declaration line is reported but never cut: the
	 * deletion takes the whole line, which would drop the live sibling with it. Same
	 * refusal the multi-declarator data-loss guard already made, now reachable through
	 * the shadow path.
	 */
	public function testMultiVarShadowedTailReportedNotFixed(): Void {
		final src: String = 'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar used:String = "u", item:String = "v";\n'
			+ '\t\tfor (item in xs) used += item;\n\t\ttrace(used);\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'item'"));
		Assert.equals(src, applyFix(src));
	}

	/**
	 * A declaration inside a conditional-compilation region is refused: the region's
	 * branches project as flat siblings, so no state of the tree is the source a single
	 * compile sees.
	 */
	public function testDeclarationInsideConditionalRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\t#if debug\n\t\tvar item:String;\n\t\tfor (item in xs) trace(item);\n'
				+ '\t\t#end\n\t}\n}'
			).length
		);
	}

	/** The mirror refusal: the shadowing construct itself inside a conditional region claims no region. */
	public function testShadowingLoopInsideConditionalRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\t#if debug\n\t\tfor (item in xs) trace(item);\n'
				+ '\t\t#end\n\t}\n}'
			).length
		);
	}

	/**
	 * An INTENT pin, not a gate test: the class is deliberately not widened past the
	 * grammar's self-scoped declarations, so a declaration shadowed by a lambda parameter
	 * stays silent. Nothing in the shadow model would have to be defeated for this to
	 * flag — the lambda projects as a `ThinArrow` carrying NO name, so the model's
	 * `node.name == name` test never even reaches its region check. Widening the class to
	 * lambda parameters means giving them a binder/body region of their own, and this
	 * fixture is what makes that a deliberate act.
	 */
	public function testLambdaParameterShadowNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\treturn xs.map(item -> item + "!");\n\t}\n}')
				.length
		);
	}

	/** Every occurrence outside the excluded regions still counts, a comment mention included. */
	public function testCommentMentionKeepsDeclaration(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\t// item is described here\n'
				+ '\t\tfor (item in xs) trace(item);\n\t}\n}'
			).length
		);
	}

	/** So does a simple string interpolation after the loop — an `Ident` the reference walker never surfaces. */
	public function testInterpolationAfterLoopKeepsDeclaration(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String = \"z\";\n\t\tfor (item in xs) trace(item);\n'
				+ "\t\ttrace('$item');\n\t}\n}"
			).length
		);
	}

	/**
	 * A GUARD, not a discriminator - it passes on the base branch too. This check tests references with
	 * a raw TEXTUAL scan over the enclosing scope span, so the capture is found whatever the frame
	 * boundaries are. What it pins is that a local `inline function` joining `RefShape.scopeKinds` did
	 * not make its body a region this check subtracts: the helper is not a self-scoped declaration, so
	 * its own name is neither a local declaration nor a shadowing region.
	 */
	public function testLocalCapturedByInlineHelperKeepsDeclaration(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tvar total:Int = 0;\n\t\tinline function add(n:Int) total += n;\n\t\tadd(1);\n\t}\n}'
			).length
		);
	}

	/**
	 * A declaration shadowed by an inline helper's PARAMETER is not flagged, exactly as the
	 * lambda-parameter case above: a parameter is not in `selfScopeDeclKinds`, so the helper's body
	 * is not a region the second scan subtracts. The over-count is the safe direction. A GUARD: the
	 * governing seam is `selfScopeDeclKinds`, which this slice did not touch, so it passes on the
	 * base branch too.
	 */
	public function testInlineHelperParameterShadowNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\tinline function use(item:String) trace(item);\n'
				+ '\t\tfor (s in xs) use(s);\n\t}\n}'
			).length
		);
	}

	/**
	 * A local declared INSIDE an inline helper's BLOCK body is still flagged. A GUARD: the operative
	 * scope is the helper's `BlockBody`, already a `scopeKinds` member before this slice, so the new
	 * frame is never the one consulted and the fixture passes on the base branch too.
	 */
	public function testUnusedLocalInsideInlineHelperFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f() {\n\t\tinline function h() {\n\t\t\tvar dead:Int = 1;\n\t\t\ttrace(2);\n\t\t}\n\t\th();\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'dead'"));
	}

	/**
	 * The reported shape: a name declared twice in ONE statement list. The second declaration is a
	 * second BINDING in effect from its own position on, so `return a` belongs to it and the first is
	 * dead — while the name still appears below, which is why a scan that counts the NAME reported
	 * nothing here before.
	 */
	public function testSameBlockRedeclarationFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f() {\n\t\tvar a = 1;\n\t\tvar a = 2;\n\t\treturn a;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('unused-local', vs[0].rule);
		Assert.isTrue(vs[0].message.contains("'a'"));
		Assert.isTrue(vs[0].message.contains('re-declared at 4:3'));
	}

	/** The autofix deletes the FIRST declaration; the second binding and its read stay. */
	public function testSameBlockRedeclarationFixDeletesFirst(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar a = 1;\n\t\tvar a = 2;\n\t\treturn a;\n\t}\n}';
		Assert.equals('class C {\n\tfunction f() {\n\t\tvar a = 2;\n\t\treturn a;\n\t}\n}', applyFix(src));
	}

	/**
	 * The second declaration's own INITIALIZER reads the FIRST binding — the one place this shape
	 * differs from a loop's, and the one that would turn a finding into a wrong deletion. Only the
	 * binder TOKEN is excluded, never the whole declaration, so `var a = a + 1` keeps the first alive.
	 */
	public function testRedeclarationInitializerReadKeepsDeclaration(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tvar a = 1;\n\t\tvar a = a + 1;\n\t\treturn a;\n\t}\n}').length);
	}

	/** A read BETWEEN the two declarations belongs to the first — the excluded region starts at the re-declaration. */
	public function testReadBeforeRedeclarationKeepsDeclaration(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f() {\n\t\tvar a = 1;\n\t\ttrace(a);\n\t\tvar a = 2;\n\t\treturn a;\n\t}\n}').length
		);
	}

	/**
	 * A declaration one level DOWN takes nothing over: it is scoped to the block it sits in, and the
	 * `return a` past that block reads the outer binding. Claiming it — which
	 * `topLevelDeclaredName`'s descent through single-child wrappers would do — makes the autofix
	 * delete a live declaration and leaves the read unbound.
	 */
	public function testNestedBlockRedeclarationKeepsDeclaration(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(c:Bool) {\n\t\tvar a = 1;\n\t\tif (c) {\n\t\t\tvar a = 2;\n\t\t\ttrace(a);\n\t\t}\n'
				+ '\t\treturn a;\n\t}\n}'
			).length
		);
	}

	/** Same refusal one construct over: a `switch` arm is a statement list of its own, not this block's. */
	public function testCaseArmRedeclarationKeepsDeclaration(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(x:Int) {\n\t\tvar a = 1;\n\t\tswitch x {\n\t\t\tcase 1:\n\t\t\t\tvar a = 2;\n'
				+ '\t\t\t\ttrace(a);\n\t\t\tcase _:\n\t\t}\n\t\treturn a;\n\t}\n}'
			).length
		);
	}

	/**
	 * A re-declaration on a conditional-compilation ARM claims nothing: its declarations are children
	 * of the region, not of the block, so the name is never seen as taking over — the same refusal
	 * `RefactorSupport.exclusiveBranchRedeclaration` makes for `rename` / `extract-method`, reached
	 * here through the direct-child rule rather than through a second model of it. In the
	 * configuration the arm is compiled out of, the first declaration is the only one there is.
	 */
	public function testConditionalArmRedeclarationKeepsDeclaration(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f() {\n\t\tvar a = 1;\n\t\t#if debug\n\t\tvar a = 2;\n\t\t#end\n\t\treturn a;\n\t}\n}').length
		);
	}

	/** A side-effecting initializer is reported but never cut — the deletion would drop the call with it. */
	public function testRedeclaredSideEffectingInitializerReportedNotFixed(): Void {
		final src: String =
			'class C {\n\tfunction f() {\n\t\tvar a = g();\n\t\tvar a = 2;\n\t\treturn a;\n\t}\n\n\tfunction g() return 5;\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'a'"));
		Assert.equals(src, applyFix(src));
	}

	/**
		 * Only the FIRST link of a chain is reported per pass: the scan spans the whole scope, so the
	earlier declaration's own binder token reads as an occurrence of the middle one and keeps it
	live. The `--fix` driver loops to a fixed point, and each pass promotes the next link to
	first — three passes clear this one.
	 */
	public function testChainedRedeclarationsCollapseOverPasses(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar a = 1;\n\t\tvar a = 2;\n\t\tvar a = 3;\n\t\treturn a;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f() {\n\t\tvar a = 3;\n\t\treturn a;\n\t}\n}', applyFix(applyFix(src)));
	}

	/**
	 * A read past the re-declaration written as a string interpolation belongs to the second binding
	 * like any other. The scan is textual, so it sees the `$a` the reference walker never surfaces —
	 * and the tail region has to cover it, or the finding is a property of how the read was spelled.
	 */
	public function testInterpolationPastRedeclarationFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f() {\n\t\tvar a = 1;\n\t\tvar a = 2;\n\t\ttrace(\'$$a\');\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('re-declared at 4:3'));
	}

	/**
	 * An INITIALIZER-LESS first declaration is not claimed. It carries no value of its own, so a
	 * WRITE is what would make it live — and a `@:build` macro that rewrites the whole statement list
	 * can supply one: Pony's `@:async` methods pre-declare `var err; var _;` ahead of an `@await`, and
	 * `com.dongxiguo.continuation` turns each bare declaration into a continuation step. Deleting one
	 * changes the generated CPS chain, and nothing in a source scan can see that.
	 */
	public function testInitializerlessDeclarationNotClaimed(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tvar a:Int;\n\t\tvar a:Int = 2;\n\t\treturn a;\n\t}\n}').length);
	}

	/**
	 * The MIRROR of the arm refusal, and it is NOT refused: the first declaration is guarded, the
	 * re-declaration is a direct child of the block. A direct child exists in EVERY configuration, so
	 * the guarded declaration is dead in the configuration that has it and absent in the rest — dead
	 * either way. The self-scoped half of the refinement IS suspended inside a `#if` region
	 * (`shadowedRegions` bails on `withinConditional`); this half deliberately is not, which is why
	 * the shape needs a fixture of its own rather than inheriting that gate's silence.
	 */
	public function testGuardedDeclarationRedeclaredOutsideFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f() {\n\t\t#if debug\n\t\tvar a = 1;\n\t\t#end\n\t\tvar a = 2;\n\t\treturn a;\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('re-declared at 6:3'));
	}

	private function violations(src: String): Array<Violation> {
		return new UnusedLocal().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new UnusedLocal(), src);
	}

}
