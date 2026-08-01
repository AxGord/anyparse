package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.RedundantParens;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.format.Text;

/**
 * The three OPERAND arms of `redundant-parens`, each opt-in per project and each
 * proof-based rather than precedence-modelled.
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
 * `comparisonOperands` — a pair on EITHER side of a comparison-tier operator
 * (`==` `!=` `<` `<=` `>` `>=`) whose bare content is purely arithmetic (`+` `-`
 * `*` `/` `%`, unary minus), all of which bind strictly tighter than a comparison
 * in Haxe AND in every C-family language. Unlike `sameOperatorLeft` a sibling pair
 * is not a blanket veto — one that is itself provable (same whitelist, or an atom
 * when `atoms` is on too) is taken along, so both drop in a single pass; the veto
 * fires only when the sibling's content is NOT provable, which would leave the
 * comparison lopsided. The BITWISE tier is off the whitelist for CORRECTNESS — C
 * binds `&` `|` `^` LOOSER than equality, unlike Haxe — while the SHIFT tier binds
 * tighter than a comparison in C exactly as in Haxe and is left out purely on
 * READABILITY: a shift operand is habitually parenthesized.
 *
 * Every drop asserted here is checked against a TREE-EQUIVALENCE oracle: both the
 * before and after source are parsed, every paren node is spliced out of each, and
 * the two shapes must render identically. A drop that re-associates fails it.
 */
class RedundantParensOperandArmsTest extends Test {

	/** Pass budget for `converged` — generous; the deepest fixture here settles in two. */
	private static inline final MAX_PASSES: Int = 8;

