package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags redundant parentheses in four shapes. A parenthesized expression wrapped
 * directly in another (`((e))`) — the outer pair adds nothing wherever it sits. And a
 * LONE `(e)` sitting in a DELIMITED position: one where the surrounding construct
 * supplies its own boundaries on both sides, so no operator can bind across the
 * parens. `Info` severity (a cosmetic cleanup); `fix` unwraps the chain to a single
 * pair (`((e))` / `(((e)))` → `(e)`) outside a delimited position and to nothing
 * inside it (`final m = (-1);` → `final m = -1;`, `((e))` → `e`).
 *
 * The third shape is PRECEDENCE-GATED: a lone `(e)` wrapping the CONDITION of a
 * ternary (`(a < b) ? 1 : -1` → `a < b ? 1 : -1`). That position is an operand, not a
 * delimited slot, so the drop is proven per-content — it fires only when the bare
 * inner binds strictly tighter than `?:` (`RefShape.ternaryConditionUnwrapKinds`),
 * never for a loose / right-greedy inner (assignment, a nested ternary, an arrow, an
 * `untyped` / `macro` / metadata wrapper) that would absorb the `? … : …` on unwrap.
 *
 * The FOURTH shape is the ELSE ARM of a ternary: `a ? 1 : (b ? 2 : 3)`. That arm is the
 * RIGHTMOST operand of a right-associative `?:`, so a nested ternary there is parsed at the
 * ternary tier either way and re-parses to the tree it already had. Only a nested ternary
 * drops — a fail-closed whitelist, so no looser arm re-associates — and a SEPARATOR-greedy
 * tail keeps the pair as it does in a delimited slot. The RIGHT-greedy gate is deliberately
 * not asked here: the pair IS the whole arm, so the bare content ends exactly where the arm
 * ends, and `Ternary` is itself a `rightGreedyExprKinds` member, which would refuse the arm
 * outright. Dropping the pair is what lets `prefer-if-expression-chain` see a chain the
 * parentheses had cut in two.
 *
 * In a delimited position the content's PRECEDENCE is irrelevant — `f((a + b))`
 * unwraps as safely as `f((x))` — but its SYNTAX is not: two content shapes keep
 * their parens even there, and both are declared by the grammar. See
 * `separatorGreedyExprKinds` and `spliceSensitiveExprKinds` below.
 *
 * ## Grammar-agnostic
 *
 * The parenthesized-expression kind comes from `RefShape.parenKind` (unset → no-op).
 * The delimited positions come from two NEW optional lists —
 * `RefShape.delimitedAllChildKinds` (every child of the host: var / final
 * initializer, `return` value, array-literal element, object-literal field value,
 * `new T(args)` argument, `${ … }` string-interpolation slot) and
 * `delimitedTailChildKinds` (every child but the head:
 * call ARGUMENT, not the callee; array INDEX, not the receiver; assignment RIGHT-hand side, not the target) — plus
 * the PRE-EXISTING condition seams `conditionFirstChildKinds` /
 * `conditionLastChildKinds` (`if` / `while` / `do … while`, whose own `(` `)` are
 * grammar syntax rather than a node).
 *
 * Those last two state a grammar FACT — "this kind's condition is child 0" — and
 * were introduced for `assignment-in-condition`, so a grammar that already declares
 * them gets the CONDITION arm of this check with no further opt-in. The two new
 * lists are what the other positions need; declaring neither leaves only the
 * conditions and the double-paren arm.
 *
 * Two content shapes keep their parens in any delimited position:
 *
 * - `separatorGreedyExprKinds` — a construct whose own syntax can consume the
 *   separator that ends the slot. In Haxe a `macro`-quoted declaration:
 *   `f((macro final w = 1), x)` unwrapped becomes `f(macro final w = 1, x)`, where
 *   the compiler reads `x` as a second declarator. The hazard is positional, so the
 *   test walks the interior's LAST child while it ends where its parent ends —
 *   reaching through `@:m macro final w = 1`, a ternary or `if`-`else` whose last
 *   branch is one, and a trailing operand, and stopping at a bracket-closed host
 *   (`q(macro final w = 1)`), whose own closing token already bounds it.
 * - `spliceSensitiveExprKinds` — a reification whose ARITY depends on being directly
 *   an argument. In Haxe `$a{args}`: `macro g(($a{args}))` builds a ONE-argument call
 *   and `macro g($a{args})` a two-argument one, with no syntax error either way. The
 *   test reads the paren's direct content and applies only in a splicing host — the
 *   `callKind` / `arrayLiteralKind` / `newExprKind` seams.
 *
 * Both tests read the content that would be left BARE (paren layers unwrapped
 * first), so `((macro final w = 1))` still collapses to one pair rather than none.
 *
 * The `${ … }` INTERPOLATION slot is delimited on the same terms — `${` and `}` are
 * hard tokens and the one expression between them parses at the loosest precedence.
 * The safety argument is DIFFERENTIAL, and deliberately so: the drop removes a
 * parenthesis and nothing else, and a parenthesis is none of the four characters the
 * real compiler's interpolation scanner reacts to (`{`, `}`, `$`, a backslash) and no
 * line break. So the scanner brace-counts its way over the same text on either
 * spelling, whatever it makes of that text — a content shape that survives the scan
 * WITH the parentheses survives it without them, object literals
 * (`${({a: 1})}` → `${{a: 1}}`), nested same-quote strings and their own `${ … }`
 * blocks included, the interior reproduced byte-for-byte.
 *
 * `HaxeStringFoldSupport.interpolationBlockSafe` describes a NEIGHBOURING question —
 * "may this source be MOVED into a `${ … }` block" — and is anyparse's own model of
 * the scanner, STRICTER than the compiler: it refuses every line break, which a real
 * `${if (a)\n\tb\nelse c}` is free to contain (a line break does not end a Haxe string
 * literal; that helper's own doc says otherwise and is wrong). It is a useful
 * reference for what the scanner reacts to, not the law this arm rests on; nothing
 * here asks it anything.
 *
 * The differential argument is also VACUOUS on a source the scanner cannot close at
 * all. `${("}")}` counts the `}` inside the nested string — the scanner does not lex
 * strings — closes the block early and reports "Unterminated string" WITH the
 * parentheses just as it does without them. Such a site is flagged and fixed like any
 * other, and that is correct in the only sense available: the file does not compile
 * on either spelling, so the rule cannot make it worse. It is not evidence the drop
 * is safe on code that DOES compile — that comes from the paragraph above.
 *
 * Only the pair sitting DIRECTLY inside the braces takes this slot: in `${(a) + (b)}`
 * the two pairs are operands of the `+`, left to the operand arms below, and
 * `${(name)}` loses its parentheses without becoming `$name` — which shorthand a
 * block deserves is `fold-adjacent-string-literals`' question, not this rule's.
 *
 * Deliberately NOT delimited:
 *
 * - The MACRO-reification `${ … }` (`DollarBlockExpr`) — bracket-delimited by exactly
 *   the same two hard tokens as the interpolation block above, and left out anyway.
 *   NOT for a safety reason, and the tempting one is false: a pair written inside a
 *   `macro` QUOTATION does reify as `EParenthesis`, but `${ … }` is the reification
 *   ESCAPE — its content is ordinary macro-TIME code, and `macro ${(e)}` builds exactly
 *   what `macro ${e}` builds (measured). The quoted region is separately handled, by
 *   `MacroExpr` in `parenOpaqueSubtreeKinds`, and that covers only the OPERAND arms —
 *   `dropsParens` does not gate the delimited arm on `opaque` — so opening this slot
 *   would need `DollarBlockExpr` in `delimitedAllChildKinds`, where its absence is a
 *   conservative omission nobody has needed rather than a decision. Listed here so the
 *   next reader stops looking for the argument.
 * - The `switch` SUBJECT — excluded by project decision, not by a safety argument.
 *   The Haxe grammar keeps a parenthesized `SwitchStmt` (carrying its own `(` `)`,
 *   like `if` / `while`) apart from a bare `SwitchStmtBare`, so a `parenKind` child
 *   there IS a redundant second pair and unwrapping it would yield `switch (x)`,
 *   never `switch x`. Whether a switch is written with or without its parens is an
 *   idiom the project's own style rules own; this check stays out of it.
 * - A `case` PATTERN, and with it the case GUARD — the guard's mandatory `(` `)`
 *   project as a bare paren node (`case X if (g):`), so treating a `CaseBranch` child
 *   as delimited would strip syntax the language requires.
 * - Every operand position of a unary or binary operator: an operand is parsed above
 *   the loosest precedence, so its interior re-associates outward — `(a + b) * c` ≢
 *   `a + b * c`, and a map-literal key `[(a ? b : c) => d]` ≢ `[a ? b : c => d]` (bare: `Unexpected =>`, measured).
 *   That is why a call's CALLEE and an assignment's TARGET are excluded while their
 *   tails are not, and why the map-literal `=>` VALUE is left alone even though its
 *   right-associative prec-0 operator would make it provably safe. The two exceptions are
 *   a ternary CONDITION and a ternary ELSE ARM, which the
 *   precedence-gated shapes above handle.
 *
 * The arms compose without overlapping: the check flags the OUTERMOST paren of a
 * chain and does not descend into it, so a site yields one finding and one edit, and
 * in a delimited position `((e))` collapses to `e` outright.
 *
 * ## The four OPERAND arms (opt-in, off by default)
 *
 * All four reach the operand positions the arms above refuse, and all four replace a
 * precedence MODEL with a per-site proof. Each is a separate `apqlint.json` option on
 * this rule, default false, so a project that declares none sees byte-identical
 * behaviour:
 *
 * - `"atoms"` — the pair wraps an ATOM: a SELF-DELIMITING expression
 *   (`RefShape.atomExprKinds` — an identifier, `this`, a literal) or a chain of
 *   TRANSPARENT LINKS bottoming out in one (`RefShape.atomChainKinds` — a call-free
 *   dotted access). Nothing outside can bind into an atom, so the pair is inert in
 *   EVERY position — `(a) + c`, `-(a)`, `arr[(i)]`, `(g)(1)`, `c ? (a) : (b)`. This is
 *   the arm that reaches the common defensive divisor, `(x - y) / (r.width)`.
 * - `"sameOperatorLeft"` — the pair is the LEFT operand of a binary operator and its
 *   content is a binary operator in the SAME left-associative precedence family
 *   (`RefShape.leftAssociativeBinaryFamilies`). Left-associativity already groups that
 *   way, so `(a * b) / c` re-parses to the tree it already had. The RIGHT operand is
 *   never a candidate (`a / (b * c)` is a different computation), families never mix
 *   (`(a + b) * c` stays), and Haxe's `%` is in no family at all — the language binds
 *   it tighter than `*` and `/`, and the grammar models that as a prec-10 tier of its
 *   own for `%`, so `%` shares a tier with no other operator. A single-member `['Mod']`
 *   (`(a % b) % c`) would now be provable; admitting it is deliberate future work.
 * - `"comparisonOperands"` — the pair is an operand of a COMPARISON-tier binary operator
 *   (`RefShape.comparisonOperandHostKinds`) and its bare content is ARITHMETIC or a
 *   POSTFIX in/decrement (`RefShape.comparisonOperandUnwrapKinds`), a fail-closed
 *   whitelist of kinds that bind strictly tighter than a comparison HERE and in every
 *   C-family language — so `(px - x - w) > (py - y - h + r)` and `(a++) < 36` re-parse
 *   to the trees they already had on either reading. EITHER side is a candidate, and
 *   the two are judged TOGETHER: unlike
 *   `sameOperatorLeft`, a parenthesized sibling is no blanket veto — one that is itself
 *   provable (same whitelist, or an ATOM when that arm is on too) takes the slot with it,
 *   so BOTH pairs drop in the same pass. The veto fires only when the sibling pair is NOT
 *   provable, which is what keeps this arm from ever leaving a comparison lopsided.
 *   The BITWISE tier is off the whitelist for a CORRECTNESS reason: Haxe binds `&` / `|` /
 *   `^` tighter than a comparison but C binds them LOOSER than `==` / `!=`, so
 *   `(x & m) != 0` reads differently there once the pair is gone, and that pair is
 *   cross-language insurance an author wrote on purpose. The SHIFT tier is off it for a
 *   READABILITY reason only — C binds shifts tighter than a comparison exactly as Haxe
 *   does, so `(a << b) > c` would be provable on both readings, but a shift operand is
 *   habitually parenthesized and this arm declines to take that away. The PREFIX `++x` /
 *   `--x` are provable too and left off on a READABILITY ground of their own — bare,
 *   `(++b) < 36` reads `++b < 36` — but only as a ROOT: unlike the leading minus, which
 *   `RefShape.unaryMinusKinds` refuses at any depth, a prefix in/decrement has no
 *   left-spine gate, so `(--b * c) > d` still drops. Only the postfix spelling puts the
 *   operand first. Atom content is off it too — the `atoms` arm owns atoms, and the two
 *   converge over `lint --fix` passes.
 * - `"additiveOperands"` — the pair is an operand of an ADDITIVE binary operator
 *   (`RefShape.additiveOperandHostKinds` — `+` and `-`) and its bare content is on the
 *   strictly TIGHTER multiplicative tiers, or a POSTFIX in/decrement
 *   (`RefShape.additiveOperandUnwrapKinds`), a fail-closed whitelist of kinds binding
 *   tighter than the host HERE and in every C-family language — so `a * s - (w / 2.0)`
 *   and `(a++) + b` re-parse to the trees they already had on either reading. EITHER
 *   side is a candidate, a chain's MIDDLE operand included (an
 *   additive chain nests to the left, so a middle operand is simply the right child of
 *   the inner node), and the two sides are judged TOGETHER under the same symmetry rule
 *   `comparisonOperands` applies: a parenthesized sibling that is itself provable (same
 *   whitelist, or an ATOM when that arm is on too) goes in the same pass, and one that is
 *   not vetoes the drop — `(a * b) + (c - d)` keeps both pairs, since firing on the
 *   provable half alone would leave the expression lopsided. Five exclusions, each for
 *   its own reason. SAME-TIER content (`a + (b - c)`, `a - (b + c)`, `a + (b + c)`) is
 *   out for CORRECTNESS: the drop RE-ASSOCIATES, which changes the rounding for floats
 *   and the value outright under `-`. Content whose LEFTMOST token is a unary minus
 *   (`RefShape.unaryMinusKinds`) is provable and out on READABILITY, since the bare form
 *   reads `a - -b` — a LEFT-SPINE test, so `a + (-b * c)` goes with `a - (-b)` rather than
 *   slipping through on its arithmetic root. The PREFIX `++x` / `--x` are left off on
 *   that same READABILITY ground — bare, `a - (--b)` reads `a - --b` — but by the
 *   WEAKER mechanism of not being on the root whitelist at all, so unlike the minus
 *   they are not refused at depth and `a - (--b * c)` still drops. What that leaves on
 *   the whitelist is the POSTFIX spelling: it puts the operand first, and its own
 *   `++` / `--` token closes the content, so no greedy tail inside can reach past the
 *   pair. The multiplicative operators are no
 *   HOSTS — Haxe binds `%` tighter than `*` and `/`, but C makes the three ONE tier, so
 *   a bare `a * b % c` reads `(a * b) % c` to a C-trained eye and the pair in
 *   `a * (b % c)` is what makes the two readings agree; the same cross-language trap the
 *   BITWISE exclusion above guards against. `%` CONTENT under `+` / `-` is fine — C
 *   agrees it binds tighter than either. Bitwise and shift are out on both sides, for two
 *   DIFFERENT reasons: as CONTENT they bind LOOSER than the additive tier, so a drop
 *   re-associates outward, which the fail-closed whitelist settles; as HOSTS a drop would
 *   be provable — `(a * b) & c` bare re-parses to the tree it already had, here and in C —
 *   and they stay out on the READABILITY ground that keeps shifts off the comparison
 *   whitelist.
 *
 * Readability parens on a MIXED-operator expression are a human choice, so
 * `sameOperatorLeft` is restricted to the same-family left operand and nothing else —
 * and it declines even that when the RIGHT operand carries a pair of its own
 * (`Math.abs((px - x) + (py - y - h))`). Both pairs are one symmetry the author wrote,
 * only the left is ever removable, and firing there leaves the expression lopsided:
 * worse to read than either keeping or dropping both. Measured on a 798-file corpus,
 * that veto is what separates the clean drops from the disfiguring ones.
 *
 * All four arms are additionally suppressed inside `RefShape.parenOpaqueSubtreeKinds` (a
 * `macro` quotation, where a pair reifies as data; a case pattern, matched
 * structurally) and at a direct child of `RefShape.parenRequiredHostKinds` (a `case`
 * guard, a `switch` subject, metadata).
 *
 * ## Two gates every PRECEDENCE-GATED slot shares
 *
 * The three opt-in arms and the shipped ternary CONDITION all prove the drop from the
 * content's ROOT kind. Two things a root cannot see make the parentheses load-bearing
 * anyway, so both gates run for those four slots — the ternary ELSE ARM is the one
 * precedence-gated slot that asks neither, and says why where it is decided. The ternary
 * CONDITION arm is default-ON, which is where each bug was actually shipping.
 *
 * A RIGHT-GREEDY TAIL. A construct whose extent ends only at its enclosing bracket, sitting
 * at the right edge of the content, eats whatever followed the pair:
 * `a + (b * untyped c) - d` has a `Mul` root and evaluates to 9, while the bare form is 7
 * because `untyped` takes `c - d`. `RefShape.rightGreedyExprKinds` names those kinds and
 * `spineEndsWith` finds them, the same right-spine walk the delimited arm already used for
 * `separatorGreedyExprKinds` — a greedy construct ALWAYS ends up at the right edge of
 * whatever bounds it, which is what makes one walk enough. A construct closed by its own
 * token (`f(untyped c)`) is not at that edge and does not gate.
 *
 * A METADATA PREFIX. This parser models `@:m` as wrapping the whole expression that
 * follows; the compiler binds it to the immediate primary. So in `@:privateAccess (a * b) + c`
 * the pair is what holds the annotation over the multiplication, and dropping it turns
 * compiling code into `Cannot access private field` — measured, not reasoned. The pair is
 * treated as `Required` whenever it sits on the LEFT EDGE of an expression a
 * `RefShape.parenRequiredHostKinds` construct annotates, which the walk carries down as a
 * flag beside `opaque`. A pair further right (`@:privateAccess a + (b * c)`) is not what
 * the annotation binds to and still drops.
 *
 * Both gates exist because the tree-shape oracle is BLIND to them: this parser's model and
 * the compiler's disagree about the extent of `cast` and of a metadata annotation, so the
 * before and after trees compare equal while the real ones do not. `RefShape` is where that
 * disagreement is recorded; see the note on `HxExpr`'s `CastExpr`.
 *
 * ## Trivia
 *
 * The fix reproduces the CONTENT NODE's source span and drops every other byte of the
 * pair, so anything in the gap between a parenthesis and that span is deleted. Every
 * arm therefore refuses a pair with a non-blank gap on either side, at EVERY layer of
 * the chain — the intermediate `(` `)` of `((e))` are the chain, not trivia.
 *
 * "Flush against the content" is measured against that SPAN, not against the visible
 * text, and on the TRAILING side the two part company. Whether a trailing comment is
 * refused or CARRIED out with the content is decided by the content NODE'S KIND, not by
 * the slot: an operator node's span runs past its last child to the consumed-trivia
 * boundary and absorbs the comment, so the gap reads blank and the pair drops
 * (`(a + c <block comment>)` collapses with the comment intact — in the interpolation
 * slot, pinned by `RedundantParensCheckTest.testInterpolationCommentInsideParens`, and
 * identically in every ordinary delimited position). A leaf or bracket-closed node's
 * span stops at its last token, the comment lands outside it, and the pair is refused
 * (`(a <block comment>)` —
 * `RedundantParensOperandArmsTest.testParensCarryingACommentAreSkipped`). A LEADING
 * comment is outside the span for every kind, and refuses everywhere.
 *
 * Carrying is sound wherever it happens: the bytes move with the expression they
 * annotate and the fix's own re-parse sees them. What the gate guarantees is the one
 * direction that matters — a comment the fix would DELETE always refuses.
 */
