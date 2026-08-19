package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.StdlibDupScan;
import utest.Assert;
import utest.Test;

/**
 * `StdlibDupScan` -- the candidate filter behind `apq stdlib-dup`. Each test drives an in-memory
 * source through a real `HaxeQueryPlugin` and asserts BOTH what survived and which stage refused
 * the rest: the per-stage counts are the filter's real output, so a test that only counted
 * candidates could not tell "refused for the right reason" from "refused by accident".
 *
 * Fixture sources are written in DOUBLE quotes so a `$` inside a fixture's own single-quoted
 * string stays literal rather than becoming an interpolation of the test file.
 */
class StdlibDupScanTest extends Test {

	/**
	 * The motivating shape -- a hand-rolled zero-pad whose name matches no stdlib name and whose
	 * signature matches no stdlib signature -- is admitted, with its parameter types resolved and
	 * the `'0'` lifted out of the INTERPOLATION FRAGMENT of `'0$str'`. That literal is the whole
	 * point: it is never a literal node of its own, and without it the mapping search has no
	 * constant to feed the pad-character slot.
	 */
	public function testPadDigitShapeAdmitted(): Void {
		final result: ScanResult = scan(padDigitSource());
		Assert.equals(1, result.candidates.length);

		final candidate: StdlibCandidate = result.candidates[0];
		Assert.equals('padDigit', candidate.name);
		Assert.equals('C', candidate.owner);
		Assert.equals('String', candidate.returnType);
		Assert.equals(2, candidate.params.length);
		Assert.equals('i', candidate.params[0].name);
		Assert.equals('Int', candidate.params[0].type);
		Assert.equals('digits', candidate.params[1].type == 'Int' ? 'digits' : 'MISTYPED', candidate.params[1].name);
		Assert.equals(0, candidate.source.indexOf('function padDigit('), 'source starts at the keyword: ${candidate.source}');
		Assert.isTrue(literalCodes(candidate).contains("'0'"), 'body literals: ${literalCodes(candidate)}');
	}

	/** A body reading an instance field is not self-contained -- it reaches the last gate and dies there. */
	public function testInstanceStateRefused(): Void {
		final source: String = "class C {\n\tvar width:Int = 2;\n\tfunction pad(i:Int):String {\n\t\tvar s:String = '' + i;\n"
			+ "\t\twhile (s.length < width) s = '0' + s;\n\t\treturn s;\n\t}\n}";
		final result: ScanResult = scan(source);
		Assert.equals(0, result.candidates.length);
		Assert.equals(1, result.stages.primitiveSig, 'the signature gate must PASS so the refusal is the self-containment one');
		Assert.equals(0, result.stages.selfContained);
	}

	/** A body calling into project code is not self-contained, however primitive its signature is. */
	public function testProjectCallRefused(): Void {
		final source: String = 'class C {\n\tfunction pad(i:Int):String return Helper.pad(i);\n}';
		final result: ScanResult = scan(source);
		Assert.equals(0, result.candidates.length);
		Assert.equals(1, result.stages.primitiveSig);
		Assert.equals(0, result.stages.selfContained);
	}

	/** `this` is a free name under the self-containment rule, so a method using it is refused by it. */
	public function testThisRefused(): Void {
		final source: String = "class C {\n\tvar n:Int = 1;\n\tfunction pad(i:Int):String return '' + (i + this.n);\n}";
		final result: ScanResult = scan(source);
		Assert.equals(0, result.candidates.length);
		Assert.equals(1, result.stages.primitiveSig);
		Assert.equals(0, result.stages.selfContained);
	}

	/** A non-primitive parameter, and an un-annotated return, both die at the signature gate. */
	public function testNonPrimitiveSignatureRefused(): Void {
		final parametric: ScanResult = scan("class C {\n\tfunction join(xs:Array<Int>):String return '' + xs.length;\n}");
		Assert.equals(1, parametric.stages.arityOk, 'arity is fine; the TYPE is what refuses it');
		Assert.equals(0, parametric.stages.primitiveSig);

		final inferred: ScanResult = scan('class C {\n\tfunction twice(i:Int) return i * 2;\n}');
		Assert.equals(1, inferred.stages.arityOk);
		Assert.equals(0, inferred.stages.primitiveSig, 'an un-annotated return is refused, never inferred');
	}

