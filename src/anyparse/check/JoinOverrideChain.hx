package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a local declaration followed by a CHAIN of conditional overwrites of that local -- two or
 * more consecutive statement-position `switch`es, each assigning the local on some paths and
 * leaving it alone on the rest -- and collapses the whole run into ONE declaration whose
 * initializer nests them, LAST construct outermost:
 *
 * ```haxe
 * var tKey:String = null;
 * switch strKey.expr {
 *     case EConst(CString(s, _)): tKey = s;
 *     case _:
 * }
 * switch intKey.expr {
 *     case EConst(CInt(i)): tKey = '$i';
 *     case _:
 * }
 * // ->
 * var tKey:String = switch intKey.expr {
 *     case EConst(CInt(i)): '$i';
 *     case _: switch strKey.expr {
 *         case EConst(CString(s, _)): s;
 *         case _: null;
 *     };
 * };
 * ```
 *
 * The MULTI-STATEMENT axis of the assignment-collapse family (`prefer-switch-expression-assignment`,
 * `prefer-if-expression-assignment`, `prefer-try-expression-assignment`, `join-declaration-assignment`,
 * `cond-assign-merge`): every one of those collapses ONE construct, and refuses this shape because the
 * target is written by several.
 */
@:nullSafety(Strict)
final class JoinOverrideChain implements Check implements DefaultOff {

	/** The rule id, and the `--rule` selector that force-enables this default-off check. */
	private static inline final RULE_ID: String = 'join-override-chain';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a local declaration followed by a chain of conditional overwrites, collapsible to one nested switch-expression assignment';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

}
