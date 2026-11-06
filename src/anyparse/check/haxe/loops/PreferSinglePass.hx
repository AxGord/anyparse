package anyparse.check.haxe.loops;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.common.expressions.PreferBind;
import anyparse.check.scan.PurityScan;
import anyparse.check.scan.RunScan;
import anyparse.check.scan.ThrowFreeScan;
import anyparse.query.InlineMethod;
import anyparse.query.MemberKinds;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;

/**
 * Flags an `Array` method chain that one pass can do — `xs.filter(p).map(f)`, `xs.map(f).map(g)`, `xs.filter(p).filter(q)`
 * and `xs.map(f).filter(p)` — because each call builds an intermediate array and walks it again. `Severity.Info`.
 *
 * The rewrite merges the two lambdas, so it changes the order the bodies run in: all of `p` before any `f` becomes
 * interleaved. `--fix` therefore applies only where both bodies are lambdas of one plain binder, `PurityScan` proves both
 * pure, and the interleaving cannot change which exception surfaces — `ThrowFreeScan` proves one of them cannot throw
 * (for `map(f).map(g)` it must be `f`, since `g` may not read `f`'s result at all). A callee that is not such a lambda,
 * a body that is not pure and a comment between the pieces leave the finding report-only. `filter(p).map(f)` becomes
 * `[for (x in xs) if (p) f]`, `map(f).map(g)` becomes `xs.map(x -> g(f(x)))` with `g` reading `f`'s result exactly
 * once, and `filter(p).filter(q)` becomes `xs.filter(x -> p && q)`. `map(f).filter(p)` has no one-call spelling
 * (`f` would run twice), so it is always report-only; `[for (x in xs) { final y = f; if (p) y; }]` is the single pass.
 *
 * The innermost receiver must resolve to an `Array`. `RiskyFix`: a comprehension takes its element type from where it is
 * written, so the rewrite stands only where it compiles. `DefaultOff`: a style preference, opted in with
 * `"prefer-single-pass": { "enabled": true }`.
 */
@:nullSafety(Strict)
final class PreferSinglePass extends HaxeRule implements DefaultOff implements RiskyFix {

	private static inline final RULE_ID: String = 'prefer-single-pass';
	private static inline final FILTER: String = 'filter';
	private static inline final MAP: String = 'map';

	/** A call and its callee: `m(arg)` holds the callee and one argument. */
	private static inline final CALL_WITH_ONE_ARGUMENT: Int = 2;

	/** A lambda: its one parameter and its body. */
	private static inline final LAMBDA_CHILD_COUNT: Int = 2;

