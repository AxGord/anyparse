package unit.check;

import anyparse.check.LintConfig;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;

/**
 * The two SHAPE-proved OPERAND arms of `redundant-parens`, each opt-in per project
 * and each proof-based rather than precedence-modelled, together with the
 * cross-arm behaviour every operand arm shares: the right-greedy content tail, the
 * metadata-prefix left edge, per-arm gating, one-pass convergence and the
 * separator the drop must keep against an adjacent token.
 *
 * `atoms` — a pair wrapping a single ATOMIC expression (identifier, `this`,
 * literal, a call-free dotted field-access chain). An atom holds no operator, so
 * no re-association is possible and the pair drops in EVERY expression position,
 * including the operand slots the shipped arms refuse.
 *
 * `sameOperatorLeft` — a pair around the LEFT operand of a binary operator whose
 * content is a binary operator of the SAME left-associative precedence family
 * (`*` `/`, or `+` `-`). Left-associativity already groups that way, so the drop
 * re-parses to the identical tree. The RIGHT operand is never touched, the families
 * never mix, and a pair on the right VETOES the left one — both together are a
 * symmetry, and dropping only the removable half reads worse than either extreme.
 *
 * The two PRECEDENCE-TIER arms — `comparisonOperands` and `additiveOperands` —
 * live in `RedundantParensTierArmsTest`.
 */
class RedundantParensOperandArmsTest extends RedundantParensOperandArmsTestBase {

	public function testAtomArmIsOffByDefault(): Void {
		Assert.equals(0, violations(inFn('var b = (a) + c;'), none()).length);
		// The index SLOT is delimited and fires with no arm on (`RedundantParensCheckTest`);
		// the RECEIVER beside it is an operand position only this arm reaches.
		Assert.equals(0, violations(inFn('var b = (arr)[i];'), none()).length);
	}

	public function testSameOperatorLeftArmIsOffByDefault(): Void {
		Assert.equals(0, violations(inFn('var b = (p * q) / r;'), none()).length);
	}

	public function testAtomIdentifierOperandDropsBothWays(): Void {
		assertDrop(inFn('var b = (a) + c;'), inFn('var b = a + c;'), atoms());
		assertDrop(inFn('var b = c + (a);'), inFn('var b = c + a;'), atoms());
	}

	/**
	 * The shape this arm was built for: a divisor written with defensive parens
	 * around a plain field read. The dividend's parens hold a real subtraction and
	 * stay.
	 */
	public function testAtomDottedChainDivisorDrops(): Void {
		assertDrop(inFn('var b = (pt.x - ruler.x) / (ruler.width);'), inFn('var b = (pt.x - ruler.x) / ruler.width;'), atoms());
	}

	public function testAtomDeepDottedChainDrops(): Void {
		assertDrop(inFn('var b = (a.b.c.d) + e;'), inFn('var b = a.b.c.d + e;'), atoms());
	}

	public function testAtomLiteralsDrop(): Void {
		assertDrop(inFn('var b = a + (1);'), inFn('var b = a + 1;'), atoms());
		assertDrop(inFn('var b = a + (1.5);'), inFn('var b = a + 1.5;'), atoms());
		assertDrop(inFn('var b = a | (0xFF);'), inFn('var b = a | 0xFF;'), atoms());
		assertDrop(inFn('var b = a && (true);'), inFn('var b = a && true;'), atoms());
		assertDrop(inFn('var b = a == (null);'), inFn('var b = a == null;'), atoms());
	}

	/**
	 * A single-quoted Haxe string projects its segments and its `${…}` interpolations as
	 * CHILDREN — internal structure sealed inside the quotes, not operands. A recursive
	 * atom test that re-examined them would refuse every interpolating literal.
	 */
	public function testAtomStringLiteralReceiverDrops(): Void {
		assertDrop(inFn('var b = ("s").length;'), inFn('var b = "s".length;'), atoms());
		assertDrop(inFn("var b = ('s').length;"), inFn("var b = 's'.length;"), atoms());
		assertDrop(inFn("var b = ('a${p + q}b').length;"), inFn("var b = 'a${p + q}b'.length;"), atoms());
	}

