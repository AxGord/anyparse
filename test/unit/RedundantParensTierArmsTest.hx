package unit;

import utest.Assert;
import anyparse.check.LintConfig;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;

/**
 * The two PRECEDENCE-TIER operand arms of `redundant-parens`, plus the postfix
 * whitelist and the unary-minus refusal they share.
 *
 * `comparisonOperands` — a pair on EITHER side of a comparison-tier operator
 * (`==` `!=` `<` `<=` `>` `>=`) whose bare content is arithmetic (`+` `-` `*` `/`
 * `%`) or a POSTFIX in/decrement (`x++` `x--`), all of which bind strictly tighter
 * than a comparison in Haxe AND in every C-family language. A sibling pair is not a
 * blanket veto — one that is itself provable (same whitelist, or an atom when
 * `atoms` is on too) is taken along, so both drop in a single pass; the veto fires
 * only when the sibling's content is NOT provable, which would leave the comparison
 * lopsided. The BITWISE tier is off the whitelist for CORRECTNESS — C binds `&` `|`
 * `^` LOOSER than equality, unlike Haxe — while the SHIFT tier binds tighter than a
 * comparison in C exactly as in Haxe and is left out purely on READABILITY: a shift
 * operand is habitually parenthesized.
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
 */
class RedundantParensTierArmsTest extends RedundantParensOperandArmsTestBase {

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

	private inline function comparisonAndAtoms(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"atoms": true, "comparisonOperands": true}}}');
	}

	private inline function additiveAndAtoms(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"atoms": true, "additiveOperands": true}}}');
	}

	private inline function comparisonAndAdditive(): (String) -> LintConfig {
		return configured('{"rules": {"redundant-parens": {"additiveOperands": true, "comparisonOperands": true}}}');
	}

	/** `src` re-emitted by the writer — what a CANONICAL file looks like, spacing included. */
	private function written(src: String): String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson('{}'));
	}

}