@:nullSafety(Strict)
final class RedundantParens implements Check implements ConfigAware {

	/** A ternary's else-arm child index — `[condition, then, else]`. */
	private static inline final TERNARY_ELSE_CHILD_INDEX: Int = 2;

	/** The rule id — also the `apqlint.json` key its four opt-in options hang off. */
	private static final ID: String = 'redundant-parens';

	/** The characters operators are spelled from — two of them side by side lex as one longer operator. */
	private static final OPERATOR_CHARS: String = '+-*/%=<>!&|^~?:';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return ID;
	}

	public function description(): String {
		return
			'parentheses that cannot affect the parse — ((e)), a lone (e) in a delimited position, or (opt-in) one around an inert operand';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		if (shape.parenKind == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final slots: ParenSlots = slotsOf(shape, entry.file);
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, slots, SlotKind.Plain, false, false);
		}
		return violations;
	}

	/**
	 * Unwrap each flagged paren chain: to nothing in a delimited position, to a
	 * single pair anywhere else.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final shape: RefShape = plugin.refShape();
		if (shape.parenKind == null) return [];
		final slots: ParenSlots = slotsOf(shape, violations[0].file);
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final siteByKey: Map<String, ParenSite> = [];
		indexParens(tree, slots, SlotKind.Plain, false, false, siteByKey);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final site: Null<ParenSite> = siteByKey['${span.from}:${span.to}'];
			if (site == null) continue;
			final inner: Null<Span> = RefactorSupport.unwrapParens(site.node, slots.parenKind).span;
			if (inner == null) continue;
			final text: String = source.substring(inner.from, inner.to);
			if (!site.dropsParens) {
				edits.push({ span: span, text: '($text)' });
				continue;
			}
			// A parenthesis can be the ONLY thing separating its content from a
			// neighbouring token, and dropping it bare welds the two — into one identifier
			// (`return(a);` before it, `(s)is String` after), which still PARSES and so
			// survives the caller's re-parse, or into one longer operator
			// (`a-(-b * c)` -> `a--b * c`), which does not. Re-separate either side.
			final lead: String = separator(source, span.from - 1, text.charCodeAt(0) ?? 0);
			final trail: String = separator(source, span.to, text.charCodeAt(text.length - 1) ?? 0);
			edits.push({ span: span, text: '$lead$text$trail' });
		}
		return edits;
	}

	/**
	 * The grammar's paren kind plus its delimited-slot vocabulary and this project's
	 * operand-arm opt-ins. `shape.parenKind` must be non-null — the caller bails on a
	 * grammar that declares none, once per run rather than once per file.
	 *
	 * EVERY vocabulary the operand arms read is emptied when no arm is on, the
	 * suppression lists (`requiredHost` / `opaqueSubtree`) included: those two answer
	 * only for the operand arms, and leaving them populated would let a future grammar
	 * that lists a host BOTH as required and as delimited change the shipped arms'
	 * answer with nothing opted in.
	 */
	private function slotsOf(shape: RefShape, file: String): ParenSlots {
		final config: LintConfig = LintConfig.resolveWith(_resolveConfig, file);
		final atomArm: Bool = config.boolOption(ID, 'atoms') == true;
		final familyArm: Bool = config.boolOption(ID, 'sameOperatorLeft') == true;
		final comparisonArm: Bool = config.boolOption(ID, 'comparisonOperands') == true;
		final additiveArm: Bool = config.boolOption(ID, 'additiveOperands') == true;
		final operandArm: Bool = atomArm || familyArm || comparisonArm || additiveArm;
		return {
			parenKind: shape.parenKind ?? '',
			ternaryKind: shape.ternaryKind,
			ternaryUnwrap: shape.ternaryConditionUnwrapKinds ?? [],
			allChild: shape.delimitedAllChildKinds ?? [],
			tailChild: shape.delimitedTailChildKinds ?? [],
			condFirstChild: shape.conditionFirstChildKinds ?? [],
			condLastChild: shape.conditionLastChildKinds ?? [],
			greedy: shape.separatorGreedyExprKinds ?? [],
			splice: shape.spliceSensitiveExprKinds ?? [],
			spliceHost: [for (k in [shape.callKind, shape.arrayLiteralKind, shape.newExprKind]) if (k != null) k],
			atoms: armVocabulary(shape.atomExprKinds, atomArm),
			atomChains: armVocabulary(shape.atomChainKinds, atomArm),
			families: armVocabulary(shape.leftAssociativeBinaryFamilies, familyArm),
			comparisonHost: armVocabulary(shape.comparisonOperandHostKinds, comparisonArm),
			comparisonUnwrap: armVocabulary(shape.comparisonOperandUnwrapKinds, comparisonArm),
			additiveHost: armVocabulary(shape.additiveOperandHostKinds, additiveArm),
			additiveUnwrap: armVocabulary(shape.additiveOperandUnwrapKinds, additiveArm),
			rightGreedy: shape.rightGreedyExprKinds ?? [],
			unaryMinus: shape.unaryMinusKinds ?? [],
			prefixAnnotation: shape.prefixAnnotationKinds ?? [],
			requiredHost: armVocabulary(shape.parenRequiredHostKinds, operandArm),
			opaqueSubtree: armVocabulary(shape.parenOpaqueSubtreeKinds, operandArm)
		};
	}

	/** Whether `c` is an identifier or number character — one a neighbouring token can lex into. */
	private static inline function isWordChar(c: Int): Bool {
		return c == '_'.code || c >= 'a'.code && c <= 'z'.code || c >= 'A'.code && c <= 'Z'.code || c >= '0'.code && c <= '9'.code;
	}

	/** Whether `c` is a character operators are spelled from, which the lexer reads greedily. */
	private static inline function isOperatorChar(c: Int): Bool {
		return OPERATOR_CHARS.indexOf(String.fromCharCode(c)) >= 0;
	}

	/**
	 * Whether a kind of `kinds` sits at the RIGHT EDGE of `inner`, which makes the
	 * parentheses around it load-bearing. The walk follows the last child while that child
	 * ends where its parent ends, so it reaches through a metadata wrapper / trailing
	 * ternary branch / trailing operand and stops at a bracket-closed host, whose own
	 * closing token already bounds the construct.
	 *
	 * TWO vocabularies ask it. `RefShape.separatorGreedyExprKinds` for a DELIMITED slot —
	 * what can eat the separator that ends the slot — and `RefShape.rightGreedyExprKinds`
	 * for the four precedence-gated slots, what can eat whatever follows the pair. The walk
	 * is the same; only the terminal set differs.
	 */
	private static inline function spineEndsWith(inner: QueryNode, kinds: Array<String>): Bool {
		return spineTerminal(inner, kinds, false);
	}

	/**
	 * The LEFT-edge mirror of `spineEndsWith`: whether a kind of `kinds` owns the leftmost
	 * token of `inner`. Reaches through a chain of binary operators to whatever is written
	 * first and stops as soon as something of the parent's own opens before it.
	 */
	private static inline function spineStartsWith(inner: QueryNode, kinds: Array<String>): Bool {
		return spineTerminal(inner, kinds, true);
	}

	/** Whether `child` is the first thing inside `parent` — nothing of `parent`'s own opens before it. */
	private static inline function startsTogether(parent: QueryNode, child: QueryNode): Bool {
		return edgeAligned(parent, child, true);
	}

	/** A grammar vocabulary an arm reads, or an EMPTY list when the arm is off or the grammar declares none. */
	private static function armVocabulary<T>(declared: Null<Array<T>>, on: Bool): Array<T> {
		return on ? declared ?? [] : [];
	}

	/**
	 * The separator a drop needs at one edge of the pair: a space when the source
	 * character at `at` would lex into ONE token with `abutting` — the content character
	 * landing beside it once the parenthesis between them is gone — and nothing otherwise.
	 * Out of range there is no neighbour, so nothing is needed.
	 *
	 * Two classes weld. An identifier / number neighbour is treated as welding with ANY
	 * content, which is why `return(-a)` also keeps a space it does not strictly need: the
	 * cost is one character and the alternative is reasoning about every keyword. Two
	 * OPERATOR characters weld because the lexer takes the longest match — `a-(-b * c)`
	 * bare is `a--b * c`, a decrement.
	 *
	 * Both character classes are spelled out here rather than read from the grammar: they
	 * are the C-family lexical conventions every grammar this check has met shares. The two
	 * directions of being wrong are NOT symmetric. A character wrongly IN `OPERATOR_CHARS`
	 * costs one space nobody needed. A character wrongly LEFT OUT is fail-open — no space,
	 * the two tokens weld, and the result can still PARSE as something else, which is how
	 * `a-(--p * q)` becomes `a---p * q`, a postfix decrement of `a`. Add to the set on
	 * suspicion.
	 */
	private static function separator(source: String, at: Int, abutting: Int): String {
		if (at < 0 || at >= source.length) return '';
		final neighbour: Int = source.charCodeAt(at) ?? 0;
		return isWordChar(neighbour) || (isOperatorChar(neighbour) && isOperatorChar(abutting)) ? ' ' : '';
	}

	/**
	 * Walk `node`; flag a paren that directly wraps another paren, or one whose `slot`
	 * lets the pair drop, and STOP — the inner redundant layers are subsumed by the
	 * single fix, and not descending keeps every edit disjoint. Otherwise descend,
	 * classifying each child's own slot and carrying whether the walk is inside a
	 * subtree where a paren is not merely grouping.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, slots: ParenSlots, slot: SlotKind, opaque: Bool,
		prefixed: Bool
	): Void {
		// `children.length == 1` is defensive: a grammar's paren wraps exactly one
		// expression, so no fixture can reach the else side in Haxe (`()` does not
		// parse). It guards a grammar whose paren kind is shaped differently.
		if (
			node.kind == slots.parenKind && node.children.length == 1
			&& (dropsParens(node.children[0], slots, slot, opaque, prefixed) || node.children[0].kind == slots.parenKind)
			&& !triviaInsideParens(source, node, slots)
		) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: ID,
					severity: Severity.Info,
					message: 'redundant parentheses'
				});
				return;
			}
		}
		final inner: Bool = opaque || slots.opaqueSubtree.contains(node.kind);
		final host: Bool = slots.prefixAnnotation.contains(node.kind);
		for (i => c in node.children)
			walk(out, file, source, c, slots, slotOf(node, i, slots), inner, host || prefixed && startsTogether(node, c));
	}

	/**
	 * Whether the paren chain around `inner` can be dropped ENTIRELY: its slot is
	 * delimited, the content left bare is not separator-greedy, and dropping the parens
	 * would not turn a splice-sensitive reification loose in a splicing host — or, under
	 * the opt-in operand arms, the content is provably inert wherever it sits (`atoms`)
	 * or provably re-parses to the tree it already had in this operand slot
	 * (`sameOperatorLeft`, `comparisonOperands`, `additiveOperands`).
	 *
	 * `prefixed` says the pair sits at the LEFT EDGE of an expression a
	 * `RefShape.parenRequiredHostKinds` construct annotates, where the pair holds that
	 * annotation over its content — the same answer as `Required`, reached from an
	 * ancestor rather than the immediate parent.
	 *
	 * Every PRECEDENCE-GATED slot additionally refuses content that ends in a
	 * `RefShape.rightGreedyExprKinds` construct. Those four slots prove the drop from the
	 * content's ROOT kind, and a root binds nothing about its right EDGE: `(b * untyped c)`
	 * has an arithmetic root over a tail that swallows whatever follows the pair.
	 *
	 * The switch is EXHAUSTIVE on purpose — no `case _`. A new `SlotKind` then fails to
	 * compile here instead of inheriting whichever branch it happens to fall into, which
	 * for this rule would be the permissive one.
	 */
	private static function dropsParens(inner: QueryNode, slots: ParenSlots, slot: SlotKind, opaque: Bool, prefixed: Bool): Bool {
		// The fix drops the WHOLE chain, so every test reads the content that would be
		// left bare, not the next paren layer down.
		final bare: QueryNode = RefactorSupport.unwrapParens(inner, slots.parenKind);
		if (prefixed) return false;
		// The operand arms answer per CONTENT, so they apply in any slot the shipped arms
		// leave alone — but never inside a subtree where a paren carries meaning.
		final atom: Bool = !opaque && isAtom(bare, slots);
		final ungreedy: Bool = !spineEndsWith(bare, slots.rightGreedy);
		return switch slot {
			case SlotKind.Required: false;
			case SlotKind.Plain: atom;
			case SlotKind.SameFamilyLeft:
				!opaque && ungreedy;
			case SlotKind.ComparisonOperand:
				!opaque && (isAtom(bare, slots) || tighterTierContent(bare, slots.comparisonUnwrap, slots)) && ungreedy;
			case SlotKind.AdditiveOperand:
				!opaque && (isAtom(bare, slots) || tighterTierContent(bare, slots.additiveUnwrap, slots)) && ungreedy;
			// A ternary condition drops its parens only when the bare content binds strictly
			// tighter than `?:` — otherwise unwrapping lets it absorb the `? … : …` branches.
			case SlotKind.TernaryCondition:
				(atom || slots.ternaryUnwrap.contains(bare.kind)) && ungreedy;
			// The else arm is the RIGHTMOST operand of a right-associative `?:`, so a nested
			// ternary there parses at the same precedence bare and the pair is transparent. The
			// right-greedy gate is not asked: the pair IS the whole arm, so the bare content ends
			// exactly where the arm does. A SEPARATOR-greedy tail is a different question and does
			// gate — a declaration continuation reaches past the `,` that ends the enclosing slot.
			case SlotKind.TernaryElse:
				atom || bare.kind == slots.ternaryKind && !spineEndsWith(bare, slots.greedy);
			case SlotKind.Delimited:
				atom || !spineEndsWith(bare, slots.greedy);
			case SlotKind.DelimitedSplice:
				atom || !slots.splice.contains(bare.kind) && !spineEndsWith(bare, slots.greedy);
		}
	}

	/**
	 * Whether `bare` is content one of the two whitelist operand slots can drop: its root
	 * is on `unwrapKinds` AND its leftmost token is not a unary minus.
	 *
	 * The leading-minus half is a READABILITY rule, not a correctness one — `a + (-b * c)`
	 * re-parses to the tree it already had. It reads `a + -b * c`, which is the defect a
	 * bare `Neg` root was excluded for, and a root kind cannot see it: the minus is a leaf
	 * of a `Mul`. Asking the left SPINE covers both, so the whitelists no longer name
	 * `Neg` at all. Shared with the sibling test in `tighterTierOperand`, so a sibling
	 * leading with a minus is not provable either.
	 */
	private static function tighterTierContent(bare: QueryNode, unwrapKinds: Array<String>, slots: ParenSlots): Bool {
		return unwrapKinds.contains(bare.kind) && !spineStartsWith(bare, slots.unaryMinus);
	}

	/**
	 * Whether nothing outside `node` can bind into it: either it is SELF-DELIMITING
	 * (`atoms` — an identifier or a literal, whose children are internal structure
	 * sealed inside its own delimiters) or a TRANSPARENT LINK whose every child is
	 * itself an atom (`atomChains` — what makes `a.b.c` one atom and `f().b` none).
	 * Empty vocabularies — the default, and any grammar that declares none — answer
	 * uniformly false.
	 */
	private static function isAtom(node: QueryNode, slots: ParenSlots): Bool {
		if (slots.atoms.contains(node.kind)) return true;
		if (!slots.atomChains.contains(node.kind)) return false;
		return node.children.foreach(c -> isAtom(c, slots));
	}

	/**
	 * Whether anything but whitespace sits between a parenthesis and the SPAN of the
	 * expression it wraps, at ANY layer of the chain — a comment the fix would delete,
	 * since it reproduces that span and nothing else. Walked layer by layer because the
	 * intermediate `(` `)` of `((e))` are the chain, not trivia. An unmeasurable span
	 * answers true, which keeps the parentheses.
	 *
	 * Measuring against the span is what makes the trailing side depend on the content
	 * node's KIND: an operator node's span already absorbs a trailing comment, so the gap
	 * reads blank and the drop carries the comment out rather than deleting it; a leaf or
	 * bracket-closed node's does not, and the pair refuses. See the class doc's Trivia
	 * section.
	 */
	private static function triviaInsideParens(source: String, node: QueryNode, slots: ParenSlots): Bool {
		var n: QueryNode = node;
		while (n.kind == slots.parenKind && n.children.length == 1) {
			final outer: Null<Span> = n.span;
			final child: QueryNode = n.children[0];
			final inner: Null<Span> = child.span;
			if (outer == null || inner == null) return true;
			if (!isBlank(source, outer.from + 1, inner.from) || !isBlank(source, inner.to, outer.to - 1)) return true;
			n = child;
		}
		return false;
	}

	/** Whether `[from, to)` of `source` is empty or whitespace only. */
	private static function isBlank(source: String, from: Int, to: Int): Bool {
		return source.substring(from, to).trim() == '';
	}

	/**
	 * The walk both spine tests are: descend the `leading` edge of `inner` — first child
	 * going left, last child going right — for as long as that child sits flush against it,
	 * and answer whether a kind of `kinds` was reached. The two directions are one
	 * algorithm; `spineStartsWith` / `spineEndsWith` name them so no call site reads a bare
	 * boolean.
	 */
	private static function spineTerminal(inner: QueryNode, kinds: Array<String>, leading: Bool): Bool {
		var n: QueryNode = inner;
		while (!kinds.contains(n.kind)) {
			if (n.children.length == 0) return false;
			final next: QueryNode = leading ? n.children[0] : n.children[n.children.length - 1];
			if (!edgeAligned(n, next, leading)) return false;
			n = next;
		}
		return true;
	}

	/**
	 * Whether `child` sits flush against one edge of `parent` — its START when `leading`,
	 * its END otherwise. Nothing of `parent`'s own opens before, or closes after, it.
	 */
	private static function edgeAligned(parent: QueryNode, child: QueryNode, leading: Bool): Bool {
		// A grammar that leaves spans unset cannot be measured; keep descending, which errs
		// towards FINDING the construct at the edge — and for every caller of either walk,
		// that keeps the parentheses.
		final p: Null<Span> = parent.span;
		if (p == null) return true;
		final c: Null<Span> = child.span;
		return c == null || (leading ? p.from == c.from : p.to == c.to);
	}

	/** How `parent`'s child at `i` is bounded — see `SlotKind`. */
	private static function slotOf(parent: QueryNode, i: Int, slots: ParenSlots): SlotKind {
		// `i == 0` is defensive, in the manner of the `children.length == 1` guards
		// below: the symmetry veto in `sameFamilyLeftOperand` already refuses a
		// parenthesized child 1, and a child that is not a paren never reaches
		// `dropsParens`. It pins the slot as the LEFT operand's for a reader.
		return if (slots.requiredHost.contains(parent.kind))
			SlotKind.Required
		else if (parent.kind == slots.ternaryKind && i == 0)
			SlotKind.TernaryCondition
		else if (parent.kind == slots.ternaryKind && i == TERNARY_ELSE_CHILD_INDEX)
			SlotKind.TernaryElse
		else if (i == 0 && sameFamilyLeftOperand(parent, slots))
			SlotKind.SameFamilyLeft
		else if (tighterTierOperand(parent, i, slots.comparisonHost, slots.comparisonUnwrap, slots))
			SlotKind.ComparisonOperand
		else if (tighterTierOperand(parent, i, slots.additiveHost, slots.additiveUnwrap, slots))
			SlotKind.AdditiveOperand
		else if (!childDelimited(parent, i, slots))
			SlotKind.Plain
		else if (slots.spliceHost.contains(parent.kind))
			SlotKind.DelimitedSplice
		else
			SlotKind.Delimited;
	}

	/**
	 * Whether `parent` is a member of a left-associative precedence family and its FIRST
	 * child is a parenthesized member of the SAME family — the shape left-associativity
	 * already groups, so the pair re-parses away. Only child 0 is asked; the right
	 * operand of the same operators is a different computation.
	 *
	 * A parenthesized RIGHT operand vetoes it. Both pairs together are a SYMMETRY the
	 * author wrote deliberately (`Math.abs((px - x) + (py - y - h))`), and only the left
	 * one is ever removable — so firing would leave the expression lopsided, which reads
	 * worse than either keeping or dropping both. Measured on a 798-file corpus: the
	 * veto is what separates the clean drops from the disfiguring ones.
	 */
	private static function sameFamilyLeftOperand(parent: QueryNode, slots: ParenSlots): Bool {
		if (parent.children.length != 2 || parent.children[0].kind != slots.parenKind) return false;
		if (parent.children[1].kind == slots.parenKind) return false;
		final bare: String = RefactorSupport.unwrapParens(parent.children[0], slots.parenKind).kind;
		return slots.families.exists(family -> family.contains(parent.kind) && family.contains(bare));
	}

	/**
	 * Whether `parent`'s child at `i` is a parenthesized operand — EITHER side — of a
	 * binary operator on `hostKinds` whose bare content is on `unwrapKinds`: the slot the
	 * two precedence-gated operand arms drop. Every kind of such a whitelist binds strictly
	 * tighter than its hosts in this language AND in the C family, so the drop holds on
	 * both readings; a kind absent from it keeps its parentheses.
	 *
	 * The sibling test is a SYMMETRY rule rather than the hard veto `sameFamilyLeftOperand`
	 * applies. A parenthesized sibling that is itself PROVABLE — its bare content is on the
	 * same whitelist, or it is an ATOM the opt-in `atoms` arm would drop anyway — takes the
	 * slot with it: both pairs go in the SAME pass, so the expression is never left
	 * lopsided. Only a sibling pair that is not provable refuses the slot, which keeps the
	 * two exactly as the author wrote them. The atom half is inert unless `atoms` is on as
	 * well, since `slots.atoms` is empty otherwise.
	 *
	 * `comparisonOperands` and `additiveOperands` share this one test because the question
	 * is identical — only the two vocabularies differ, and each is asked with its OWN pair,
	 * so neither arm's whitelist can prove a sibling for the other. An arm that is off
	 * supplies EMPTY vocabularies, which answer false for every host.
	 */
	private static function tighterTierOperand(
		parent: QueryNode, i: Int, hostKinds: Array<String>, unwrapKinds: Array<String>, slots: ParenSlots
	): Bool {
		if (!hostKinds.contains(parent.kind) || parent.children.length != 2) return false;
		if (parent.children[i].kind != slots.parenKind) return false;
		final sibling: QueryNode = parent.children[1 - i];
		if (sibling.kind != slots.parenKind) return true;
		final bare: QueryNode = RefactorSupport.unwrapParens(sibling, slots.parenKind);
		return tighterTierContent(bare, unwrapKinds, slots) || isAtom(bare, slots);
	}

	/**
	 * Whether `parent`'s child at `i` sits in a slot the surrounding construct delimits
	 * itself.
	 *
	 * The `condLastChild` index test is defensive: Haxe's only such host is
	 * `DoWhileStmt`, whose children are `[body, cond]`, and a body never projects as a
	 * bare paren — so no fixture can reach its false side. It pins the slot for a grammar
	 * whose do-while carries more children.
	 */
	private static function childDelimited(parent: QueryNode, i: Int, slots: ParenSlots): Bool {
		if (slots.allChild.contains(parent.kind)) return true;
		return if (slots.tailChild.contains(parent.kind))
			i > 0
		else if (slots.condFirstChild.contains(parent.kind))
			i == 0
		else
			slots.condLastChild.contains(parent.kind) && i == parent.children.length - 1;
	}

	/** Index every paren node by its `from:to` span key, recording whether its own pair can be dropped entirely. */
	private static function indexParens(
		node: QueryNode, slots: ParenSlots, slot: SlotKind, opaque: Bool, prefixed: Bool, out: Map<String, ParenSite>
	): Void {
		// Same defensive `children.length == 1` as `walk` — see the note there.
		if (node.kind == slots.parenKind && node.children.length == 1) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = {
				node: node,
				dropsParens: dropsParens(node.children[0], slots, slot, opaque, prefixed)
			};
		}
		final inner: Bool = opaque || slots.opaqueSubtree.contains(node.kind);
		final host: Bool = slots.prefixAnnotation.contains(node.kind);
		for (i => c in node.children)
			indexParens(c, slots, slotOf(node, i, slots), inner, host || prefixed && startsTogether(node, c), out);
	}

}

