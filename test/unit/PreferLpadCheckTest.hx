package unit;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.check.PreferLpad;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-lpad` check: a hand-written zero-pad `if`-ladder becomes one `lpad` call.
 *
 * The fixtures are built around the ONE gate that decides whether the rewrite is legal -- the
 * RANGE. `testUnboundSubjectReportedWithoutFix`, `testAboveTopReportedWithoutFix` and
 * `testNegativeLowBoundReportedWithoutFix` are all shape-perfect ladders that differ from the
 * flagged-and-fixed ones only in what can be proved about the value, so each one fails for the
 * range and not for the shape: every one of them still produces a FINDING, and the assertion is
 * that `fix` yields no edit. The redeclaration pair
 * (`testBinderRedeclaredInBodyNotProven` / `testInnerLoopWithOtherBinderStillProven`) differs by
 * exactly one character -- the inner loop's binder name -- so nothing but that gate separates them.
 */
class PreferLpadCheckTest extends Test {

	public function testLadderInLiteralRangeLoopFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f() {\n'
			+ "\t\tfor (i in 1...145) items.push(if (i < 10) 'p000$i' else if (i < 100) 'p00$i' else 'p0$i');\n\t}\n}"
		);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-lpad', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf("'p' + '$i'.lpad('0', 4)") >= 0);
	}

	/** The whole rewrite in one assertion: the ladder gone, the `using` in, the loop header untouched. */
	public function testFixEmitsLpadAndInsertsUsing(): Void {
		Assert.equals(
			"using StringTools;\n\nclass C {\n\tfunction f() {\n\t\tfor (i in 1...145) items.push('p' + '$i'.lpad('0', 4));\n\t}\n}\n",
			applyFix(
				'class C {\n\tfunction f() {\n'
				+ "\t\tfor (i in 1...145) items.push(if (i < 10) 'p000$i' else if (i < 100) 'p00$i' else 'p0$i');\n\t}\n}"
			)
		);
	}

	/** A trailing segment is shared text, not padding: it rides along after the call. */
	public function testSuffixCarriedIntoRewrite(): Void {
		Assert.equals(
			"using StringTools;\n\nclass C {\n\tfunction f() {\n\t\tfor (i in 0...100) items.push('p' + '$i'.lpad('0', 2) + '.png');\n"
			+ '\t}\n}\n',
			applyFix("class C {\n\tfunction f() {\n\t\tfor (i in 0...100) items.push(if (i < 10) 'p0$i.png' else 'p$i.png');\n\t}\n}")
		);
	}

	/** A file already declaring the module keeps ONE `using`, and a ladder with no base emits the bare call. */
	public function testExistingUsingNotDuplicated(): Void {
		Assert.equals(
			"using StringTools;\n\nclass C {\n\tfunction f() {\n\t\tfor (i in 0...100) items.push('$i'.lpad('0', 3));\n\t}\n}\n",
			applyFix(
				"using StringTools;\n\nclass C {\n\tfunction f() {\n\t\tfor (i in 0...100) items.push(if (i < 10) '00$i' else '0$i');\n"
				+ '\t}\n}'
			)
		);
	}

	/** A parameter carries no provable range, so the finding names the interval it would need and nothing is written. */
	public function testUnboundSubjectReportedWithoutFix(): Void {
		final src: String = "class C {\n\tfunction f(i: Int) {\n\t\tg(if (i < 10) 'p0$i' else 'p$i');\n\t}\n}";
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('holds only where i is in [0, 100)') >= 0);
		Assert.equals(0, fixEdits(src).length);
	}

	/** `0...1001` reaches a four-digit value the three-branch else keeps padding: outside the interval. */
	public function testAboveTopReportedWithoutFix(): Void {
		final src: String =
			"class C {\n\tfunction f() {\n\t\tfor (i in 0...1001) g(if (i < 10) 'p00$i' else if (i < 100) 'p0$i' else 'p$i');\n\t}\n}";
		Assert.equals(1, violations(src).length);
		Assert.equals(0, fixEdits(src).length);
	}

	/** The exclusive bound may reach the top exactly -- `0...1000` never yields 1000. */
	public function testBoundExactlyAtTopFixed(): Void {
		final src: String =
			"class C {\n\tfunction f() {\n\t\tfor (i in 0...1000) g(if (i < 10) 'p00$i' else if (i < 100) 'p0$i' else 'p$i');\n\t}\n}";
		Assert.equals(1, violations(src).length);
		Assert.isTrue(fixEdits(src).length > 0);
	}

	/** A negative low bound is the divergence the differential measured at 100%: reported, never written. */
	public function testNegativeLowBoundReportedWithoutFix(): Void {
		final src: String = "class C {\n\tfunction f() {\n\t\tfor (i in -5...100) g(if (i < 10) 'p0$i' else 'p$i');\n\t}\n}";
		Assert.equals(1, violations(src).length);
		Assert.equals(0, fixEdits(src).length);
	}

	/** `i < 20` spans one- AND two-digit values, which no single width fits. */
	public function testNonPowerOfTenThresholdRefused(): Void {
		Assert.equals(
			0, violations("class C {\n\tfunction f() {\n\t\tfor (i in 0...100) g(if (i < 20) 'p0$i' else 'p$i');\n\t}\n}").length
		);
	}

	/** A ladder starting at 100 leaves the one-digit band unhandled by its own first branch. */
	public function testLadderNotStartingAtTenRefused(): Void {
		Assert.equals(
			0, violations("class C {\n\tfunction f() {\n\t\tfor (i in 0...100) g(if (i < 100) 'p00$i' else 'p0$i');\n\t}\n}").length
		);
	}

	/** Equal zero runs are not a pad ladder -- the widths would differ per branch. */
	public function testZeroRunNotSteppingRefused(): Void {
		Assert.equals(
			0, violations("class C {\n\tfunction f() {\n\t\tfor (i in 0...100) g(if (i < 10) 'p00$i' else 'p00$i');\n\t}\n}").length
		);
	}

	/** The text before the zeros must be the same in every branch -- otherwise it is not a shared base. */
	public function testDifferentBaseRefused(): Void {
		Assert.equals(
			0, violations("class C {\n\tfunction f() {\n\t\tfor (i in 0...100) g(if (i < 10) 'a0$i' else 'b$i');\n\t}\n}").length
		);
	}

	/** The same requirement on the trailing side. */
	public function testDifferentSuffixRefused(): Void {
		Assert.equals(
			0, violations("class C {\n\tfunction f() {\n\t\tfor (i in 0...100) g(if (i < 10) 'p0$i.png' else 'p$i.jpg');\n\t}\n}").length
		);
	}

	/** A double-quoted literal projects no segments, so it carries no modelled cut point. */
	public function testDoubleQuotedBranchRefused(): Void {
		Assert.equals(
			0, violations("class C {\n\tfunction f() {\n\t\tfor (i in 0...100) g(if (i < 10) \"p0$i\" else \"p$i\");\n\t}\n}").length
		);
	}

	/** A backslash in the leading segment may put a `0` inside an escape, where a character cut corrupts it. */
	public function testEscapeInSegmentRefused(): Void {
		Assert.equals(
			0, violations("class C {\n\tfunction f() {\n\t\tfor (i in 0...100) g(if (i < 10) 'a\\t0$i' else 'a\\t$i');\n\t}\n}").length
		);
	}

	/** A chain whose tail is an `else if` with no `else` has no value on the tail path. */
	public function testMissingElseRefused(): Void {
		Assert.equals(
			0,
			violations("class C {\n\tfunction f() {\n\t\tfor (i in 0...100) g(if (i < 10) 'p0$i' else if (i < 100) 'p$i');\n\t}\n}").length
		);
	}

	/** The condition subject and the string's hole must be the same binding. */
	public function testSubjectMismatchRefused(): Void {
		Assert.equals(
			0, violations("class C {\n\tfunction f() {\n\t\tfor (i in 0...100) g(if (i < 10) 'p0$j' else 'p$j');\n\t}\n}").length
		);
	}

	/** A comment inside the ladder would be dropped by the splice, so the site is not claimed at all. */
	public function testCommentInsideLadderRefused(): Void {
		Assert.equals(
			0, violations("class C {\n\tfunction f() {\n\t\tfor (i in 0...100) g(if (i < 10) /* pad */ 'p0$i' else 'p$i');\n\t}\n}").length
		);
	}

	/** An inner loop reusing the name rebinds it, so the outer interval proves nothing about the read. */
	public function testBinderRedeclaredInBodyNotProven(): Void {
		final src: String = "class C {\n\tfunction f() {\n\t\tfor (i in 1...100) for (i in list) g(if (i < 10) 'p0$i' else 'p$i');\n\t}\n}";
		Assert.equals(1, violations(src).length);
		Assert.equals(0, fixEdits(src).length);
	}

	/** The discriminating twin: rename the inner binder and the outer interval carries again. */
	public function testInnerLoopWithOtherBinderStillProven(): Void {
		final src: String = "class C {\n\tfunction f() {\n\t\tfor (i in 1...100) for (j in list) g(if (i < 10) 'p0$i' else 'p$i');\n\t}\n}";
		Assert.equals(1, violations(src).length);
		Assert.isTrue(fixEdits(src).length > 0);
	}

	/** New rules ship OFF; the count guards a silent double-bump when parallel slices each add one. */
	public function testRegisteredAsDefaultOffBuiltin(): Void {
		final check: Null<Check> = Linter.byId('prefer-lpad');
		Assert.notNull(check);
		Assert.isTrue(check is DefaultOff);
		Assert.isFalse(check is RiskyFix);
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-lpad'));
		Assert.equals(178, Linter.builtins().length);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferLpad().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The check's own edits for its own findings — empty is the report-only verdict. */
	private function fixEdits(src: String): Array<{ span: Span, text: String }> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferLpad = new PreferLpad();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
	}

	/** Run `fix` and re-emit through the canonical writer — layout of the rewritten expression is its job. */
	private function applyFix(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferLpad = new PreferLpad();
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, found, plugin);
		return switch RefactorSupport.canonicalize(src, edits, true, plugin) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
