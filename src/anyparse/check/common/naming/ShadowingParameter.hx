package anyparse.check.common.naming;

import anyparse.check.Check.DefaultOff;
import anyparse.query.SymbolIndex;

/**
 * Flags a function PARAMETER whose name is already bound — by an enclosing local, a loop or
 * catch binder, a local function, or an enclosing parameter — at the point it takes effect.
 * `Warning` and `DefaultOff`; its fix is `shadowing-local`'s rename (`ShadowingLocal.fixWith`).
 *
 * ## The same trap one spelling over
 *
 * `shadowing-local` names the mistake: one name, two bindings, and a write meant for the outer
 * one silently lands on the inner. A nested function's PARAMETER hides an enclosing binding
 * exactly the same way, and until this rule existed every spelling of it was silent —
 * `q -> …`, `(q) -> …`, `function(q) …`, `function nm(q) …`, `inline function li(q) …` — while
 * the block form one line below was reported. The parameter was only ever the OUTER side of
 * `shadowing-local`'s question, never the inner.
 *
 * ```haxe
 * var q:Int = 1;
 * final doubled = xs.map(q -> q * 2);   // the outer q is invisible in here
 * ```
 *
 * ## Why it is a SEPARATE rule
 *
 * Because it is not the question `shadowing-local` advertises. That rule's own doc says "a LOCAL
 * declaration whose name is already bound"; the parameter was always the OUTER side of it, never
 * the inner. Widening it in place would change what a project already opted into, and reusing a
 * lambda parameter name is common idiom. Shipping it under its own id, off by default, leaves both bars byte-identical and makes the wider
 * question opt-in (`"rules": { "shadowing-parameter": { "enabled": true } }`, or
 * `--rule shadowing-parameter`).
 *
 * The WALK is `ShadowingLocal.collect` — one ancestor-chain scan, one set of gates, one
 * definition of the outer side. Only the reported declaration family differs.
 *
 * ## What is not reported
 *
 * A parameter whose name starts with `_`, and a field of an anonymous STRUCTURE type — which the
 * Haxe grammar projects with the very kind a parameter uses, so `{ span: Span, text: String }`
 * as a return type would otherwise read as two bindings. Both gates and the numbers behind them
 * are on `ShadowingLocal.reportableParam`.
 *
 * A method's or module-level function's own parameters are never findings: the frame walk stops
 * at the first class-like container, so a parameter sharing a name with a FIELD is the ordinary
 * idiom, not a mistake — same rule, same reason, as for a local declaration.
 */
@:nullSafety(Strict)
final class ShadowingParameter extends RuleBase implements DefaultOff {

	/** The rule's stable identifier — the `apqlint.json` key and the `--rule` selector. */
	private static inline final RULE_ID: String = 'shadowing-parameter';

	public function new() {
		super(RULE_ID, 'a function parameter whose name is already bound by an enclosing local, binder or parameter', RuleCategory.Naming);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return ShadowingLocal.collect(files, plugin, true, RULE_ID);
	}

	/**
	 * The parameter takes its written type's lower-camel name — `(item:DiskSystemItemData) -> …` becomes
	 * `(diskSystemItemData:DiskSystemItemData) -> …` — through `Rename.rename`, refusing whatever it refuses; a
	 * parameter no written nominal type names (an untyped arrow parameter, `Null<Array<T>>`, `String`) stays reported.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return ShadowingLocal.fixWith(source, violations, plugin, true, RULE_ID);
	}

}
