package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.UnusedLocal;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

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
			'class C {\n\tfunction f() {\n\t\tvar error:String;\n\t\ttry {\n\t\t\tg();\n\t\t} catch (error:String) {\n\t\t\ttrace(error);\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'error'"));
	}

	/** Nesting does not matter: the inner loop owns both of its occurrences. */
	public function testNestedLoopShadowFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f(rows:Array<Array<String>>) {\n\t\tvar item:String;\n\t\tfor (row in rows) for (item in row) trace(item);\n\t}\n}'
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
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\tfinal ys = #if debug [for (item in xs) item] #else [] #end;\n\t\treturn ys;\n\t}\n}'
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
				'class C {\n\tfunction f(m:Map<String, String>) {\n\t\tvar item:String = "a";\n\t\tfor (k => item in m) trace(k + item);\n\t\ttrace(item);\n\t}\n}'
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
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String = "a";\n\t\tfor (item in xs) trace(item);\n\t\ttrace(item);\n\t}\n}'
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
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\titem = "y";\n\t\ttrace(item);\n\t\tfor (item in xs) trace(item);\n\t}\n}'
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
		final src: String =
			'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar used:String = "u", item:String = "v";\n\t\tfor (item in xs) used += item;\n\t\ttrace(used);\n\t}\n}';
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
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\t#if debug\n\t\tvar item:String;\n\t\tfor (item in xs) trace(item);\n\t\t#end\n\t}\n}'
			).length
		);
	}

	/** The mirror refusal: the shadowing construct itself inside a conditional region claims no region. */
	public function testShadowingLoopInsideConditionalRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\t#if debug\n\t\tfor (item in xs) trace(item);\n\t\t#end\n\t}\n}'
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
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\t// item is described here\n\t\tfor (item in xs) trace(item);\n\t}\n}'
			).length
		);
	}

	/** So does a simple string interpolation after the loop — an `Ident` the reference walker never surfaces. */
	public function testInterpolationAfterLoopKeepsDeclaration(): Void {
		Assert.equals(
			0,
			violations(
				"class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String = \"z\";\n\t\tfor (item in xs) trace(item);\n\t\ttrace('$item');\n\t}\n}"
			).length
		);
	}

	/**
	 * A local `inline function` — the form this project's Haxe style prescribes for a local
	 * helper — joined `RefShape.scopeKinds`, which is the seam this check reads for its
	 * enclosing-scope span. The helper is NOT a self-scoped declaration, so its own name is
	 * neither a local declaration nor a shadowing region: the enclosing local it CAPTURES stays
	 * referenced, and the helper's own name never surfaces as a finding.
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
	 * lambda-parameter case above: a parameter is not in `selfScopeDeclKinds`, so the helper's
	 * body is not a region the second scan subtracts. The over-count is the safe direction.
	 */
	public function testInlineHelperParameterShadowNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(xs:Array<String>) {\n\t\tvar item:String;\n\t\tinline function use(item:String) trace(item);\n\t\tfor (s in xs) use(s);\n\t}\n}'
			).length
		);
	}

	/** A local declared INSIDE an inline helper's body is still flagged — the new frame does not hide it. */
	public function testUnusedLocalInsideInlineHelperFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f() {\n\t\tinline function h() {\n\t\t\tvar dead:Int = 1;\n\t\t\ttrace(2);\n\t\t}\n\t\th();\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'dead'"));
	}

	private function violations(src: String): Array<Violation> {
		return new UnusedLocal().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: UnusedLocal = new UnusedLocal();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
