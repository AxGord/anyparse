package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.SwitchChain.ChainSeams;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a VALUE-position conditional chain that tests one or more expressions
 * against constants — a right-nested ternary `a == P ? v1 : a == Q ? v2 : v3`, or
 * the same shape written as an if-EXPRESSION — which reads more clearly as a
 * `switch` expression. `Info`: the code is correct, this is a readability
 * suggestion. `--fix` rewrites the chain to `switch … { case …: …; }` in place,
 * leaving the enclosing `return` / initializer / assignment untouched.
 *
 * The statement-position sibling is `prefer-switch`. The two match DISJOINT node
 * kinds — an `if` statement there, a ternary / if-expression here — so no site is
 * ever reported by both. The split follows the family precedent of
 * `prefer-ternary-*` vs `prefer-if-expression-*`: shape and position decide the
 * rule, because they decide what the rewrite may emit.
 *
 * ## What is flagged
 *
 * The HEAD of a chain of `ternaryKind` / `ifExpressionKinds` nodes — one not
 * reached as another chain node's else-slot, so an inner rung is never
 * re-reported — that additionally satisfies:
 *
 * 1. **A whitelisted host.** The head's PARENT kind must be in
 *    `switchExpressionHostKinds` (a `return`, a local / member initializer, an
 *    assignment r-value). A chain in any other expression position — a call
 *    argument, an operand of a larger expression — is left alone: the switch would
 *    parse there but reads worse than the ternary it replaced, and a fixer that
 *    makes a real site worse needs a narrower precondition, not a caveat.
 * 2. **A trailing else-slot value**, rendered as `case _`. A switch EXPRESSION has
 *    to produce a value on every path, so a chain without one (an `if` expression
 *    with no `else`) could not be converted anyway. `SwitchChain` gate 7 requires
 *    the else-slot of EVERY chain, statement or value, so this rule contributes no
 *    policy of its own here — value position merely makes the requirement doubly
 *    obvious, `var x = switch (n) { case 1: 'a'; case 2: 'b'; }` over an `Int`
 *    being `Unmatched patterns: _` (verified on 4.3.7) where the same
 *    wildcard-less switch in STATEMENT position compiles.
 * 3. **Everything `SwitchChain` requires** — at least two rungs, each condition a
 *    conjunction of equalities over the SAME call-free discriminant tuple, each
 *    constant a valid `case` pattern (a literal, or a qualified static the
 *    `SymbolIndex` proves constant). The full gate catalogue with the reason for
 *    each gate, and the two documented behaviour deltas a converted chain carries,
 *    live on `SwitchChain`; this rule contributes the chain kinds, the host gate
 *    and the report.
 *
 * ## Autofix
 *
 * `--fix` replaces the chain's span — and only that span — with
 * `switch (D) { case P: V; … case _: E }`, or `switch [D1, D2] { case [P1, P2]: V; … }`
 * for a tuple of discriminants. Branch values are taken verbatim and terminated
 * with `;`, being bare expressions rather than statements. The result is re-parsed
 * and reformatted by the canonical pipeline. A chain carrying a comment is
 * report-only: the comment lives in trivia the verbatim rebuild would drop.
 *
 * The cross-file constant proof needs a `SymbolIndex`. `lint --fix` hands one in;
 * a direct `fix` call without one falls back to a single-file index, under which a
 * constant declared in ANOTHER file is unresolvable and the chain stays
 * report-only — the conservative direction.
 *
 * ## Grammar-agnostic
 *
 * Contributes `ternaryKind` + `ifExpressionKinds` as the chain kinds and
 * `switchExpressionHostKinds` as the host gate, and reads every other seam through
 * `SwitchChain.seamsOf`. The check no-ops when `switchExpressionHostKinds` is
 * empty, and when `ternaryKind` AND `ifExpressionKinds` are BOTH unset — an empty
 * `ifExpressionKinds` alone still converts ternaries. No language-specific kind is
 * named here.
 */
@:nullSafety(Strict)
final class PreferSwitchExpression implements Check {

	/**
	 * A branch value of an expression chain is a bare expression, so each rendered `case`
	 * body needs its own terminator — unlike the statement rule, whose bodies already
	 * carry one.
	 */
	private static inline final BODY_TERMINATOR: String = ';';

	public function new() {}

	public function id(): String {
		return 'prefer-switch-expression';
	}

	public function description(): String {
		return
			'a value-position ternary / if-expression chain testing one or more expressions against constants — clearer as a switch expression';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final config: Null<Config> = configOf(plugin);
		return config == null
			? []
			: SwitchChain.violationsOf(files, plugin, config.seams, hostAccepts.bind(config.hosts), id(), messageFor);
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final config: Null<Config> = configOf(plugin);
		return config == null ? [] : SwitchChain.editsOf(source, violations, plugin, config.seams, hostAccepts.bind(config.hosts), index);
	}

	/**
	 * Whether THIS rule claims the chain at `head`, whose parent kind is `parentKind` — both
	 * its host gate and every `SwitchChain` gate pass. The deferral seam
	 * `prefer-if-expression-chain` asks before converting a chain of its own, so one site is
	 * never reported by both: the switch rewrite wins wherever it applies, and the if-chain
	 * rewrite takes the rest (including every equality-shaped chain in a host this rule's
	 * narrower whitelist does not accept).
	 *
	 * `resolveIndex` must be the resolver THIS rule would have used — `SwitchChain.lazyIndexOf`
	 * over the same file set. A weaker one leaves a qualified-static constant unprovable, and
	 * an under-reported claim is exactly the direction that double-claims.
	 */
	public static function claims(
		source: String, head: QueryNode, parentKind: Null<String>, plugin: GrammarPlugin, resolveIndex: () -> Null<SymbolIndex>
	): Bool {
		final config: Null<Config> = configOf(plugin);
		if (config == null || !hostAccepts(config.hosts, parentKind)) return false;
		return SwitchChain.claims(source, head, config.seams, resolveIndex);
	}

	/**
	 * This rule's chain configuration — the value-position chain kinds and `;`-terminated
	 * bodies — paired with the host kinds its head gate whitelists. Null
	 * when the grammar declares no host kind or `SwitchChain` finds a required seam unset,
	 * either of which makes the check a no-op.
	 */
	private static function configOf(plugin: GrammarPlugin): Null<Config> {
		final shape: RefShape = plugin.refShape();
		final hostKinds: Array<String> = shape.switchExpressionHostKinds ?? [];
		if (hostKinds.length == 0) return null;
		final kinds: Array<String> = (shape.ifExpressionKinds ?? []).copy();
		final ternary: Null<String> = shape.ternaryKind;
		if (ternary != null && !kinds.contains(ternary)) kinds.push(ternary);
		final seams: Null<ChainSeams> = SwitchChain.seamsOf(plugin, kinds, BODY_TERMINATOR);
		return seams == null ? null : { seams: seams, hosts: hostKinds };
	}

	/** Whether `parentKind` is one of the positions a switch expression may be spliced into (null = the tree root). */
	private static function hostAccepts(hostKinds: Array<String>, parentKind: Null<String>): Bool {
		return parentKind != null && hostKinds.contains(parentKind);
	}

	/** The finding text for a chain over `subject`. */
	private static function messageFor(subject: String): String {
		return 'conditional chain testing `$subject` against constants — clearer as a switch expression';
	}

}

/** `PreferSwitchExpression`'s resolved configuration: the chain seams and the host kinds its head gate whitelists. */
private typedef Config = {
	final seams: ChainSeams;
	final hosts: Array<String>;
}
