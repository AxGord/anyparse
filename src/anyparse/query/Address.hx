package anyparse.query;

import anyparse.query.Matcher.Match;
import anyparse.query.Pattern.KindEquivalence;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

import anyparse.query.Selector.SelectorSegment;

/**
 * The outcome of resolving one target address: the byte offset the op's
 * downstream resolver consumes, plus the resolved node when the mode yields
 * one (`--select` / `--match` always do; a position resolves the innermost
 * containing node as a best-effort extra).
 */
enum AddressResult {

	Ok(offset: Int, node: Null<QueryNode>);
	Err(message: String);

}

/**
 * One parsed set of address flags. Exactly one of the three modes must be
 * given; `nth` is a 1-based disambiguator valid with `select` / `match` only.
 */
typedef AddressSpec = {
	@:optional var at: String;
	@:optional var select: String;
	@:optional var match: String;
	@:optional var nth: Null<Int>;
}

/**
 * The shared target-address resolver of the mutation ops — one place that
 * turns any accepted address form into a byte offset (and node):
 *
 *  - **`<line>[:<col>]`** — a 1-based position. Column omitted → the first
 *    non-whitespace character of the line (line numbers come from lint /
 *    compiler output; the column is the fiddly part, so it is optional).
 *  - **`--select '<sel>'`** — a Selector v2 path (`Kind[:name]`, `>` direct
 *    child, `>>` any-depth descendant), kind-equivalence-aware.
 *  - **`--match '<pattern>'`** — an `apq search` structural pattern
 *    (`$x` metavars); the matched node is the target.
 *
 * `--select` / `--match` must resolve to exactly ONE node; several matches
 * need `--nth <k>` (1-based, document order) — the ambiguity error lists the
 * first candidates with their positions so the pick is one step away.
 * Addresses are edit-stable (a name / pattern survives edits above it), so
 * chains of ops need no re-locate step — prefer them over positions.
 */
@:nullSafety(Strict)
final class Address {

	/** How many candidates an ambiguity error lists before eliding the rest. */
	private static inline final CANDIDATE_LIMIT: Int = 5;

	private function new() {}

	/**
	 * Resolve `spec` against a parsed tree. Exactly one mode must be present;
	 * every failure is a user-facing `Err` the op prefixes with its own name.
	 */
	public static function resolve(tree: QueryNode, source: String, plugin: GrammarPlugin, spec: AddressSpec): AddressResult {
		final modes: Int = (spec.at != null ? 1 : 0) + (spec.select != null ? 1 : 0) + (spec.match != null ? 1 : 0);
		if (modes == 0) return Err("no target address — give <line>[:<col>], --select '<sel>', or --match '<pattern>'");
		if (modes > 1) return Err('give exactly one of <line>[:<col>] / --select / --match');
		if (spec.nth != null && spec.at != null) return Err('--nth applies to --select / --match only');
		final at: Null<String> = spec.at;
		if (at != null) return resolveAt(tree, source, at);
		final sel: Null<String> = spec.select;
		if (sel != null) return resolveSelect(tree, source, plugin, sel, spec.nth);
		final pattern: Null<String> = spec.match;
		return pattern != null ? resolveMatch(tree, source, plugin, pattern, spec.nth) : Err('no address mode');
	}

	/**
	 * The innermost ancestor-or-self of `node` matching `kind` (kind-equivalence
	 * aware) — the `--kind` LIFT for `--select` / `--match` addresses: a pattern
	 * matches the expression node (`addCase(x)` = the Call), while the edit often
	 * wants its statement (`--kind ExprStmt`). Null when no ancestor matches.
	 */
	public static function liftToKind(tree: QueryNode, node: QueryNode, kind: String, equiv: Null<KindEquivalence>): Null<QueryNode> {
		final path: Null<Array<QueryNode>> = pathTo(tree, node);
		if (path == null) return null;
		final seg: SelectorSegment = new SelectorSegment(kind, null);
		var i: Int = path.length - 1;
		while (i >= 0) {
			if (seg.matches(path[i], equiv)) return path[i];
			i--;
		}
		return null;
	}

