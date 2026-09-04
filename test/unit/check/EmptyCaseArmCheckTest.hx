package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.EmptyCaseArm;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `empty-case-arm` check: the LAST arm of a statement switch, empty, over a subject the
 * compiler never exhaustiveness-checks, with no catch-all anywhere in the switch.
 *
 * Every refusal fixture is a MINIMAL PAIR of a firing one — it differs by exactly the feature
 * its gate names, so it can only pass because of that gate. The subject-type gate is pinned by
 * fixtures with byte-identical branches and a different parameter TYPE; the position gate by
 * moving the SAME empty arm off the end; the catch-all gate by adding one arm above it.
 */
class EmptyCaseArmCheckTest extends Test {

	private static inline final MESSAGE: String =
		'this trailing empty case arm matches values and does nothing — the switch has no catch-all, so deleting it changes nothing';

	/** The firing shape every refusal fixture is a minimal pair of. */
	private static inline final FIRING_BRANCHES: String = 'case 1: t();\n\t\t\tcase 2, 3:';

	public function testTrailingEmptyArmFlagged(): Void {
		final vs: Array<Violation> = violations(sw('Int', FIRING_BRANCHES));
		Assert.equals(1, vs.length);
		Assert.equals('empty-case-arm', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(MESSAGE, vs[0].message);
	}

	/** The whole arm goes; the arm above it is untouched. */
	public function testFixDeletesArm(): Void {
		final out: String = applyFixOnce(sw('Int', FIRING_BRANCHES));
		Assert.stringContains('case 1:', out);
		Assert.isFalse(out.contains('case 2, 3'), 'the empty arm is gone');
	}

	/**
	 * A THREE-arm fixture, so the survivors are two arms and gate 2 has nothing to say: the re-run
	 * finds nothing because the new trailing arm carries a body, which is idempotence rather than
	 * degeneracy.
	 */
	public function testFixIsIdempotent(): Void {
		final out: String = applyFixOnce(sw('Int', 'case 1: t();\n\t\t\tcase 2: u();\n\t\t\tcase 3:'));
		Assert.stringContains('case 2: u();', out);
		Assert.equals(0, violations(out).length);
	}

	/** An empty `case _:` IS the lone catch-all, and a catch-all that does nothing is the same no-op. */
	public function testTrailingEmptyWildcardFlagged(): Void {
		final src: String = sw('Int', 'case 1: t();\n\t\t\tcase _:');
		Assert.equals(1, violations(src).length);
		Assert.isFalse(applyFixOnce(src).contains('case _'), 'the empty wildcard arm is gone');
	}

	/** So is an empty `default:`. */
	public function testTrailingEmptyDefaultFlagged(): Void {
		final src: String = sw('Int', 'case 1: t();\n\t\t\tdefault:');
		Assert.equals(1, violations(src).length);
		Assert.isFalse(applyFixOnce(src).contains('default'), 'the empty default arm is gone');
	}

	/**
	 * A `Bool` switch IS exhaustiveness-checked, so dropping an arm can stop it compiling. The
	 * branches are byte-identical to the firing fixture's and only the parameter TYPE differs, so
	 * nothing but the subject gate can refuse it. That makes the fixture type-INVALID (`case 1:`
	 * over a `Bool`) and parse-valid, which is on purpose: the check is a syntax-plus-resolution
	 * scan and never type-checks, so an invalid pair is the sharpest discriminator available.
	 */
	public function testBoolSubjectRefused(): Void {
		Assert.equals(0, violations(sw('Bool', FIRING_BRANCHES)).length);
	}

	/** `Dynamic` is not on the whitelist either — the gate is a whitelist, so an unlisted type fails closed. */
	public function testDynamicSubjectRefused(): Void {
		Assert.equals(0, violations(sw('Dynamic', FIRING_BRANCHES)).length);
	}

	/** `Null<Int>` resolves to its OUTER nominal `Null`, which is not on the whitelist. */
	public function testNullableSubjectRefused(): Void {
		Assert.equals(0, violations(sw('Null<Int>', FIRING_BRANCHES)).length);
	}

	/** An `enum` subject is the exhaustiveness case the whitelist exists for. */
	public function testEnumSubjectRefused(): Void {
		final src: String = 'enum E {\n\tA;\n\tB;\n}\n\nclass C {\n\tfunction f(v: E): Void {\n\t\tswitch v {\n\t\t\tcase A: t();'
			+ '\n\t\t\tcase B:\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A mid-switch empty arm SUPPRESSES the arm below it for the values it names — deleting it
	 * reroutes them. The minimal pair of `testTrailingEmptyArmFlagged`: the SAME two arms, only
	 * which of them is empty differs, and the other arm is an ordinary one so no catch-all gate
	 * can claim the refusal.
	 */
	public function testMidSwitchEmptyArmRefused(): Void {
		Assert.equals(0, violations(sw('Int', 'case 1:\n\t\t\tcase 2: t();')).length);
	}

	/** With a catch-all above it the trailing arm is UNREACHABLE, not silent. */
	public function testOtherCatchAllRefused(): Void {
		Assert.equals(0, violations(sw('Int', 'case 1: t();\n\t\t\tcase _: u();\n\t\t\tcase 5:')).length);
	}

	/** A wildcard ALTERNATIVE makes its arm a catch-all too — the scan reads the whole pattern run. */
	public function testOrPatternCatchAllRefused(): Void {
		Assert.equals(0, violations(sw('Int', 'case 5, _: u();\n\t\t\tcase 2:')).length);
	}

	/**
	 * An `#if` among the arms may HIDE a catch-all, so gate 6 cannot be proved — the region projects
	 * as a sibling of the arms, not as one, and the catch-all scan alone would walk straight past it.
	 */
	public function testConditionalArmHidingCatchAllRefused(): Void {
		Assert.equals(0, violations(sw('Int', 'case 1: t();\n\t\t\t#if debug\n\t\t\tcase _: u();\n\t\t\t#end\n\t\t\tcase 2:')).length);
	}

	/**
	 * The other half of the same gate: the arms OUTSIDE the region may be the only ones a build
	 * keeps, so deleting the candidate could leave a degenerate `switch v { #if … #end }`.
	 */
	public function testConditionalArmLeavingDegenerateSwitchRefused(): Void {
		Assert.equals(0, violations(sw('Int', '#if debug\n\t\t\tcase 1: t();\n\t\t\t#end\n\t\t\tcase 2:')).length);
	}

	/** An extractor RUNS code while matching, so deleting its arm would drop that call. */
	public function testExtractorCandidateRefused(): Void {
		Assert.equals(0, violations(sw('Int', 'case 1: t();\n\t\t\tcase _ => 2:')).length);
	}

	/** A `case null:` arm is out of scope by construction — this rule stays out of null-matching semantics. */
	public function testNullPatternCandidateRefused(): Void {
		Assert.equals(0, violations(sw('Int', 'case 1: t();\n\t\t\tcase null:')).length);
	}

	/** A bare lowercase identifier BINDS, and a binding label is a catch-all whose deletion reroutes values. */
	public function testBinderCandidateRefused(): Void {
		Assert.equals(0, violations(sw('Int', 'case 1: t();\n\t\t\tcase x:')).length);
	}

	/**
	 * The trailing-blank TRIM, isolated — and asserted on the EDIT SPAN, not on the output: a
	 * switch's LAST arm absorbs the whitespace up to the closing brace into its own span, so a
	 * blank line before that brace lands INSIDE it. Removing the span verbatim would pull the brace
	 * onto the previous arm's line, which the canonical writer then quietly repairs — so an
	 * output-level assertion cannot see the difference and would pass with the trim reverted
	 * (checked). Reading the removed TEXT is what discriminates. The behavioural consequence the
	 * trim exists for is pinned by `testCommentOnPreviousArmLineFlagged`, where the untrimmed span
	 * buries the brace in a `// …` and the result does not parse.
	 */
	public function testTrailingBlankLinesTrimmedFromEditSpan(): Void {
		final src: String = sw('Int', 'case 1: t();\n\t\t\tcase 2, 3:\n');
		final edits: Array<{ span: Span, text: String }> = fixEdits(src);
		Assert.equals(1, edits.length);
		final removed: String = src.substring(edits[0].span.from, edits[0].span.to);
		Assert.stringContains('case 2, 3:', removed);
		Assert.isTrue(removed.endsWith(':'), 'the blank line before the brace stays');
		Assert.stringContains('case 1: t();\n\t\t}', applyFixOnce(src));
	}

	/** The walk descends: a switch nested inside another switch's arm is analysed on its own terms. */
	public function testNestedSwitchFlagged(): Void {
		final branches: String = 'case 1:\n\t\t\t\tswitch v {\n\t\t\t\t\tcase 7: t();\n\t\t\t\t\tcase 8:\n\t\t\t\t}\n\t\t\tcase 2: u();';
		final vs: Array<Violation> = violations(sw('Int', branches));
		Assert.equals(1, vs.length);
		final out: String = applyFixOnce(sw('Int', branches));
		Assert.stringContains('case 7: t();', out);
		Assert.isFalse(out.contains('case 8'), 'the INNER empty arm is the one that goes');
		Assert.stringContains('case 2: u();', out);
	}

	/**
	 * A guard RUNS, so the arm is not silent even with an empty body. Only the guard separates
	 * this from `testTrailingEmptyArmFlagged`'s shape, but it does NOT isolate the guard gate: a
	 * guard is an extra CHILD of the arm, so the emptiness test rejects it as well. No fixture can
	 * isolate the guard gate for that reason, and the claim is dropped rather than pretended.
	 */
	public function testGuardedEmptyArmRefused(): Void {
		Assert.equals(0, violations(sw('Int', 'case 1: t();\n\t\t\tcase 2 if (c):')).length);
	}

	/** A trailing `// …` is TRIVIA outside the arm's span; the writer would re-attach it to the switch. */
	public function testTrailingCommentRefused(): Void {
		Assert.equals(0, violations(sw('Int', 'case 1: t();\n\t\t\tcase 2, 3: // keep me')).length);
	}

	/** A comment on the line ABOVE survives the deletion and then documents the closing brace. */
	public function testPrecedingCommentRefused(): Void {
		Assert.equals(0, violations(sw('Int', 'case 1: t();\n\t\t\t// why 2 and 3 are silent\n\t\t\tcase 2, 3:')).length);
	}

	/**
	 * A trailing `// …` on the PREVIOUS arm's line is behind everything the deletion reaches — the
	 * removed region starts at the newline that ends that line — so it must not refuse. The minimal
	 * pair of `testTrailingCommentRefused`, which moves the same comment one line down.
	 */
	public function testCommentOnPreviousArmLineFlagged(): Void {
		final src: String = sw('Int', 'case 1: t(); // note\n\t\t\tcase 2, 3:');
		Assert.equals(1, violations(src).length);
		final out: String = applyFixOnce(src);
		Assert.stringContains('case 1: t(); // note', out);
		Assert.isFalse(out.contains('case 2, 3'), 'the empty arm is gone and the comment survived it');
	}

	/** Deleting the SOLE arm leaves a degenerate `switch v {}` rather than a smaller switch. */
	public function testSingleArmSwitchRefused(): Void {
		Assert.equals(0, violations(sw('Int', 'case 1:')).length);
	}

	/** The subject resolves through a field chain — `d.code` reads `D.code`'s declared type off the index. */
	public function testFieldChainSubjectFlagged(): Void {
		final src: String = 'class D {\n\tpublic var code: Int;\n}\n\nclass C {\n\tfunction f(d: D): Void {\n\t\tswitch d.code {'
			+ '\n\t\t\tcase 1: t();\n\t\t\tcase 2:\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
		final out: String = applyFixOnce(src);
		Assert.stringContains('case 1:', out);
		Assert.isFalse(out.contains('case 2:'), 'the empty arm is gone');
	}

	/**
	 * The subject's type is declared in ANOTHER file, so only a cross-file index resolves it: `run`
	 * finds the arm, `fix` WITHOUT an index re-derives nothing (its fallback index sees one file),
	 * and `fix` WITH the run-built index — the way `Cli.computeFileLintEdits` calls it — emits the
	 * deletion.
	 */
	public function testCrossFileSubjectNeedsIndex(): Void {
		final owner: { file: String, source: String } = { file: 'D.hx', source: 'class D {\n\tpublic var code: Int;\n}' };
		final user: { file: String, source: String } = {
			file: 'C.hx',
			source: 'class C {\n\tfunction f(d: D): Void {\n\t\tswitch d.code {\n\t\t\tcase 1: t();\n\t\t\tcase 2:\n\t\t}\n\t}\n}'
		};
		final files: Array<{ file: String, source: String }> = [owner, user];
		final check: EmptyCaseArm = new EmptyCaseArm();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final found: Array<Violation> = check.run(files, plugin);
		Assert.equals(1, found.length);
		Assert.equals(0, check.fix(user.source, found, plugin).length);
		Assert.equals(1, check.fix(user.source, found, plugin, SymbolIndex.build(files, plugin)).length);
	}

	/** A STATIC root resolves too: `S.mode` has no value receiver at all. */
	public function testStaticRootSubjectFlagged(): Void {
		final src: String = 'class S {\n\tpublic static var mode: Int;\n}\n\nclass C {\n\tfunction f(): Void {\n\t\tswitch S.mode {'
			+ '\n\t\t\tcase 1: t();\n\t\t\tcase 2:\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	/** An EXPRESSION switch must yield a value from every arm, so its arm list is checked whatever the subject is. */
	public function testExpressionSwitchRefused(): Void {
		final src: String =
			'class C {\n\tfunction f(v: Int): Void {\n\t\tfinal y: Int = switch v {\n\t\t\tcase 1: 2;\n\t\t\tcase 3:\n\t\t};\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testRegisteredAsBuiltin(): Void {
		Assert.notNull(Linter.byId('empty-case-arm'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('empty-case-arm'));
	}

	/** A statement switch over a `type`-annotated parameter, holding `branches`. */
	private function sw(type: String, branches: String): String {
		return 'class C {\n\tfunction f(v: $type): Void {\n\t\tswitch v {\n\t\t\t$branches\n\t\t}\n\t}\n}';
	}


	private function violations(src: String): Array<Violation> {
		return new EmptyCaseArm().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** `fix` with NO index — the single-file fallback a direct caller gets. */
	private function fixEdits(src: String): Array<{ span: Span, text: String }> {
		final check: EmptyCaseArm = new EmptyCaseArm();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
	}


	/** Run `empty-case-arm`'s fix and re-emit through the canonical writer. */
	private function applyFixOnce(src: String): String {
		return canonical(src, fixEdits(src));
	}

	/** Apply `edits` to `src` and re-emit through the canonical writer, the way `lint --fix` does. */
	private function canonical(src: String, edits: Array<{ span: Span, text: String }>): String {
		return switch CanonicalEdit.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
