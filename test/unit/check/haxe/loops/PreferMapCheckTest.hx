package unit.check.haxe.loops;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Severity;
import anyparse.check.haxe.loops.PreferMap;

/**
 * The `prefer-map` check: an array comprehension over an `Array` that is one mapping of each element is flagged `Info`
 * and rewritten to `xs.map(...)`. A body that is one call taking the binder as one bare argument becomes the partial
 * application `bind` spells; any other value expression reading the binder becomes the lambda `xs.map(x -> body)`.
 * Another collection, a filter, control flow, a binder that is written, rebound or never read, a bare binder and a
 * comprehension holding a comment are left alone. The fix is risky: the comprehension's element type comes from where it
 * is written.
 */
class PreferMapCheckTest extends Test {

	public function testComprehensionFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('final ys = [for (x in xs) g(k, x)];'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-map', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this comprehension maps each element — it can be xs.map(g.bind(k))', vs[0].message);
	}

	/** The binder last is dropped, first takes `_`, alone leaves the bare callee. */
	public function testFixSpellsPartialApplication(): Void {
		Assert.equals(wrap('final ys = xs.map(g.bind(k));'), fixed(wrap('final ys = [for (x in xs) g(k, x)];')));
		Assert.equals(wrap('final ys = xs.map(g.bind(_, 2));'), fixed(wrap('final ys = [for (x in xs) g(x, 2)];')));
		Assert.equals(wrap('final ys = xs.map(one);'), fixed(wrap('final ys = [for (x in xs) one(x)];')));
	}

	/** A chain of plain field reads keeps the binder's name. */
	public function testFieldReadBecomesLambda(): Void {
		final vs: Array<Violation> = violations(wrap('final ys = [for (p in ps) p.a];'));
		Assert.equals(1, vs.length);
		Assert.equals('this comprehension maps each element — it can be ps.map(p -> p.a)', vs[0].message);
		Assert.equals(wrap('final ys = ps.map(p -> p.a);'), fixed(wrap('final ys = [for (p in ps) p.a];')));
		Assert.equals(wrap('final ys = ps.map(p -> p.b.a);'), fixed(wrap('final ys = [for (p in ps) p.b.a];')));
	}

	/** A getter is read once per element in the same order by both spellings. */
	public function testGetterReadBecomesLambda(): Void {
		Assert.equals(wrap('final ys = ps.map(p -> p.prop);'), fixed(wrap('final ys = [for (p in ps) p.prop];')));
	}

	public function testValueExpressionBodiesBecomeLambdas(): Void {
		Assert.equals(wrap('final ys = ps.map(p -> p.m());'), fixed(wrap('final ys = [for (p in ps) p.m()];')));
		Assert.equals(wrap('final ys = ps.map(p -> one(p.a));'), fixed(wrap('final ys = [for (p in ps) one(p.a)];')));
		Assert.equals(wrap('final ys = ps.map(p -> p.a + 1);'), fixed(wrap('final ys = [for (p in ps) p.a + 1];')));
		Assert.equals(wrap('final ys = ps.map(p -> k > 0 ? p.a : p.b.a);'), fixed(wrap('final ys = [for (p in ps) k > 0 ? p.a : p.b.a];')));
		Assert.equals(wrap('final ys = ps.map(p -> p?.a);'), fixed(wrap('final ys = [for (p in ps) p?.a];')));
		Assert.equals(
			wrap('final ys = ps.map(p -> if (k > 0) p.a else 0);'), fixed(wrap('final ys = [for (p in ps) if (k > 0) p.a else 0];'))
		);
		Assert.equals(wrap('final ys = ps.map(p -> {a: p.a});'), fixed(wrap('final ys = [for (p in ps) {a: p.a}];')));
	}

	/** Where the partial application's proof does not hold, the lambda is the spelling. */
	public function testLambdaIsTheFallbackForBind(): Void {
		Assert.equals(wrap('final ys = xs.map(x -> g(fld, x));'), fixed(wrap('final ys = [for (x in xs) g(fld, x)];')));
		Assert.equals(wrap('final ys = xs.map(x -> g(x, x));'), fixed(wrap('final ys = [for (x in xs) g(x, x)];')));
		Assert.equals(wrap('final ys = xs.map(x -> g(k, x) + 1);'), fixed(wrap('final ys = [for (x in xs) g(k, x) + 1];')));
	}

	/** `List.map` returns a `List`: only an `Array` keeps the comprehension's type. */
	@:pin('control')
	@:killer('M-PM-ANY-ITERABLE')
	public function testOtherCollectionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (x in ls) one(x)];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in pl) p.a];')).length);
	}

	/** An `if` without `else` filters: the comprehension has fewer elements than the array. */
	@:pin('control')
	@:killer('M-PM-FILTER')
	public function testFilterNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (x in xs) if (x > 0) one(x)];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) if (p.a > 0) p.a];')).length);
	}

	/** A body that is not one value expression keeps the comprehension. */
	@:pin('control')
	@:killer('M-PM-LEAVING')
	public function testBlockAndDeclarationNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) { p.a; }];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) { var t = p.a; t; }];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) for (q in p.items) q.a];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) try p.a catch (e: Dynamic) 0];')).length);
	}

	/** A body that never reads the binder is not a mapping of the element. */
	@:pin('control')
	@:killer('M-PM-READS-BINDER')
	public function testBodyWithoutBinderNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) k];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) fld + 1];')).length);
	}

	/** `xs.map(x -> x)` is a copy, which the comprehension already is. */
	@:pin('control')
	@:killer('M-PM-BARE-BINDER')
	public function testBareBinderNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) p];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) (p)];')).length);
	}

	/** A body that writes the binder keeps the comprehension. */
	@:pin('control')
	@:killer('M-PM-BINDER-WRITE')
	public function testBinderWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (x in xs) x++];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (x in xs) x += 1];')).length);
	}

	public function testRebindingAndSuperNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) call(p -> p.a)];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) super.f(p.a)];')).length);
	}

	public function testKeyValueBinderNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (i => p in ps) p.a];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) p.a => p.b];')).length);
	}

	/** The rewrite drops the comprehension's punctuation, and a comment in it would go too. */
	public function testCommentKeepsTheComprehension(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) /* keep */ p.a];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps /* keep */) p.a];')).length);
	}

	public function testDefaultOffAndRisky(): Void {
		Assert.isTrue(Std.isOfType(new PreferMap(), DefaultOff));
		Assert.isTrue(Std.isOfType(new PreferMap(), RiskyFix));
	}

	/**
	 * A `return`, `break`, `continue` or `throw` in expression position
	 * would leave the enclosing function or loop from inside a closure.
	 */
	@:pin('control')
	@:killer('M-PM-EXIT-KINDS')
	public function testControlExitNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) if (p.a > 0) p.a else return null];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) if (p.a > 0) p.a else continue];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) if (p.a > 0) p.a else break];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) p.b ?? return null];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) p.a > 0 ? continue : p.a];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) one(if (p.a > 0) p.a else return null)];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) p.a + (p.a > 0 ? break : 1)];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) p.a > 0 ? p.a : throw p];')).length);
	}

	public function testConditionalCompilationNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) #if foo p.a #else p.b #end];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (p in ps) one(#if foo p.a #else p.b #end)];')).length);
	}

	public function testSwitchBodyBecomesLambda(): Void {
		final src: String = wrap('final ys = [for (p in ps) switch p.a { case 1: 2; default: 3; }];');
		Assert.equals(1, violations(src).length);
		Assert.isTrue(fixed(src).indexOf('ps.map(p -> switch p.a {') > 0);
	}

	/** A bare `$p` and a `${p.a}` interpolation both read the binder. */
	public function testInterpolationReadsTheBinder(): Void {
		Assert.equals(wrap('final ys = ps.map(p -> \'$$p!\');'), fixed(wrap('final ys = [for (p in ps) \'$$p!\'];')));
		Assert.equals(1, violations(wrap('final ys = [for (p in ps) \'v=$$p $${k}\'];')).length);
		Assert.equals(1, violations(wrap('final ys = [for (p in ps) \'$${p.a}\'];')).length);
	}

	/** The message is one line whatever the body spans, and the rewrite text stays whole. */
	public function testMessageIsOneLine(): Void {
		final src: String = wrap(
			'final ys = [for (p in ps) switch p.a {\n\t\t\tcase 1: p.b.a + 1;\n\t\t\tdefault: k + p.a + 100000;\n\t\t}];'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(-1, vs[0].message.indexOf('\n'));
		Assert.isTrue(vs[0].message.length < 130);
		Assert.isTrue(fixed(src).indexOf('k + p.a + 100000') > 0);
	}

	/** The bind spelling drops the body's text, so a comment inside it keeps the body, as a lambda. */
	@:pin('control')
	@:killer('M-PM-BIND-COMMENT')
	public function testCommentInBodyIsKeptByTheLambda(): Void {
		Assert.equals(wrap('final ys = xs.map(x -> one(/* keep */ x));'), fixed(wrap('final ys = [for (x in xs) one(/* keep */ x)];')));
		Assert.equals(wrap('final ys = xs.map(x -> g(/* keep */ k, x));'), fixed(wrap('final ys = [for (x in xs) g(/* keep */ k, x)];')));
	}

	/** A comment outside the body goes with the rewrite's punctuation, so neither spelling is offered. */
	@:pin('control')
	@:killer('M-PM-GAP-COMMENT')
	public function testCommentInGapKeepsTheComprehensionForBind(): Void {
		Assert.equals(0, violations(wrap('final ys = [/* keep */ for (x in xs) one(x)];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (/* keep */ x in xs) one(x)];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (x in xs) /* keep */ one(x)];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (x in xs /* keep */) one(x)];')).length);
		Assert.equals(0, violations(wrap('final ys = [for (x in xs) one(x) /* keep */];')).length);
	}

	/** A `${...}` expression in an argument is computed per element: `bind` would compute it once, with no binder in scope. */
	public function testBlockInterpolationArgumentTakesTheLambda(): Void {
		Assert.equals(wrap('final ys = xs.map(x -> g(\'$${x + 1}\', x));'), fixed(wrap('final ys = [for (x in xs) g(\'$${x + 1}\', x)];')));
		Assert.equals(
			wrap('final ys = xs.map(y -> g(\'$${fld + 1}\', y));'), fixed(wrap('final ys = [for (y in xs) g(\'$${fld + 1}\', y)];'))
		);
	}

	/**
	 * The identity keeps the lead and drops the quoted rewrite, so a comprehension
	 * whose rewrite moved keeps its key. Pinned against messages `run` produced.
	 */
	@:pin('control')
	@:killer('M-PREFER-MAP-IDENTITY-UNWIRED')
	public function testIdentityMasksTheQuotedRewrite(): Void {
		final check: PreferMap = new PreferMap();
		final a: String = violations(wrap('final ys = [for (p in ps) p.a];'))[0].message;
		final b: String = violations(wrap('final ys = [for (p in ps) p.b.a];'))[0].message;
		Assert.notEquals(a, b);
		final identity: String = check.messageIdentity(a);
		Assert.equals('this comprehension maps each element — it can be #', identity);
		Assert.equals(identity, check.messageIdentity(b));
		Assert.equals(identity, check.messageIdentity(identity));
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferMap(), src);
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new PreferMap(), src);
	}

	private static function wrap(statement: String): String {
		return 'class C extends B {\n\tvar fld: Int = 0;\n\n\tfunction g(a: Int, b: Int): Int {\n\t\treturn a + b;\n\t}\n\n'
			+ '\tfunction one(a: Int): Int {\n\t\treturn a;\n\t}\n\n'
			+ '\tfunction f(xs: Array<Int>, ls: List<Int>, ps: Array<P>, pl: List<P>, k: Int): Void {\n\t\t$statement\n\t}\n}';
	}

}