/**
 * The grammar's parenthesis kind, the four host-kind lists that pin a DELIMITED slot
 * — `allChild` (every child), `tailChild` (every child but the first),
 * `condFirstChild` / `condLastChild` (the bracketed condition of a conditional) — and
 * `greedy`, the interior kinds whose parens stay even in a delimited slot.
 *
 * `atoms` (self-delimiting kinds), `atomChains` (transparent links, atomic only when
 * every child is), `families`, and the two host / unwrap PAIRS — `comparisonHost` /
 * `comparisonUnwrap` (comparison-tier hosts, arithmetic content) and `additiveHost` /
 * `additiveUnwrap` (additive hosts, multiplicative content) — carry the four OPERAND
 * arms, with `opaqueSubtree` bounding them. Each holds the grammar's vocabulary when this
 * project opted the owning arm in and an EMPTY array otherwise, so a default run answers
 * every operand question uniformly false with no second flag to read. Resolved once per
 * file so the walk never re-reads the shape or the config.
 *
 * `rightGreedy`, `unaryMinus` and `requiredHost` are deliberately NOT arm-scoped. The
 * first two gate the SHIPPED, default-on ternary-condition arm as well as the opt-in ones,
 * and the third states where a metadata annotation binds — a correctness rule that holds
 * whatever a project opted in.
 *
 * WHEN A THIRD PRECEDENCE-GATED HOST/UNWRAP PAIR LANDS beside `comparison*` and
 * `additive*`, collapse the parallel fields into one array of pairs and loop `slotOf` over
 * it. Two pairs still read better spelled out; three is the trigger.
 */
