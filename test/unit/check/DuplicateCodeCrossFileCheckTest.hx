package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.DuplicateCode;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The cross-file axis of the `duplicate-code` check: three or more consecutive statements
 * repeated (whitespace-insensitive) across TWO DIFFERENT files are an `Info`, report-only clone
 * whose message names BOTH sites (`file A line X ↔ this file line Y`). A same-file clone is
 * reported by the same-file pass only — never doubled by the cross-file pass; the below-threshold
 * and below-content-gate misses hold across files exactly as within one; a differently-named copy
 * is a safe miss; and an unrelated pair of files produces nothing.
 */
class DuplicateCodeCrossFileCheckTest extends Test {

	public function testCrossFileCloneNamesBothSites(): Void {
		final vs: Array<Violation> = violations([
			file('A.hx', [
				'class A {',
				'\tfunction f():Void {',
				'\t\ttrace(alpha, beta);',
				'\t\ttrace(gamma, delta);',
				'\t\ttrace(epsilon, zeta);',
				'\t}',
				'}'
			]),
			file('B.hx', [
				'class B {',
				'\tfunction g():Void {',
				'\t\ttrace(alpha, beta);',
				'\t\ttrace(gamma, delta);',
				'\t\ttrace(epsilon, zeta);',
				'\t}',
				'}'
			])
		]);
		Assert.equals(1, vs.length);
		Assert.equals('B.hx', vs[0].file);
		Assert.equals('duplicate-code', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('3 statements duplicated from A.hx:3 — extract a shared helper (report-only, cross-file)', vs[0].message);
	}

	public function testSameFileCloneNotDoubledByCrossFile(): Void {
		final vs: Array<Violation> = violations([
			file('C.hx', [
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
		]);
		Assert.equals(1, vs.length);
		Assert.isTrue(StringTools.startsWith(vs[0].message, '3 statements duplicated from line 3'));
		Assert.equals(-1, vs[0].message.indexOf('cross-file'));
	}

	public function testSameFileAndCrossFileCoexistNoDoubleReport(): Void {
		// A holds an internal clone (f, g); B holds a third copy. The internal pair is a same-file
		// finding; B is a cross-file finding pointing at A. The second A copy is skipped by the
		// cross-file pass (a same-file start), so the clone family reports exactly twice.
		final vs: Array<Violation> = violations([
			file('A.hx', [
				'class A {',
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
			]),
			file('B.hx', [
				'class B {',
				'\tfunction h():Void {',
				'\t\ttrace(alpha, beta);',
				'\t\ttrace(gamma, delta);',
				'\t\ttrace(epsilon, zeta);',
				'\t}',
				'}'
			])
		]);
		Assert.equals(2, vs.length);
		final same: Array<Violation> = [for (v in vs) if (v.message.indexOf('cross-file') == -1) v];
		final cross: Array<Violation> = [for (v in vs) if (v.message.indexOf('cross-file') != -1) v];
		Assert.equals(1, same.length);
		Assert.equals('A.hx', same[0].file);
		Assert.equals(1, cross.length);
		Assert.equals('B.hx', cross[0].file);
		Assert.equals('3 statements duplicated from A.hx:3 — extract a shared helper (report-only, cross-file)', cross[0].message);
	}

	public function testTwoStatementCrossFileNotFlagged(): Void {
		Assert.equals(
			0, violations([
				file('A.hx', [
					'class A {',
					'\tfunction f():Void {',
					'\t\ttrace(alpha, beta);',
					'\t\ttrace(gamma, delta);',
					'\t}',
					'}'
				]),
				file('B.hx', [
					'class B {',
					'\tfunction g():Void {',
					'\t\ttrace(alpha, beta);',
					'\t\ttrace(gamma, delta);',
					'\t}',
					'}'
				])
			]).length
		);
	}

	public function testWhitespaceVariantCrossFileFlagged(): Void {
		final vs: Array<Violation> = violations([
			file('A.hx', [
				'class A {',
				'\tfunction f():Void {',
				'\t\ttrace(alpha, beta);',
				'\t\ttrace(gamma, delta);',
				'\t\ttrace(epsilon, zeta);',
				'\t}',
				'}'
			]),
			file('B.hx', [
				'class B {',
				'\tfunction g():Void {',
				'\t\ttrace(alpha,',
				'\t\t\tbeta);',
				'\t\ttrace(gamma, delta);',
				'\t\ttrace(epsilon, zeta);',
				'\t}',
				'}'
			])
		]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('cross-file') != -1);
	}

	public function testDifferentIdentifiersCrossFileNotFlagged(): Void {
		Assert.equals(
			0, violations([
				file('A.hx', [
					'class A {',
					'\tfunction f():Void {',
					'\t\ttrace(alpha, beta);',
					'\t\ttrace(gamma, delta);',
					'\t\ttrace(epsilon, zeta);',
					'\t}',
					'}'
				]),
				file('B.hx', [
					'class B {',
					'\tfunction g():Void {',
					'\t\ttrace(one, two);',
					'\t\ttrace(three, four);',
					'\t\ttrace(five, six);',
					'\t}',
					'}'
				])
			]).length
		);
	}

	public function testBelowContentGateCrossFileNotFlagged(): Void {
		Assert.equals(
			0, violations([
				file('A.hx', [
					'class A {',
					'\tfunction f():Void {',
					'\t\ti++;',
					'\t\tj++;',
					'\t\tk++;',
					'\t}',
					'}'
				]),
				file('B.hx', [
					'class B {',
					'\tfunction g():Void {',
					'\t\ti++;',
					'\t\tj++;',
					'\t\tk++;',
					'\t}',
					'}'
				])
			]).length
		);
	}

	public function testUnrelatedFilesEmpty(): Void {
		Assert.equals(
			0, violations([
				file('A.hx', [
					'class A {',
					'\tfunction f():Void {',
					'\t\ttrace(alpha, beta);',
					'\t\ttrace(gamma, delta);',
					'\t\ttrace(epsilon, zeta);',
					'\t}',
					'}'
				]),
				file('B.hx', [
					'class B {',
					'\tfunction g():Void {',
					'\t\ttrace(one, two);',
					'\t\ttrace(three, four);',
					'\t\ttrace(five, six);',
					'\t}',
					'}'
				])
			]).length
		);
	}

	public function testSrcTestPairFlaggedAcrossBoundary(): Void {
		final vs: Array<Violation> = violations([
			file('src/Foo.hx', [
				'class Foo {',
				'\tfunction f():Void {',
				'\t\ttrace(alpha, beta);',
				'\t\ttrace(gamma, delta);',
				'\t\ttrace(epsilon, zeta);',
				'\t}',
				'}'
			]),
			file('test/Bar.hx', [
				'class Bar {',
				'\tfunction g():Void {',
				'\t\ttrace(alpha, beta);',
				'\t\ttrace(gamma, delta);',
				'\t\ttrace(epsilon, zeta);',
				'\t}',
				'}'
			])
		]);
		Assert.equals(1, vs.length);
		Assert.equals('test/Bar.hx', vs[0].file);
		Assert.equals('3 statements duplicated from src/Foo.hx:3 — extract a shared helper (report-only, cross-file)', vs[0].message);
	}

	public function testDuplicateCodeStillSingleBuiltin(): Void {
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.equals(1, [for (id in ids) if (id == 'duplicate-code') id].length);
	}

	/**
	 * The cross-file half of the `VolatileMessage` pin. The partner FILENAME and the statement
	 * COUNT stay in the key — a blanket digit mask ate both, which is how a substitution
	 * against the same partner became invisible to the gate.
	 */
	public function testMessageIdentityMasksThePartnerLineOnly(): Void {
		final check: DuplicateCode = new DuplicateCode();
		final message: String = check.run([
			file('A.hx', [
				'class A {',
				'\tfunction f():Void {',
				'\t\ttrace(alpha, beta);',
				'\t\ttrace(gamma, delta);',
				'\t\ttrace(epsilon, zeta);',
				'\t}',
				'}'
			]),
			file('B.hx', [
				'class B {',
				'\tfunction g():Void {',
				'\t\ttrace(alpha, beta);',
				'\t\ttrace(gamma, delta);',
				'\t\ttrace(epsilon, zeta);',
				'\t}',
				'}'
			])
		], new HaxeQueryPlugin())[0].message;
		final identity: String = check.messageIdentity(message);
		Assert.equals('3 statements duplicated from A.hx:# — extract a shared helper (report-only, cross-file)', identity);
		Assert.equals(identity, check.messageIdentity(identity), 'the normalization is idempotent');
		// The mask reads BACKWARDS from the tail and stops at the first non-digit, so a partner
		// whose name ends in a digit keeps it. Two clones against different origins must not
		// collapse onto one key — that would be a finding disappearing from the gate.
		final tail: String = ' — extract a shared helper (report-only, cross-file)';
		final withDigit: String = check.messageIdentity('4 statements duplicated from src/v2.hx:9$tail');
		Assert.equals('4 statements duplicated from src/v2.hx:#$tail', withDigit);
		Assert.notEquals(withDigit, check.messageIdentity('4 statements duplicated from src/v3.hx:9$tail'));
	}

	public function testAnchorIsPathEarliestNotScanEarliest(): Void {
		// The ORDER the caller listed the scope in must not decide which end of a clone is the
		// "original". At base it did: the anchor was `bucket[0]` after a sort on the file's
		// SCAN INDEX, so handing the same two files over in the other order moved the finding
		// from `Z.hx` to `A.hx` and swapped the path the message names. Measured on this
		// project, `lint src test` and `lint test src` disagreed on 9 findings each way.
		final a: { file: String, source: String } = file('A.hx', clone('A'));
		final z: { file: String, source: String } = file('Z.hx', clone('Z'));
		final forward: Array<Violation> = violations([a, z]);
		final reversed: Array<Violation> = violations([z, a]);
		Assert.equals(1, forward.length);
		Assert.equals(1, reversed.length);
		Assert.equals('Z.hx', forward[0].file);
		Assert.equals('Z.hx', reversed[0].file);
		Assert.equals(forward[0].message, reversed[0].message);
		Assert.isTrue(forward[0].message.indexOf('from A.hx:') != -1, forward[0].message);
	}

	public function testMessageIdentityKeepsTheStatementCount(): Void {
		// The one tally S15 did NOT mask, and the arm that proves the decision was made rather
		// than forgotten. `lint-diff` keys on `(file, rule, severity, message)` with no span; both
		// coordinates in this message are already masked and the partner path is shared by every
		// clone against that file, so the COUNT is the last thing telling two different clones in
		// one file apart. Blanking it made a substitution invisible — 57% of this rule's findings
		// on anyparse shared a key with a sibling under the old blanket digit mask — and its noise
		// cost is zero: over the campaign's last three blast-radius verdicts this rule contributed
		// no lines while two masked rules contributed all six.
		final check: DuplicateCode = new DuplicateCode();
		final three: String = check.run([file('A.hx', clone('A')), file('Z.hx', clone('Z'))], new HaxeQueryPlugin())[0].message;
		final four: String = check.run([file('A.hx', longerClone('A')), file('Z.hx', longerClone('Z'))], new HaxeQueryPlugin())[0].message;
		Assert.isTrue(three.indexOf('3 statements') == 0, three);
		Assert.isTrue(four.indexOf('4 statements') == 0, four);
		final identity: String = check.messageIdentity(three);
		Assert.isTrue(identity.indexOf('3 statements duplicated from A.hx:#') == 0, identity);
		Assert.notEquals(identity, check.messageIdentity(four));
		Assert.equals(identity, check.messageIdentity(identity));
	}

	private function violations(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new DuplicateCode().run(files, new HaxeQueryPlugin());
	}

	private function file(name: String, lines: Array<String>): { file: String, source: String } {
		return { file: name, source: lines.join('\n') };
	}

	/** A one-method class named `t` holding the three-statement clone body. */
	private function clone(t: String): Array<String> {
		return [
			'class $t {',
			'\tfunction f():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t}',
			'}'
		];
	}

	/** `clone` with a fourth shared statement, so the same pair reports a count of 4. */
	private function longerClone(t: String): Array<String> {
		final lines: Array<String> = clone(t);
		lines.insert(lines.length - 2, '\t\ttrace(eta, theta);');
		return lines;
	}

}
