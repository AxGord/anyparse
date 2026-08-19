package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantCaseBody;
import anyparse.check.Severity;
import anyparse.check.UnusedCaseBinder;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using StringTools;

/**
 * The `redundant-case-body` check: an arm whose body its IMMEDIATE neighbour repeats
 * folds two ways — DELETED when that neighbour is a catch-all, MERGED into one
 * or-pattern label otherwise.
 *
 * The fixtures pair each fold with the neighbouring shape that must not fold. Every
 * gate defends one way textual body identity stops implying behavioural identity: a
 * pattern that BINDS (the same body text then reads a binder in one arm and an outer
 * name in the other), a guard, an extractor that runs code while matching, a `null`
 * literal a wildcard does not match, a non-adjacent twin whose fold would reroute the
 * arms between, and a comment the edit would discard.
 */
class RedundantCaseBodyCheckTest extends Test {

	private static inline final SUBSUME_MESSAGE: String =
		'this case body is identical to the catch-all that follows it; the arm is redundant';
	private static inline final MERGE_MESSAGE: String =
		'this case body is identical to the next arm\'s; merge the two labels into one case';

	public function testSubsumeFlagged(): Void {
		final vs: Array<Violation> = violations(sw('case "User": t(k);\n\t\t\tcase _: t(k);'));
		Assert.equals(1, vs.length);
		Assert.equals('redundant-case-body', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(SUBSUME_MESSAGE, vs[0].message);
	}

	/** The subsumed arm is deleted outright; the catch-all keeps the shared body. */
	public function testSubsumeDeletesArm(): Void {
		final out: String = applyFixOnce(sw('case "User": t(k);\n\t\t\tcase _: t(k);'));
		Assert.isFalse(out.contains('"User"'), 'the redundant arm is gone');
		Assert.stringContains('case _:', out);
	}

	/** A `default:` neighbour is a catch-all too. */
	public function testSubsumeUnderDefault(): Void {
		final out: String = applyFixOnce(sw('case "User": t(k);\n\t\t\tdefault: t(k);'));
		Assert.isFalse(out.contains('"User"'), 'the redundant arm is gone');
	}

	public function testMergeFlagged(): Void {
		final vs: Array<Violation> = violations(sw('case A: r();\n\t\t\tcase B: r();\n\t\t\tcase _: z();'));
		Assert.equals(1, vs.length);
		Assert.equals(MERGE_MESSAGE, vs[0].message);
	}

	/** Two ordinary arms sharing a body become one or-pattern label. */
	public function testMergeJoinsLabels(): Void {
		Assert.stringContains('case A, B:', applyFixOnce(sw('case A: r();\n\t\t\tcase B: r();\n\t\t\tcase _: z();')));
	}

	/** Three arms sharing a body fold in ONE pass — the two edits are disjoint. */
	public function testThreeArmChainMergesInOnePass(): Void {
		final src: String = sw('case A: r();\n\t\t\tcase B: r();\n\t\t\tcase C: r();\n\t\t\tcase _: z();');
		Assert.equals(2, violations(src).length);
		Assert.stringContains('case A, B, C:', applyFixOnce(src));
	}

	/** Empty bodies are identical bodies: two silent arms merge. */
	public function testEmptyBodiesMerge(): Void {
		Assert.stringContains('case A, B:', applyFixOnce(sw('case A:\n\t\t\tcase B:\n\t\t\tcase _: z();')));
	}

	/** ADJACENCY is load-bearing: folding across the arm between would reroute everything it matches. */
	public function testNonAdjacentTwinRefused(): Void {
		Assert.equals(0, violations(sw('case A: r();\n\t\t\tcase B: q();\n\t\t\tcase C: r();\n\t\t\tcase _: z();')).length);
	}

	/** A guard may reject, so the label alone no longer decides. */
	public function testGuardedArmRefused(): Void {
		Assert.equals(0, violations(sw('case A if (c): r();\n\t\t\tcase B: r();\n\t\t\tcase _: z();')).length);
		Assert.equals(0, violations(sw('case A: r();\n\t\t\tcase B if (c): r();\n\t\t\tcase _: z();')).length);
	}

	/** A BINDING pattern breaks the identity: `use(x)` reads the binder in one arm and an outer `x` in the other. */
	public function testBindingPatternRefused(): Void {
		Assert.equals(0, violations(sw('case Foo(x): use(x);\n\t\t\tcase _: use(x);')).length);
	}

	/** The merge partner must bind nothing either — an or-pattern's alternatives must agree on their bindings. */
	public function testBindingMergePartnerRefused(): Void {
		Assert.equals(0, violations(sw('case A: r();\n\t\t\tcase Foo(x): r();\n\t\t\tcase _: z();')).length);
	}

	/** `case _` does NOT match `null` on a nullable subject, so a null arm is never subsumed away. */
	public function testNullPatternRefused(): Void {
		Assert.equals(0, violations(sw('case null: w();\n\t\t\tcase _: w();')).length);
	}

	/** An extractor RUNS code while matching — deleting the arm would drop that call. */
	public function testExtractorPatternRefused(): Void {
		Assert.equals(0, violations(sw('case tap(_) => P: w();\n\t\t\tcase _: w();')).length);
	}

	/** Structural equality compares literal CONTENT, so whitespace inside a string keeps two bodies apart. */
	public function testStringLiteralWhitespaceKeepsBodiesDistinct(): Void {
		Assert.equals(0, violations(sw('case A: f("a  b");\n\t\t\tcase _: f("a b");')).length);
	}

	/** A comment inside the deleted arm has nowhere to go, so the subsume is refused. */
	public function testCommentInDeletedArmRefused(): Void {
		Assert.equals(0, violations(sw('case A: // why\n\t\t\t\tr();\n\t\t\tcase _: r();')).length);
	}

	/**
	 * An `#if` region in only ONE arm already makes the bodies structurally unequal, so this pins the pair as refused without reaching the conditional gate — `testMatchingConditionalCompilationArmsRefused` is what isolates that gate.
	 */
	public function testConditionalCompilationArmSkipped(): Void {
		Assert.equals(0, violations(sw('case A:\n\t\t\t\t#if debug\n\t\t\t\tr();\n\t\t\t\t#end\n\t\t\tcase _: r();')).length);
	}

	/** After the fold the survivor has no duplicate neighbour left. */
	public function testFixIsIdempotent(): Void {
		Assert.equals(0, violations(applyFixOnce(sw('case "User": t(k);\n\t\t\tcase _: t(k);'))).length);
	}

	/**
	 * The two case-arm rules COMPOSE to the shape that motivated them: unbinding the
	 * trailing catch-all first turns the arm above it into a redundant twin, and the
	 * second pass deletes it.
	 */
	public function testComposesWithUnusedCaseBinder(): Void {
		final src: String = 'class C {\n\tfunction f(data: Dynamic): String {\n\t\treturn switch data.role {\n\t\t\tcase "Owner": '
			+ 't("Owner", 10149);\n\t\t\tcase "User": t("User", 10150);\n\t\t\tcase _data: t("User", 10150);\n\t\t}\n\t}\n}';
		final once: String = applyBinderFix(src);
		Assert.stringContains('case _:', once);
		final twice: String = applyFixOnce(once);
		Assert.stringContains('case "Owner":', twice);
		Assert.isFalse(twice.contains('case "User"'), 'the duplicated arm is gone');
		Assert.equals(0, violations(twice).length);
	}

	public function testRegisteredAsBuiltin(): Void {
		Assert.notNull(Linter.byId('redundant-case-body'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-case-body'));
	}

	/**
	 * A trailing `// …` is TRIVIA outside the arm's span, so the deletion would leave it
	 * orphaned and the writer would re-attach it to the enclosing node — a comment
	 * silently migrating onto code it never described. The gate scans past the arm.
	 */
	public function testTrailingCommentOnDeletedArmRefused(): Void {
		Assert.equals(0, violations(sw('case A: r(); // keep me\n\t\t\tcase _: r();')).length);
	}

	/**
	 * A comment on the line ABOVE the deleted arm survives the deletion and then documents
	 * the catch-all instead — the same defect from the other side, so the gate scans back
	 * to the previous arm too.
	 */
	public function testPrecedingCommentOnDeletedArmRefused(): Void {
		Assert.equals(0, violations(sw('case Z: q();\n\t\t\t// why A is special\n\t\t\tcase A: r();\n\t\t\tcase _: r();')).length);
	}

	/**
	 * The NORMALISED-SOURCE half of the body-identity gate, isolated: a comment inside the
	 * KEPT arm's body leaves the statement lists structurally equal and the comment gate
	 * untouched (it sits in no discarded region), so only normalised-source inequality can
	 * refuse this pair.
	 */
	public function testCommentInsideKeptBodyKeepsBodiesDistinct(): Void {
		Assert.equals(0, violations(sw('case A: r();\n\t\t\t\ts();\n\t\t\tcase _: r();\n\t\t\t\t/* x */ s();')).length);
	}

	/**
	 * The conditional-compilation gate, isolated: the SAME `#if` region in both arms leaves
	 * the bodies structurally and textually equal, so nothing but that gate can refuse the
	 * pair. (A region in only ONE arm is refused by body identity, and would prove nothing.)
	 */
	public function testMatchingConditionalCompilationArmsRefused(): Void {
		final arm: String = '\n\t\t\t\t#if debug\n\t\t\t\tr();\n\t\t\t\t#end';
		Assert.equals(0, violations(sw('case A:$arm\n\t\t\tcase _:$arm')).length);
	}

	/** A GUARDED catch-all is not a catch-all: it routes to the merge path, which its own guard gate refuses. */
	public function testGuardedCatchAllPartnerRefused(): Void {
		Assert.equals(0, violations(sw('case A: r();\n\t\t\tcase _ if (c): r();\n\t\t\tcase _: z();')).length);
	}

	/** A statement switch over `v` holding `branches`. */
	private function sw(branches: String): String {
		return 'class C {\n\tfunction f(v: Dynamic): Void {\n\t\tswitch v {\n\t\t\t$branches\n\t\t}\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantCaseBody().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixEdits(src: String): Array<{ span: Span, text: String }> {
		final check: RedundantCaseBody = new RedundantCaseBody();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `redundant-case-body`'s fix and re-emit through the canonical writer. */
	private function applyFixOnce(src: String): String {
		return canonical(src, fixEdits(src));
	}

	/** Run `unused-case-binder`'s fix — the pass that has to run first for the composition fixture. */
	private function applyBinderFix(src: String): String {
		final check: UnusedCaseBinder = new UnusedCaseBinder();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return canonical(src, edits);
	}

	private function canonical(src: String, edits: Array<{ span: Span, text: String }>): String {
		return switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
