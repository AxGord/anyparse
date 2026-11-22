package anyparse.check.haxe.expressions;

import anyparse.check.Check.NoAutofix;
import anyparse.query.SymbolIndex;

/**
 * Flags a call to a local `inline function` whose body holds an object literal, when the call sits in the right operand
 * of a short-circuit `||` / `&&`: the Haxe JVM backend expands it there into an invalid stack map (a `VerifyError`
 * at class load), while js compiles it fine, so only a jvm build shows it. The function is matched by name within the
 * enclosing function; the literal is the grammar's `RefShape.objectLiteralKind`.
 */
@:nullSafety(Strict)
final class JvmShortCircuitInlineLocalFn extends HaxeRule implements NoAutofix {

	public static inline final RULE_ID: String = 'jvm-short-circuit-inline-local-fn';

	public function new() {
		super(
			RULE_ID,
			'a call to a local inline function with an object literal in a short-circuit operand, which the jvm target miscompiles',
			RuleCategory.Expressions
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final literalKind: Null<String> = shape.objectLiteralKind;
		final callKind: Null<String> = shape.callKind;
		final inlineKinds: Array<String> = shape.inlineFunctionKinds ?? [];
		final shortCircuit: Array<String> = [ for (kind in [shape.logicalAndKind, shape.logicalOrKind]) if (kind != null) kind ];
		return callKind == null || literalKind == null || inlineKinds.length == 0 || shortCircuit.length == 0
			? []
			: RunScan.collect(files, plugin, (entry, tree, out) -> {
				new InlineCallWalk(shape, callKind, literalKind, inlineKinds, shortCircuit, entry.file, out).walk(tree, false);
			});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'the call has to be bound to a local before the condition, and which statement it joins depends on the surrounding flow';
	}

}
