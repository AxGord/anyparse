package unit.check.common.loops;

import anyparse.check.common.loops.PreferComprehension;

/**
 * `prefer-comprehension` over a MAP FILL: a fresh `Map<K, V>` binding filled by key right after its
 * declaration, `for (x in xs) m[k] = v;`, becomes `[for (x in xs) k => v]`. The loop and the comprehension
 * both evaluate the key then the value and the later pair for a repeated key wins in both, so a repeated key
 * is no refusal. Each refusal differs from its fold by one construct.
 */
@:nullSafety(Strict)
class PreferComprehensionMapFillTest extends Test {

	@:pin('control')
	@:killer('M-COMPR-MAPFILL-NEVER')
	public function testAMapFillFolds(): Void {
		Assert.equals(
			fn('final out:Map<Int, String> = [for (x in xs) x * 2 => \'v\' + x];'),
			applyFix(fn('final out:Map<Int, String> = [];\n\t\tfor (x in xs) out[x * 2] = \'v\' + x;'))
		);
		Assert.equals(
			fn('final out:Map<Int, Int> = [for (x in xs) x % 2 => x];'),
			applyFix(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) {\n\t\t\tout[x % 2] = x;\n\t\t}'))
		);
		Assert.equals(
			fn('final out:Map<Int, Int> = [for (j in 0...n) j => j];'),
			applyFix(fn('var out:Map<Int, Int> = [];\n\t\tfor (j in 0...n) out[j] = j;'))
		);
	}

	/** The report and the fix type an operand over the same index, so a computed key the fix proves is also reported. */
	@:pin('control')
	@:killer('M-COMPR-MAPFILL-RUN-NO-INDEX')
	public function testAComputedKeyIsReportedAsWellAsFixed(): Void {
		Assert.equals(1, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) out[x * 2] = x;')));
	}

	public function testAPlainIfFilterIsKept(): Void {
		Assert.equals(
			fn('final out:Map<Int, Int> = [for (x in xs) if (x > 1) x => x];'),
			applyFix(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) if (x > 1) out[x] = x;'))
		);
	}

	public function testNestedLoopsFold(): Void {
		Assert.equals(
			fn('final out:Map<Int, Int> = [for (x in xs) for (y in xs) x + y => x];'),
			applyFix(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) for (y in xs) out[x + y] = x;'))
		);
	}

	@:pin('control')
	@:killer('M-COMPR-MAPFILL-ANY-CONTAINER')
	public function testAKeyedWriteIntoANonMapIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Array<Int> = [];\n\t\tfor (x in xs) out[k] = x;')));
		Assert.equals(0, count(fn('final out:Logged = [];\n\t\tfor (x in xs) out[x] = x;')));
		Assert.equals(0, count(fn('final out = [];\n\t\tfor (x in xs) out[k] = x;')));
	}

	@:pin('control')
	@:killer('M-COMPR-MAPFILL-VALUE-UNCHECKED')
	public function testAValueReadingTheMapIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) out[x] = (out.get(x - 1) : Int);')));
	}

	@:pin('control')
	@:killer('M-COMPR-MAPFILL-KEY-UNCHECKED')
	public function testAKeyReadingTheMapIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) out[(out.count() : Int)] = x;')));
	}

	public function testAnIterableOrFilterReadingTheMapIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in out.keys()) out[x] = x;')));
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) if (out.exists(x)) out[x] = x;')));
	}

	@:pin('control')
	@:killer('M-COMPR-MAPFILL-WHILE')
	public function testAWhileLoopIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\twhile (k < n) out[k] = k;')));
	}

	@:pin('guard')
	public function testAGuardOtherThanAPlainIfIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) if (x > 1) out[x] = x; else out[0] = x;')));
		Assert.equals(
			0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) {\n\t\t\tif (x < 1) continue;\n\t\t\tout[x] = x;\n\t\t}'))
		);
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) {\n\t\t\tfinal y = x + 1;\n\t\t\tout[y] = x;\n\t\t}')));
	}

	@:pin('guard')
	public function testAnotherWriteShapeIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) out[x] += 1;')));
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) other[x] = x;')));
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) out.set(x, x);')));
	}

	public function testANestedMapBuildIsLeftToItsInnerPair(): Void {
		Assert.equals(
			fn(
				'final out:Array<Map<Int, Int>> = [];\n\t\tfor (y in xs) {\n'
				+ '\t\t\tfinal inner:Map<Int, Int> = [for (x in xs) x => y];\n\t\t\tout.push(inner);\n\t\t}'
			),
			applyFix(fn(
				'final out:Array<Map<Int, Int>> = [];\n\t\tfor (y in xs) {\n\t\t\tfinal inner:Map<Int, Int> = [];\n'
				+ '\t\t\tfor (x in xs) inner[x] = y;\n\t\t\tout.push(inner);\n\t\t}'
			))
		);
	}

	/**
	 * A map comprehension is invariant against `Map<K, V>`: a value the typing cannot show exactly V stays the loop.
	 */
	@:pin('control')
	@:killer('M-COMPR-MAPFILL-VALUE-UNPROVEN')
	public function testAValueNotProvenTheDeclaredTypeIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Map<Int, Float> = [];\n\t\tfor (x in xs) out[x] = x;')));
		Assert.equals(0, count(fn('final out:Map<Int, Base> = [];\n\t\tfor (x in xs) out[x] = new Child();')));
	}

	/**
	 * The key side of the same invariance: a wider, narrower or null-narrowed key stays the loop.
	 */
	@:pin('control')
	@:killer('M-COMPR-MAPFILL-KEY-UNPROVEN')
	public function testAKeyNotProvenTheDeclaredTypeIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Map<Float, Int> = [];\n\t\tfor (x in xs) out[x] = x;')));
		Assert.equals(0, count(fn('final out:Map<String, Bool> = [];\n\t\tfor (n in nodes) if (n.name != null) out[n.name] = true;')));
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (a => b in other) out[a] = b;')));
	}

	@:pin('control')
	@:killer('M-COMPR-MAPFILL-MESSAGE-ARRAY')
	public function testAMapSiteHasItsOwnMessage(): Void {
		final found: Array<Violation> = CheckFixture.violations(
			new PreferComprehension(), fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) out[x] = x;')
		);
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('map comprehension') >= 0, found[0].message);
	}

	/**
	 * A key shape the typing does not prove (conditional, cast, untyped) stays the loop.
	 */
	@:pin('guard')
	public function testAKeyThatNeedsGroupingIsRefused(): Void {
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) out[x > 1 ? 1 : 2] = x;')));
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) out[cast x] = x;')));
		Assert.equals(0, count(fn('final out:Map<Int, Int> = [];\n\t\tfor (x in xs) out[untyped x] = x;')));
	}

	private function fn(stmts: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, n:Int, k:Int, other:Map<Int, Int>, nodes:Array<{ name:Null<String> }>):Dynamic {\n'
			+ '\t\t$stmts\n\t\treturn out;\n\t}\n}';
	}

	private function count(source: String): Int {
		return CheckFixture.violations(new PreferComprehension(), source).length;
	}

	private function applyFix(source: String): String {
		return CheckFixture.fixedSource(new PreferComprehension(), source);
	}

}
