package unit;

import anyparse.check.Check;
import anyparse.check.CollapseNestedSwitch;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `collapse-nested-switch` check: an outer `case P(b):` whose body is EXACTLY one
 * `switch b { … }` on that binder is flagged `Info`, and the fix splices each inner arm
 * into the outer pattern's binder slot — `case P(Q_i): body_i`.
 *
 * The rewrite is NOT universally equivalent, and every gate below defends one way the
 * difference shows. A value that matched `P(...)` but matched no inner arm used to fall
 * out of the inner switch with the outer arm CONSUMED; after the collapse it resumes
 * matching at the outer switch's later arms. The coverage gate closes that, either by
 * emitting the inner catch-all as an explicit `case P(_)` backstop or by proving every
 * later outer arm is empty and one of them a catch-all. The rest of the fixtures come in
 * pairs: the shape that collapses, and the neighbouring shape that must not.
 */
class CollapseNestedSwitchCheckTest extends Test {

	/** The line break + indent before an INNER case label in a `nest()` fixture. */
	private static inline final INNER_LABEL: String = '\n\t\t\t\t\t';

	/** An unguarded, EMPTY outer arm after the collapsible one — the tail that makes a merge harmless. */
	private static inline final EMPTY_TAIL: String = '\n\t\t\tcase _:';

	/** An outer arm that ACTS, so falling out of the collapsed run would newly run it. */
	private static inline final ACTING_TAIL: String = '\n\t\t\tcase _: z();';

	/** A later outer arm whose EXTRACTOR pattern RUNS code while matching — reaching it would call `tap`. */
	private static inline final EXTRACTOR_TAIL: String = '\n\t\t\tcase tap(_) => P(Q):';