	/**
	 * Inside a `${ … }` block the SOLE pair is the shipped delimited-slot arm's (see
	 * `RedundantParensCheckTest`); an operand pair there is this arm's, on the same terms
	 * as anywhere else. Pins that opening the slot did not double-claim the operands.
	 */
	public function testAtomInterpolationOperandsDrop(): Void {
		assertDrop(inFn("var s = '${(p) + (q)}';"), inFn("var s = '${p + q}';"), atoms());
		Assert.equals(inFn("var s = '${(p) + (q)}';"), fixed(inFn("var s = '${(p) + (q)}';"), none()));
	}

	public function testAtomThisReceiverDrops(): Void {
		assertDrop(inFn('var b = (this).q;'), inFn('var b = this.q;'), atoms());
	}

	public function testAtomUnaryOperandDrops(): Void {
		assertDrop(inFn('var b = -(a);'), inFn('var b = -a;'), atoms());
		assertDrop(inFn('var b = !(flag);'), inFn('var b = !flag;'), atoms());
	}

	public function testAtomCalleeDrops(): Void {
		assertDrop(inFn('(g)(1);'), inFn('g(1);'), atoms());
	}

	public function testAtomAssignmentTargetDrops(): Void {
		assertDrop(inFn('(x) = 1;'), inFn('x = 1;'), atoms());
	}

	/**
	 * The RECEIVER, which is the operand half of an index access — the index slot beside it
	 * is bracket-delimited and drops with no arm on at all (`RedundantParensCheckTest`).
	 */
	public function testAtomIndexOperandDrops(): Void {
		assertDrop(inFn('var b = (arr)[i];'), inFn('var b = arr[i];'), atoms());
	}

	public function testAtomTernaryBranchesDrop(): Void {
		assertDrop(inFn('x = c ? (a) : (b);'), inFn('x = c ? a : b;'), atoms());
	}

	public function testAtomMapLiteralArrowOperandsDrop(): Void {
		assertDrop(inFn('var m = [(a) => (b)];'), inFn('var m = [a => b];'), atoms());
	}

	public function testAtomDoubleParensCollapseFullyInAnOperandSlot(): Void {
		assertDrop(inFn('var b = ((a)) + c;'), inFn('var b = a + c;'), atoms());
	}

	/** A call anywhere in the chain is not an atom — it can carry arguments, so the chain is not a pure name. */
	public function testCallChainIsNotAnAtom(): Void {
		Assert.equals(0, violations(inFn('var b = (f()) + c;'), atoms()).length);
		Assert.equals(0, violations(inFn('var b = (f().x) + c;'), atoms()).length);
		Assert.equals(0, violations(inFn('var b = (a.f()) + c;'), atoms()).length);
	}

	/**
	 * `?.` is not a plain dotted link: `(a?.b).c` and `a?.b.c` do not agree on what the
	 * null short-circuit covers, so a safe-nav chain is deliberately not an atom.
	 */
	public function testSafeNavChainIsNotAnAtom(): Void {
		Assert.equals(0, violations(inFn('var b = (a?.b) + c;'), atoms()).length);
	}

	/**
	 * A regex literal ends in `/`, so a drop can weld it onto a following `/` into a
	 * line comment (`(~/x/)/a` -> `~/x//a`). Left out of the atom vocabulary.
	 */
	public function testRegexLiteralIsNotAnAtom(): Void {
		Assert.equals(0, violations(inFn('var b = (~/x/).match(s);'), atoms()).length);
	}

	public function testOperatorContentIsNotAnAtom(): Void {
		Assert.equals(0, violations(inFn('var b = (a + c) * d;'), atoms()).length);
		Assert.equals(0, violations(inFn('var b = -(a + c);'), atoms()).length);
		Assert.equals(0, violations(inFn('var b = (cast a).x;'), atoms()).length);
		Assert.equals(0, violations(inFn('var b = (untyped a).x;'), atoms()).length);
	}