	public function new() {
		super(RULE_ID, 'an Array method chain (filter.map, map.map, filter.filter, map.filter) that one pass can do', RuleCategory.Loops);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: String -> Null<SymbolIndex> = PreferBind.coveringIndex(files, plugin);
		return RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, violations) -> {
			for (f in findings(tree, entry.file, entry.source, seams, plugin, index)) violations.push({
				file: entry.file,
				span: f.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: f.message
			});
		});
	}

	/** Merge each flagged chain whose bodies are proven safe to interleave; the rest stay report-only. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final file: String = violations.length == 0 ? '' : violations[0].file;
		final scope: String -> Null<SymbolIndex> = PreferBind.coveringIndex([{ file: file, source: source }], plugin, index);
		return CheckScan.applyTextMatches(plugin, source, violations, (tree, text) -> {
			final edits: Array<FixEdit> = [];
			for (f in findings(tree, file, text, seams, plugin, scope)) {
				final rewrite: Null<String> = f.text;
				final edit: Null<FixEdit> = rewrite == null ? null : { span: f.span, text: rewrite };
				if (edit != null) edits.push(edit);
			}
			return edits;
		});
	}

	/**
	 * Every chain under `tree` with its message and, where the merge is
	 * proven safe, its rewrite; a fixed chain's inside is the next pass.
	 */
	private static function findings(
		tree: QueryNode, file: String, source: String, seams: Seams, plugin: GrammarPlugin, index: String -> Null<SymbolIndex>
	): Array<Finding> {
		final out: Array<Finding> = [];
		var types: Null<(QueryNode) -> Null<String>> = null;
		var purity: Null<PurityCtx> = null;
		var built: Bool = false;
		function walk(node: QueryNode): Void {
			if (seams.opaqueKinds.contains(node.kind)) return;
			final head: Null<Chain> = chainAt(node, seams);
			if (head != null) {
				if (!built) {
					built = true;
					types = CheckScan.typeNominalResolver(source, plugin, tree, file, index(file), true);
					final symbols: Null<SymbolIndex> = index(file);
					purity = symbols == null ? null : PurityScan.contextOf(plugin, source, tree, symbols);
				}
				final resolve: Null<(QueryNode) -> Null<String>> = types;
				final type: Null<String> = resolve == null ? null : resolve(arrayBase(head.receiver, seams));
				if (type != null && seams.arrayTypeNames.contains(type)) {
					final text: Null<String> = merged(head, source, seams, purity);
					out.push({ span: head.span, message: message(head.pairing), text: text });
					if (text != null) return;
				}
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/** `recv.<first>(a).<second>(b)` read off a call node, or null when `node` is no such chain. */
	private static function chainAt(node: QueryNode, s: Seams): Null<Chain> {
		final span: Null<Span> = node.span;
		final outer: Null<QueryNode> = callee(node, s);
		final innerCall: Null<QueryNode> = outer?.children[0];
		final inner: Null<QueryNode> = innerCall == null ? null : callee(innerCall, s);
		if (span == null || outer == null || innerCall == null || inner == null) return null;
		final pairing: Null<Pairing> = pairingOf(inner.name, outer.name);
		final receiver: QueryNode = inner.children[0];
		final receiverSpan: Null<Span> = receiver.span;
		return pairing == null || receiverSpan == null ? null : {
			span: span,
			receiver: receiver,
			receiverSpan: receiverSpan,
			pairing: pairing,
			first: innerCall.children[1],
			second: node.children[1]
		};
	}

	/** The field access `call` invokes when it is `recv.name(one argument)`. */
	private static function callee(call: QueryNode, s: Seams): Null<QueryNode> {
		if (call.kind != s.callKind || call.children.length != CALL_WITH_ONE_ARGUMENT) return null;
		final access: QueryNode = call.children[0];
		return access.kind == s.fieldAccessKind && access.children.length == 1 ? access : null;
	}

	/** The receiver whose type decides `receiver`'s: `filter` and `map` of an `Array` are an `Array`, so the chain's base stands for it. */
	private static function arrayBase(receiver: QueryNode, s: Seams): QueryNode {
		final access: Null<QueryNode> = callee(receiver, s);
		return access == null || (access.name != FILTER && access.name != MAP) ? receiver : arrayBase(access.children[0], s);
	}

	private static function pairingOf(first: Null<String>, second: Null<String>): Null<Pairing> {
		return switch [first, second] {
			case [FILTER, MAP]: FilterMap;
			case [MAP, MAP]: MapMap;
			case [FILTER, FILTER]: FilterFilter;
			case [MAP, FILTER]: MapFilter;
			case _: null;
		}
	}

	private static function message(pairing: Pairing): String {
		return switch pairing {
			case FilterMap: 'this filter(…).map(…) walks the array twice — [for (x in xs) if (p) f] does it in one pass';
			case MapMap: 'this map(…).map(…) walks the array twice — one map(x -> g(f(x))) does it in one pass';
			case FilterFilter: 'this filter(…).filter(…) walks the array twice — one filter(x -> p && q) does it in one pass';
			case MapFilter:
				'this map(…).filter(…) walks the array twice — [for (x in xs) { final y = f; if (p) y; }] does it in one pass';
		}
	}

	/** The one-pass spelling of `c`, or null where the merge is not proven safe or has no one-call spelling. */
	private static function merged(c: Chain, source: String, s: Seams, purity: Null<PurityCtx>): Null<String> {
		final p: Null<Arrow> = lambdaOf(c.first, source, s);
		final q: Null<Arrow> = lambdaOf(c.second, source, s);
		if (purity == null || p == null || q == null || c.pairing == MapFilter) return null;
		if (!gapsHoldNoComment(c, p, q, source) || !interleavesSafely(c.pairing, p, q, purity, s)) return null;
		final shape: RefShape = s.shape;
		final receiver: String = source.substring(c.receiverSpan.from, c.receiverSpan.to);
		final firstText: String = source.substring(p.bodySpan.from, p.bodySpan.to);
		final renamed: Null<String> = InlineMethod.substituteTexts(source, q.body, [q.binder], [p.binder], shape);
		if (renamed == null) return null;
		return switch c.pairing {
			case FilterMap: '[for (${p.binder} in $receiver) if ($firstText) $renamed]';
			case MapMap:
				final roots: Array<String> = MemberKinds.parenFreeRootKinds(shape);
				final through: Null<String> = InlineMethod.countIdentExprNamed(q.body, q.binder, shape) == 1
					? InlineMethod.substituteTexts(source, q.body, [q.binder], [InlineMethod.argText(source, p.body, roots)], shape)
					: null;
				through == null ? null : '$receiver.map(${p.binder} -> $through)';
			case FilterFilter:
				final andText: Null<String> = s.andText;
				andText == null
					? null
					: '$receiver.filter(${p.binder} -> ${wrap(firstText, p.body, s)} $andText ${wrap(renamed, q.body, s)})';
			case MapFilter: null;
		}
	}

	/**
	 * Whether running the two bodies interleaved is the same as one after the other: both pure, neither able to be captured
	 * by the other's binder, and at most one of them able to throw — so the same exception surfaces first.
	 */
	private static function interleavesSafely(pairing: Pairing, p: Arrow, q: Arrow, purity: PurityCtx, s: Seams): Bool {
		if (!PurityScan.isPure(p.body, purity) || !PurityScan.isPure(q.body, purity)) return false;
		final firstCannotThrow: Bool = ThrowFreeScan.isThrowFree(p.body, purity);
		// `g` may sit under a short circuit of its own, so `f` must be the one that cannot throw.
		final throwSafe: Bool = pairing == MapMap ? firstCannotThrow : firstCannotThrow || ThrowFreeScan.isThrowFree(q.body, purity);
		// Both bodies end up under `p`'s binder: a read of that name in `q` would be captured by it.
		return throwSafe && (p.binder == q.binder || InlineMethod.countIdentExprNamed(q.body, p.binder, s.shape) == 0);
	}

	/** `x -> body` read off a lambda node: one plain parameter and an expression body. */
	private static function lambdaOf(node: QueryNode, source: String, s: Seams): Null<Arrow> {
		if (!s.lambdaKinds.contains(node.kind) || node.children.length != LAMBDA_CHILD_COUNT) return null;
		final param: QueryNode = node.children[0];
		final body: QueryNode = node.children[1];
		final binder: Null<String> = param.name;
		final bodySpan: Null<Span> = body.span;
		final plain: Bool = s.paramKinds.contains(param.kind) && param.kind != s.optionalParamKind && param.kind != s.restParamKind;
		// A typed, defaulted or optional parameter has more text than its name, and the merged lambda would drop it.
		final bare: Bool = SourceText.nodeText(param, source) == binder;
		return !plain || !bare || binder == null || bodySpan == null ? null : {
			binder: binder,
			body: body,
			bodySpan: bodySpan
		};
	}

	/** The operand text, parenthesised when its root binds looser than the `&&` it joins. */
	private static function wrap(text: String, operand: QueryNode, s: Seams): String {
		return s.andLowerKinds.contains(operand.kind) ? '($text)' : text;
	}

	/** Whether the text the rewrite drops around the receiver and the two bodies holds no comment. */
	private static function gapsHoldNoComment(c: Chain, p: Arrow, q: Arrow, source: String): Bool {
		return !CheckScan.hasCommentMarker(source, c.span.from, c.receiverSpan.from)
			&& !CheckScan.hasCommentMarker(source, c.receiverSpan.to, p.bodySpan.from)
			&& !CheckScan.hasCommentMarker(source, p.bodySpan.to, q.bodySpan.from)
			&& !CheckScan.hasCommentMarker(source, q.bodySpan.to, c.span.to);
	}

	/** The seams the rule reads, or null when one it cannot do without is unset. */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final arrayTypes: Null<Array<String>> = shape.arrayTypeNames;
		final lambdaKinds: Null<Array<String>> = shape.lambdaKinds;
		final paramKinds: Null<Array<String>> = shape.paramKinds;
		return callKind == null || fieldAccessKind == null || arrayTypes == null || lambdaKinds == null || paramKinds == null ? null : {
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			arrayTypeNames: arrayTypes,
			lambdaKinds: lambdaKinds,
			paramKinds: paramKinds,
			optionalParamKind: shape.optionalParamKind,
			restParamKind: shape.restParamKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			andText: shape.andOperatorText,
			andLowerKinds: shape.andLowerPrecedenceKinds ?? [],
			shape: shape
		};
	}

}

private enum Pairing {
	FilterMap;
	MapMap;
	FilterFilter;
	MapFilter;
}

/** `receiver.<first>(first).<second>(second)` spanning `span`. */
private typedef Chain = {
	final span: Span;
	final receiver: QueryNode;
	final receiverSpan: Span;
	final pairing: Pairing;
	final first: QueryNode;
	final second: QueryNode;
}

/** A lambda of one plain parameter and an expression body. */
private typedef Arrow = {
	final binder: String;
	final body: QueryNode;
	final bodySpan: Span;
}

private typedef Finding = {
	final span: Span;
	final message: String;
	final text: Null<String>;
}

private typedef Seams = {
	final callKind: String;
	final fieldAccessKind: String;
	final arrayTypeNames: Array<String>;
	final lambdaKinds: Array<String>;
	final paramKinds: Array<String>;
	final optionalParamKind: Null<String>;
	final restParamKind: Null<String>;
	final opaqueKinds: Array<String>;
	final andText: Null<String>;
	final andLowerKinds: Array<String>;
	final shape: RefShape;
}
