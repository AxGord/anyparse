package unit;

import anyparse.check.Check.Violation;
import anyparse.check.DuplicateCode;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `duplicate-code` check: three or more consecutive statements repeated
 * (whitespace-insensitive) within one file are an `Info`, report-only clone. The
 * later occurrence is flagged once, pointing at the first occurrence's line; a
 * two-statement run, a below-content-gate triple, and a differently-named copy are
 * safe misses; a five-statement clone reports once as its maximal run; overlapping
 * self-repeats resolve to non-overlapping occurrences; and a clone that spans two
 * different block kinds (a method body vs an `if` body) is still caught.
 */
class DuplicateCodeCheckTest extends Test {

	public function testThreeStatementCloneFlaggedOnce(): Void {
		final vs: Array<Violation> = violations(src([
			'class C {',
			'\tfunction f():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t}',
			'\tfunction g():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t}',
			'}'
		]));
		Assert.equals(1, vs.length);
		Assert.equals('duplicate-code', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('3 statements duplicated from line 3 — extract a helper (hxq extract-method)', vs[0].message);
	}

	public function testTwoStatementRunNotFlagged(): Void {
		Assert.equals(
			0, violations(src([
				'class C {',
				'\tfunction f():Void {',
				'\t\ttrace(alpha, beta);',
				'\t\ttrace(gamma, delta);',
				'\t}',
				'\tfunction g():Void {',
				'\t\ttrace(alpha, beta);',
				'\t\ttrace(gamma, delta);',
				'\t}',
				'}'
			])).length
		);
	}

	public function testWhitespaceVariantFlagged(): Void {
		final vs: Array<Violation> = violations(src([
			'class C {',
			'\tfunction f():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t}',
			'\tfunction g():Void {',
			'\t\ttrace(alpha,',
			'\t\t\tbeta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t}',
			'}'
		]));
		Assert.equals(1, vs.length);
		Assert.isTrue(StringTools.startsWith(vs[0].message, '3 statements duplicated'));
	}

	public function testDifferentIdentifiersNotFlagged(): Void {
		Assert.equals(
			0, violations(src([
				'class C {',
				'\tfunction f():Void {',
				'\t\ttrace(alpha, beta);',
				'\t\ttrace(gamma, delta);',
				'\t\ttrace(epsilon, zeta);',
				'\t}',
				'\tfunction g():Void {',
				'\t\ttrace(one, two);',
				'\t\ttrace(three, four);',
				'\t\ttrace(five, six);',
				'\t}',
				'}'
			])).length
		);
	}

	public function testFiveStatementMaximalReportedOnce(): Void {
		final vs: Array<Violation> = violations(src([
			'class C {',
			'\tfunction f():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t\ttrace(eta, theta);',
			'\t\ttrace(iota, kappa);',
			'\t}',
			'\tfunction g():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t\ttrace(eta, theta);',
			'\t\ttrace(iota, kappa);',
			'\t}',
			'}'
		]));
		Assert.equals(1, vs.length);
		Assert.isTrue(StringTools.startsWith(vs[0].message, '5 statements duplicated'));
	}

	public function testOverlappingSelfRepeatNonOverlapping(): Void {
		final vs: Array<Violation> = violations(src([
			'class C {',
			'\tfunction f():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(alpha, beta);',
			'\t}',
			'}'
		]));
		Assert.equals(1, vs.length);
		Assert.equals('3 statements duplicated from line 3 — extract a helper (hxq extract-method)', vs[0].message);
	}

	public function testBelowContentGateNotFlagged(): Void {
		Assert.equals(
			0, violations(src([
				'class C {',
				'\tfunction f():Void {',
				'\t\ti++;',
				'\t\tj++;',
				'\t\tk++;',
				'\t}',
				'\tfunction g():Void {',
				'\t\ti++;',
				'\t\tj++;',
				'\t\tk++;',
				'\t}',
				'}'
			])).length
		);
	}

	public function testThreeOccurrencesTwoFindings(): Void {
		final vs: Array<Violation> = violations(src([
			'class C {',
			'\tfunction f():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t}',
			'\tfunction g():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t}',
			'\tfunction h():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t}',
			'}'
		]));
		Assert.equals(2, vs.length);
		Assert.equals('3 statements duplicated from line 3 — extract a helper (hxq extract-method)', vs[0].message);
		Assert.equals('3 statements duplicated from line 3 — extract a helper (hxq extract-method)', vs[1].message);
	}

	public function testDivergingTailReportsOncePerBlock(): Void {
		// Block a shares a 3-statement prefix with b and c; b and c additionally share a longer
		// 5-statement run. Each later block must report once — not as partially-overlapping windows.
		final vs: Array<Violation> = violations(src([
			'class C {',
			'\tfunction a():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t}',
			'\tfunction b():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t\ttrace(eta, theta);',
			'\t\ttrace(iota, kappa);',
			'\t}',
			'\tfunction c():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t\ttrace(eta, theta);',
			'\t\ttrace(iota, kappa);',
			'\t}',
			'}'
		]));
		Assert.equals(2, vs.length);
	}

	public function testCloneAcrossBlockKindsFlagged(): Void {
		final vs: Array<Violation> = violations(src([
			'class C {',
			'\tfunction f():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t}',
			'\tfunction g():Void {',
			'\t\tif (cond) {',
			'\t\t\ttrace(alpha, beta);',
			'\t\t\ttrace(gamma, delta);',
			'\t\t\ttrace(epsilon, zeta);',
			'\t\t}',
			'\t}',
			'}'
		]));
		Assert.equals(1, vs.length);
		Assert.isTrue(StringTools.startsWith(vs[0].message, '3 statements duplicated'));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('duplicate-code'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('duplicate-code'));
	}

	/**
	 * The anti-drift pin for `VolatileMessage`: the mask is anchored on a literal fragment of
	 * this rule's own wording, so a reworded message turns it into a silent no-op and the
	 * blast-radius gate goes back to re-keying every clone whose ORIGINAL moved a line. The
	 * input is a message `run` PRODUCED, never a hand-written one.
	 */
	public function testMessageIdentityMasksItsOwnOriginalLine(): Void {
		final check: DuplicateCode = new DuplicateCode();
		final message: String = check.run([
			{
				file: 'C.hx',
				source: src([
					'class C {',
					'\tfunction f():Void {',
					'\t\ttrace(alpha, beta);',
					'\t\ttrace(gamma, delta);',
					'\t\ttrace(epsilon, zeta);',
					'\t}',
					'\tfunction g():Void {',
					'\t\ttrace(alpha, beta);',
					'\t\ttrace(gamma, delta);',
					'\t\ttrace(epsilon, zeta);',
					'\t}',
					'}'
				])
			}
		], new HaxeQueryPlugin())[0].message;
		final identity: String = check.messageIdentity(message);
		Assert.equals('3 statements duplicated from line # — extract a helper (hxq extract-method)', identity);
		Assert.equals(identity, check.messageIdentity(identity), 'the normalization is idempotent');
	}

	private function violations(source: String): Array<Violation> {
		return new DuplicateCode().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function src(lines: Array<String>): String {
		return lines.join('\n');
	}

}