	public function testAtomArmIsOffByDefault(): Void {
		Assert.equals(0, violations(inFn('var b = (a) + c;'), none()).length);
		Assert.equals(0, violations(inFn('var b = arr[(i)];'), none()).length);
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

	public function testAtomIndexOperandDrops(): Void {
		assertDrop(inFn('var b = arr[(i)];'), inFn('var b = arr[i];'), atoms());
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

	public function testComparisonOperandArmIsOffByDefault(): Void {
		Assert.equals(0, violations(inFn('var v = (a - b) > c;'), none()).length);
		Assert.equals(0, violations(inFn('var v = (a - b) > c;'), atoms()).length);
		Assert.equals(0, violations(inFn('var v = (a - b) > c;'), sameOperatorLeft()).length);
	}

	/**
	 * The shape this arm was built for: a comparison of two parenthesized arithmetic
	 * operands. Both pairs are provable, so BOTH drop in one pass — the arm never leaves
	 * a comparison lopsided.
	 */
	public function testComparisonBothOperandsDropInOnePass(): Void {
		assertDrop(inFn('var v = (px - x - w) > (py - y - h + r);'), inFn('var v = px - x - w > py - y - h + r;'), comparisonOperands());
	}

	/** Either side alone is a candidate, over the whole arithmetic whitelist. */
	public function testComparisonSingleOperandDrops(): Void {
		assertDrop(inFn('var v = (a - b) > c;'), inFn('var v = a - b > c;'), comparisonOperands());
		assertDrop(inFn('var v = a > (b - c);'), inFn('var v = a > b - c;'), comparisonOperands());
		assertDrop(inFn('var v = (a * b) < c;'), inFn('var v = a * b < c;'), comparisonOperands());
		assertDrop(inFn('var v = (a % b) == c;'), inFn('var v = a % b == c;'), comparisonOperands());
		assertDrop(inFn('var v = (-a) > b;'), inFn('var v = -a > b;'), comparisonOperands());
	}

	/**
	 * A parenthesized sibling whose own content is NOT provable vetoes the drop: firing
	 * on the provable half alone would leave the expression lopsided, the same reason
	 * `sameOperatorLeft` declines a symmetric pair. The bare fixture pins that the
	 * sibling is what rejects this one.
	 */
	public function testComparisonSiblingPairVetoesTheDrop(): Void {
		Assert.equals(0, violations(inFn('var v = (a - b) > (c ?? d);'), comparisonOperands()).length);
		Assert.equals(1, violations(inFn('var v = (a - b) > c;'), comparisonOperands()).length);
	}

	/**
	 * Only arithmetic content is whitelisted. A nested comparison would re-associate, and
	 * the looser tiers (`&&`, `??`) obviously would. The BITWISE pair is kept for
	 * CORRECTNESS — Haxe binds `&` tighter than `!=` but C binds it LOOSER, so the pair is
	 * what makes `(x & m) != 0` read alike in both. The SHIFT pair is kept on READABILITY
	 * alone: C agrees with Haxe there, so `(a << b) > c` would be provable, but a shift
	 * operand is habitually parenthesized and this arm declines to take that away.
	 */
	public function testComparisonNonWhitelistedContentStays(): Void {
		Assert.equals(0, violations(inFn('var v = (a > b) == c;'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var v = (x & m) != 0;'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var v = (a << b) > c;'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var v = (a && b) == c;'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var v = (a ?? b) != c;'), comparisonOperands()).length);
	}

	/** An additive operator is not a comparison tier, so this arm never reaches its operands. */
	public function testComparisonArmDoesNotReachANonComparisonHost(): Void {
		Assert.equals(0, violations(inFn('var v = (a - b) + c;'), comparisonOperands()).length);
	}

	/** Inside a `macro` quotation a paren reifies as data, so no operand arm drops one. */
	public function testComparisonArmIsSuppressedInAMacroQuotation(): Void {
		Assert.equals(0, violations(inFn('var e = macro (a - b) > c;'), comparisonOperands()).length);
		Assert.equals(1, violations(inFn('var e = (a - b) > c;'), comparisonOperands()).length);
	}

	/**
	 * With `atoms` on as well an atomic sibling counts as PROVABLE, so `(a - b) > (x)`
	 * settles in ONE pass rather than leaving the arithmetic pair waiting a round — the
	 * "never lopsided" rule holds within the pass, not merely across passes.
	 */
	public function testComparisonConvergesWithTheAtomArm(): Void {
		final out: String = fixed(inFn('var v = (a - b) > (x);'), comparisonAndAtoms());
		Assert.equals(inFn('var v = a - b > x;'), out);
		Assert.equals(out, converged(inFn('var v = (a - b) > (x);'), comparisonAndAtoms()));
		Assert.equals(out, fixed(out, comparisonAndAtoms()));
		Assert.equals(bareTree(inFn('var v = (a - b) > (x);')), bareTree(out), 'paren drop preserved the tree shape');
	}

	/** The double-paren arm and this one compose: the whole chain goes in one edit. */
	public function testComparisonDoubleParensCollapseFully(): Void {
		assertDrop(inFn('var v = ((a - b)) > c;'), inFn('var v = a - b > c;'), comparisonOperands());
	}

	/**
	 * A non-provable sibling stays vetoed while the double-paren arm still collapses its
	 * chain: `((c))` loses its redundant layer, `(a - b)` keeps its pair, and the pair
	 * that survives is the symmetry the author wrote.
	 */
	public function testComparisonVetoSurvivesASiblingChainCollapse(): Void {
		Assert.equals(1, violations(inFn('var v = (a - b) > ((c));'), comparisonOperands()).length);
		Assert.equals(inFn('var v = (a - b) > (c);'), converged(inFn('var v = (a - b) > ((c));'), comparisonOperands()));
	}

	/** The three arms are independent: no opt-in reaches another's candidates. */
	public function testArmsAreIndependentlyGated(): Void {
		Assert.equals(0, violations(inFn('var b = (a) + c;'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = (p * q) / r;'), atoms()).length);
		Assert.equals(0, violations(inFn('var b = (a) + c;'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var v = (p * q) / r;'), comparisonOperands()).length);
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
	 * The equivalence oracle is not vacuous: splicing paren nodes out of both sides
	 * still separates a re-associating drop from a transparent one.
	 */
	public function testTreeEquivalenceOracleRejectsReassociation(): Void {
		Assert.notEquals(bareTree(inFn('var v = (p + q) * r;')), bareTree(inFn('var v = p + q * r;')));
		Assert.equals(bareTree(inFn('var v = (p * q) / r;')), bareTree(inFn('var v = p * q / r;')));
	}

	/** `fixed(before)` must equal `after`, and the two must parse to the same paren-free shape. */
	private function assertDrop(before: String, after: String, resolve: (String) -> LintConfig): Void {
		Assert.equals(after, fixed(before, resolve));
		Assert.equals(bareTree(before), bareTree(after), 'paren drop preserved the tree shape');
	}

	private function violations(src: String, ?resolve: (String) -> LintConfig): Array<Violation> {
		final check: RedundantParens = new RedundantParens();
		if (resolve != null) check.setConfigResolver(resolve);
		return check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** `src` with every edit ONE pass of the check's own `fix` produces applied. */
	private function fixed(src: String, ?resolve: (String) -> LintConfig): String {
		final check: RedundantParens = new RedundantParens();
		if (resolve != null) check.setConfigResolver(resolve);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		return RefactorSupport.applyEdits(src, check.fix(src, vs, plugin));
	}

	/** `src` fixed repeatedly until it stops changing — what `lint --fix` does over passes. */
	private function converged(src: String, resolve: (String) -> LintConfig): String {
		var out: String = src;
		for (_ in 0...MAX_PASSES) {
			final next: String = fixed(out, resolve);
			if (next == out) return out;
			out = next;
		}
		Assert.fail('fix did not converge within $MAX_PASSES passes');
		return out;
	}

	/** `src` parsed with every parenthesis node spliced out — the shape a redundant pair must not change. */
	private static function bareTree(src: String): String {
		return Text.render(stripParens(new HaxeQueryPlugin().parseFile(src)));
	}

	private static function stripParens(node: QueryNode): QueryNode {
		final bare: QueryNode = RefactorSupport.unwrapParens(node, 'ParenExpr');
		return new QueryNode(bare.kind, bare.name, [for (c in bare.children) stripParens(c)]);
	}

	private static inline function atoms(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"atoms": true}}}');
	}

	private static inline function sameOperatorLeft(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"sameOperatorLeft": true}}}');
	}

	private static inline function comparisonOperands(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"comparisonOperands": true}}}');
	}

	/** An explicit EMPTY project config — hermetic, unlike falling through to a discovered `apqlint.json`. */
	private static inline function none(): (String) -> LintConfig {
		return configured('{}');
	}

	private static inline function atomsAndSameOperatorLeft(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"atoms": true, "sameOperatorLeft": true}}}');
	}

	private static inline function comparisonAndAtoms(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"atoms": true, "comparisonOperands": true}}}');
	}

	private static function configured(json: String): (String) -> LintConfig {
		final config: LintConfig = LintConfig.parse(json);
		return _ -> config;
	}

	/** `body` as the sole statement of a method — the shortest host for a statement-level fixture. */
	private static inline function inFn(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

}