	public function testCanaryShapeFlagged(): Void {
		final vs: Array<Violation> = violations(canary());
		Assert.equals(1, vs.length);
		Assert.equals('collapse-nested-switch', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this case body is a switch on its own binder; collapse it into a deep pattern', vs[0].message);
	}

	/** The canary collapses to two deep arms, and the EMPTY inner wildcard merges into the outer one. */
	public function testCanaryCollapsesWithMergedWildcard(): Void {
		final out: String = applyFixOnce(canary());
		Assert.stringContains('case EConst(CString(s, kind)): tKey = s;', out);
		Assert.stringContains('case EConst(CInt(i)): tKey = i;', out);
		Assert.isFalse(out.contains('switch c'), 'the nested switch is gone');
		Assert.equals(1, occurrences(out, 'case _:'), 'the inner wildcard merged into the outer one');
	}

	/** One inner arm needs no inner catch-all: the empty outer tail is what makes the fall-through harmless. */
	public function testSingleInnerArmCollapses(): Void {
		final src: String = sw(nest('P(b)', 'b', 'case Q: p();') + EMPTY_TAIL);
		Assert.equals(1, violations(src).length);
		Assert.stringContains('case P(Q): p();', applyFixOnce(src));
	}

	/** A NON-empty inner wildcard is never merged away — it becomes the explicit backstop arm. */
	public function testNonEmptyInnerWildcardEmittedAsExplicitArm(): Void {
		final src: String = sw(nest('P(b)', 'b', 'case Q: p();${INNER_LABEL}case _: r();') + EMPTY_TAIL);
		final out: String = applyFixOnce(src);
		Assert.stringContains('case P(Q): p();', out);
		Assert.stringContains('case P(_): r();', out);
	}

	/** The backstop arm covers everything the outer pattern did, so a later outer arm that ACTS is no obstacle. */
	public function testNonEmptyInnerWildcardEmittedWithActingLaterArm(): Void {
		final src: String = sw(nest('P(b)', 'b', 'case Q: p();${INNER_LABEL}case _: r();') + ACTING_TAIL);
		Assert.equals(1, violations(src).length);
		Assert.stringContains('case P(_): r();', applyFixOnce(src));
	}

	/** An EMPTY inner wildcard merges only when the fall-through is harmless; an acting later arm forces it to be EMITTED. */
	public function testEmptyInnerWildcardEmittedWhenLaterOuterArmActs(): Void {
		final src: String = sw(nest('P(b)', 'b', 'case Q: p();${INNER_LABEL}case _:') + ACTING_TAIL);
		final out: String = applyFixOnce(src);
		Assert.stringContains('case P(Q): p();', out);
		Assert.stringContains('case P(_):', out);
	}

	/** Only the switched slot substitutes; the other binder keeps its text and stays usable in the body. */
	public function testMultiBinderPatternSubstitutesOnlySwitchedSlot(): Void {
		final src: String = sw(nest('P(a, b)', 'b', 'case Q: use(a);${INNER_LABEL}case _:') + EMPTY_TAIL);
		Assert.equals(1, violations(src).length);
		Assert.stringContains('case P(a, Q): use(a);', applyFixOnce(src));
	}

	/** An inner multi-pattern arm splices once per pattern, each into its own copy of the outer slot. */
	public function testInnerMultiPatternArmSplicesEachPattern(): Void {
		final src: String = sw(nest('P(b)', 'b', 'case A, B: p();${INNER_LABEL}case _:') + EMPTY_TAIL);
		Assert.stringContains('case P(A), P(B): p();', applyFixOnce(src));
	}

	/** A null-matching arm must survive the splice — losing it turns a handled null into a crash. */
	public function testInnerNullArmSurvives(): Void {
		final src: String = sw(nest('P(b)', 'b', 'case null: n();${INNER_LABEL}case _:') + EMPTY_TAIL);
		Assert.stringContains('case P(null): n();', applyFixOnce(src));
	}

	/** An inner guard carries over verbatim: a failing guard falls to the next spliced arm, and the backstop ends the run. */
	public function testInnerGuardCarriedOverVerbatim(): Void {
		final src: String = sw(nest('P(b)', 'b', 'case Q if (g): p();${INNER_LABEL}case _: r();') + EMPTY_TAIL);
		Assert.equals(1, violations(src).length);
		final out: String = applyFixOnce(src);
		Assert.stringContains('case P(Q) if (g): p();', out);
		Assert.stringContains('case P(_): r();', out);
	}

	/** A catch-all in a NON-final position is never merged — merging it would revive the arms it makes unreachable. */
	public function testNonFinalInnerCatchAllEmitted(): Void {
		final src: String = sw(nest('P(b)', 'b', 'case _: r();${INNER_LABEL}case Q: p();') + EMPTY_TAIL);
		final out: String = applyFixOnce(src);
		Assert.stringContains('case P(_): r();', out);
		Assert.stringContains('case P(Q): p();', out);
	}

	/**
	 * An outer GUARD sits between the pattern run and the body, a slot the spliced label has no
	 * room for. Jointly enforced: a guarded arm's children are [pattern, guard, body…], which the
	 * exactly-two-children gate refuses as well — no fixture can separate the two.
	 */
	public function testGuardedOuterArmNotFlagged(): Void {
		Assert.equals(0, violations(sw(nest('P(b) if (g)', 'b', 'case Q: p();${INNER_LABEL}case _:') + EMPTY_TAIL)).length);
	}

	/**
	 * Two outer patterns give two slots to substitute, and only one binder is switched on. The
	 * second pattern deliberately does NOT mention the binder: an `R(b)` would be refused by the
	 * isolation gate as well. Jointly enforced all the same: a two-pattern arm carrying a body
	 * holds THREE children, which the exactly-two-children gate refuses too.
	 */
	public function testTwoOuterPatternsNotFlagged(): Void {
		Assert.equals(0, violations(sw(nest('P(b), R(x)', 'b', 'case Q: p();${INNER_LABEL}case _:') + EMPTY_TAIL)).length);
	}

	/** The binder read in an inner BODY would be left unbound: the deep pattern replaces it with the inner pattern. */
	public function testBinderReadInInnerBodyNotFlagged(): Void {
		Assert.equals(0, violations(sw(nest('P(b)', 'b', 'case Q: p(b);${INNER_LABEL}case _:') + EMPTY_TAIL)).length);
	}

	/** A `'$b'` read is a string-interpolation identifier, not an ordinary one — missing it would strand the read. */
	public function testBinderReadThroughInterpolationNotFlagged(): Void {
		final arms: String = 'case Q: t = \'$$b\';${INNER_LABEL}case _:';
		Assert.equals(0, violations(sw(nest('P(b)', 'b', arms) + EMPTY_TAIL)).length);
	}

	/** A `case var b:` deeper in the arm re-binds the name, so the two mentions the isolation gate demands are three. */
	public function testBinderReboundByCaptureNotFlagged(): Void {
		final arms: String = 'case Q: switch y { case var b: g(); }${INNER_LABEL}case _:';
		Assert.equals(0, violations(sw(nest('P(b)', 'b', arms) + EMPTY_TAIL)).length);
	}

	/**
	 * A whole-pattern `=`-capture puts the binder's name where only a NAME may stand, so the
	 * splice would emit `case Q = P(x)`. The isolation gate cannot catch this: a capture spells
	 * its bound name with an ordinary identifier, which is exactly the one in-pattern mention
	 * that gate demands, so the fixture reaches — and discriminates — the capture gate.
	 */
	public function testOuterCaptureWholePatternNotFlagged(): Void {
		Assert.equals(0, violations(sw(nest('b = P(x)', 'b', 'case Q: p();${INNER_LABEL}case _:') + EMPTY_TAIL)).length);
	}

	/** The same capture one level down: `case P(b = Q)` would splice to `case P(R = Q)`. */
	public function testOuterCapturedSlotNotFlagged(): Void {
		Assert.equals(0, violations(sw(nest('P(b = Q)', 'b', 'case R: p();${INNER_LABEL}case _:') + EMPTY_TAIL)).length);
	}

	/**
	 * An inner pattern that re-binds a name the outer pattern binds in ANOTHER slot only
	 * SHADOWED it while nested; spliced, both land in one pattern and Haxe rejects
	 * `case P(a, Q(a))` with `Variable a is bound multiple times`. Every earlier gate passes —
	 * `b` is still mentioned exactly twice — so the freshness gate is what refuses it.
	 */
	public function testInnerPatternRebindingOuterSlotNotFlagged(): Void {
		final arms: String = 'case Q(a): use(a);${INNER_LABEL}case _:';
		Assert.equals(0, violations(sw(nest('P(a, b)', 'b', arms) + EMPTY_TAIL)).length);
	}

	/**
	 * A block-wrapped nested switch is `unnecessary-block`'s job first; the two compose across
	 * `--fix` passes. Jointly enforced: the block is not a switch kind, and it also holds fewer
	 * children than a switch's subject-plus-one-arm minimum.
	 */
	public function testBlockWrappedInnerSwitchNotFlagged(): Void {
		final arm: String = 'case P(b): {\n\t\t\t\tswitch b {${INNER_LABEL}case Q: p();${INNER_LABEL}case _:\n\t\t\t\t}\n\t\t\t}';
		Assert.equals(0, violations(sw(arm + EMPTY_TAIL)).length);
	}

	/**
	 * A second statement in the arm is code the collapsed label has nowhere to put — here it
	 * PRECEDES the nested switch, so dropping it would be a silent loss. Jointly enforced: the
	 * arm then holds three children, and its second child is not a switch either.
	 */
	public function testTwoBodyStatementsNotFlagged(): Void {
		final arm: String = nestWith('P(b)', ' p();\n\t\t\t\t', 'b', 'case Q: q();${INNER_LABEL}case _:');
		Assert.equals(0, violations(sw(arm + EMPTY_TAIL)).length);
	}

	/**
	 * An inner `default:` carries no pattern to splice into the outer slot. Jointly enforced: it
	 * is not a case branch, and it also opens with no pattern for the arm decomposition to read.
	 */
	public function testInnerDefaultArmNotFlagged(): Void {
		Assert.equals(0, violations(sw(nest('P(b)', 'b', 'case Q: p();${INNER_LABEL}default: r();') + EMPTY_TAIL)).length);
	}

	/** A capitalised bare identifier is a CONSTRUCTOR reference, not a capture binder — its slot must not be substituted. */
	public function testCapitalisedBinderNotFlagged(): Void {
		Assert.equals(0, violations(sw(nest('P(CONST)', 'CONST', 'case Q: p();${INNER_LABEL}case _:') + EMPTY_TAIL)).length);
	}

	/** With no inner catch-all a value can fall out of the collapsed run, so a later outer arm that ACTS is a behaviour change. */
	public function testNoInnerCatchAllWithActingLaterArmNotFlagged(): Void {
		Assert.equals(0, violations(sw(nest('P(b)', 'b', 'case Q: p();') + ACTING_TAIL)).length);
	}

	/** With no inner catch-all and NO later arm at all, the fall-through has nothing harmless to land on. */
	public function testNoInnerCatchAllWithNoLaterArmNotFlagged(): Void {
		Assert.equals(0, violations(sw(nest('P(b)', 'b', 'case Q: p();'))).length);
	}

	/**
	 * An EXTRACTOR runs code while MATCHING, so a later outer arm carrying one is not a harmless
	 * landing place even with an empty body: reaching it for the first time would call `tap`.
	 * The empty inner wildcard is therefore EMITTED as the backstop rather than merged away,
	 * which leaves the extractor arm exactly as unreachable as it was.
	 */
	public function testExtractorInLaterOuterArmForcesBackstop(): Void {
		final src: String = sw(nest('P(b)', 'b', 'case Q: p();${INNER_LABEL}case _:') + EXTRACTOR_TAIL + EMPTY_TAIL);
		Assert.equals(1, violations(src).length);
		Assert.stringContains('case P(_):', applyFixOnce(src));
	}

	/**
	 * A comment between the label and the nested switch sits in a region the emitted run drops.
	 * Jointly enforced: the label gap must be the bare terminator, and the captured terminator is
	 * also what each inner arm's own label must match — a comment breaks both.
	 */
	public function testCommentBeforeInnerSwitchNotFlagged(): Void {
		final arm: String = nestWith('P(b)', ' // note\n\t\t\t\t', 'b', 'case Q: p();${INNER_LABEL}case _:');
		Assert.equals(0, violations(sw(arm + EMPTY_TAIL)).length);
	}

	/** A comment between two inner arms sits in a gap the emitted run drops. */
	public function testCommentBetweenInnerArmsNotFlagged(): Void {
		final arms: String = 'case Q: p();${INNER_LABEL}// note${INNER_LABEL}case _:';
		Assert.equals(0, violations(sw(nest('P(b)', 'b', arms) + EMPTY_TAIL)).length);
	}

	/** A comment in the outer pattern's PREFIX would be DUPLICATED once per spliced arm, not merely moved. */
	public function testCommentInOuterPatternNotFlagged(): Void {
		Assert.equals(0, violations(sw(nest('P(/* x */ b)', 'b', 'case Q: p();${INNER_LABEL}case _:') + EMPTY_TAIL)).length);
	}

	/** A conditional-compilation region inside the arm holds code this scan cannot enumerate. */
	public function testConditionalCompilationInArmNotFlagged(): Void {
		final arms: String = 'case Q:${INNER_LABEL}#if js${INNER_LABEL}p();${INNER_LABEL}#end${INNER_LABEL}case _:';
		Assert.equals(0, violations(sw(nest('P(b)', 'b', arms) + EMPTY_TAIL)).length);
	}

	/** A reification nested INSIDE the arm may splice in references this scan cannot see. */
	public function testReificationInsideArmNotFlagged(): Void {
		final arms: String = 'case Q: g(macro foo);${INNER_LABEL}case _:';
		Assert.equals(0, violations(sw(nest('P(b)', 'b', arms) + EMPTY_TAIL)).length);
	}

	/**
	 * The mirror direction: an arm written INSIDE `macro { … }` is out of reach entirely, since a
	 * splice there can carry a read of the binder that no source scan resolves. Both anyparse's own
	 * matches for this rule were of exactly this shape.
	 */
	public function testArmInsideReificationNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\treturn macro {\n\t\t\tswitch v {\n\t\t\t\tcase P(b):\n'
			+ "\t\t\t\t\tswitch b {\n\t\t\t\t\t\tcase Q: $e;\n\t\t\t\t\t\tcase _:\n\t\t\t\t\t}\n\t\t\t\tcase _:\n\t\t\t}\n\t\t};\n\t}\n}";
		Assert.equals(0, violations(src).length);
	}

	/** An expression switch's arms must all yield a value, so its empty later arms can never make a merge harmless. */
	public function testExpressionSwitchInnerWildcardNotMerged(): Void {
		final src: String = swExpr(nest('P(b)', 'b', 'case Q: p();${INNER_LABEL}case _:') + EMPTY_TAIL);
		Assert.equals(1, violations(src).length);
		Assert.stringContains('case P(_):', applyFixOnce(src));
	}

	/** The same expression switch with NO inner catch-all has no sound outer fall-through to lean on. */
	public function testExpressionSwitchWithoutInnerCatchAllNotFlagged(): Void {
		Assert.equals(0, violations(swExpr(nest('P(b)', 'b', 'case Q: p();') + EMPTY_TAIL)).length);
	}

	public function testRegisteredInBuiltinsAsDefaultOff(): Void {
		Assert.notNull(Linter.byId('collapse-nested-switch'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('collapse-nested-switch'));
		final registered: Null<Check> = Linter.byId('collapse-nested-switch');
		Assert.isTrue(registered is DefaultOff, 'pattern depth is a project style call, so the rule is opt-in');
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/** The `macros/Lang.hx` shape this check was written for: two constant arms under an empty inner wildcard. */
	private function canary(): String {
		final arms: String = 'case CString(s, kind): tKey = s;${INNER_LABEL}case CInt(i): tKey = i;${INNER_LABEL}case _:';
		return sw(nest('EConst(c)', 'c', arms) + EMPTY_TAIL);
	}

	/** Wrap switch `branches` in a minimal parseable class + method; an outer case label lands at three tabs. */
	private function sw(branches: String): String {
		return 'class C {\n\tfunction f(s: String): Void {\n\t\tswitch s {\n\t\t\t$branches\n\t\t}\n\t}\n}';
	}

	/** `sw()` with the outer switch in EXPRESSION position, where every arm must yield a value. */
	private function swExpr(branches: String): String {
		return 'class C {\n\tfunction f(s: String): Void {\n\t\tfinal v = switch s {\n\t\t\t$branches\n\t\t};\n\t}\n}';
	}

	/** An outer arm labelled `case <label>:` whose ONLY statement is `switch <binder> { <arms> }`. */
	private function nest(label: String, binder: String, arms: String): String {
		return nestWith(label, '\n\t\t\t\t', binder, arms);
	}

	/** `nest()` with an explicit `gap` between the label's `:` and the nested `switch`. */
	private function nestWith(label: String, gap: String, binder: String, arms: String): String {
		return 'case $label:${gap}switch $binder {${INNER_LABEL}$arms\n\t\t\t\t}';
	}

	private function occurrences(text: String, needle: String): Int {
		var count: Int = 0;
		var at: Int = text.indexOf(needle);
		while (at != -1) {
			count++;
			at = text.indexOf(needle, at + needle.length);
		}
		return count;
	}

	private function violations(src: String): Array<Violation> {
		return new CollapseNestedSwitch().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixEdits(src: String): Array<{ span: Span, text: String }> {
		final check: CollapseNestedSwitch = new CollapseNestedSwitch();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer, `reformat` on so the minimal fixture need not be canonical. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, fixEdits(src), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
