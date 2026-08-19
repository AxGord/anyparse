package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferSwitchExpressionAssignment;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `prefer-switch-expression-assignment` check: a single mutable local declaration
 * immediately followed by a statement-position `switch` that assigns that local in every arm
 * is flagged `Info`, and `fix` collapses the pair to `final x:T = switch subj { … };`. The
 * `switch` twin of `prefer-if-expression-assignment` and the decl-pairing sibling of
 * `join-declaration-assignment`: an existing `case _:` / `default:` arm drops the initializer,
 * otherwise a `case _: <init>;` is synthesized from it; a bare decl with a non-exhaustive
 * switch, an impure initializer, a compound / `??=` arm, an external write, or a `#if` arm all
 * disqualify.
 */
class PreferSwitchExpressionAssignmentCheckTest extends Test {

	/** The trigger shape written INSIDE a `macro …` quotation, where the switch is AST the macro builds. */
	private static inline final QUOTED: String = 'class C {\n\tfunction f(x:Int, r:Int):Void {\n\t\tfinal e = macro {\n'
		+ '\t\t\tswitch x {\n\t\t\t\tcase 1: r = 1;\n\t\t\t\tcase 2: r = 2;\n\t\t\t\tcase _: r = 3;\n\t\t\t}\n\t\t};\n\t}\n}\n';

	/** The same shape quoted AND then written as real code — exactly one of the two is a finding. */
	private static inline final QUOTED_THEN_RUNTIME: String = 'class C {\n\tfunction f(x:Int, r:Int):Void {\n\t\tfinal e = macro {\n'
		+ '\t\t\tswitch x {\n\t\t\t\tcase 1: r = 1;\n\t\t\t\tcase 2: r = 2;\n\t\t\t\tcase _: r = 3;\n\t\t\t}\n\t\t};\n'
		+ '\t\tswitch x {\n\t\t\tcase 1: r = 1;\n\t\t\tcase 2: r = 2;\n\t\t\tcase _: r = 3;\n\t\t}\n\t}\n}\n';

	/** Collapsing a switch inside a REIFICATION subtree changes the statement tree the macro emits into an expression. */
	public function testMacroQuotationNotFlagged(): Void {
		Assert.equals(0, linted(QUOTED).length);
	}

