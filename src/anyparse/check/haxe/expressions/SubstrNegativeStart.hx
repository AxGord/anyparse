package anyparse.check.haxe.expressions;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.NoAutofix;
import anyparse.check.scan.OrderGuards;
import anyparse.check.scan.RunScan;
import anyparse.query.IndexScope;
import anyparse.query.StdlibPurity;
import anyparse.query.SymbolIndex;
import anyparse.query.TypingService;

/**
 * Flags a `substr` call whose start is a subtraction — an index that goes negative once the subtrahend outgrows the
 * minuend — since `substr` counts a negative start back from the END of the string and returns a window there instead of
 * failing or clamping (`'0123456789'.substr(3 - 6, 2)` is `78`). The subtraction kind is the grammar's
 * (`ExecutionShape.integerFoldOperators`).
 *
 * A start the enclosing conditions prove non-negative is left alone (`s.length > k ? s.substr(s.length - k) : s`, a
 * `&&` / `||` length test, an exiting `if` before the call, a `for` range bound) — `OrderGuards` reads those bounds.
 */
@:nullSafety(Strict)
final class SubstrNegativeStart extends HaxeRule implements NoAutofix {

	private static inline final RULE_ID: String = 'substr-negative-start';

	/** The method whose negative start counts from the end; `substring` clamps one to 0 instead. */
	private static inline final METHOD: String = 'substr';

	/** The string length member a last-character start subtracts one from. */
	private static inline final LENGTH: String = 'length';

	public function new() {
		super(
			RULE_ID, 'a substr call whose start is a subtraction, which counts from the end of the string once it goes negative',
			RuleCategory.Expressions
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final subtractKinds: Array<String> = [
			for (kind => op in shape.execution?.integerFoldOperators ?? []) if (op == 'subtract') kind
		];
		final guards: OrderSeams = OrderGuards.seamsOf(shape);
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		final text: Null<String> = TypingService.stringType(shape);
		return callKind == null || fieldAccessKind == null || subtractKinds.length == 0
			? []
			: RunScan.collect(files, plugin, (entry, tree, out) -> {
				final path: Array<QueryNode> = [];
				var ctx: Null<OrderContext> = null;
				function proved(start: QueryNode, call: QueryNode): Bool {
					final c: OrderContext = ctx ?? OrderGuards.contextOf(
						tree, entry.source, guards, effectsOf(entry, tree, plugin, index, text)
					);
					ctx = c;
					return OrderGuards.provesNonNegative(start, path.concat([call]), c);
				}
				function walk(node: QueryNode): Void {
					if (node.kind == callKind && node.children.length >= 2) {
						final callee: QueryNode = node.children[0];
						final start: QueryNode = node.children[1];
						final span: Null<Span> = start.span;
						if (
							span != null
							&& callee.kind == fieldAccessKind
							&& callee.name == METHOD
							&& subtractKinds.contains(start.kind)
							&& !lastCharacterStart(start, callee, fieldAccessKind, entry.source)
							&& !proved(start, node)
						) out.push({
							file: entry.file,
							span: span,
							rule: RULE_ID,
							severity: Severity.Warning,
							message: 'substr counts a negative start from the end of the string: guard this start, or use substring'
						});
					}
					path.push(node);
					for (c in node.children) walk(c);
					path.pop();
				}
				walk(tree);
			});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'substring clamps a negative start to 0 but takes an end index where substr takes a length, and a guard keeps'
			+ ' substr: which repair is right depends on what the call meant';
	}

	/**
	 * Whether `start` is the receiver's own `length - 1`: it goes negative only on an empty string, where `substr(-1)`
	 * returns the empty string a clamped start would, so the last-character idiom is safe without a guard.
	 */
	private static function lastCharacterStart(start: QueryNode, callee: QueryNode, fieldAccessKind: Null<String>, source: String): Bool {
		final minuend: Null<QueryNode> = start.children[0];
		final subtrahend: Null<QueryNode> = start.children[1];
		final receiver: Null<QueryNode> = callee.children[0];
		return minuend != null
			&& subtrahend != null
			&& receiver != null
			&& minuend.kind == fieldAccessKind
			&& minuend.name == LENGTH
			&& minuend.children.length == 1
			&& textOf(subtrahend, source) == '1'
			&& textOf(minuend.children[0], source) == textOf(receiver, source);
	}

	/** `node`'s source text, or empty when it has no span. */
	private static function textOf(node: QueryNode, source: String): String {
		final span: Null<Span> = node.span;
		return span == null ? '' : source.substring(span.from, span.to);
	}

	/**
	 * What the typing knows of a file's calls: an effect-free std callee (`StdlibPurity`), and a `String` receiver, a value no
	 * call changes in place, so `s.length` of a local `s` keeps its bound across a call.
	 */
	private static function effectsOf(
		entry: { file: String, source: String }, tree: QueryNode, plugin: GrammarPlugin, index: () -> Null<SymbolIndex>, text: Null<String>
	): CallEffects {
		final shape: RefShape = plugin.refShape();
		var declared: Null<Map<Int, String>> = null;
		var typeOf: Null<(QueryNode) -> Null<String>> = null;
		return {
			effectFree: call -> {
				final idx: Null<SymbolIndex> = index();
				final types: Map<Int, String> = declared ?? RunScan.typeInfoOf(plugin)?.declaredTypes(entry.source) ?? [];
				declared = types;
				idx != null && call.kind == shape.callKind && StdlibPurity.isEffectFreeCallee(call, tree, shape, types, idx);
			},
			immutable: receiver -> {
				final read: Null<(QueryNode) -> Null<String>> = typeOf ?? CheckScan.typeNominalResolver(
					entry.source, plugin, tree, entry.file, index()
				);
				typeOf = read;
				text != null && read != null && read(receiver) == text;
			}
		};
	}

}