private typedef ParenSlots = {
	var parenKind: String;
	var ternaryKind: Null<String>;
	var ternaryUnwrap: Array<String>;
	var allChild: Array<String>;
	var tailChild: Array<String>;
	var condFirstChild: Array<String>;
	var condLastChild: Array<String>;
	var greedy: Array<String>;
	var splice: Array<String>;
	var spliceHost: Array<String>;
	var atoms: Array<String>;
	var atomChains: Array<String>;
	var families: Array<Array<String>>;
	var comparisonHost: Array<String>;
	var comparisonUnwrap: Array<String>;
	var additiveHost: Array<String>;
	var additiveUnwrap: Array<String>;
	var rightGreedy: Array<String>;
	var unaryMinus: Array<String>;
	var prefixAnnotation: Array<String>;
	var requiredHost: Array<String>;
	var opaqueSubtree: Array<String>;
}

/**
 * An indexed paren node plus whether its own pair can be dropped entirely (rather
 * than collapsed to one pair) — the `fix` lookup's payload.
 */
private typedef ParenSite = {
	var node: QueryNode;
	var dropsParens: Bool;
}

/**
 * How a child slot is bounded. `Plain` — nothing delimits it, so a paren there may be
 * load-bearing for precedence. `Delimited` — the construct supplies its own boundaries.
 * `DelimitedSplice` — delimited AND the host expands a splicing reification argument
 * (`RefShape.spliceSensitiveExprKinds`), where a paren changes ARITY, not syntax.
 * `TernaryCondition` — a ternary's condition child, a precedence-gated slot where the
 * paren drops only when the bare inner binds strictly tighter than `?:`
 * (`RefShape.ternaryConditionUnwrapKinds`). `SameFamilyLeft` — the LEFT operand of a
 * binary operator whose parenthesized content is another member of the same
 * left-associative precedence family, which the opt-in `sameOperatorLeft` arm drops.
 * `Required` — a direct child of a `RefShape.parenRequiredHostKinds` host, where the
 * pair is grammar syntax or an idiom this check declines to own. `ComparisonOperand` —
 * either operand of a `RefShape.comparisonOperandHostKinds` operator, a second
 * precedence-gated slot where the paren drops only for the arithmetic content on
 * `RefShape.comparisonOperandUnwrapKinds`, and only when a parenthesized sibling is
 * itself provable (on that same whitelist, or as an atom when the `atoms` arm is
 * on) — the opt-in `comparisonOperands` arm. `AdditiveOperand` — the next arm down:
 * either operand of a `RefShape.additiveOperandHostKinds` operator, where the paren
 * drops for the strictly tighter multiplicative content on
 * `RefShape.additiveOperandUnwrapKinds` under the identical sibling rule — the opt-in
 * `additiveOperands` arm.
 *
 * `TernaryElse` — a ternary's else-arm child, the RIGHTMOST operand of a right-associative
 * `?:`, where a nested ternary re-parses to the tree it already had; a fail-closed whitelist
 * of one kind, gated only on the SEPARATOR-greedy tail.
 *
 * The four PRECEDENCE-GATED slots that prove the drop from the content's ROOT kind —
 * `TernaryCondition`, `SameFamilyLeft`, `ComparisonOperand`, `AdditiveOperand` —
 * additionally refuse content ending in a `RefShape.rightGreedyExprKinds` construct, and the two whitelist
 * ones refuse content whose leftmost token is a `RefShape.unaryMinusKinds`. `dropsParens` switches over this
 * enum EXHAUSTIVELY, so a new member fails to compile until it states which of those it
 * wants.
 */
private enum abstract SlotKind(Int) {

	final Plain = 0;

	final Delimited = 1;

	final DelimitedSplice = 2;

	final TernaryCondition = 3;

	final SameFamilyLeft = 4;

	final Required = 5;

	final ComparisonOperand = 6;

	final AdditiveOperand = 7;

	final TernaryElse = 8;

}