	/**
	 * Byte offset of the node's NAME token within its span — the first
	 * word-boundary occurrence of `node.name` at-or-after `span.from` (a decl's
	 * name follows its keyword: `function NAME`, `var NAME`, `class NAME`). The
	 * cursor-based fn-ops resolve an identifier AT the cursor, so a named address
	 * must land on the name, not the leading keyword. Null for an unnamed node or
	 * a name its span does not contain.
	 */
	public static function nameTokenOffset(source: String, node: QueryNode): Null<Int> {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (name == null || span == null || name.length == 0) return null;
		final stop: Int = span.to < source.length ? span.to : source.length;
		var i: Int = span.from;
		while (i + name.length <= stop) {
			final at: Int = source.indexOf(name, i);
			if (at < 0 || at + name.length > stop) return null;
			final beforeOk: Bool = at == 0 || !isIdentChar(StringTools.fastCodeAt(source, at - 1));
			final afterIdx: Int = at + name.length;
			final afterOk: Bool = afterIdx >= source.length || !isIdentChar(StringTools.fastCodeAt(source, afterIdx));
			if (beforeOk && afterOk) return at;
			i = at + 1;
		}
		return null;
	}

	/**
	 * The canonical, edit-stable address of `node` — the SHORTEST selector that
	 * resolves to exactly it: the node's own `Kind[:name]` segment, prefixed with
	 * named ancestors (`>>`) one at a time until unique, and disambiguated with
	 * `--nth <k>` when names alone cannot tell instances apart. The follow-up op
	 * in a chain can use it verbatim instead of a position that the first edit
	 * may have shifted. Falls back to `<line>:<col>` for an unreachable node.
	 */
	public static function describe(tree: QueryNode, source: String, node: QueryNode, ?equiv: KindEquivalence): String {
		final path: Null<Array<QueryNode>> = pathTo(tree, node);
		final span: Null<Span> = node.span;
		final posFallback: String = if (span != null) {
			final pos: Position = span.lineCol(source);
			'${pos.line}:${pos.col}';
		} else
			'?:?';
		if (path == null) return posFallback;
		var selector: String = segmentOf(node);
		if (uniquelyResolves(tree, selector, node, equiv)) return selector;
		// Prepend the nearest named ancestors until the selector is unique.
		var i: Int = path.length - 2;
		while (i >= 0) {
			final ancestor: QueryNode = path[i];
			if (ancestor.name != null) {
				selector = segmentOf(ancestor) + ' >> ' + selector;
				if (uniquelyResolves(tree, selector, node, equiv)) return selector;
			}
			i--;
		}
		// Names cannot disambiguate — pick the instance ordinal.
		final matches: Array<QueryNode> = try Engine.select(tree, Selector.parse(selector), equiv) catch (exception: Exception) [];
		final k: Int = matches.indexOf(node);
		return k >= 0 ? '$selector --nth ${k + 1}' : posFallback;
	}

	/** A position `<line>[:<col>]`; a missing column snaps to the line's first non-whitespace character. */
	private static function resolveAt(tree: QueryNode, source: String, at: String): AddressResult {
		final colon: Int = at.indexOf(':');
		final lineText: String = colon >= 0 ? at.substring(0, colon) : at;
		final line: Null<Int> = Std.parseInt(lineText);
		if (line == null || line < 1 || '$line' != lineText.trim())
			return Err('malformed position "$at" — expected <line>[:<col>] (1-based)');
		if (colon >= 0) {
			final colText: String = at.substring(colon + 1);
			final col: Null<Int> = Std.parseInt(colText);
			if (col == null || col < 1 || '$col' != colText.trim())
				return Err('malformed position "$at" — expected <line>[:<col>] (1-based)');
			final offset: Int = Span.offsetOf(source, line, col);
			return Ok(offset, Engine.at(tree, offset));
		}
		var offset: Int = Span.offsetOf(source, line, 1);
		while (offset < source.length) {
			final c: Int = StringTools.fastCodeAt(source, offset);
			if (c == '\n'.code) return Err('line $line is blank — no element starts on it');
			if (c != ' '.code && c != '\t'.code && c != '\r'.code) break;
			offset++;
		}
		return offset >= source.length ? Err('line $line is past the end of the file') : Ok(offset, Engine.at(tree, offset));
	}

	/** A Selector v2 path — must resolve to exactly one node (or `nth` picks among several). */
	private static function resolveSelect(
		tree: QueryNode, source: String, plugin: GrammarPlugin, selectorExpr: String, nth: Null<Int>
	): AddressResult {
		final selector: Selector = try Selector.parse(selectorExpr) catch (exception: Exception) {
			return Err('malformed selector "$selectorExpr": ${exception.message}');
		};
		final equiv: Null<KindEquivalence> = plugin.selectKindEquivalence();
		final matches: Array<QueryNode> = Engine.select(tree, selector, equiv);
		return pick(matches.map(describeNode.bind(source)), matches, '--select "$selectorExpr"', nth);
	}

