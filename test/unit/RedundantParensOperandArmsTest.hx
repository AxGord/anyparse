package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.RedundantParens;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.format.Text;

/**
 * The four OPERAND arms of `redundant-parens`, each opt-in per project and each
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
 * (`==` `!=` `<` `<=` `>` `>=`) whose bare content is arithmetic (`+` `-` `*` `/`
 * `%`) or a POSTFIX in/decrement (`x++` `x--`), all of which bind strictly tighter
 * than a comparison in Haxe AND in every C-family language. Unlike `sameOperatorLeft`
 * a sibling pair is not a blanket veto — one that is itself provable (same whitelist,
 * or an atom when `atoms` is on too) is taken along, so both drop in a single pass;
 * the veto fires only when the sibling's content is NOT provable, which would leave
 * the comparison lopsided. The BITWISE tier is off the whitelist for CORRECTNESS — C
 * binds `&` `|` `^` LOOSER than equality, unlike Haxe — while the SHIFT tier binds
 * tighter than a comparison in C exactly as in Haxe and is left out purely on
 * READABILITY: a shift operand is habitually parenthesized.
 *
 * `additiveOperands` — the same shape one tier down: a pair on EITHER side of `+`
 * or `-` whose bare content is on the strictly tighter multiplicative tiers (`*`
 * `/` `%`) or is a POSTFIX in/decrement, which C agrees bind tighter than either
 * additive operator. The sibling symmetry rule is `comparisonOperands`' unchanged.
 * SAME-TIER content (`a + (b - c)`) is excluded for CORRECTNESS — the drop
 * re-associates — and `Neg` for READABILITY (`a - -b`). `*` and `/` are deliberately
 * NOT hosts: Haxe binds `%` tighter than either, but C makes the three one tier, so
 * the pair in `a * (b % c)` is what makes the two readings agree — the same
 * cross-language trap as the bitwise exclusion.
 *
 * The two READABILITY exclusions differ in REACH, which the fixtures below pin. A
 * leading unary minus is refused by a LEFT-SPINE gate (`RefShape.unaryMinusKinds`),
 * so `a + (-b * c)` goes with `a - (-b)`. The PREFIX `++x` / `--x` have no such
 * gate: they are simply absent from the root whitelist, so `a - (--b)` is refused
 * while `a - (--b * c)` — a `Mul` root that merely BEGINS with `--` — still drops.
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
	}

	/**
	 * A bare `Neg` root USED to drop here (`(-a) > b` -> `-a > b`). It no longer does: the
	 * leading-minus rule refuses a minus written first at ANY depth, and a bare `Neg` root
	 * is the shallowest case of that. A deliberate narrowing of shipped behaviour — one
	 * readability rule instead of a root test that could not see `(-a * c) > b`.
	 */
	public function testABareNegationRootNoLongerDrops(): Void {
		Assert.equals(0, violations(inFn('var v = (-a) > b;'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var v = a > (-b);'), comparisonOperands()).length);
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

	public function testAdditiveOperandArmIsOffByDefault(): Void {
		Assert.equals(0, violations(inFn('var v = a - (b / c);'), none()).length);
		Assert.equals(0, violations(inFn('var v = a - (b / c);'), atoms()).length);
		Assert.equals(0, violations(inFn('var v = a - (b / c);'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = a - (b / c);'), comparisonOperands()).length);
	}

	/**
	 * The shape this arm was built for: a division parenthesized as an operand of a
	 * subtraction. `/` is a whole tier tighter than `-` in Haxe and in every C-family
	 * language, so the bare form parses to the tree it already had on either reading.
	 */
	public function testAdditiveTighterOperandDrops(): Void {
		assertDrop(inFn('var v = a * s - (w / 2.0);'), inFn('var v = a * s - w / 2.0;'), additiveOperands());
	}

	/** Either side is a candidate, over the whole multiplicative whitelist. */
	public function testAdditiveSingleOperandDrops(): Void {
		assertDrop(inFn('var v = a - (b / c);'), inFn('var v = a - b / c;'), additiveOperands());
		assertDrop(inFn('var v = a + (b * c);'), inFn('var v = a + b * c;'), additiveOperands());
		assertDrop(inFn('var v = (a * b) - c;'), inFn('var v = a * b - c;'), additiveOperands());
		assertDrop(inFn('var v = a - (b % c);'), inFn('var v = a - b % c;'), additiveOperands());
	}

	/**
	 * An additive chain nests to the LEFT, so a middle operand is the right child of the
	 * inner node and reaches this arm on exactly the same terms as an outer one.
	 */
	public function testAdditiveChainMiddleOperandDrops(): Void {
		assertDrop(inFn('var v = a + (b * c) + d;'), inFn('var v = a + b * c + d;'), additiveOperands());
	}

	/** The content is judged by its ROOT kind — a dotted read inside it is ordinary structure. */
	public function testAdditiveNestedContentDrops(): Void {
		assertDrop(inFn('var v = (x.y / 2.0) + z;'), inFn('var v = x.y / 2.0 + z;'), additiveOperands());
	}

	/**
	 * SAME-TIER content RE-ASSOCIATES on unwrap: `a + (b - c)` becomes `(a + b) - c`, a
	 * different rounding for floats and a different value outright under `-`. The
	 * fail-closed whitelist holds only the strictly tighter tiers, so none of these is on
	 * it. `(a + b) - c` is `sameOperatorLeft`'s candidate, never this arm's.
	 */
	public function testAdditiveSameTierContentStays(): Void {
		Assert.equals(0, violations(inFn('var v = a + (b - c);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = a - (b + c);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = a + (b + c);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = (a + b) - c;'), additiveOperands()).length);
	}

	/**
	 * A unary minus IS strictly tighter and the drop would be provable, but `a - (-b)`
	 * bare reads `a - -b`. Off the whitelist on READABILITY alone.
	 */
	public function testAdditiveNegContentStays(): Void {
		Assert.equals(0, violations(inFn('var v = a - (-b);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = (-a) + b;'), additiveOperands()).length);
	}

	/**
	 * The hosts are ADDITIVE only. Haxe binds `%` tighter than `*` and `/`, but C makes
	 * the three one tier — so a C-trained reader parses a bare `a * b % c` as
	 * `(a * b) % c`, and the pair in `a * (b % c)` is what makes the two readings agree.
	 * `(a + b) * c` is looser content under a tighter host, never in scope for any arm.
	 */
	public function testAdditiveArmDoesNotReachATighterHost(): Void {
		Assert.equals(0, violations(inFn('var v = a * (b % c);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = a / (b * c);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = (a + b) * c;'), additiveOperands()).length);
	}

	/**
	 * Bitwise and shift are out on BOTH sides, for two different reasons. As CONTENT they
	 * bind LOOSER than `+` / `-`, so a drop re-associates outward — the fail-closed
	 * whitelist settles that. As HOSTS the drop would be PROVABLE (`(a * b) & c` bare
	 * re-parses to the tree it already had, here and in C); they stay out on the same
	 * READABILITY ground that keeps shifts off the comparison whitelist.
	 */
	public function testAdditiveBitwiseAndShiftStayOut(): Void {
		Assert.equals(0, violations(inFn('var v = (a & b) + c;'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = a + (b << c);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = (a * b) & c;'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = (a * b) << c;'), additiveOperands()).length);
	}

	/**
	 * `comparisonOperands`' symmetry rule, applied unchanged: a parenthesized sibling that
	 * is NOT itself provable vetoes the drop, so the expression is never left lopsided.
	 * `(a * b) + (c - d)` keeps both pairs even though the left one is provable alone —
	 * the two together are a symmetry the author wrote. The bare fixture pins that the
	 * sibling is what rejects it.
	 */
	public function testAdditiveSiblingPairVetoesTheDrop(): Void {
		Assert.equals(0, violations(inFn('var v = (a * b) + (c - d);'), additiveOperands()).length);
		Assert.equals(1, violations(inFn('var v = (a * b) + c;'), additiveOperands()).length);
	}

	/** Two provable operands go in the SAME pass — the symmetry is dissolved, never halved. */
	public function testAdditiveBothOperandsDropInOnePass(): Void {
		assertDrop(inFn('var v = (a * b) + (c / d);'), inFn('var v = a * b + c / d;'), additiveOperands());
	}

	/** With `atoms` on as well an atomic sibling counts as PROVABLE, so the pair settles in one pass. */
	public function testAdditiveConvergesWithTheAtomArm(): Void {
		final out: String = fixed(inFn('var v = (a * b) + (x);'), additiveAndAtoms());
		Assert.equals(inFn('var v = a * b + x;'), out);
		Assert.equals(out, fixed(out, additiveAndAtoms()));
		Assert.equals(bareTree(inFn('var v = (a * b) + (x);')), bareTree(out), 'paren drop preserved the tree shape');
	}

	/** The double-paren arm and this one compose: the whole chain goes in one edit. */
	public function testAdditiveDoubleParensCollapseFully(): Void {
		assertDrop(inFn('var v = ((a * b)) + c;'), inFn('var v = a * b + c;'), additiveOperands());
	}

	/** Inside a `macro` quotation a paren reifies as data, so no operand arm drops one. */
	public function testAdditiveArmIsSuppressedInAMacroQuotation(): Void {
		Assert.equals(0, violations(inFn('var e = macro (a * b) + c;'), additiveOperands()).length);
		Assert.equals(1, violations(inFn('var e = (a * b) + c;'), additiveOperands()).length);
	}

	/** A comparison host is the other arm's turf: with only this arm on its operands are untouched. */
	public function testAdditiveArmDoesNotReachAComparisonHost(): Void {
		Assert.equals(0, violations(inFn('var v = (a * b) < (c - d);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = (a * b) < c;'), additiveOperands()).length);
	}

	/** Both precedence-gated operand arms on at once: each owns its own host tier, and they compose. */
	public function testAdditiveAndComparisonArmsCoexist(): Void {
		assertDrop(inFn('var v = (a * b) < (c - d);'), inFn('var v = a * b < c - d;'), comparisonAndAdditive());
		assertDrop(inFn('var v = a - (b / c);'), inFn('var v = a - b / c;'), comparisonAndAdditive());
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

	/**
	 * Content whose LEFTMOST token is a unary minus is refused, whatever its root kind:
	 * `a + (-b * c)` bare reads `a + -b * c`, the same defect the `Neg` root is excluded
	 * for. The `atoms` arm still owns its own candidates, so only the whitelist arms
	 * consult this. The comparison fixture pins a DELIBERATE change to shipped behaviour.
	 */
	public function testContentLeadingWithAUnaryMinusIsRefused(): Void {
		Assert.equals(0, violations(inFn('var v = a + (-b * c);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = a - (-1 * b);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = a > (-c * d);'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var v = (-c * d) > a;'), comparisonOperands()).length);
	}

	/** A minus anywhere but the leftmost token is untouched — the positive control for the gate above. */
	public function testAnInteriorUnaryMinusStillFires(): Void {
		assertDrop(inFn('var v = a - (b * -c);'), inFn('var v = a - b * -c;'), additiveOperands());
		assertDrop(inFn('var v = a > (b * -c);'), inFn('var v = a > b * -c;'), comparisonOperands());
	}

	/** A sibling pair leading with a unary minus is not provable, so it vetoes the drop like any other. */
	public function testAUnaryMinusSiblingVetoesTheDrop(): Void {
		Assert.equals(0, violations(inFn('var v = (a * b) + (-c * d);'), additiveOperands()).length);
		Assert.equals(2, violations(inFn('var v = (a * b) + (c * d);'), additiveOperands()).length);
	}

	/**
	 * A POSTFIX in/decrement is content for the two whitelist arms and nothing else: it
	 * rides the existing `comparisonOperands` / `additiveOperands` flags, so a project
	 * that opted neither in sees it nowhere, and each arm still owns only its own host
	 * tier.
	 */
	public function testPostfixOperandNeedsItsOwnArm(): Void {
		Assert.equals(0, violations(inFn('var v = (a++) < 36;'), none()).length);
		Assert.equals(0, violations(inFn('var v = (a++) < 36;'), atoms()).length);
		Assert.equals(0, violations(inFn('var v = (a++) < 36;'), sameOperatorLeft()).length);
		Assert.equals(0, violations(inFn('var v = (a++) < 36;'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = (a++) + b;'), none()).length);
		Assert.equals(0, violations(inFn('var v = (a++) + b;'), comparisonOperands()).length);
	}

	/**
	 * The shape this content class was admitted for: `while ((a++) < 36)`. A postfix
	 * `++` binds tighter than a comparison in Haxe and in every C-family language, and
	 * it is TWO-SIDEDLY closed in a way the arithmetic roots are not — its own `++`
	 * token ends the content, and its leftmost token is the operand rather than an
	 * operator, so neither edge gate has anything to refuse.
	 */
	public function testComparisonPostfixOperandDrops(): Void {
		assertDrop(inFn('while ((a++) < 36) g();'), inFn('while (a++ < 36) g();'), comparisonOperands());
		assertDrop(inFn('var v = (a++) < 36;'), inFn('var v = a++ < 36;'), comparisonOperands());
		assertDrop(inFn('var v = c > (a--);'), inFn('var v = c > a--;'), comparisonOperands());
		assertDrop(inFn('var v = (a--) == b;'), inFn('var v = a-- == b;'), comparisonOperands());
	}

	/** The same content one tier down, on either side of `+` / `-` and in a chain's middle. */
	public function testAdditivePostfixOperandDrops(): Void {
		assertDrop(inFn('var v = (a++) + b;'), inFn('var v = a++ + b;'), additiveOperands());
		assertDrop(inFn('var v = b - (a--);'), inFn('var v = b - a--;'), additiveOperands());
		assertDrop(inFn('var v = c + (a++) + d;'), inFn('var v = c + a++ + d;'), additiveOperands());
	}

	/**
	 * The content is judged by its ROOT kind, so the operand under the `++` is ordinary
	 * structure — a dotted read or an index access reaches the arm on the same terms as a
	 * bare identifier. It need not be an ATOM: what makes the drop safe is the postfix
	 * token, not what precedes it.
	 */
	public function testPostfixOperandShapeIsNotRestricted(): Void {
		assertDrop(inFn('var v = (a.b++) + c;'), inFn('var v = a.b++ + c;'), additiveOperands());
		assertDrop(inFn('var v = (arr[i]++) < n;'), inFn('var v = arr[i]++ < n;'), comparisonOperands());
	}

	/**
	 * A SMOKE control, and deliberately labelled one: nothing can falsify it. A `PostIncr`
	 * span ends at its own `++`, so the right-spine walk (`edgeAligned`) never descends
	 * into the operand — and no greedy construct can sit under a `PostIncr` root anyway,
	 * since it would swallow the `++` and BE the root (`untyped c++` parses as
	 * `UntypedExpr(PostIncr(c))`, which is off the whitelist). The fixture below is
	 * bracket-bounded on its own account too, so it would drop even without the postfix
	 * boundary. It is here to pin that the shape is reached, not to discriminate a gate.
	 */
	public function testAPostfixTokenClosesAGreedyTail(): Void {
		assertDrop(inFn('var v = a + (arr[untyped i]++) - d;'), inFn('var v = a + arr[untyped i]++ - d;'), additiveOperands());
	}

	/**
	 * The PREFIX forms are not on the whitelist. They are provable — `++` and `--` bind
	 * tighter than either host tier here and in C — and they are left off on READABILITY
	 * grounds: bare, `(++b) < 36` reads `++b < 36` and `a - (--b)` reads `a - --b`.
	 *
	 * That exclusion is ROOT-ONLY, and the last two fixtures pin its limit rather than its
	 * effect. A leading unary minus is refused by a LEFT-SPINE gate, so `a + (-b * c)`
	 * goes with `a - (-b)`; a prefix in/decrement has no such gate, so content that merely
	 * BEGINS with one keeps dropping. Shipped behaviour, unchanged by admitting the
	 * postfix forms — closing it would need a left-spine vocabulary of its own.
	 */
	public function testAPrefixIncrementIsRefusedAsAContentRoot(): Void {
		Assert.equals(0, violations(inFn('var v = a + (++b);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = a - (--b);'), additiveOperands()).length);
		Assert.equals(0, violations(inFn('var v = (++a) > c;'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var v = c != (--a);'), comparisonOperands()).length);
		// The bare fixtures pin that the PREFIX spelling is what rejects each of these.
		Assert.equals(1, violations(inFn('var v = a + (b++);'), additiveOperands()).length);
		Assert.equals(1, violations(inFn('var v = (a++) > c;'), comparisonOperands()).length);
		// The reach: a prefix in/decrement below the root is NOT refused, unlike a minus.
		Assert.equals(1, violations(inFn('var v = a - (--b * c);'), additiveOperands()).length);
		Assert.equals(1, violations(inFn('var v = (--b * c) > d;'), comparisonOperands()).length);
		Assert.equals(0, violations(inFn('var v = a - (-b * c);'), additiveOperands()).length);
	}

	/**
	 * `++` and `+` are spelled from the same character, but for POSTFIX content the lexer's
	 * maximal munch lands on the reading the drop intended: measured on the compiler,
	 * `a+b+++c` is `a + b++ + c` (1+1+1 = 3, `b` left at 2) and `a-b---c` is `a - b-- - c`.
	 * So the fix's weld guard is belt-and-braces here — it is load-bearing for the
	 * LEADING-operator content these arms refuse (`a-(--p * q)`, pinned by
	 * `testDropKeepsASeparatorAgainstAnOperatorToken`), not for this one. What the
	 * whitespace-free fixtures pin is that `fix` does not DEPEND on the writer's spacing;
	 * the `written` assertions pin the other half, that a canonical file — the only thing
	 * `lint --fix` runs on — already separates the two operators.
	 */
	public function testAPostfixDropCannotWeldOntoTheHostOperator(): Void {
		assertDrop(inFn('var v = a+(b++)+c;'), inFn('var v = a+b++ +c;'), additiveOperands());
		assertDrop(inFn('var v = a-(b--)-c;'), inFn('var v = a-b-- -c;'), additiveOperands());
		assertDrop(inFn('var v = a + (b++) + c;'), inFn('var v = a + b++ + c;'), additiveOperands());
		Assert.isTrue(written(inFn('var v = a + b++ + c;')).indexOf('a + b++ + c') != -1);
		Assert.equals(written(inFn('var v = a + b++ + c;')), written(inFn('var v = a+b++ +c;')));
	}

	/**
	 * The sibling SYMMETRY rule is unchanged: a postfix pair is provable, so it is taken
	 * along by a provable sibling in the same pass and vetoed by one that is not.
	 */
	public function testAPostfixSiblingIsProvable(): Void {
		assertDrop(inFn('var v = (a++) > (b - c);'), inFn('var v = a++ > b - c;'), comparisonOperands());
		assertDrop(inFn('var v = (a++) + (b * c);'), inFn('var v = a++ + b * c;'), additiveOperands());
		Assert.equals(0, violations(inFn('var v = (a++) > (c ?? d);'), comparisonOperands()).length);
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

	/** `src` re-emitted by the writer — what a CANONICAL file looks like, spacing included. */
	private static function written(src: String): String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson('{}'));
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

	private static inline function additiveOperands(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"additiveOperands": true}}}');
	}

	private static inline function additiveAndAtoms(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"atoms": true, "additiveOperands": true}}}');
	}

	private static inline function comparisonAndAdditive(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"additiveOperands": true, "comparisonOperands": true}}}');
	}

	/** Every opt-in arm at once — what a project switching the whole family on gets. */
	private static inline function allArms(): (String) -> LintConfig {
		return configured(
			'{"rules": {"redundant-parens": {"atoms": true, "sameOperatorLeft": true, "comparisonOperands": true, "additiveOperands": true}}}'
		);
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
