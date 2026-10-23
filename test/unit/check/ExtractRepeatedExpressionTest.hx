package unit.check;

import anyparse.check.ExtractRepeatedExpression;
import anyparse.check.Severity;

/**
 * The `extract-repeated-expression` check: a non-trivial, PURE value expression
 * repeated three or more co-executing times within one function body is flagged
 * `Info` as a candidate for a `final` local. Report-only — `fix` yields no edits.
 */
class ExtractRepeatedExpressionTest extends Test {

	public function testFieldChainRepeatedThriceFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function m() { k(a.b.c); k(a.b.c); k(a.b.c); } }');
		Assert.equals(1, vs.length);
		Assert.equals('extract-repeated-expression', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('a.b.c') != -1);
		Assert.isTrue(vs[0].message.indexOf('repeated 3 times') != -1);
	}

	public function testTwoOccurrencesNotFlagged(): Void {
		Assert.equals(0, violations('class C { function m() { k(a.b.c); k(a.b.c); } }').length);
	}

	public function testCalleeOfCallNotCounted(): Void {
		// The callee position holds a method REFERENCE, not a value: hoisting `a.b.c` out of
		// `a.b.c(...)` binds a method, which is never what the suggestion means. The receiver
		// `a.b` is left as the only value candidate, and it is a single hop — trivial.
		Assert.equals(0, violations('class C { function m() { a.b.c(1); a.b.c(2); a.b.c(3); } }').length);
	}

	public function testCalleeReceiverStillCountedWhenNonTrivial(): Void {
		// Excluding the callee does not blind the check to the value inside it: `a.b.c` is a
		// two-hop chain and a genuine repeated value, so it is reported in place of `a.b.c.d`.
		final vs: Array<Violation> = violations('class C { function m() { a.b.c.d(1); a.b.c.d(2); a.b.c.d(3); } }');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('`a.b.c`') != -1);
	}

	public function testRepeatedCallValueStillFlagged(): Void {
		// A repeated pure CALL is a value, not a callee — the gate must not touch it.
		final vs: Array<Violation> = violations('class C { function m(v:Float) { s(Std.int(v)); s(Std.int(v)); s(Std.int(v)); } }');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('Std.int(v)') != -1);
	}

	public function testSingleHopNotFlagged(): Void {
		// `this.x` is one hop and holds no call — caching it buys nothing.
		Assert.equals(0, violations('class C { var x:Int; function m() { p(this.x); p(this.x); p(this.x); } }').length);
	}

	public function testBareFieldAccessNotFlagged(): Void {
		// `a.b` is a single-hop read — trivial.
		Assert.equals(0, violations('class C { function m() { p(a.b); p(a.b); p(a.b); } }').length);
	}

	public function testImpureCallNotFlagged(): Void {
		// A local/instance call of unknown effect is impure — never a candidate.
		Assert.equals(0, violations('class C { function m() { f(getData()); f(getData()); f(getData()); } }').length);
	}

	public function testPureStdlibCallFlagged(): Void {
		final vs: Array<Violation> =
			violations('class C { function m(a:Int, b:Int) { s(Math.max(a, b)); s(Math.max(a, b)); s(Math.max(a, b)); } }');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('Math.max(a, b)') != -1);
	}

	public function testNonDeterministicCallExcluded(): Void {
		// `Std.random` is not referentially transparent — extracting would change behaviour.
		Assert.equals(0, violations('class C { function m() { u(Std.random(10)); u(Std.random(10)); u(Std.random(10)); } }').length);
	}

	/**
	 * Effect-free is not transparent. A `StringTools` iterator is a fresh, STATEFUL object per call — one shared by
	 * three loops is drained by the first — and `Date.now()` reads the clock. The scan's own `Math` / `Std` /
	 * `StringTools` list took every member but `random`, so it hoisted the iterator; the one stdlib table
	 * (`TypeResolver`) keeps both out of the transparent set.
	 */
	@:pin('control') @:killer('M-STD-EFFECT-FREE-AS-TRANSPARENT')
	public function testEffectFreeButNotTransparentCallExcluded(): Void {
		Assert.equals(
			0,
			violations(
				'class C { function m(s:String) { k(StringTools.iterator(s)); k(StringTools.iterator(s)); k(StringTools.iterator(s)); } }'
			).length,
			'a fresh iterator per call'
		);
		Assert.equals(0, violations('class C { function m() { k(Date.now()); k(Date.now()); k(Date.now()); } }').length, 'the clock');
	}

	/**
	 * A `String` method on a binding declared `String` and a `Path` static are pure stdlib calls too, and the scan
	 * now sees them through the same table the deletion predicates read — its own list knew neither. `split` answers a
	 * fresh mutable array, so it is not hoisted.
	 */
	@:pin('control') @:killer('M-STD-SPLIT-TRANSPARENT', 'M-PURE-STRING-METHOD-OFF')
	public function testStringMethodAndPathStaticAreTransparent(): Void {
		final upper: Array<Violation> =
			violations('class C { function m(s:String) { k(s.toUpperCase()); k(s.toUpperCase()); k(s.toUpperCase()); } }');
		Assert.equals(1, upper.length, 'a String method on a String binding');
		final path: Array<Violation> = violations(
			'import haxe.io.Path; class C { function m(p:String) { k(Path.directory(p)); k(Path.directory(p)); k(Path.directory(p)); } }'
		);
		Assert.equals(1, path.length, 'a Path static');
		Assert.equals(
			0, violations('class C { function m(s:String) { k(s.split(",")); k(s.split(",")); k(s.split(",")); } }').length,
			'a fresh array per split'
		);
	}

	/** A project type named like the std one is not the std one: its `int` may do anything. */
	@:pin('control') @:killer('M-STD-SHADOW-IGNORED')
	public function testProjectShadowOfAStdTypeExcluded(): Void {
		Assert.equals(
			0,
			violations(
				'class Std { public static function int(v:Float):Int return 0; } class C { function m(v:Float) {'
				+ ' s(Std.int(v)); s(Std.int(v)); s(Std.int(v)); } }'
			).length
		);
	}

	public function testMutuallyExclusiveBranchesExcluded(): Void {
		// One occurrence per exclusive switch case — only one runs, so a shared local is pointless.
		Assert.equals(
			0, violations('class C { function m(x:Int) { switch x { case 0: k(a.b.c); case 1: k(a.b.c); case 2: k(a.b.c); } } }').length
		);
	}

	public function testCoExecutingBranchOccurrencesFlagged(): Void {
		// Two occurrences co-execute in the then-branch, so the repeat is real.
		final vs: Array<Violation> = violations('class C { function m(c:Bool) { if (c) { k(a.b.c); k(a.b.c); } else { k(a.b.c); } } }');
		Assert.equals(1, vs.length);
	}

	public function testNestedFunctionIsSeparateBody(): Void {
		// Two in the outer body + one in a nested function — neither body reaches the threshold.
		Assert.equals(0, violations('class C { function m() { k(a.b.c); k(a.b.c); function inner() { k(a.b.c); } } }').length);
	}

	public function testSubsumedSubExpressionDropped(): Void {
		// Only the maximal chain is reported, not its equally-frequent prefix.
		final vs: Array<Violation> = violations('class C { function m() { k(a.b.c.d); k(a.b.c.d); k(a.b.c.d); } }');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('a.b.c.d') != -1);
	}

	public function testGetterReadExcluded(): Void {
		// A field read through a property GETTER is treated as impure (may have effects).
		final src: String = 'class D { public var prop(get, never):Int; function get_prop():Int return 1; } '
			+ 'class C { var obj:D; function m() { k(obj.prop.x); k(obj.prop.x); k(obj.prop.x); } }';
		Assert.equals(0, violations(src).length);
	}

	public function testFixYieldsNoEdits(): Void {
		final src: String = 'class C { function m() { k(a.b.c); k(a.b.c); k(a.b.c); } }';
		final check: ExtractRepeatedExpression = new ExtractRepeatedExpression();
		Assert.equals(0, CheckFixture.edits(check, src).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('extract-repeated-expression'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('extract-repeated-expression'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { k(a.b.c);').length);
	}

	/**
	 * The chain's first hop is a getter INHERITED from a supertype. `memberGetter` used to
	 * answer `null` there, so the chain read as pure and was extracted; resolving through the
	 * supertype makes it `true` — impure, and the group is dropped.
	 */
	public function testInheritedGetterReadExcluded(): Void {
		final src: String = 'class B { public var prop(get, never):Int; function get_prop():Int return 1; } class D extends B {} '
			+ 'class C { var obj:D; function m() { k(obj.prop.x); k(obj.prop.x); k(obj.prop.x); } }';
		Assert.equals(0, violations(src).length);
	}

	public function testMessageIdentityMasksTheOccurrenceTally(): Void {
		// Pinned against messages `run` produced, as `Check.VolatileMessage` requires: an
		// expression going from three occurrences to four is the same standing advisory about
		// the same body, so the tally leaves the blast-radius key.
		final check: ExtractRepeatedExpression = new ExtractRepeatedExpression();
		final three: String = CheckFixture.violations(check, 'class C { function m() { k(a.b.c); k(a.b.c); k(a.b.c); } }')[0].message;
		final four: String = CheckFixture.violations(
			check, 'class C { function m() { k(a.b.c); k(a.b.c); k(a.b.c); k(a.b.c); } }'
		)[0].message;
		Assert.notEquals(three, four);
		final identity: String = check.messageIdentity(three);
		Assert.isTrue(identity.indexOf('repeated # times in one function body') != -1);
		Assert.equals(identity, check.messageIdentity(four));
		Assert.equals(identity, check.messageIdentity(identity));
	}

	/**
	 * THE discriminating pair for the token-interior half. `norm` collapses whitespace inside a
	 * string literal, so three calls bucket together although two spell their argument `"  "`
	 * and one spells it `" "` — a group no single `final` local can stand for, reported at a
	 * span whose own bytes the message then contradicted. `splitByRender` separates them. The
	 * twin, where every occurrence spells the literal the same way, still reports, and its
	 * message quotes the two-space literal exactly as it is written.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-REPEAT-RENDER-SPLIT')
	public function testALiteralInteriorDifferenceSplitsTheGroup(): Void {
		final mixed: String = 'class C { function m(s:String) { k(StringTools.replace(s, "  ", "-")); '
			+ 'k(StringTools.replace(s, " ", "-")); k(StringTools.replace(s, "  ", "-")); } }';
		Assert.equals(0, violations(mixed).length, 'two spellings of one argument are not one repeated expression');
		final same: String = 'class C { function m(s:String) { k(StringTools.replace(s, "  ", "-")); '
			+ 'k(StringTools.replace(s, "  ", "-")); k(StringTools.replace(s, "  ", "-")); } }';
		final vs: Array<Violation> = violations(same);
		Assert.equals(1, vs.length);
		Assert.isTrue(
			vs[0].message.indexOf('StringTools.replace(s, "  ", "-")') != -1,
			'the message quotes the literal as written, not whitespace-collapsed'
		);
	}

	/**
	 * A named function expression and an `inline` local function are bodies of their own too: what they
	 * compute runs when they are CALLED, never where they are written, so their occurrences never count
	 * toward the enclosing body (`ShapeVocab.functionLikeKinds`).
	 */
	public function testEveryNestedFunctionFormIsSeparateBody(): Void {
		for (inner in [
			'final g = function named() { k(a.b.c); };',
			'inline function inl() { k(a.b.c); }'
		]) {
			final src: String = 'class C { function m() { k(a.b.c); k(a.b.c); $inner } }';
			Assert.equals(0, violations(src).length, inner);
		}
	}

	/**
	 * A write of an operand between two occurrences makes them different values — `i++` and `--i` here. The group is cut
	 * at the write's EFFECT point: the occurrences on either side are separate runs, and a run of fewer than three is no
	 * finding. The twins keep the threshold run whole: a write before every occurrence, three after the write, another
	 * local written in between.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-REPEAT-WRITE-SPLIT')
	public function testAnIncrementBetweenOccurrencesSplitsTheGroup(): Void {
		for (write in ['i++;', '--i;', '++i;', 'i--;'])
			Assert.equals(
				0, violations('class C { function m() { var i = 0; k(Std.int(i)); $write k(Std.int(i)); k(Std.int(i)); } }').length, write
			);
		Assert.equals(1, violations('class C { function m() { var i = 0; i++; k(Std.int(i)); k(Std.int(i)); k(Std.int(i)); } }').length);
		Assert.equals(
			1, violations('class C { function m() { var i = 0; var j = 0; k(Std.int(i)); j++; k(Std.int(i)); k(Std.int(i)); } }').length
		);
		final split: Array<Violation> = violations(
			'class C { function m() {'
			+ ' var i = 0; k(Std.int(i)); k(Std.int(i)); k(Std.int(i)); i++; k(Std.int(i)); k(Std.int(i)); k(Std.int(i)); } }'
		);
		Assert.equals(2, split.length, 'three before the write and three after it are two runs');
	}

	/**
	 * A plain and a compound assignment are writes too, a parenthesised target included, and a write takes effect at
	 * the END of its node: `i = Std.int(i) + 1` reads `i` first and writes it after, so the occurrence inside its own
	 * right-hand side and the two after it are not one value.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-REPEAT-WRITE-EFFECT', 'M-WRITE-SITES-PAREN-TARGET')
	public function testAnAssignmentBetweenOccurrencesSplitsTheGroup(): Void {
		for (write in ['i = 5;', 'i += 2;', 'i *= 2;', '(i) -= 1;'])
			Assert.equals(
				0, violations('class C { function m() { var i = 1; k(Std.int(i)); $write k(Std.int(i)); k(Std.int(i)); } }').length, write
			);
		Assert.equals(0, violations('class C { function m() { var i = 1.5; i = Std.int(i) + 1; k(Std.int(i)); k(Std.int(i)); } }').length);
		Assert.equals(
			1, violations('class C { function m() { var i = 1.5; var j = Std.int(i) + 1; k(Std.int(i)); k(Std.int(i)); } }').length
		);
		final other: String = 'class C { function m() { var i = 1; var j = 1; k(Std.int(i)); (j) -= 1; k(Std.int(i)); k(Std.int(i)); } }';
		Assert.equals(1, violations(other).length, 'a parenthesised write of another local');
	}

	/**
	 * A write of the field an occurrence reads — through `this.` or bare — and a write of a path below the occurrence's
	 * root (`a.b = …` under `a.b.c`) split the group as well: the root's storage changed.
	 */
	@:pin('control')
	@:killer('M-WRITE-SITES-SELF-FIELD', 'M-WRITE-SITES-MEMBER-TARGET', 'M-WRITE-SITES-INDEX-TARGET', 'M-WRITE-SITES-CAST-TARGET')
	public function testAFieldWriteBetweenOccurrencesSplitsTheGroup(): Void {
		for (write in [
			'this.a = null;',
			'a = null;',
			'a.b = null;',
			'a.b.c = null;',
			'cast(a, A).b = null;'
		]) Assert.equals(0, violations('class C { var a:A; function m() { k(a.b.c); $write k(a.b.c); k(a.b.c); } }').length, write);
		Assert.equals(1, violations('class C { var a:A; var z:A; function m() { k(a.b.c); this.z = null; k(a.b.c); k(a.b.c); } }').length);
		final indexed: String = 'class C { var a:A; var zs:Array<A>; function m() { k(a.b.c); zs[0] = null; k(a.b.c); k(a.b.c); } }';
		Assert.equals(1, violations(indexed).length, 'an index write of another member');
		final sibling: String = 'class C { var a:A; function m() { k(a.b.c); cast(a, A).z = null; k(a.b.c); k(a.b.c); } }';
		Assert.equals(1, violations(sibling).length, 'a write of a sibling member through a cast');
	}

	/**
	 * A group that IS an access chain holds a reference: a write below it (`a.b.c.d = …` under `a.b.c`) changes what
	 * the reference points at, never the reference. A value COMPUTED from the chain (`Std.int(a.b)`) is a different
	 * matter — what is below it is what it is computed from.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-REPEAT-REFERENCE-READ')
	public function testAWriteBelowAChainKeepsItsReference(): Void {
		Assert.equals(1, violations('class C { var a:A; function m() { k(a.b.c); a.b.c.d = null; k(a.b.c); k(a.b.c); } }').length);
		Assert.equals(
			0, violations('class C { var a:A; function m() { k(Std.int(a.b)); a.b.c = 1; k(Std.int(a.b)); k(Std.int(a.b)); } }').length
		);
	}

	/** A write inside a macro reification is code the macro EMITS, which runs nothing where it is written. */
	@:pin('control')
	@:killer('M-WRITE-SITES-MACRO-EMIT')
	public function testAWriteInAMacroReificationIsNoWrite(): Void {
		final src: String = 'class C { function m() { var i = 0; k(Std.int(i)); final e = macro i = 5; k(Std.int(i)); k(Std.int(i)); } }';
		Assert.equals(1, violations(src).length);
	}

	/** A write whose target has no root the binder can name (`f().x = …`) is assumed to write every operand. */
	@:pin('control')
	@:killer('M-EXTRACT-REPEAT-UNKNOWN-WRITE')
	public function testAWriteOfAnUnnamedTargetSplitsTheGroup(): Void {
		Assert.equals(0, violations('class C { var a:A; function m() { k(a.b.c); f().x = null; k(a.b.c); k(a.b.c); } }').length);
	}

	/**
	 * A write inside a nested function — a lambda or a local function — runs whenever that function is called, which
	 * no position in the body decides; nor does one in a SIBLING closure, which a call inside a lambda body may run.
	 * The group dies whole. A write in the body that DECLARES the local cannot run while a closure reading it executes,
	 * so it leaves the closure's group alone.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-REPEAT-CLOSURE-WRITE')
	public function testAWriteInAClosureKillsTheGroup(): Void {
		for (closure in [
			'final bump = () -> i++;',
			'function bump() i += 1;',
			'final bump = function() { i = 0; };'
		])
			Assert.equals(
				0,
				violations('class C { function m() { var i = 0; $closure k(Std.int(i)); bump(); k(Std.int(i)); k(Std.int(i)); } }').length,
				closure
			);
		final sibling: String = 'class C { function m() { var i = 0; final bump = () -> i++; '
			+ 'final g = () -> { k(Std.int(i)); bump(); k(Std.int(i)); k(Std.int(i)); }; } }';
		Assert.equals(0, violations(sibling).length, 'a call in a lambda may run a sibling closure that writes the captured local');
		final outer: String =
			'class C { function m() { var i = 0; final g = () -> { k(Std.int(i)); k(Std.int(i)); k(Std.int(i)); }; i++; } }';
		Assert.equals(1, violations(outer).length, 'the declaring body writes it while no call of the lambda is running');
	}

	/**
	 * A loop's back edge carries a write that sits textually AFTER every occurrence round to the next iteration's
	 * occurrences, so the value the first one computed is stale there — unless the statement list the shared `final`
	 * would go into is itself inside that loop, where every iteration recomputes it. In the loop's condition it is not.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-REPEAT-BACK-EDGE')
	public function testAWriteCarriedRoundALoopSplitsTheGroup(): Void {
		Assert.equals(
			0,
			violations('class C { function m() { var i = 0; k(Std.int(i)); k(Std.int(i)); while (c()) { k(Std.int(i)); i++; } } }').length
		);
		Assert.equals(
			0, violations('class C { function m() { var i = 0; while (Std.int(i) < 3) { k(Std.int(i)); k(Std.int(i)); i++; } } }').length
		);
		Assert.equals(
			0,
			violations('class C { function m() { var i = 0; do { k(Std.int(i)); k(Std.int(i)); i++; } while (Std.int(i) < 3); } }').length
		);
		Assert.equals(
			1,
			violations('class C { function m() { var i = 0; while (c()) { k(Std.int(i)); k(Std.int(i)); k(Std.int(i)); i++; } } }').length
		);
	}

	/**
	 * Occurrences whose operands bind to DIFFERENT declarations are different values however alike they read: three
	 * comprehensions each with its own binder, a redeclared local. Each binding is a group of its own.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-REPEAT-REBIND')
	public function testOperandsBoundToDifferentDeclarationsAreSeparateGroups(): Void {
		final comprehensions: String = 'class C { function m(xs:Array<Float>) { '
			+ 'final a = [for (x in xs) Std.int(x)]; final b = [for (x in xs) Std.int(x)]; final c = [for (x in xs) Std.int(x)]; } }';
		Assert.equals(0, violations(comprehensions).length);
		Assert.equals(
			0, violations('class C { function m() { var x = 1.5; k(Std.int(x)); k(Std.int(x)); var x = 2.5; k(Std.int(x)); } }').length
		);
		Assert.equals(
			1,
			violations('class C { function m(xs:Array<Float>) { for (x in xs) { k(Std.int(x)); k(Std.int(x)); k(Std.int(x)); } } }').length
		);
	}

	/**
	 * The target of a write is the storage it replaces, not one more reading of the value: two reads and an
	 * assignment of the same chain are two occurrences, whatever the operator. Three reads before it still report.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-REPEAT-TARGET-COUNTED')
	public function testAWriteTargetIsNoOccurrence(): Void {
		for (write in ['a.b.c = 5;', 'a.b.c += 5;', 'a.b.c++;'])
			Assert.equals(0, violations('class C { var a:A; function m() { k(a.b.c); k(a.b.c); $write } }').length, write);
		Assert.equals(1, violations('class C { var a:A; function m() { k(a.b.c); k(a.b.c); k(a.b.c); a.b.c = 5; } }').length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new ExtractRepeatedExpression(), src);
	}

}
