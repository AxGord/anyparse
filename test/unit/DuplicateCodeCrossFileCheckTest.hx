package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DuplicateCode;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

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
		Assert.equals(0, violations([
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
		]).length);
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
		Assert.equals(0, violations([
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
		]).length);
	}

	public function testBelowContentGateCrossFileNotFlagged(): Void {
		Assert.equals(0, violations([
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
		]).length);
	}

	public function testUnrelatedFilesEmpty(): Void {
		Assert.equals(0, violations([
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
		]).length);
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

	private function violations(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new DuplicateCode().run(files, new HaxeQueryPlugin());
	}

	private function file(name: String, lines: Array<String>): { file: String, source: String } {
		return { file: name, source: lines.join('\n') };
	}

}
