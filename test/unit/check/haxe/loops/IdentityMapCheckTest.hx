package unit.check.haxe.loops;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Severity;
import anyparse.check.haxe.loops.IdentityMap;

/**
 * The `identity-map` check: a map handing every element of an `Array` back unchanged — `xs.map(x -> x)`,
 * `xs.map(x -> (x : T))` and the comprehensions of both — is flagged `Info`. A bare binder is a copy, `xs.copy()`; an
 * ascribed one widens the element type, so the array carries the ascription, `(xs : Array<T>)`, copied unless a copying
 * call already follows. Another collection, a value-type element, a real mapping and a comment in the dropped text are left
 * alone.
 */
class IdentityMapCheckTest extends Test {

	public function testBareMapIsACopy(): Void {
		final vs: Array<Violation> = violations(wrap('final ys = ps.map(p -> p);'));
		Assert.equals(1, vs.length);
		Assert.equals('identity-map', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this map hands every element back unchanged — it is a copy of the array', vs[0].message);
		Assert.equals(wrap('final ys = ps.copy();'), fixed(wrap('final ys = ps.map(p -> p);')));
		Assert.equals(wrap('final ys = ps.copy();'), fixed(wrap('final ys = ps.map((p) -> (p));')));
	}

	/** The ascribed map is the array ascribed; the result may be mutated, so it is copied. */
	@:pin('control')
	@:killer('M-IM-ALWAYS-CHAINED')
	public function testAscribedMapIsTheArrayAscribedAndCopied(): Void {
		final vs: Array<Violation> = violations(wrap('final ys = ps.map(p -> (p : Null<P>));'));
		Assert.equals(1, vs.length);
		Assert.equals('this map only widens the element type — the array itself can carry the ascription', vs[0].message);
		Assert.equals(wrap('final ys = (ps : Array<Null<P>>).copy();'), fixed(wrap('final ys = ps.map(p -> (p : Null<P>));')));
	}

	/** A copying call after the map copies already, so the rewrite adds none. */
	@:pin('control')
	@:killer('M-IM-CHAIN-COPIES')
	public function testCopyingCallAfterTheMapNeedsNoCopy(): Void {
		Assert.equals(
			wrap('final ys = (ps : Array<Null<P>>).concat([null]);'), fixed(wrap('final ys = ps.map(p -> (p : Null<P>)).concat([null]);'))
		);
		Assert.equals(wrap('final ys = ps.filter(f);'), fixed(wrap('final ys = ps.map(p -> p).filter(f);')));
		Assert.equals(wrap('final ys = ps.slice(1);'), fixed(wrap('final ys = [for (p in ps) p].slice(1);')));
		Assert.equals(wrap('final ys = (ps : Array<Null<P>>).join(k);'), fixed(wrap('final ys = ps.map(p -> (p : Null<P>)).join(k);')));
	}

	public function testComprehensionForms(): Void {
		Assert.equals(wrap('final ys = ps.copy();'), fixed(wrap('final ys = [for (p in ps) p];')));
		Assert.equals(wrap('final ys = (ps : Array<Null<P>>).copy();'), fixed(wrap('final ys = [for (p in ps) (p : Null<P>)];')));
	}

	/** `List.map` returns a `List` and an iterator has none: the array is not the map's result there. */
	@:pin('control')
	@:killer('M-IM-ARRAY-ONLY')
	public function testOtherCollectionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = pl.map(p -> p);')).length);
		Assert.equals(0, violations(wrap('final ys = pl.map(p -> (p : Null<P>));')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in pl) p];')).length);
		Assert.equals(0, violations(wrap('final ys = vs.map(p -> p);')).length);
	}

	/**
	 * `Array<Int>` unifies with `Array<Null<Int>>`, but a static target lays the two out differently, so a map over value-type
	 * elements — written, aliased or behind an abstract — is no finding, whether it widens through the ascription or the
	 * expected type, and the compiler cannot decide it.
	 */
	@:pin('control')
	@:killer('M-IM-VALUE-TYPE')
	public function testValueTypeElementNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = xs.map(x -> (x : Null<Int>));')).length);
		Assert.equals(0, violations(wrap('final ys = [for (x in xs) (x : Float)];')).length);
		Assert.equals(0, violations(wrap('final ys = xs.map(x -> x);')).length);
		Assert.equals(0, violations(wrap('final ys = [for (x in xs) x];')).length);
		Assert.equals(0, violations(wrap('final ys = xs.map(x -> (x : Dynamic));')).length);
	}

	/** An abstract or an alias over a value type is one: the layout follows what the array holds. */
	@:pin('control')
	@:killer('M-IM-OVER-VALUE-TYPE')
	public function testAbstractAndAliasOverValueTypeNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = ns.map(n -> n);')).length);
		Assert.equals(0, violations(wrap('final ys = ids.map(i -> (i : Null<Id>));')).length);
		Assert.equals(1, violations(wrap('final ys = ss.map(s -> s);')).length);
	}

	/** Only a body that is the binder, bare or ascribed, is the identity. */
	@:pin('control')
	@:killer('M-IM-REAL-MAP')
	public function testRealMappingNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = xs.map(x -> x + 1);')).length);
		Assert.equals(0, violations(wrap('final ys = xs.map(x -> k);')).length);
		Assert.equals(0, violations(wrap('final ys = ps.map(p -> (q : Null<P>));')).length);
		Assert.equals(0, violations(wrap('final ys = ps.map(function(p) return p);')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) if (f(p)) p];')).length);
	}

	/** The rewrite drops the lambda around the element, so a comment there would go with it. */
	@:pin('control')
	@:killer('M-IM-COMMENT')
	public function testCommentInDroppedTextNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = ps.map(p -> /* same */ p);')).length);
		Assert.equals(0, violations(wrap('final ys = ps.map(p -> (p : /* wide */ Null<P>));')).length);
		Assert.equals(1, violations(wrap('final ys = ps.map(p -> (p : Null</* kept */ P>));')).length);
	}

	public function testDefaultOffAndRisky(): Void {
		Assert.isTrue(Std.isOfType(new IdentityMap(), DefaultOff));
		Assert.isTrue(Std.isOfType(new IdentityMap(), RiskyFix));
	}

	/** A method may hand back an array it holds, whatever it is named: the map of its result is copied. */
	@:pin('guard')
	public function testUserMethodIterableKeepsTheCopy(): Void {
		Assert.equals(wrap('final ys = a.slice(1).copy();'), fixed(wrap('final ys = [for (p in a.slice(1)) p];')));
		Assert.equals(wrap('final ys = a.filter(f).copy();'), fixed(wrap('final ys = a.filter(f).map(p -> p);')));
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new IdentityMap(), src);
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new IdentityMap(), src);
	}

	private static function wrap(statement: String): String {
		return 'class P {}\n\nabstract N(Int) {}\n\ntypedef Id = Int;\n\nenum abstract S(String) {}\n\nclass A {\n'
			+ '\tpublic function slice(n: Int): Array<P> {\n\t\treturn [];\n\t}\n\n\tpublic function filter(p: P -> Bool): Array<P> {\n'
			+ '\t\treturn [];\n\t}\n}\n\nclass C {\n\tfunction run(xs: Array<Int>, ps: Array<P>, pl: List<P>, a: A, k: Int, q: P, f: P -> '
			+ 'Bool, ns: Array<N>, ids: Array<Id>, ss: Array<S>, vs: Vector<P>): Void {\n\t\t$statement\n\t}\n}';
	}

}