	public function testCaseGuardKeepsItsRequiredParens(): Void {
		Assert.equals(0, violations(inFn('switch v {\n\t\t\tcase X if (g): t();\n\t\t\tcase _:\n\t\t}'), atoms()).length);
	}

	public function testCasePatternSubtreeIsUntouched(): Void {
		Assert.equals(0, violations(inFn('switch v {\n\t\t\tcase (X): t();\n\t\t\tcase _:\n\t\t}'), atoms()).length);
		Assert.equals(0, violations(inFn('switch v {\n\t\t\tcase A | (B): t();\n\t\t\tcase _:\n\t\t}'), atoms()).length);
	}

	/** A case BODY is an ordinary statement — the pattern suppression must not reach it. */
	public function testCaseBodyIsStillReached(): Void {
		assertDrop(inFn('switch v {\n\t\t\tcase _: q = (a) + c;\n\t\t}'), inFn('switch v {\n\t\t\tcase _: q = a + c;\n\t\t}'), atoms());
	}

	public function testSwitchSubjectIsUntouched(): Void {
		Assert.equals(0, violations(inFn('switch ((v)) {\n\t\t\tcase _:\n\t\t}'), atoms()).length);
	}

	public function testMetadataArgumentsAreUntouched(): Void {
		Assert.equals(0, violations(inFn('@:m((a)) var z = 1;'), atoms()).length);
		Assert.equals(0, violations(inFn('@:m (a);'), atoms()).length);
	}

	/**
	 * Inside a `macro` quotation a paren is DATA: it reifies as `EParenthesis`, so
	 * dropping it rewrites the built expression with nothing rejecting it. The bare
	 * fixtures below pin that the quotation is what rejects these — the shipped
	 * delimited arm reaches inside a quotation and is deliberately left as it was.
	 */
	public function testMacroQuotationSubtreeIsUntouched(): Void {
		Assert.equals(0, violations(inFn('var e = macro (a) + b;'), atoms()).length);
		Assert.equals(1, violations(inFn('var e = (a) + b;'), atoms()).length);
		Assert.equals(0, violations(inFn('var e = macro (p * q) / r;'), sameOperatorLeft()).length);
		Assert.equals(1, violations(inFn('var e = (p * q) / r;'), sameOperatorLeft()).length);
	}

	/** A comment between the parens and their content would be deleted by the drop. */
	public function testParensCarryingACommentAreSkipped(): Void {
		Assert.equals(0, violations(inFn('var z = (/* c */ a);'), none()).length);
		Assert.equals(0, violations(inFn('var z = (a /* c */);'), none()).length);
		Assert.equals(0, violations(inFn('var z = ((/* c */ a));'), none()).length);
		// A comment OUTSIDE the pair is not between the parens and their content, so it
		// does not gate the drop.
		Assert.equals(1, violations(inFn('var z = (a); // c'), none()).length);
	}

	public function testSameOperatorLeftMultiplicativeDrops(): Void {
		assertDrop(inFn('var v = (p * q) / r;'), inFn('var v = p * q / r;'), sameOperatorLeft());
		assertDrop(inFn('var v = (p / q) * r;'), inFn('var v = p / q * r;'), sameOperatorLeft());
		assertDrop(inFn('var v = (p / q) / r;'), inFn('var v = p / q / r;'), sameOperatorLeft());
	}

	public function testSameOperatorLeftAdditiveDrops(): Void {
		assertDrop(inFn('var v = (p + q) - r;'), inFn('var v = p + q - r;'), sameOperatorLeft());
		assertDrop(inFn('var v = (p - q) + r;'), inFn('var v = p - q + r;'), sameOperatorLeft());
		assertDrop(inFn('var v = (p - q) - r;'), inFn('var v = p - q - r;'), sameOperatorLeft());
	}

