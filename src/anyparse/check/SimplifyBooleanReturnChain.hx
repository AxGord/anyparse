package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a boolean guard chain — two or more contiguous `if (cond) return true;` /
 * `if (cond) return false;` guards (no `else`) closed by a final `return true;` /
 * `return false;` — and rewrites it to one flat boolean `return` (`a || b`,
 * `!a && !b`, `a || !b`, ...). `Severity.Info` with an autofix.
 *
 * ## Why a dedicated check rather than the ternary path
 *
 * `prefer-ternary-return` collapses such a chain into a nested ternary
 * `a ? true : b ? true : false`, which `simplify-boolean-ternary` would reduce to
 * `a || b` — but only when each operand is provably non-null `Bool`. When a guard
 * condition is a `Call` / `switch` (no typer to prove non-nullness) the ternary
 * gets stuck half-reduced and ugly. This check reduces on the GUARD form instead,
 * where every condition is an `if` condition — non-null `Bool` under
 * `@:nullSafety(Strict)` by construction (the source compiles) — so the reduction
 * is sound and the stuck ternary never forms. It is registered before
 * `prefer-ternary-return`, so on a shared chain its edit wins and prefer-ternary's
 * overlapping edit is deferred (and then finds nothing to do).
 *
 * ## Grammar-agnostic
 *
 * Blocks come from `ControlFlowSupport.blockKinds`; the `if` / `return` / boolean
 * literal kinds from `RefShape.ifStatementKinds` / `returnStatementKind` /
 * `boolLitKind`; the De Morgan / precedence rewrite from
 * `BooleanLogicSupport.reduceBooleanGuardChain` (which refuses a degenerate chain
 * that would drop a condition's evaluation). Any unset seam makes the check a no-op.
 */
@:nullSafety(Strict)
final class SimplifyBooleanReturnChain implements Check {

	public function new() {}

	public function id(): String {
		return 'simplify-boolean-return-chain';
	}

	public function description(): String {
		return 'a boolean guard chain reducible to a single boolean return';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final ctx: Null<Ctx> = context(plugin);
		if (ctx == null) return [];
		final c: Ctx = ctx;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			for (chain in collectChains(tree, c)) if (reducible(chain, entry.source, c)) violations.push({
				file: entry.file,
				span: chain.span,
				rule: 'simplify-boolean-return-chain',
				severity: Severity.Info,
				message: 'this boolean guard chain can be a single boolean return'
			});
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final ctx: Null<Ctx> = context(plugin);
		if (ctx == null) return [];
		final c: Ctx = ctx;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];
		final bySpan: Map<String, Chain> = [];
		for (chain in collectChains(tree, c)) bySpan['${chain.span.from}:${chain.span.to}'] = chain;
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final chain: Null<Chain> = bySpan['${span.from}:${span.to}'];
			if (chain == null) continue;
			final expr: Null<String> = c.support.reduceBooleanGuardChain(chain.conds, chain.lits, chain.finalLit, source);
			if (expr != null) edits.push({ span: span, text: 'return $expr;' });
		}
		return edits;
	}

	/** Whether the seam can reduce `chain` without dropping a condition's evaluation. */
	private static function reducible(chain: Chain, source: String, c: Ctx): Bool {
		return c.support.reduceBooleanGuardChain(chain.conds, chain.lits, chain.finalLit, source) != null;
	}

	/** Bundle the seams + kinds the check needs, or null when the grammar lacks any of them. */
	private static function context(plugin: GrammarPlugin): Null<Ctx> {
		final shape: RefShape = plugin.refShape();
		final support: Null<BooleanLogicSupport> = plugin.booleanLogicSupport();
		final cf: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final returnKind: Null<String> = shape.returnStatementKind;
		final boolLitKind: Null<String> = shape.boolLitKind;
		if (support == null || cf == null || ifKinds.length == 0 || returnKind == null || boolLitKind == null) return null;
		final s: BooleanLogicSupport = support;
		final ctrl: ControlFlowSupport = cf;
		final rk: String = returnKind;
		final bk: String = boolLitKind;
		return {
			support: s,
			blockKinds: ctrl.blockKinds(),
			ifKinds: ifKinds,
			returnKind: rk,
			boolLitKind: bk
		};
	}

	/** Every boolean guard chain (>= 2 guards closed by a boolean return) in `node`, recursively. */
	private static function collectChains(node: QueryNode, c: Ctx): Array<Chain> {
		final out: Array<Chain> = [];
		walk(out, node, c);
		return out;
	}

	private static function walk(out: Array<Chain>, node: QueryNode, c: Ctx): Void {
		if (c.blockKinds.contains(node.kind)) findChainsInBlock(out, node, c);
		for (child in node.children) walk(out, child, c);
	}

	/** Scan `block`'s direct children for maximal `if-return` guard runs closed by a boolean return. */
	private static function findChainsInBlock(out: Array<Chain>, block: QueryNode, c: Ctx): Void {
		final kids: Array<QueryNode> = block.children;
		var i: Int = 0;
		while (i < kids.length) {
			var j: Int = i;
			while (j < kids.length && isGuard(kids[j], c)) j++;
			final guardCount: Int = j - i;
			if (guardCount >= 2 && j < kids.length && isBoolReturn(kids[j], c)) {
				final chain: Null<Chain> = makeChain(kids, i, j, c);
				if (chain != null) out.push(chain);
				i = j + 1;
			} else {
				i = guardCount > 0 ? j : i + 1;
			}
		}
	}

	/** A `Chain` over the `kids[i...j]` guards + the closing return `kids[j]`, or null if a span or a guard's bool return is missing. */
	private static function makeChain(kids: Array<QueryNode>, i: Int, j: Int, c: Ctx): Null<Chain> {
		final firstSpan: Null<Span> = kids[i].span;
		final lastSpan: Null<Span> = kids[j].span;
		if (firstSpan == null || lastSpan == null) return null;
		final conds: Array<QueryNode> = [for (k in i ... j) kids[k].children[0]];
		final lits: Array<QueryNode> = [];
		for (k in i ... j) {
			final ret: Null<QueryNode> = boolReturnOf(kids[k].children[1], c);
			if (ret == null) return null;
			lits.push(ret.children[0]);
		}
		return {
			span: new Span(firstSpan.from, lastSpan.to),
			conds: conds,
			lits: lits,
			finalLit: kids[j].children[0]
		};
	}

	/** `if (cond) return <bool>;` with no `else` — the bool return bare, or wrapped in a single-statement block (`{ return true; }`). */
	private static function isGuard(node: QueryNode, c: Ctx): Bool {
		return c.ifKinds.contains(node.kind) && node.children.length == 2 && boolReturnOf(node.children[1], c) != null;
	}

	/** `return <bool-literal>;` — the chain's return kind with a single boolean-literal child. */
	private static function isBoolReturn(node: QueryNode, c: Ctx): Bool {
		return node.kind == c.returnKind && node.children.length == 1 && node.children[0].kind == c.boolLitKind;
	}

	/**
	 * The `return <bool>;` a guard then-body resolves to: the bare return, or the
	 * sole statement of a single-statement block (`{ return true; }`); else null.
	 * The single-statement requirement keeps the reduction sound — a block with any
	 * other statement carries an evaluation that flattening the chain would drop.
	 */
	private static function boolReturnOf(node: QueryNode, c: Ctx): Null<QueryNode> {
		return isBoolReturn(node, c)
			? node
			: c.blockKinds.contains(node.kind) && node.children.length == 1 && isBoolReturn(node.children[0], c) ? node.children[0] : null;
	}

}

private typedef Ctx = {
	support: BooleanLogicSupport,
	blockKinds: Array<String>,
	ifKinds: Array<String>,
	returnKind: String,
	boolLitKind: String
};

private typedef Chain = {
	span: Span,
	conds: Array<QueryNode>,
	lits: Array<QueryNode>,
	finalLit: QueryNode
};