	/** Arity above the cap, an optional parameter, and a defaulted one are each refused before typing. */
	public function testArityAndOptionalityRefused(): Void {
		final wide: ScanResult = scan('class C {\n\tfunction f(a:Int, b:Int, c:Int, d:Int):Int return a;\n}');
		Assert.equals(1, wide.stages.bodied);
		Assert.equals(0, wide.stages.arityOk);

		final optional: ScanResult = scan('class C {\n\tfunction f(?a:Int):Int return 1;\n}');
		Assert.equals(0, optional.stages.arityOk);

		final defaulted: ScanResult = scan('class C {\n\tfunction f(a:Int = 2):Int return a;\n}');
		Assert.equals(0, defaulted.stages.arityOk);

		final nullary: ScanResult = scan('class C {\n\tfunction f():Int return 1;\n}');
		Assert.equals(0, nullary.stages.arityOk, 'a nullary function has no input to drive a differential with');
	}

	/** A body may recurse, declare locals, loop, and call the deterministic stdlib -- all still self-contained. */
	public function testRecursionLocalsAndStdlibAdmitted(): Void {
		final source: String = "class C {\n\tfunction repeat(s:String, n:Int):String {\n\t\tvar out:String = '';\n"
			+ '\t\tfor (step in 0...n) out = out + s;\n\t\treturn out + Std.string(Math.abs(n));\n\t}\n'
			+ '\tfunction down(n:Int):Int return n <= 0 ? 0 : down(n - 1);\n}';
		final result: ScanResult = scan(source);
		Assert.equals(2, result.candidates.length, 'the loop binder, the local and the recursion are all bound names');
	}

	/** A non-deterministic stdlib member cannot be differentially compared, so a body touching one is refused. */
	public function testNonDeterministicRefused(): Void {
		final result: ScanResult = scan('class C {\n\tfunction pick(n:Int):Int return Std.int(Math.random() * n);\n}');
		Assert.equals(1, result.stages.primitiveSig);
		Assert.equals(0, result.stages.selfContained);
	}

	/** Allocation and `throw` are refused outright -- neither survives being lifted into a bare probe module. */
	public function testAllocationAndThrowRefused(): Void {
		final allocating: ScanResult = scan('class C {\n\tfunction f(n:Int):String return new StringBuf().toString() + n;\n}');
		Assert.equals(0, allocating.stages.selfContained);

		final throwing: ScanResult = scan("class C {\n\tfunction f(n:Int):Int {\n\t\tif (n < 0) throw 'bad';\n\t\treturn n;\n\t}\n}");
		Assert.equals(1, throwing.stages.primitiveSig);
		Assert.equals(0, throwing.stages.selfContained);
	}

	/** `scanAll` sums the stage counts and keeps candidates in input-file order. */
	public function testScanAllAggregates(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'src/A.hx', source: padDigitSource() },
			{ file: 'src/B.hx', source: 'class B {\n\tfunction twice(i:Int):Int return i * 2;\n}' }
		];
		final result: ScanResult = StdlibDupScan.scanAll(files, new HaxeQueryPlugin());
		Assert.equals(2, result.stages.selfContained);
		Assert.equals('src/A.hx', result.candidates[0].file);
		Assert.equals('src/B.hx', result.candidates[1].file);
	}

	/** The motivating case, spelled the way the real tree spells it. */
	private static inline function padDigitSource(): String {
		return "class C {\n\tprivate function padDigit(i:Int, digits:Int):String {\n\t\tvar str:String = '$i';\n"
			+ "\t\twhile (str.length < digits) str = '0$str';\n\t\treturn str;\n\t}\n}";
	}

	/** The verbatim spellings of a candidate's lifted body literals. */
	private static function literalCodes(candidate: StdlibCandidate): Array<String> {
		return [for (literal in candidate.literals) literal.code];
	}

	/** One in-memory file through a real Haxe plugin. */
	private static function scan(source: String): ScanResult {
		return StdlibDupScan.scan('src/C.hx', source, new HaxeQueryPlugin());
	}

}