	/** …and the skip is the quotation's SUBTREE, not everything that follows it. */
	public function testSwitchAfterMacroQuotationStillFlagged(): Void {
		CheckFixture.assertOnlyAfterQuotation(linted(QUOTED_THEN_RUNTIME), QUOTED_THEN_RUNTIME, 'switch');
	}

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(
			wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase 2: x = \'b\';\n\t\t}')
		);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-switch-expression-assignment', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this declaration and its following switch assignment can be a single switch-expression assignment', vs[0].message);
	}

	/** No source default arm, so the initializer becomes a synthesized `case _: <init>;`. */
	public function testFixAppendsDefaultFromInit(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase 2: x = \'b\';\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('final x:String = switch v { case 1: \'a\'; case 2: \'b\'; case _: \'\'; };', es[0].text);
	}

	/** An unguarded `case _:` arm makes the switch exhaustive, so the initializer is dropped. */
	public function testExistingWildcardDropsInit(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('var x:String = \'z\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase _: x = \'d\';\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('final x:String = switch v { case 1: \'a\'; case _: \'d\'; };', es[0].text);
	}

	/** A `default:` arm is a default too — initializer dropped, keyword preserved. */
	public function testExistingDefaultBranchDropsInit(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('var x:String = \'z\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tdefault: x = \'d\';\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('final x:String = switch v { case 1: \'a\'; default: \'d\'; };', es[0].text);
	}

	/** A bare `var x;` is collapsible when the switch already has a default (definite assignment holds). */
	public function testBareDeclWithDefaultFlagged(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('var x:String;\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase _: x = \'d\';\n\t\t}'));
		Assert.equals(1, es.length);
		Assert.equals('final x:String = switch v { case 1: \'a\'; case _: \'d\'; };', es[0].text);
	}

	/** A bare `var x;` with no default arm cannot synthesize one — not exhaustive, so not flagged. */
	public function testBareDeclNoDefaultNotFlagged(): Void {
		Assert.equals(
			0, violations(wrap('var x:String;\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase 2: x = \'b\';\n\t\t}')).length
		);
	}

	/** An impure initializer cannot move to (or be dropped from) the default path without losing its effect. */
	public function testImpureInitNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('var x:String = compute();\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase 2: x = \'b\';\n\t\t}')).length
		);
	}

	/** Even with an existing default (initializer dropped), an impure initializer's effect must not vanish. */
	public function testImpureInitWithDefaultNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('var x:String = compute();\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase _: x = \'d\';\n\t\t}')).length
		);
	}

	/** A compound `+=` arm is excluded — collapsing it can break per-branch type unification. */
	public function testCompoundOperatorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x:Int = 0;\n\t\tswitch v {\n\t\t\tcase 1: x += 1;\n\t\t\tcase _: x += 2;\n\t\t}')).length);
	}

	/** A short-circuit `??=` arm is excluded. */
	public function testNullCoalAssignNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: x ??= \'a\';\n\t\t\tcase _: x ??= \'d\';\n\t\t}')).length
		);
	}

	/** An arm assigning a different l-value disqualifies. */
	public function testDifferentLvalueNotFlagged(): Void {
		Assert.equals(
			0, violations(wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase _: y = \'d\';\n\t\t}')).length
		);
	}

	/**
	 * A field l-value (`obj.x = …`) is not the bare declared identifier, so the decl pair does not collapse; with no default the l-value arm does not fire either.
	 */
	public function testFieldLvalueNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: obj.x = \'a\';\n\t\t\tcase 2: obj.x = \'b\';\n\t\t}'))
				.length
		);
	}

	/** A multi-statement arm body is deliberately grouped, never collapsed. */
	public function testMultiStatementArmNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: { x = \'a\'; y = 2; }\n\t\t\tcase _: x = \'d\';\n\t\t}'))
				.length
		);
	}

	/** A non-assignment arm body disqualifies. */
	public function testNonAssignmentArmNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: trace(\'a\');\n\t\t\tcase _: x = \'d\';\n\t\t}')).length
		);
	}

	/** A subject reading `x` would become a self-reference in `x`'s own initializer after the collapse. */
	public function testSubjectReferencesXNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x:Int = 0;\n\t\tswitch x {\n\t\t\tcase 1: x = 5;\n\t\t\tcase _: x = 6;\n\t\t}')).length);
	}

	/** An arm value reading `x` becomes a rejected self-reference after the collapse. */
	public function testArmValueReferencesXNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x:Int = 0;\n\t\tswitch v {\n\t\t\tcase 1: x = x + 1;\n\t\t\tcase _: x = 2;\n\t\t}')).length);
	}

	/** A write to `x` after the switch means it is not final — cannot collapse. */
	public function testExternalWriteNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase _: x = \'d\';\n\t\t}\n\t\tx = \'later\';')
			).length
		);
	}

	/** A `#if`-guarded arm run projects as a `Conditional`, disqualifying the whole switch. */
	public function testConditionalArmNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\t#if debug\n\t\t\tcase 2: x = \'b\';\n\t\t\t#end\n\t\t\tcase _: x = \'d\';\n\t\t}'
			)).length
		);
	}

	/** A guard-carrying arm is fine when the body shape matches; the pattern and guard are copied verbatim. */
	public function testGuardedArmFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase n if (n > 0): x = \'a\';\n\t\t\tcase _: x = \'d\';\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('final x:String = switch v { case n if (n > 0): \'a\'; case _: \'d\'; };', es[0].text);
	}

	/** A braced single-statement arm body (`{ x = e; }`) is unwrapped to the value. */
	public function testBracedArmFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: { x = \'a\'; }\n\t\t\tcase _: { x = \'d\'; }\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('final x:String = switch v { case 1: \'a\'; case _: \'d\'; };', es[0].text);
	}

	/** A comma-alternative pattern (`case 1, 2:`) is copied verbatim into the header. */
	public function testCommaAltFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1, 2: x = \'a\';\n\t\t\tcase _: x = \'d\';\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('final x:String = switch v { case 1, 2: \'a\'; case _: \'d\'; };', es[0].text);
	}

	/** A parenthesized subject (`switch (v)`) collapses; the subject is copied without the parens. */
	public function testParenSwitchFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('var x:String = \'\';\n\t\tswitch (v) {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase _: x = \'d\';\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('final x:String = switch v { case 1: \'a\'; case _: \'d\'; };', es[0].text);
	}

	/**
	 * A statement between the declaration and the switch breaks adjacency, so the decl pair does not collapse; with no default the l-value arm does not fire either.
	 */
	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				wrap('var x:String = \'\';\n\t\ttrace(\'mid\');\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase 2: x = \'b\';\n\t\t}')
			).length
		);
	}

	/** The pair yields exactly ONE finding. */
	public function testFlaggedOnce(): Void {
		Assert.equals(
			1, violations(wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase 2: x = \'b\';\n\t\t}')).length
		);
	}

	/** End-to-end through the canonical writer: the emitted file holds the collapsed switch-expression assignment. */
	public function testFixOutputCollapsesPair(): Void {
		final out: String = applyFixOnce(
			wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase 2: x = \'b\';\n\t\t}')
		);
		Assert.isTrue(out.indexOf('final x:String = switch v {') != -1);
		Assert.isTrue(out.indexOf('case _: \'\';') != -1);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-switch-expression-assignment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-switch-expression-assignment'));
	}

	/** The driving case: a field-access l-value assigned in every arm hoists out of the switch. */
	public function testLvalueFieldFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap(
			'switch x {\n\t\t\tcase A: controlsHolder.y = 1;\n\t\t\tcase B: controlsHolder.y = 2;\n\t\t\tcase _: controlsHolder.y = 0;\n'
			+ '\t\t}'
		));
		Assert.equals(1, es.length);
		Assert.equals('controlsHolder.y = switch x { case A: 1; case B: 2; case _: 0; };', es[0].text);
	}

	/** The l-value arm reports its own message and `Info` severity. */
	public function testLvalueMessage(): Void {
		final vs: Array<Violation> =
			violations(wrap('switch x {\n\t\t\tcase 1: controlsHolder.y = 1;\n\t\t\tcase _: controlsHolder.y = 0;\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this switch that assigns the same l-value in every arm can be a single switch-expression assignment', vs[0].message);
	}

	/** A standalone switch with no default arm cannot synthesize one — not exhaustive, so not flagged. */
	public function testLvalueNoDefaultNotFlagged(): Void {
		Assert.equals(0, violations(wrap('switch v {\n\t\t\tcase 1: obj.y = 1;\n\t\t\tcase 2: obj.y = 2;\n\t\t}')).length);
	}

	/** A plain-identifier l-value with no adjacent declaration collapses; the prior statement stays. */
	public function testLvaluePlainIdentFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('existing = 5;\n\t\tswitch v {\n\t\t\tcase 1: existing = 1;\n\t\t\tcase _: existing = 0;\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('existing = switch v { case 1: 1; case _: 0; };', es[0].text);
	}

	/** With an adjacent matching declaration the decl-pairing arm keeps priority (one decl-form fix). */
	public function testLvalueDeclPriority(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase _: x = \'d\';\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('final x:String = switch v { case 1: \'a\'; case _: \'d\'; };', es[0].text);
	}

	/** A field l-value whose receiver is an impure call is skipped (the receiver would reorder). */
	public function testLvalueImpureReceiverNotFlagged(): Void {
		Assert.equals(0, violations(wrap('switch v {\n\t\t\tcase 1: obj().y = 1;\n\t\t\tcase _: obj().y = 0;\n\t\t}')).length);
	}

	/** A subject reading the l-value receiver is order-sensitive with it after the collapse — skipped. */
	public function testLvalueSubjectReferencesReceiverNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('switch controlsHolder {\n\t\t\tcase 1: controlsHolder.y = 1;\n\t\t\tcase _: controlsHolder.y = 0;\n\t\t}'))
				.length
		);
	}

	/** A multi-segment receiver (`a.b.c`) carries an unprovable field read — conservatively skipped. */
	public function testLvalueDeepPathNotFlagged(): Void {
		Assert.equals(0, violations(wrap('switch v {\n\t\t\tcase 1: a.b.c = 1;\n\t\t\tcase _: a.b.c = 0;\n\t\t}')).length);
	}

	/** A guard-carrying arm is fine; the pattern and guard are copied verbatim into the header. */
	public function testLvalueGuardedArmFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('switch v {\n\t\t\tcase n if (n > 0): obj.y = 1;\n\t\t\tcase _: obj.y = 0;\n\t\t}'));
		Assert.equals(1, es.length);
		Assert.equals('obj.y = switch v { case n if (n > 0): 1; case _: 0; };', es[0].text);
	}

	/** A `this.field` l-value collapses — the receiver `this` is side-effect-free. */
	public function testLvalueThisFieldFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('switch v {\n\t\t\tcase 1: this.y = 1;\n\t\t\tcase _: this.y = 0;\n\t\t}'));
		Assert.equals(1, es.length);
		Assert.equals('this.y = switch v { case 1: 1; case _: 0; };', es[0].text);
	}

	/** Arms disagreeing on the l-value disqualify. */
	public function testLvalueDifferentLvalueNotFlagged(): Void {
		Assert.equals(0, violations(wrap('switch v {\n\t\t\tcase 1: obj.y = 1;\n\t\t\tcase _: obj.z = 0;\n\t\t}')).length);
	}

	/** A compound `+=` arm is excluded on the l-value arm too. */
	public function testLvalueCompoundNotFlagged(): Void {
		Assert.equals(0, violations(wrap('switch v {\n\t\t\tcase 1: obj.y += 1;\n\t\t\tcase _: obj.y += 2;\n\t\t}')).length);
	}

	/** A `#if`-guarded arm run projects as a `Conditional`, disqualifying the l-value switch. */
	public function testLvalueConditionalArmNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'switch v {\n\t\t\tcase 1: obj.y = 1;\n\t\t\t#if debug\n\t\t\tcase 2: obj.y = 2;\n\t\t\t#end\n\t\t\tcase _: obj.y = 0;\n\t\t}'
			)).length
		);
	}

	/** An index-access l-value (`a[i]`) is neither an identifier nor a field path — skipped. */
	public function testLvalueArrayAccessNotFlagged(): Void {
		Assert.equals(0, violations(wrap('switch v {\n\t\t\tcase 1: a[i] = 1;\n\t\t\tcase _: a[i] = 0;\n\t\t}')).length);
	}

	/** A multi-statement arm body is never collapsed on the l-value arm. */
	public function testLvalueMultiStatementArmNotFlagged(): Void {
		Assert.equals(0, violations(wrap('switch v {\n\t\t\tcase 1: { obj.y = 1; z = 2; }\n\t\t\tcase _: obj.y = 0;\n\t\t}')).length);
	}

	/** End-to-end through the canonical writer: the field l-value assignment is hoisted. */
	public function testLvalueFixOutputCollapses(): Void {
		final out: String = applyFixOnce(
			wrap('switch v {\n\t\t\tcase 1: controlsHolder.y = 1;\n\t\t\tcase _: controlsHolder.y = 0;\n\t\t}')
		);
		Assert.isTrue(out.indexOf('controlsHolder.y = switch v {') != -1);
	}

	/** A plain-ident switch whose declaration is NOT adjacent (a statement between) is an l-value-arm match — the decl-pairing needs adjacency, the l-value arm does not. */
	public function testLvalueNonAdjacentIdentFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('var x:String = \'\';\n\t\ttrace(\'mid\');\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase _: x = \'d\';\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('x = switch v { case 1: \'a\'; case _: \'d\'; };', es[0].text);
	}

	/**
	 * The recursive case: a `switch` whose arm is an `if`/`else` that itself ends in a nested `switch`,
	 * all assigning the same l-value, hoists in one shot to a switch-expression whose arm value is the
	 * nested if-expression / switch-expression tree.
	 */
	public function testNestedSwitchInIfInSwitchFixed(): Void {
		final src: String = wrap(
			'switch outer {\n\t\t\tcase A:\n\t\t\t\tif (c) x = 1;\n\t\t\t\telse switch inner {\n\t\t\t\t\tcase P: x = 2;\n'
			+ '\t\t\t\t\tcase _: x = 3;\n\t\t\t\t}\n\t\t\tcase _: x = 0;\n\t\t}'
		);
		Assert.equals(1, violations(src).length);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		// The nested switch terminates itself: `} case _:` is valid Haxe (compiled on -cpp and run on
		// --interp with a further case following), and the `;` the builder used to append here was
		// stranded on its own line by the writer.
		Assert.equals('x = switch outer { case A: if (c) 1 else switch inner { case P: 2; case _: 3; } case _: 0; };', es[0].text);
	}

	/** A switch arm holding a 2-branch `if`/`else` (both plain, same l-value) hoists the `if` to an if-expression value. */
	public function testNestedIfInSwitchArmFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('switch v {\n\t\t\tcase A: if (c) x = 1; else x = 2;\n\t\t\tcase _: x = 0;\n\t\t}'));
		Assert.equals(1, es.length);
		Assert.equals('x = switch v { case A: if (c) 1 else 2; case _: 0; };', es[0].text);
	}

	/** A nested arm whose branches disagree on the l-value disqualifies the whole tree. */
	public function testNestedMixedLvalueNotFlagged(): Void {
		Assert.equals(0, violations(wrap('switch v {\n\t\t\tcase A: if (c) x = 1; else y = 2;\n\t\t\tcase _: x = 0;\n\t\t}')).length);
	}

	/** The decl-pairing arm gains the same recursion: a nested `if` arm value collapses to `final x = switch … { case A: if (c) a else b; … };`. */
	public function testDeclArmNestedIfFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('var x:Int = 0;\n\t\tswitch v {\n\t\t\tcase A: if (c) x = 1; else x = 2;\n\t\t\tcase _: x = 3;\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('final x:Int = switch v { case A: if (c) 1 else 2; case _: 3; };', es[0].text);
	}

	/** A nested arm reading the declared local (`if (x > 0) …`) is a self-reference after the decl collapse — skipped. */
	public function testDeclArmNestedSelfReferenceNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('var x:Int = 0;\n\t\tswitch v {\n\t\t\tcase A: if (x > 0) x = 1; else x = 2;\n\t\t\tcase _: x = 3;\n\t\t}'))
				.length
		);
	}

	/**
	 * A nested if-chain arm whose NON-TERMINAL branch value ends in an else-less `if` is refused:
	 * the arm's built value would be `if (e) if (q) 2 else 5`, where the ` else ` the hoist emits
	 * after the first branch re-parents onto `if (q)` and the `!e` path stops yielding a value.
	 * The arm nesting runs through `AssignmentTreeHoist.ifChainValue`, so the if-rule's gate covers
	 * this rule for free.
	 */
	public function testElseLessConditionalInNestedIfArmNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:Int;\n\t\tswitch v {\n\t\t\tcase 1: if (e) {\n\t\t\t\tx = if (q) 2;\n\t\t\t} else {\n\t\t\t\tx = 5;\n\t\t\t}\n\t\t\tcase _: x = 9;\n\t\t}'
			)).length
		);
	}

	/**
	 * An arm whose r-value is an else-less conditional at its ROOT is refused: the parser folds the
	 * statement's own `;` into it, so the arm would be emitted as ` case 1: if (q) 2;;`, which
	 * anyparse re-parses but Haxe rejects. The gate sits in `AssignmentTreeHoist.unitValue` — the
	 * single point a leaf r-value becomes emitted text — so this rule inherits it from the if-rule
	 * work rather than carrying its own copy.
	 */
	public function testElseLessConditionalAtArmRootNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x:Int;\n\t\tswitch v {\n\t\t\tcase 1: x = if (q) 2;\n\t\t\tcase _: x = 9;\n\t\t}')).length);
	}

	/**
	 * An empty `case _:` borrows the paired declaration's PURE-literal initializer as its own
	 * value, exactly the shape `writtenOnlyByArms` still validates: the target holds that literal
	 * at the switch (adjacency + no other writes), so an empty arm evaluates to the same value it
	 * would already have held.
	 */
	public function testEmptyDefaultArmBorrowsInit(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase _:\n\t\t}'));
		Assert.equals(1, es.length);
		Assert.equals('final x:String = switch v { case 1: \'a\'; case _: \'\'; };', es[0].text);
	}

	/** An empty `default:` arm borrows the initializer just like an empty wildcard `case _:`. */
	public function testEmptyDefaultBranchBorrowsInit(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('var x:String = \'\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tdefault:\n\t\t}'));
		Assert.equals(1, es.length);
		Assert.equals('final x:String = switch v { case 1: \'a\'; default: \'\'; };', es[0].text);
	}

	/** A bare `var x;` has no initializer to lend an empty default arm — still not exhaustive. */
	public function testEmptyDefaultArmNoInitNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x:String;\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase _:\n\t\t}')).length);
	}

	/** An impure initializer must not be duplicated into the borrowed default arm either. */
	public function testEmptyDefaultArmImpureInitNotFlagged(): Void {
		Assert.equals(
			0, violations(wrap('var x:String = compute();\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase _:\n\t\t}')).length
		);
	}

	/** A write to `x` between the declaration and the switch means the empty arm's borrowed value would be wrong — refused. */
	public function testEmptyDefaultArmInterveningWriteNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('var x:String = \'\';\n\t\tx = \'mid\';\n\t\tswitch v {\n\t\t\tcase 1: x = \'a\';\n\t\t\tcase _:\n\t\t}'))
				.length
		);
	}

	/**
	 * A standalone switch (the l-value arm, consumer 3) has no paired declaration to lend an empty
	 * default arm a value — the opt-in fallback is NOT threaded to this caller, so it keeps
	 * refusing exactly as before the slice.
	 */
	public function testLvalueEmptyDefaultArmNotFlagged(): Void {
		Assert.equals(0, violations(wrap('switch v {\n\t\t\tcase 1: obj.y = 1;\n\t\t\tcase _:\n\t\t}')).length);
	}

	/**
	 * A nested switch arm (consumer 1, `switchValue`) has no initializer to synthesize either — an
	 * empty default arm inside it must still refuse the whole nested-switch value.
	 */
	public function testNestedSwitchEmptyDefaultArmNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:Int = 0;\n\t\tswitch v {\n\t\t\tcase A: switch inner {\n\t\t\t\tcase P: x = 1;\n\t\t\t\tcase _:\n\t\t\t}\n'
				+ '\t\t\tcase _: x = 2;\n\t\t}'
			)).length
		);
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}


	private function violations(src: String): Array<Violation> {
		return new PreferSwitchExpressionAssignment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/**
	 * The same findings THROUGH THE LINTER — the altitude the central reification gate lives at
	 * (`Linter.run`), so a quoted finding is dropped here and not by the check itself.
	 */
	private function linted(src: String): Array<Violation> {
		return Linter.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin(), [new PreferSwitchExpressionAssignment()]);
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferSwitchExpressionAssignment = new PreferSwitchExpressionAssignment();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}


	/**
	 * An arm whose value is itself a `switch` needs no `;`: the nested `}` already terminates it, and
	 * the writer strands the redundant token on a line of its own. Valid Haxe either way — a probe with
	 * a further `case` after the brace-terminated arm compiles and runs — so the token buys nothing.
	 */
	public function testNestedSwitchArmValueTakesNoRedundantSemicolon(): Void {
		final out: String = applyFixOnce(wrap(
			'var r = 0;\n\t\tswitch (a) {\n\t\t\tcase 1:\n\t\t\t\tswitch (b) {\n\t\t\t\t\tcase 2: r = 20;\n'
			+ '\t\t\t\t\tcase _: r = 30;\n\t\t\t\t}\n\t\t\tcase _: r = 40;\n\t\t}'
		));
		Assert.isTrue(out.indexOf('}\n\t\t\t\t;') == -1, 'no stranded `;` after a nested switch arm - got:\n$out');
		Assert.isTrue(out.indexOf('case _: 40;') != -1, 'a plain arm value keeps its `;` - got:\n$out');
	}

}
