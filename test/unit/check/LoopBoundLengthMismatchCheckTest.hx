package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.LoopBoundLengthMismatch;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `loop-bound-length-mismatch` check: an indexed loop reading `xs[i]` whose bound is not the
 * expression `xs`'s length provably comes from — a loop filling it in the constructor or its own
 * block, a literal, a fixed-length construction. Every refusal below is a shape where the length
 * is NOT proven, and the check stays silent there.
 */
class LoopBoundLengthMismatchCheckTest extends Test {

	/** A field filled in the constructor to a parameter, read by a loop running to a constant: the motivating shape. */
	@:pin('control') @:killer('M-LOOPBOUND-SILENT')
	public function testAFieldFilledInTheConstructorIsReportedAgainstAnUnrelatedBound(): Void {
		final vs: Array<Violation> = violations(GRID);
		Assert.equals(1, vs.length);
		Assert.equals('loop-bound-length-mismatch', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('the length of `points` comes from `numPoints` (line 8), this loop runs to `G.N + 1`', vs[0].message);
	}

	/** A local filled by a loop of its own block; the loop that runs to the same bound is not reported. */
	@:pin('control') @:killer('M-LOOPBOUND-SILENT')
	public function testALocalFilledByALoopIsReported(): Void {
		final vs: Array<Violation> = violations(fn(
			'final xs:Array<Int> = [];\n\t\tfor (k in 0...n) xs.push(k);\n'
			+ '\t\tfor (i in 0...n) trace(xs[i]);\n\t\tfor (i in 0...n + 1) trace(xs[i]);'
		));
		Assert.equals(1, vs.length);
		Assert.equals('the length of `xs` comes from `n` (line 4), this loop runs to `n + 1`', vs[0].message);
	}

	/** A literal's length is its element count. */
	@:pin('control') @:killer('M-LOOPBOUND-SILENT')
	public function testALiteralIsItsElementCount(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tstatic final DIRS:Array<Int> = [1, 2, 3, 4];\n\n\tfunction f():Void {\n\t\tfor (i in 0...4) trace(DIRS[i]);\n'
			+ '\t\tfor (i in 0...5) trace(DIRS[i]);\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('the length of `DIRS` comes from its 4-element literal (line 2), this loop runs to `5`', vs[0].message);
	}

	/** A fixed-length construction is a length, and an index WRITE does not resize it. */
	@:pin('control') @:killer('M-LOOPBOUND-SILENT', 'M-LOOPBOUND-FIXED-WRITE')
	public function testAFixedLengthConstructionIsItsArgument(): Void {
		final vs: Array<Violation> = violations(
			fn('final v:haxe.ds.Vector<Int> = new haxe.ds.Vector(3);\n\t\tv[0] = 1;\n' + '\t\tfor (i in 0...n) trace(v[i]);')
		);
		Assert.equals(1, vs.length);
		Assert.equals('the length of `v` comes from `3` (line 3), this loop runs to `n`', vs[0].message);
	}

	/** The simple name counts when the file imports exactly the fixed-length type's path. */
	@:pin('control') @:killer('M-LOOPBOUND-SILENT')
	public function testAnImportedSimpleNameIsTheFixedLengthType(): Void {
		Assert.equals(
			1,
			violations('import haxe.ds.Vector;\n\n' + fn('final v:Vector<Int> = new Vector(3);\n\t\tfor (i in 0...n) trace(v[i]);')).length
		);
	}

	/** Without that import `Vector` may be a growable one (OpenFL's), so its length is not known. */
	@:pin('control') @:killer('M-LOOPBOUND-VECTOR-IMPORT')
	public function testAnUnimportedVectorIsNoFixedLengthType(): Void {
		Assert.equals(0, violations(fn('final v:Vector<Int> = new Vector(3);\n\t\tfor (i in 0...n) trace(v[i]);')).length);
	}

	/** Constants fold: `4 + 1` is `5`. */
	@:pin('control') @:killer('M-LOOPBOUND-FOLD-OFF')
	public function testFoldedConstantsCompareByValue(): Void {
		Assert.equals(
			0,
			violations(
				fn('final xs:Array<Int> = [];\n\t\tfor (k in 0...5) xs.push(k);\n\t\tfor (i in 0...G.N + 1) trace(xs[i]);') + CONSTANTS
			).length
		);
	}

	/** A bound that names the array itself is related to its length by construction. */
	@:pin('control') @:killer('M-LOOPBOUND-RELATED-OFF')
	public function testABoundNamingTheArrayIsRelated(): Void {
		Assert.equals(0, violations(fn(fill('xs') + '\t\tfor (i in 0...xs.length - 1) trace(xs[i]);')).length);
	}

	/** Arrays appended in one loop share its bound, so one's `length` bounds the other. */
	@:pin('control') @:killer('M-LOOPBOUND-RELATED-OFF')
	public function testParallelArraysShareTheirBound(): Void {
		Assert.equals(
			0,
			violations(fn(
				'final a:Array<Int> = [];\n\t\tfinal b:Array<Int> = [];\n\t\tfor (k in 0...n) {\n\t\t\ta.push(k);\n'
				+ '\t\t\tb.push(k);\n\t\t}\n\t\tfor (i in 0...a.length) trace(b[i]);'
			)).length
		);
	}

	/** A read of `xs[i + 1]` moves the loop's reach one past its bound. */
	@:pin('control') @:killer('M-LOOPBOUND-REACH-IGNORED')
	public function testAReadPastTheIndexMovesTheReach(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tstatic final F:Array<Int> = [1, 2, 3, 4, 5];\n\n\tfunction f():Void {\n\t\tfor (r in 0...4) trace(F[r] + F[r + 1]);\n'
			+ '\t\tfor (r in 0...5) trace(F[r + 1]);\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals(
			'the length of `F` comes from its 5-element literal (line 2), this loop runs to `5` and reads `F[r + 1]`', vs[0].message
		);
	}

	/** An array handed to a call may be resized there. */
	@:pin('control') @:killer('M-LOOPBOUND-ADMIT-ALL')
	public function testAnArrayHandedOutHasNoKnownLength(): Void {
		Assert.equals(0, violations(fn(fill('xs') + '\t\tconsume(xs);\n\t\tfor (i in 0...n + 1) trace(xs[i]);')).length);
	}

	/** An append outside the fill loop changes the length. */
	@:pin('control') @:killer('M-LOOPBOUND-ADMIT-ALL')
	public function testAnAppendOutsideTheFillLoopRefuses(): Void {
		Assert.equals(0, violations(GRID.replace('function f():Void {', 'function f():Void {\n\t\tpoints.push(9);')).length);
	}

	/** An index write extends an array. */
	@:pin('control') @:killer('M-LOOPBOUND-ARRAY-WRITE')
	public function testAnIndexWriteExtendsAnArray(): Void {
		Assert.equals(0, violations(fn(fill('xs') + '\t\txs[n] = 1;\n\t\tfor (i in 0...n + 1) trace(xs[i]);')).length);
	}

	/** A public field may be changed from another file. */
	@:pin('control') @:killer('M-LOOPBOUND-PUBLIC')
	public function testAPublicFieldIsNotConfined(): Void {
		Assert.equals(0, violations(GRID.replace('\tvar points', '\tpublic var points')).length);
	}

	/** A subtype that mentions the field may change it. */
	@:pin('control') @:killer('M-LOOPBOUND-CONFINED-OFF')
	public function testASubtypeMentioningTheFieldRefuses(): Void {
		final sub: String = 'class H extends G {\n\tfunction g():Void {\n\t\tpoints.push(1);\n\t}\n}';
		Assert.equals(
			0,
			new LoopBoundLengthMismatch().run([{ file: 'G.hx', source: GRID }, { file: 'H.hx', source: sub }], new HaxeQueryPlugin())
				.filter(v -> v.file == 'G.hx')
				.length
		);
	}

	/** A fill loop that may leave an iteration early appends fewer elements than its bound. */
	@:pin('control') @:killer('M-LOOPBOUND-EXITS')
	public function testAFillLoopThatMayJumpRefuses(): Void {
		Assert.equals(
			0,
			violations(fn(
				'final xs:Array<Int> = [];\n\t\tfor (k in 0...n) {\n\t\t\tif (k > 2) continue;\n\t\t\txs.push(k);\n'
				+ '\t\t}\n\t\tfor (i in 0...n + 1) trace(xs[i]);'
			)).length
		);
	}

	/** Two appends an iteration double the length. */
	public function testTwoAppendsInOneIterationRefuse(): Void {
		Assert.equals(
			0,
			violations(fn(
				'final xs:Array<Int> = [];\n\t\tfor (k in 0...n) {\n\t\t\txs.push(k);\n\t\t\txs.push(k);\n\t\t}\n'
				+ '\t\tfor (i in 0...n + 1) trace(xs[i]);'
			)).length
		);
	}

	/** A loop that only writes the array reads nothing past its end. */
	@:pin('control') @:killer('M-LOOPBOUND-WRITE-READ')
	public function testALoopThatOnlyWritesIsNotReported(): Void {
		Assert.equals(0, violations(fn('final v:haxe.ds.Vector<Int> = new haxe.ds.Vector(3);\n\t\tfor (i in 0...n) v[i] = 0;')).length);
	}

	/** A loop inside the fill loop reads an array still being filled, which is not the length this check compares. */
	@:pin('control') @:killer('M-LOOPBOUND-NESTED-FILL')
	public function testALoopInsideTheFillLoopIsNotChecked(): Void {
		Assert.equals(
			0,
			violations(fn(
				'final xs:Array<Int> = [];\n\t\tfor (k in 0...n) {\n\t\t\txs.push(k);\n' + '\t\t\tfor (j in 0...n + 1) trace(xs[j]);\n\t\t}'
			)).length
		);
	}

	/** A binder taking the field's name makes its bare occurrences ambiguous. */
	@:pin('control') @:killer('M-LOOPBOUND-SHADOW')
	public function testABinderTakingTheNameRefuses(): Void {
		Assert.equals(0, violations(GRID.replace('function f():Void {', 'function h(points:Int):Void {}\n\n\tfunction f():Void {')).length);
	}

	/** A local's name spelled ahead of its declaration belongs to another binding, so the local's length is not proven there. */
	@:pin('control') @:killer('M-LOOPBOUND-AHEAD')
	public function testANameAheadOfTheLocalRefuses(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tvar xs:Array<Int> = [1, 2];\n\n\tfunction f(n:Int):Void {\n\t\tfor (i in 0...n + 1) trace(xs[i]);\n'
				+ '\t\tfinal xs:Array<Int> = [];\n\t\tfor (k in 0...n) xs.push(k);\n\t}\n}'
			).length
		);
	}

	/** A literal holding a comprehension has no fixed element count. */
	@:pin('control') @:killer('M-LOOPBOUND-UNSIZED')
	public function testAComprehensionLiteralIsNoLength(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tstatic final F:Array<Int> = [for (i in 0...3) i];\n\n\tfunction f():Void {\n'
				+ '\t\tfor (i in 0...5) trace(F[i]);\n\t}\n}'
			).length
		);
	}

