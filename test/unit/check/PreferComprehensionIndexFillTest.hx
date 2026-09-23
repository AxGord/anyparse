package unit.check;

import anyparse.check.PreferComprehension;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `prefer-comprehension`'s two build shapes beyond a push-only loop: a SEQUENTIAL INDEX FILL
 * `for (j in 0...n) out[j] = v;` into the still-empty array (each write lands at `out.length`, so it
 * appends), and a NESTED BUILD whose outer body declares an empty inner array, fills it by a shape the
 * rule folds, and pushes it. Each refusal differs from its fold by one construct.
 */
@:nullSafety(Strict) class PreferComprehensionIndexFillTest extends Test {

	/** The motivating nested build, as in TM's `Grid.get_gridData`. */
	private static inline final NESTED: String = 'final out:Array<Array<P>> = [];\n\n\t\t// create empty array\n'
		+ '\t\tfor (_ in 0...v + 1) {\n\t\t\tfinal arr:Array<P> = [];\n\t\t\tfor (j in 0...h + 1) arr[j] = { name: \'\', x: 0 };\n'
		+ '\t\t\tout.push(arr);\n\t\t}';

	@:pin('control') @:killer('M-COMPR-INDEXFILL-NEVER')
	public function testAnIndexFillFolds(): Void {
		Assert.equals(
			fn('final out:Array<Int> = [for (j in 0...n) j * 2];'),
			applyFix(fn('final out:Array<Int> = [];\n\t\tfor (j in 0...n) out[j] = j * 2;'))
		);
		Assert.equals(
			fn('final out:Array<Int> = [for (j in 0...n) j];'),
			applyFix(fn('final out:Array<Int> = [];\n\t\tfor (j in 0...n) {\n\t\t\tout[j] = j;\n\t\t}'))
		);
	}

	@:pin('control') @:killer('M-COMPR-INDEXFILL-VALUE-UNCHECKED')
	public function testAnIndexFillReadingTheArrayIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Array<Int> = [];\n\t\tfor (j in 0...n) out[j] = out.length;')));
	}

	@:pin('control') @:killer('M-COMPR-INDEXFILL-ANY-START')
	public function testAnIndexFillFromANonZeroStartIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Array<Int> = [];\n\t\tfor (j in 1...n) out[j] = j;')));
	}

	@:pin('control') @:killer('M-COMPR-INDEXFILL-ANY-INDEX')
	public function testAnIndexOtherThanTheBinderIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Array<Int> = [];\n\t\tfor (j in 0...n) out[k] = j;')));
		Assert.equals(0, count(fn('final out:Array<Int> = [];\n\t\tfor (j in 0...n) out[j + 1] = j;')));
	}

	/** A write into an array the gap already touched no longer appends from slot 0. */
	@:pin('control') @:killer('M-COMPR-GAP-NAME-BLIND')
	public function testAnArrayTouchedBeforeTheLoopIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Array<Int> = [];\n\t\tout.push(7);\n\t\tfor (j in 0...n) out[j] = j;')));
	}

	/** Under an outer loop the same writes overwrite slots instead of appending. */
	public function testAnIndexFillUnderAnOuterLoopIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Array<Int> = [];\n\t\tfor (x in xs) for (j in 0...n) out[j] = x;')));
	}

	@:pin('control') @:killer('M-COMPR-NESTED-NEVER')
	public function testANestedBuildFolds(): Void {
		Assert.equals(
			fn(
				'// create empty array\n'
				+ '\t\tfinal out:Array<Array<P>> = [for (_ in 0...v + 1) [for (j in 0...h + 1) { name: \'\', x: 0 }]];'
			),
			applyFix(fn(NESTED))
		);
	}

	@:pin('control') @:killer('M-COMPR-GAP-COMMENT-DROPPED')
	public function testAnOwnLineCommentBetweenTheDeclarationAndTheLoopIsHoisted(): Void {
		Assert.equals(
			fn('// doubled\n\t\tfinal out:Array<Int> = [for (x in xs) x * 2];'),
			applyFix(fn('final out:Array<Int> = [];\n\t\t// doubled\n\t\tfor (x in xs) out.push(x * 2);'))
		);
	}

	@:pin('control') @:killer('M-COMPR-NESTED-ANY-LENGTH')
	public function testAnExtraStatementInTheOuterBodyIsRefused(): Void {
		assertOuterKept(applyFix(fn(NESTED.replace('out.push(arr);', 'out.push(arr);\n\t\t\ttrace(1);'))));
	}

	@:pin('control') @:killer('M-COMPR-NESTED-PUSH-ANY')
	public function testAnOuterPushOfSomethingElseIsRefused(): Void {
		Assert.equals(0, count(fn(NESTED.replace('out.push(arr);', 'out.push(other);'))));
	}

	@:pin('control') @:killer('M-COMPR-NESTED-INNER-UNCHECKED')
	public function testAnInnerFillReadingTheInnerArrayIsRefused(): Void {
		Assert.equals(0, count(fn(NESTED.replace('{ name: \'\', x: 0 }', '{ name: \'\', x: arr.length }'))));
	}

	@:pin('control') @:killer('M-COMPR-NESTED-CHECKS-UNMERGED')
	public function testAnInnerFillReadingTheOuterArrayIsRefused(): Void {
		assertOuterKept(applyFix(fn(NESTED.replace('{ name: \'\', x: 0 }', '{ name: \'\', x: out.length }'))));
	}

	@:pin('control') @:killer('M-COMPR-NESTED-ASCRIPTION-DROPPED')
	public function testAnInnerAnnotationTheOuterDoesNotRestateIsAscribed(): Void {
		Assert.equals(
			fn('final out:Array<Dynamic> = [for (x in xs) ([for (j in 0...x) j] : Array<Float>)];'),
			applyFix(fn(
				'final out:Array<Dynamic> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal arr:Array<Float> = [];\n'
				+ '\t\t\tfor (j in 0...x) arr[j] = j;\n\t\t\tout.push(arr);\n\t\t}'
			))
		);
	}

	/** A `Map` index write is no append (the fold does not compile), and an `@:arrayAccess` setter would never run. */
	@:pin('control') @:killer('M-COMPR-INDEXFILL-ANY-CONTAINER')
	public function testAnIndexFillIntoANonArrayIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Map<Int, String> = [];\n\t\tfor (j in 0...n) out[j] = \'x\';')));
		Assert.equals(0, count(fn('final out:Logged = [];\n\t\tfor (j in 0...n) out[j] = j;')));
		Assert.equals(0, count(fn(NESTED.replace('final arr:Array<P> = [];', 'final arr:Map<Int, P> = [];'))));
		Assert.equals(0, count(fn(NESTED.replace('final arr:Array<P> = [];', 'final arr:Logged = [];'))));
	}

	@:pin('control') @:killer('M-COMPR-INDEXFILL-RANGE-UNCHECKED')
	public function testAnIndexFillBoundedByTheArrayIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Array<Int> = [];\n\t\tfor (j in 0...out.length) out[j] = j;')));
	}

	/** Two comments code separated would be welded by the hoist, which the linter's guard answers by dropping the file's edits. */
	@:pin('control') @:killer('M-COMPR-WELD-BLIND')
	public function testAHoistThatWouldWeldTwoCommentsIsRefused(): Void {
		Assert.equals(
			0, count(fn('final out:Array<Int> = [];\n\t\t// gap\n\t\tfor (j in 0...n) {\n\t\t\t// inner\n\t\t\tout.push(j);\n\t\t}'))
		);
		Assert.equals(
			0, count(fn('final out:Array<Int> = [];\n\t\tfor (j in 0...n) {\n\t\t\t// inner\n\t\t\tout[j] = j;\n\t\t\t// tail\n\t\t}'))
		);
		Assert.equals(
			1, count(fn('final out:Array<Int> = [];\n\t\t// gap\n\t\t// more\n\t\tfor (j in 0...n) out.push(j);')), 'adjacent comments'
		);
	}

	/**
	 * An inner array named like the outer one shadows it: `out.push(out)` pushes the inner array into
	 * itself. No gate of its own refuses it — the push argument IS the outer name, so the outer
	 * self-reference gate does.
	 */
	public function testAnInnerArrayShadowingTheOuterIsRefused(): Void {
		final fixed: String = applyFix(fn(
			'final out:Array<Dynamic> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal out:Array<Int> = [];\n'
			+ '\t\t\tfor (j in 0...x) out[j] = j;\n\t\t\tout.push(out);\n\t\t}'
		));
		Assert.isTrue(fixed.indexOf('out.push(out);') >= 0, fixed);
	}

	/** A comment inside the inner declaration would be stranded by dissolving it. */
	@:pin('control') @:killer('M-COMPR-NESTED-DECL-COMMENT')
	public function testACommentInsideTheInnerDeclarationRefusesTheNest(): Void {
		final fixed: String = applyFix(fn(NESTED.replace('final arr:Array<P> = [];', 'final arr:Array<P> = /* seed */ [];')));
		Assert.isTrue(fixed.indexOf('/* seed */') >= 0, fixed);
		Assert.isTrue(fixed.indexOf('out.push(arr);') >= 0, fixed);
	}

	/** A comment trailing the declaration annotates it, so it still refuses rather than moving. */
	public function testACommentTrailingTheDeclarationStillRefuses(): Void {
		Assert.equals(0, count(fn('final out:Array<Int> = []; // seed\n\t\tfor (j in 0...n) out[j] = j;')));
	}

	/**
	 * The OUTER build of a refused cell stays a loop. The inner declaration and its fill are a pair of
	 * their own, which the rule folds on its own merits, so the cell asserts what it refuses rather than a count.
	 */
	private function assertOuterKept(fixed: String): Void {
		Assert.isTrue(fixed.indexOf('out.push(arr);') >= 0, fixed);
		Assert.isTrue(fixed.indexOf('final arr:Array<P> = [for (j in 0...h + 1)') >= 0, fixed);
	}

	private function fn(stmts: String): String {
		return
			'class C {\n\tfunction f(xs:Array<Int>, n:Int, k:Int, v:Int, h:Int, other:Array<P>):Dynamic {\n\t\t$stmts\n\t\treturn out;\n\t}\n}';
	}

	private function count(source: String): Int {
		return new PreferComprehension().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()).length;
	}

	private function applyFix(source: String): String {
		return CheckFixture.fixedSource(new PreferComprehension(), source);
	}

}