	/** `a / (b * c)` is a different computation — the right operand is never a candidate. */
	public function testRightOperandIsNeverDropped(): Void {
		Assert.equals(0, violations(inFn('var v = p / (q * r);'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = p - (q + r);'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = p * (q * r);'), sameOperatorLeft()).length);
	}

	/**
	 * Both operands parenthesized is a SYMMETRY the author wrote, and only the left pair
	 * is ever removable — firing would leave the expression lopsided. The bare fixtures
	 * pin that the sibling pair is what rejects these: drop it and the left one goes.
	 */
	public function testSymmetricOperandPairIsLeftIntact(): Void {
		Assert.equals(0, violations(inFn('var v = (p * q) / (r * s);'), sameOperatorLeft()).length);
		Assert.equals(1, violations(inFn('var v = (p * q) / r;'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = (p + q) - (r + s);'), sameOperatorLeft()).length);
		Assert.equals(1, violations(inFn('var v = (p + q) - r;'), sameOperatorLeft()).length);
		// The sibling need not be same-family — any pair on the right is the symmetry.
		Assert.equals(0, violations(inFn('var v = (p + q) - (r);'), sameOperatorLeft()).length);
	}

	/**
	 * The `atoms` arm is not symmetry-vetoed: the reference shape it was built for has a
	 * parenthesized non-atom on the left and the removable atom on the right.
	 */
	public function testAtomArmIgnoresASiblingPair(): Void {
		assertDrop(inFn('var b = (p - q) / (r.w);'), inFn('var b = (p - q) / r.w;'), atoms());
	}

	public function testMixedFamiliesAreNeverDropped(): Void {
		Assert.equals(0, violations(inFn('var v = (p + q) * r;'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = (p * q) + r;'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = (p << q) * r;'), sameOperatorLeft()).length);
	}

	/**
	 * Haxe binds `%` TIGHTER than `*` and `/` (`2 * 7 % 4` is 6, i.e. `2 * (7 % 4)`),
	 * so a modulo can never join the multiplicative family — and this parser models it
	 * at the same tier, which would make a tree-equivalence proof drawn from its own
	 * output agree with a rewrite the compiler reads differently. Left out entirely.
	 */
	public function testModuloIsNeverDropped(): Void {
		Assert.equals(0, violations(inFn('var v = (p * q) % r;'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = (p % q) * r;'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = (p % q) % r;'), sameOperatorLeft()).length);
	}

	/**
	 * A construct that captures everything to its RIGHT, sitting at the right edge of the
	 * content, makes the parentheses load-bearing in EVERY precedence-gated slot: the
	 * whitelists judge the content's ROOT, and `a + (b * untyped c) - d` has an arithmetic
	 * root over a tail that swallows the `- d` once the pair is gone (measured against the
	 * real compiler: 9 with the parentheses, 7 without). The default-on ternary-condition
	 * arm is reached too, with no opt-in at all.
	 */
	public function testRightGreedyContentTailIsRefusedInEverySlot(): Void {
		Assert.equals(0, violations(inFn('var v = a + (b * untyped c) - d;'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = (b * untyped c) > d;'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var v = (b + untyped c) - d;'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = q = (b * untyped c) ? x : y;'), none()).length);
		// The bare fixtures pin that the greedy tail is what rejects each of these.
		Assert.equals(1, violations(inFn('var v = a + (b * w) - d;'), additiveOperands()).length);
		Assert.equals(1, violations(inFn('var v = (b * w) > d;'), comparisonOperands()).length);
		Assert.equals(1, violations(inFn('var v = (b + w) - d;'), sameOperatorLeft()).length);
		Assert.equals(1, violations(inFn('var v = q = (b * w) ? x : y;'), none()).length);
	}

	/**
	 * The whole right-greedy vocabulary, one shape apiece. `cast` is here because the REAL
	 * compiler captures rightward through it (`x + b * cast c - d` is 7, not 9) while this
	 * parser models it as bounded — so the tree-shape oracle would have called that drop
	 * safe. See the note on `HxExpr`'s `CastExpr`.
	 */
	public function testEveryRightGreedyKindIsRefused(): Void {
		for (tail in [
			'untyped c',
			'macro c',
			'cast c',
			'function() return c',
			'@:m c',
			'if (p) q else c',
			'throw c',
			'inline g()',
			'(z) -> c'
		]) Assert.equals(0, violations(inFn('var v = a + (b * $tail) - d;'), additiveOperands()).length, 'tail: $tail');
	}

	/**
	 * A greedy construct bounded by its own closing token is NOT at the right edge of the
	 * content — the spine walk stops where the parent closes after its last child — so the
	 * pair still drops. This is the positive control for the gate above.
	 */
	public function testBoundedGreedyContentStillFires(): Void {
		assertDrop(inFn('var v = a + (b * f(untyped c)) - d;'), inFn('var v = a + b * f(untyped c) - d;'), additiveOperands());
		assertDrop(inFn('var v = a + (b * (untyped c)) - d;'), inFn('var v = a + b * (untyped c) - d;'), additiveOperands());
	}

	/**
	 * This parser models `@:m` as wrapping the whole expression that follows, but the real
	 * compiler binds the annotation to the immediate primary — so a pair at the LEFT EDGE
	 * under a metadata prefix is what holds the annotation over its operand. Measured:
	 * `@:privateAccess (A.s * B.s) + 1` compiles, `@:privateAccess A.s * B.s + 1` fails with
	 * `Cannot access private field`. The pair is load-bearing in every slot, the default-on
	 * ternary arm included.
	 */
	public function testAMetadataPrefixKeepsALeftEdgeParen(): Void {
		Assert.equals(0, violations(inFn('var v = @:privateAccess (a * b) + c;'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = @:privateAccess (a * b) > c;'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var v = @:privateAccess (a + b) - c;'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = q = @:privateAccess (a * b) ? x : y;'), none()).length);
		Assert.equals(0, violations(inFn('var v = @:privateAccess (a * b) + c;'), atoms()).length);
	}

	/**
	 * A `case … :` header ends in a hard token, so a pair inside the BODY is ordinary — the
	 * prefix rule must not be read off `parenRequiredHostKinds`, which lists `CaseBranch`
	 * for its mandatory guard pair. Reading it there suppressed two real corpus sites of
	 * exactly this shape.
	 */
	public function testACaseBodyIsNotUnderAPrefixAnnotation(): Void {
		assertDrop(
			inFn('switch p {\n\t\t\tcase _: q = (v <= 2) ? x : y;\n\t\t}'), inFn('switch p {\n\t\t\tcase _: q = v <= 2 ? x : y;\n\t\t}'),
			none()
		);
	}

	/** The annotated expression's own left edge only — a pair further right is not what the meta binds to. */
	public function testAMetadataPrefixDoesNotReachPastTheLeftEdge(): Void {
		assertDrop(inFn('var v = @:privateAccess a + (b * c);'), inFn('var v = @:privateAccess a + b * c;'), additiveOperands());
		Assert.equals(1, violations(inFn('var v = (a * b) + c;'), additiveOperands()).length);
	}

	/** A metadata prefix directly on the pair is the shipped required-host rule, and still keeps it. */
	public function testAMetadataPrefixOnThePairItselfIsUnchanged(): Void {
		Assert.equals(0, violations(inFn('var v = @:privateAccess (a * b);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = @:privateAccess (a * b);'), none()).length);
	}

	/** The four arms are independent: no opt-in reaches another's candidates. */
	public function testArmsAreIndependentlyGated(): Void {
		Assert.equals(0, violations(inFn('var b = (a) + c;'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = (p * q) / r;'), atoms()).length);
		Assert.equals(0, violations(inFn('var b = (a) + c;'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var v = (p * q) / r;'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var b = (a) + c;'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = (p * q) / r;'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = (a - b) > c;'), additiveOperands()).length);
	}

	/** All four arms on one fixture, one statement apiece: every drop lands in a single pass. */
	public function testAllArmsFixInOnePass(): Void {
		final before: String = inFn('var v = (a) + b;\n\t\tvar w = (p * q) / r;\n\t\tvar y = (m - n) > c;\n\t\tvar z = d - (e / f);');
		final after: String = inFn('var v = a + b;\n\t\tvar w = p * q / r;\n\t\tvar y = m - n > c;\n\t\tvar z = d - e / f;');
		Assert.equals(after, fixed(before, allArms()));
		Assert.equals(after, fixed(after, allArms()));
		Assert.equals(bareTree(before), bareTree(after), 'paren drop preserved the tree shape');
	}

	public function testFixIsIdempotent(): Void {
		final stable: String = converged(inFn('var b = (a) + (p * q) / (r.w);'), atomsAndSameOperatorLeft());
		Assert.equals(stable, fixed(stable, atomsAndSameOperatorLeft()));
	}

	/**
	 * One pass drops the atom `(r.w)`, which un-symmetrises the division and only then
	 * frees `(p * q)` — so the arms converge over passes, as `lint --fix` runs them.
	 */
	public function testFixConvergesOverPasses(): Void {
		Assert.equals(inFn('var b = a + (p * q) / r.w;'), fixed(inFn('var b = (a) + (p * q) / (r.w);'), atomsAndSameOperatorLeft()));
		final out: String = converged(inFn('var b = (a) + (p * q) / (r.w);'), atomsAndSameOperatorLeft());
		Assert.equals(inFn('var b = a + p * q / r.w;'), out);
		Assert.notNull(new HaxeQueryPlugin().parseFile(out));
	}

	/**
	 * A drop must not weld its content onto a neighbouring word token. `return(a)` is
	 * the leading case the shipped arms already handle; `(s)is String` is the trailing
	 * one the operand arms reach first.
	 */
	public function testDropKeepsASeparatorAgainstAWordToken(): Void {
		assertDrop(inFn('var b = (s)is String;'), inFn('var b = s is String;'), atoms());
		assertDrop(inFn('var b = a + (s)is String;'), inFn('var b = a + s is String;'), atoms());
	}

	/**
	 * The OPERATOR half of the same guard, which the multiplicative content this arm
	 * unwraps is the first to reach: `a-(-b * c)` bare would read `a--b * c`, a decrement
	 * the lexer takes greedily and the parser then rejects. Whitespace-free source is not
	 * what `lint --fix` sees (it refuses a non-canonical file, and the writer separates
	 * these itself), but `fix` is callable on any source and must not depend on that.
	 */
	public function testDropKeepsASeparatorAgainstAnOperatorToken(): Void {
		assertDrop(inFn('var v = a-(--p * q);'), inFn('var v = a- --p * q;'), additiveOperands());
		assertDrop(inFn('var v = a-(--p*q)-d;'), inFn('var v = a- --p*q-d;'), additiveOperands());
	}

	/**
	 * The equivalence oracle is not vacuous: splicing paren nodes out of both sides
	 * still separates a re-associating drop from a transparent one.
	 */
	public function testTreeEquivalenceOracleRejectsReassociation(): Void {
		Assert.notEquals(bareTree(inFn('var v = (p + q) * r;')), bareTree(inFn('var v = p + q * r;')));
		Assert.equals(bareTree(inFn('var v = (p * q) / r;')), bareTree(inFn('var v = p * q / r;')));
	}

	private inline function atomsAndSameOperatorLeft(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"atoms": true, "sameOperatorLeft": true}}}');
	}

	/** Every opt-in arm at once — what a project switching the whole family on gets. */
	private inline function allArms(): (String) -> LintConfig {
		return configured(
			'{"rules": {"redundant-parens": {'
			+ '"atoms": true, "sameOperatorLeft": true, "comparisonOperands": true, "additiveOperands": true}}}'
		);
	}

}