	/** A static field is filled once per construction, so its length grows with every instance. */
	@:pin('control') @:killer('M-LOOPBOUND-STATIC-FILL')
	public function testAStaticFieldFilledInTheConstructorRefuses(): Void {
		Assert.equals(
			0,
			violations(
				GRID.replace('\tvar points:Array<Int>;', '\tstatic var points:Array<Int> = [];')
					.replace('\t\tpoints = new Array<Int>();\n', '')
			).length
		);
	}

	/** `this.points` is an occurrence of the field like the bare name. */
	@:pin('control') @:killer('M-LOOPBOUND-SELF-REF')
	public function testASelfQualifiedReadIsAnOccurrence(): Void {
		Assert.equals(1, violations(GRID.replace('trace(points[i])', 'trace(this.points[i])')).length);
	}

	/** A declared type that is not the array type the source builds refuses. */
	@:pin('control') @:killer('M-LOOPBOUND-TYPE-OFF')
	public function testADeclaredTypeOtherThanTheBuiltOneRefuses(): Void {
		Assert.equals(
			0,
			violations(fn('final xs:Null<Array<Int>> = [];\n\t\tfor (k in 0...n) xs.push(k);\n' + '\t\tfor (i in 0...n + 1) trace(xs[i]);'))
				.length
		);
		Assert.equals(0, violations(fn('final v:Array<Int> = new haxe.ds.Vector(3);\n\t\tfor (i in 0...n) trace(v[i]);')).length);
	}

