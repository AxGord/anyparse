package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.SwitchChain.ChainSeams;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a STATEMENT-position `if` / `else if` chain that tests one or more
 * expressions against constant values — `if (x == 'a') … else if (x == 'b') …`,
 * or `if (a == P && b == Q) … else if (a == R && b == S) …` — which reads more
 * clearly as a `switch`. Structural apart from the cross-file constant proof, so
 * it holds without a type-checker; `Info` — the code is correct, this is a
 * readability suggestion. `--fix` rewrites the chain to a `switch`.
 *
 * ## What is flagged
 *
 * The HEAD of a chain of `ifStatementKinds` (an `if` not reached as another
 * `if`'s else-slot, so an inner `else if` rung is never re-reported) that
 * `SwitchChain` accepts: at least two rungs, every rung's condition a
 * conjunction of equalities over the SAME call-free discriminant tuple, every
 * constant a valid `case` pattern, and a trailing `else`. The full gate
 * catalogue, with the reason for each gate and the two documented behaviour
 * deltas, lives on `SwitchChain` — this rule contributes the chain kinds and the
 * report.
 *
 * VALUE-position chains are NOT matched here: a value-position `if`
 * (`var y = if (…) …`) and a ternary are different node kinds, and rewriting
 * them needs a switch EXPRESSION with different exhaustiveness rules. They are
 * `prefer-switch-expression`'s subject, and the two rules match disjoint kinds
 * so one site is never reported twice.
 *
 * ## Autofix
 *
 * `--fix` replaces the chain span with `switch (D) { case P1: B1; …; case _: E }`
 * — the discriminant, each rung's constant and its then-branch body taken
 * verbatim, and the trailing `else` body as `case _`. A chain with NO trailing
 * `else` is not flagged at all, and so is never converted: the wildcard-less
 * switch it would emit compiles only when the SUBJECT's type is one the compiler
 * does not enumerate, and no structural check can decide that. `SwitchChain`'s
 * gate 7 carries the reproduced miscompiles a waiver leaked — a `Bool` subject,
 * an enum-abstract subject, a name-shadowed built-in reached three different
 * ways, a `#if`-guarded `else` that never lands in the `if`'s else-slot — and
 * names the `OracleAssisted` / `RiskyFix` machinery as the only sound home for
 * restoring the conversion. Statement bodies already carry their own `;` / `{}`,
 * so no terminator is appended. The generated source is re-parsed and
 * reformatted by the canonical pipeline; a chain whose pieces resist a clean
 * rebuild, or one carrying a comment (whose trivia the verbatim-body rebuild
 * would drop), is report-only.
 *
 * ## Grammar-agnostic
 *
 * Contributes `ifStatementKinds` (unset → no-op) and reads everything else
 * through `SwitchChain.seamsOf`. No language-specific kinds are named here.
 */
@:nullSafety(Strict)
final class PreferSwitch implements Check {

	/**
	 * A statement branch body already carries its own `;` / `{}`, so nothing is appended
	 * after it — unlike the expression rule, whose bodies are bare values.
	 */
	private static inline final BODY_TERMINATOR: String = '';

	public function new() {}

	public function id(): String {
		return 'prefer-switch';
	}

	public function description(): String {
		return 'an if/else-if chain testing one or more expressions against constants — clearer as a switch';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<ChainSeams> = seamsOf(plugin);
		return seams == null ? [] : SwitchChain.violationsOf(files, plugin, seams, anyHost, id(), messageFor);
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<ChainSeams> = seamsOf(plugin);
		return seams == null ? [] : SwitchChain.editsOf(source, violations, plugin, seams, anyHost, index);
	}

	/** This rule's chain configuration: statement-position `if` kinds, bodies self-terminating. */
	private static function seamsOf(plugin: GrammarPlugin): Null<ChainSeams> {
		return SwitchChain.seamsOf(plugin, plugin.refShape().ifStatementKinds ?? [], BODY_TERMINATOR);
	}

	/** A statement chain reads well as a switch wherever it stands, so every host is accepted. */
	private static function anyHost(parentKind: Null<String>): Bool {
		return true;
	}

	/** The finding text for a chain over `subject`. */
	private static function messageFor(subject: String): String {
		return 'if/else-if chain testing `$subject` against constants — clearer as a switch';
	}

}