	/** An `apq search` pattern — the matched node is the target; same exactly-one / `nth` discipline. */
	private static function resolveMatch(
		tree: QueryNode, source: String, plugin: GrammarPlugin, patternSource: String, nth: Null<Int>
	): AddressResult {
		final pattern: Pattern = try plugin.parsePattern(patternSource) catch (exception: Exception) {
			return Err('malformed pattern "$patternSource": ${exception.message}');
		};
		final found: Array<Match> = Matcher.search(pattern, tree);
		final nodes: Array<QueryNode> = [];
		for (m in found) {
			final node: Null<QueryNode> = nodeAtSpan(tree, m.span);
			if (node != null && !nodes.contains(node)) nodes.push(node);
		}
		return pick(nodes.map(describeNode.bind(source)), nodes, '--match "$patternSource"', nth);
	}

	/** Apply the exactly-one / `nth` discipline to a candidate list; the ambiguity error lists positions ready for an `--nth` pick. */
	private static function pick(labels: Array<String>, nodes: Array<QueryNode>, what: String, nth: Null<Int>): AddressResult {
		if (nodes.length == 0) return Err('$what matched no nodes');
		if (nth != null) {
			return nth < 1 || nth > nodes.length
				? Err('--nth $nth out of range — $what matched ${nodes.length} node(s)')
				: toResult(nodes[nth - 1], what);
		}
		if (nodes.length > 1) {
			final shown: Int = nodes.length < CANDIDATE_LIMIT ? nodes.length : CANDIDATE_LIMIT;
			final lines: Array<String> = [for (i in 0...shown) '  #${i + 1} ${labels[i]}'];
			final more: String = nodes.length > shown ? '\n  … ${nodes.length - shown} more' : '';
			return Err('$what matched ${nodes.length} nodes — narrow it or pick one with --nth <k>:\n' + lines.join('\n') + more);
		}
		return toResult(nodes[0], what);
	}

	/** The chosen node as a result — its span start is the offset the ops consume. */
	private static function toResult(node: QueryNode, what: String): AddressResult {
		final span: Null<Span> = node.span;
		return span == null ? Err('$what resolved a node with no source span') : Ok(span.from, node);
	}

	/** One candidate line for the ambiguity listing: position + kind (+ name). */
	private static function describeNode(source: String, node: QueryNode): String {
		final span: Null<Span> = node.span;
		if (span == null) return '(no span) ${node.kind}';
		final pos: Position = span.lineCol(source);
		final name: Null<String> = node.name;
		return '${pos.line}:${pos.col} ${node.kind}' + (name != null ? ':$name' : '');
	}

	/** The first pre-order node whose span equals `span` exactly — a `Match.span` is always some input node's span. */
	private static function nodeAtSpan(tree: QueryNode, span: Span): Null<QueryNode> {
		final own: Null<Span> = tree.span;
		if (own != null && own.from == span.from && own.to == span.to) return tree;
		for (c in tree.children) {
			final hit: Null<QueryNode> = nodeAtSpan(c, span);
			if (hit != null) return hit;
		}
		return null;
	}

	/** Root-to-node path (inclusive), by reference identity; null when `node` is not in `tree`. */
	private static function pathTo(tree: QueryNode, node: QueryNode): Null<Array<QueryNode>> {
		if (tree == node) return [tree];
		for (c in tree.children) {
			final sub: Null<Array<QueryNode>> = pathTo(c, node);
			if (sub != null) {
				sub.unshift(tree);
				return sub;
			}
		}
		return null;
	}

	/** Identifier-character test for the name-token word-boundary scan. */
	private static inline function isIdentChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	/** One selector segment for a node: `Kind` or `Kind:name`. */
	private static function segmentOf(node: QueryNode): String {
		final name: Null<String> = node.name;
		return name != null ? '${node.kind}:$name' : node.kind;
	}

	/** Whether `selector` resolves to exactly `node` in `tree`. */
	private static function uniquelyResolves(tree: QueryNode, selector: String, node: QueryNode, equiv: Null<KindEquivalence>): Bool {
		final matches: Array<QueryNode> =
			try Engine.select(tree, Selector.parse(selector), equiv) catch (exception: Exception) return false;
		return matches.length == 1 && matches[0] == node;
	}

}