	/** The line the length comes from is a coordinate, masked out of the finding's identity. */
	public function testTheLineIsMaskedInTheIdentity(): Void {
		final message: String = violations(GRID)[0].message;
		final identity: String = new LoopBoundLengthMismatch().messageIdentity(message);
		Assert.isTrue(identity.indexOf('(line 8)') < 0, identity);
		Assert.equals(identity, new LoopBoundLengthMismatch().messageIdentity(identity));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('loop-bound-length-mismatch'));
	}

	/** The motivating fixture: a field filled `numPoints` times, read by a loop that runs to `G.N + 1`. */
	private static final GRID: String = 'class G {\n\tstatic inline final N:Int = 4;\n\n\tvar points:Array<Int>;\n\n'
		+ '\tpublic function new(numPoints:Int = 5) {\n\t\tpoints = new Array<Int>();\n\t\tfor (i in 0...numPoints) points.push(i);\n\t}\n\n'
		+ '\tfunction f():Void {\n\t\tfor (i in 0...G.N + 1) trace(points[i]);\n\t}\n}';

	/** A second type declaring the constant `G.N` the folding tests read. */
	private static final CONSTANTS: String = '\n\nclass G {\n\tpublic static inline final N:Int = 4;\n}';

	private function violations(src: String): Array<Violation> {
		return new LoopBoundLengthMismatch().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** A class holding one method `f(n)` with `body`. */
	private static function fn(body: String): String {
		return 'class C {\n\tfunction f(n:Int):Void {\n\t\t$body\n\t}\n}';
	}

	/** A local `name` filled by a loop to `n`, as statements of `fn`'s body. */
	private static function fill(name: String): String {
		return 'final $name:Array<Int> = [];\n\t\tfor (k in 0...n) $name.push(k);\n';
	}

}
