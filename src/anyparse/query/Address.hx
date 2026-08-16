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
		final path: Null<Array<QueryNode>> = TreePath.pathTo(tree, node);
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
			final beforeOk: Bool = at == 0 || !isIdentChar(source.fastCodeAt(at - 1));
			final afterIdx: Int = at + name.length;
			final afterOk: Bool = afterIdx >= source.length || !isIdentChar(source.fastCodeAt(afterIdx));
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
		return describerFor(tree, equiv).describe(source, node);
	}

	/**
	 * An `AddressIndex` over `tree` — the reusable form of `describe` for a caller
	 * that addresses MANY nodes of the SAME tree (the JSON lint report asks for one
	 * address per finding). `describe` builds a throwaway index per call, so a single
	 * address pays for a whole-tree walk it cannot amortise; every address after the
	 * first is what the index is for.
	 * The index is bound to `tree`, so reuse stays explicit at the call site: a caller
	 * that re-parses must take a new one.
	 */
	public static function describerFor(tree: QueryNode, ?equiv: KindEquivalence): AddressIndex {
		return new AddressIndex(tree, equiv);
	}

	/** Identifier-character test for the name-token word-boundary scan. */
	private static inline function isIdentChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
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
			final c: Int = source.fastCodeAt(offset);
			if (c == '\n'.code) return Err('line $line is blank — no element starts on it');
			if (c != ' '.code && c != '\t'.code && c != '\r'.code) break;
			offset++;
		}
		if (offset >= source.length) return Err('line $line is past the end of the file');
		final target: Int = declAfterModifierPrefix(tree, source, offset);
		return Ok(target, Engine.at(tree, target));
	}

	/**
	 * The offset a BARE line number addresses, given the offset of the line's first non-whitespace
	 * character. A declaration's modifiers and metadata project as SIBLINGS before it, so that
	 * character is `public` / `static` / `@:meta` and `Engine.at` lands on the prefix, not on the
	 * declaration the line declares — every op then refuses a position copied straight out of lint or
	 * compiler output. Walk the prefix run onto the declaration, the same grouping `declGroupSpan`
	 * applies to structural edits. `<line>:<col>` keeps resolving exactly, so the prefix nodes stay
	 * addressable.
	 */
	private static function declAfterModifierPrefix(tree: QueryNode, source: String, offset: Int): Int {
		var at: Int = offset;
		var node: Null<QueryNode> = Engine.at(tree, at);
		while (node != null && RefactorSupport.isModifierOrMetaKind(node.kind)) {
			final span: Null<Span> = node.span;
			if (span == null) break;
			var next: Int = span.to;
			while (next < source.length && RefactorSupport.isSpace(source.fastCodeAt(next))) next++;
			if (next >= source.length || next <= at) break;
			final ahead: Null<QueryNode> = Engine.at(tree, next);
			// Only a node that STARTS here is the thing the line declares. Anything else means the walk
			// ran into trivia (a comment between the prefix and the declaration) and `Engine.at` answered
			// with the enclosing type — keep the prefix node rather than widen the address to a container.
			final aheadSpan: Null<Span> = ahead == null ? null : ahead.span;
			if (aheadSpan == null || aheadSpan.from != next) break;
			at = next;
			node = ahead;
		}
		return at;
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
		if (nodes.length <= 1) return toResult(nodes[0], what);
		final shown: Int = nodes.length < CANDIDATE_LIMIT ? nodes.length : CANDIDATE_LIMIT;
		final lines: Array<String> = [for (i in 0...shown) '  #${i + 1} ${labels[i]}'];
		final more: String = nodes.length > shown ? '\n  … ${nodes.length - shown} more' : '';
		return Err('$what matched ${nodes.length} nodes — narrow it or pick one with --nth <k>:\n' + lines.join('\n') + more);
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

}

/**
 * A pre-order index over ONE parsed tree, shared by every address derived from
 * it. `describe` probes the tree once per candidate selector, so a report that
 * addresses every finding of a file used to re-walk that file's tree thousands
 * of times — on a large source the annotation cost several times the analysis it
 * annotates. Here those probes are lookups instead: a segment's candidates come
 * from per-kind and per-kind-and-name groups already held in document order, and
 * "does this node sit inside that one" is a comparison of pre-order intervals
 * rather than another walk.
 *
 * The index keys on node IDENTITY, so it is bound to the tree it indexed and a
 * re-parse invalidates it. Reuse therefore stays explicit at the call site
 * rather than hiding behind a cache that cannot tell a stale tree from a fresh
 * one.
 */
@:nullSafety(Strict)
final class AddressIndex {

	/**
	 * Whether every spanned node sits inside its nearest spanned ancestor. That is
	 * the premise `nodeAt` prunes on, and it is a property of the tree rather than
	 * of the grammar, so it is measured while indexing instead of assumed: a tree
	 * that breaks it sends `nodeAt` back to `Engine.at`'s full walk, which makes the
	 * shortcut output-neutral on any tree rather than only on the ones checked.
	 *
	 * Readable because the two paths answer identically by design — so this flag is
	 * the ONLY observable of which one runs, and a grammar change that quietly
	 * un-nested real trees would otherwise revert the shortcut with nothing to notice.
	 */
	public var nested(default, null): Bool = true;

	/** Nodes per kind-equivalence-canonical kind, in document order — a nameless segment's candidates. */
	private final _byKind: Map<String, Array<QueryNode>> = [];

	/** Nodes per canonical kind and name — a named segment resolves without scanning its whole kind. */
	private final _byKindName: Map<String, Array<QueryNode>> = [];

	/** Pre-order rank per node; its presence is also the "does this tree hold the node" test. */
	private final _ordinalOf: Map<QueryNode, Int> = [];

	/** Highest pre-order rank inside a node's subtree — with `_ordinalOf` it turns descendancy into a range test. */
	private final _lastOrdinalOf: Map<QueryNode, Int> = [];

	/** Each node's parent — the chain `describe` widens along, without a root-down search per step. */
	private final _parentOf: Map<QueryNode, QueryNode> = [];

	private final _root: QueryNode;
	private final _equiv: Null<KindEquivalence>;

	public function new(root: QueryNode, ?equiv: KindEquivalence) {
		_root = root;
		_equiv = equiv;
		indexNode(root, null, null, 0);
	}

	/** The canonical, edit-stable address of `node` — `Address.describe`'s contract, answered from the index. */
	public function describe(source: String, node: QueryNode): String {
		if (!_ordinalOf.exists(node)) return positionOf(source, node);
		var selector: String = segmentOf(node);
		if (uniquelyResolves(selector, node)) return selector;
		// Prepend the nearest named ancestors until the selector is unique.
		var ancestor: Null<QueryNode> = _parentOf[node];
		while (ancestor != null) {
			final above: QueryNode = ancestor;
			if (above.name != null) {
				selector = '${segmentOf(above)} >> $selector';
				if (uniquelyResolves(selector, node)) return selector;
			}
			ancestor = _parentOf[above];
		}
		// Names cannot disambiguate — pick the instance ordinal.
		final matches: Array<QueryNode> = try resolveSelector(Selector.parse(selector)) catch (exception: Exception) [];
		final k: Int = matches.indexOf(node);
		return k >= 0 ? '$selector --nth ${k + 1}' : positionOf(source, node);
	}

	/**
	 * The innermost node whose span contains `offset` — `Engine.at`'s answer without
	 * `Engine.at`'s walk. A report addresses every finding of a file, so locating the
	 * node was a full pre-order per FINDING while the index it feeds is one per file;
	 * `Engine.atNested` instead descends only through the children that can hold the
	 * offset, which is the root-to-node path plus each level's siblings.
	 *
	 * All this class contributes is the PREMISE: `atNested` needs every spanned node to
	 * sit inside its nearest spanned ancestor, and `indexNode` measures exactly that
	 * while it builds. A tree that breaks it goes to `Engine.at` unchanged, so the
	 * shortcut is output-neutral on any tree rather than only on the ones checked.
	 */
	public function nodeAt(offset: Int): Null<QueryNode> {
		return nested ? Engine.atNested(_root, offset) : Engine.at(_root, offset);
	}

	/**
	 * Whether `selectorExpr` resolves to exactly `node` — `Engine.select`'s answer, read
	 * off the index. The question is "exactly one", so a second match already settles it:
	 * the resolve stops there instead of collecting every sibling of a selector whose whole
	 * purpose is to be rejected and widened.
	 */
	private function uniquelyResolves(selectorExpr: String, node: QueryNode): Bool {
		final matches: Array<QueryNode> = try resolveSelector(Selector.parse(selectorExpr), 2) catch (exception: Exception) return false;
		return matches.length == 1 && matches[0] == node;
	}

	/**
	 * `Engine.select` for the all-descendant selectors `describe` builds: every
	 * segment after the first matches at any depth below the previous one, so the
	 * candidate set narrows step by step from the outermost segment. A direct-child
	 * (`>`) segment can only appear when a node NAME contains a `>` — a shape this
	 * narrowing does not model, so it defers to `selectByWalk`.
	 *
	 * The result is READ-ONLY: a single-segment selector hands back the index's own
	 * group rather than a copy.
	 *
	 * `limit` (0 = every match) caps the LAST segment only: an earlier segment's matches
	 * are the next one's search scope, so truncating one there would drop matches rather
	 * than defer them. It is a cap on the answer, not a change to it — a caller reading
	 * `length` past the cap must not pass one. Best-effort, too: a single-segment selector
	 * answers unbounded (its group is the index's own array, which must not be sliced) and
	 * so does `selectByWalk`. The only caller asks whether the answer is exactly one, and
	 * that question survives an over-long answer.
	 */
	private function resolveSelector(selector: Selector, limit: Int = 0): Array<QueryNode> {
		final segments: Array<SelectorSegment> = selector.segments;
		for (i in 1...segments.length) if (!segments[i].descendant) return selectByWalk(selector, segments);
		var current: Array<QueryNode> = candidatesFor(segments[0]);
		for (i in 1...segments.length) {
			if (current.length == 0) return current;
			current = descendantsOf(current, candidatesFor(segments[i]), i == segments.length - 1 ? limit : 0);
		}
		return current;
	}

	/**
	 * `Engine.select` for a selector the interval narrowing cannot model. Reached only when a
	 * node NAME holds a `>`, which `Selector.parse` reads as a direct-child separator — not a
	 * corner case: a string literal containing `>` is a node like any other, and this repo's
	 * own sources hold thousands. The walk costs exactly what the index exists to avoid, so ask
	 * the index first: `candidatesFor` IS a segment's match set, so a segment with an empty
	 * group matches nothing and the whole selector resolves to nothing however it is walked.
	 * Output-neutral by construction — it changes only how long the answer takes.
	 */
	private function selectByWalk(selector: Selector, segments: Array<SelectorSegment>): Array<QueryNode> {
		for (segment in segments) if (candidatesFor(segment).length == 0) return [];
		return Engine.select(_root, selector, _equiv);
	}

	/** Every node `segment` matches, in document order — the index's own group, never copied. */
	private function candidatesFor(segment: SelectorSegment): Array<QueryNode> {
		final equiv: Null<KindEquivalence> = _equiv;
		final kind: String = equiv == null ? segment.kind : equiv.canon(segment.kind);
		final name: Null<String> = segment.name;
		return name == null ? _byKind[kind] ?? [] : _byKindName[groupKey(kind, name)] ?? [];
	}

	/**
	 * The members of `group` sitting strictly inside one of `outers`, in document
	 * order and without repeats. Both lists are document-ordered and subtrees are
	 * nested or disjoint, so the outers' pre-order intervals sweep `group` left to
	 * right: each starts at a binary search and stops at the first node past its end.
	 *
	 * `limit` (0 = every match) stops the sweep once that many are found. The prefix is
	 * the same one the unbounded sweep produces, so a bounded call answers "are there at
	 * least N" without paying for the rest.
	 */
	private function descendantsOf(outers: Array<QueryNode>, group: Array<QueryNode>, limit: Int = 0): Array<QueryNode> {
		final found: Array<QueryNode> = [];
		var emitted: Int = -1;
		for (outer in outers) {
			final first: Null<Int> = _ordinalOf[outer];
			final last: Null<Int> = _lastOrdinalOf[outer];
			if (first == null || last == null) throw new Exception('address index: outer ${outer.kind} is not indexed (unreachable)');
			var i: Int = lowerBound(group, first + 1);
			if (i <= emitted) i = emitted + 1;
			while (i < group.length) {
				final ordinal: Null<Int> = _ordinalOf[group[i]];
				if (ordinal == null) throw new Exception('address index: candidate ${group[i].kind} is not indexed (unreachable)');
				if (ordinal > last) break;
				found.push(group[i]);
				if (limit > 0 && found.length >= limit) return found;
				emitted = i;
				i++;
			}
		}
		return found;
	}

	/** The first index in the document-ordered `group` whose pre-order rank reaches `ordinal`. */
	private function lowerBound(group: Array<QueryNode>, ordinal: Int): Int {
		var lo: Int = 0;
		var hi: Int = group.length;
		while (lo < hi) {
			final mid: Int = (lo + hi) >> 1;
			final rank: Null<Int> = _ordinalOf[group[mid]];
			if (rank == null) throw new Exception('address index: candidate ${group[mid].kind} is not indexed (unreachable)');
			if (rank < ordinal)
				lo = mid + 1;
			else
				hi = mid;
		}
		return lo;
	}

	/**
	 * Record `node` and its subtree, returning the next free pre-order rank. An
	 * already-recorded node is skipped whole, so a tree reaching the same node twice
	 * keeps the FIRST occurrence throughout — its parent, and also its interval, so a
	 * selector rooted at the SECOND parent would not see it as a descendant. Real
	 * trees are trees: zero shared node identities over 1355 parsed files.
	 * Runs after `_equiv` is assigned, and must: it buckets by the CANONICAL kind, so
	 * an earlier call would group by the raw kind with no error and no failing test.
	 * `enclosing` is the nearest SPANNED ancestor's span rather than the parent's, so a
	 * spanless node in between does not hide a grandchild that escapes its grandparent
	 * — the containment `nodeAt` prunes on is exactly the one measured here. That test
	 * runs BEFORE the skip, because the skip keeps only the first parent: a node reached
	 * a second time would otherwise never have its second enclosure checked, and a DAG
	 * would pass for nested while `nodeAt`'s pruning could no longer reach it.
	 */
	private function indexNode(node: QueryNode, parent: Null<QueryNode>, enclosing: Null<Span>, ordinal: Int): Int {
		final span: Null<Span> = node.span;
		if (span != null && enclosing != null && (span.from < enclosing.from || span.to > enclosing.to)) nested = false;
		if (_ordinalOf.exists(node)) return ordinal;
		_ordinalOf[node] = ordinal;
		if (parent != null) _parentOf[node] = parent;
		final equiv: Null<KindEquivalence> = _equiv;
		final kind: String = equiv == null ? node.kind : equiv.canon(node.kind);
		bucket(_byKind, kind).push(node);
		final name: Null<String> = node.name;
		if (name != null) bucket(_byKindName, groupKey(kind, name)).push(node);
		final within: Null<Span> = span ?? enclosing;
		var next: Int = ordinal + 1;
		for (child in node.children) next = indexNode(child, node, within, next);
		_lastOrdinalOf[node] = next - 1;
		return next;
	}

	/** Kind and name joined into one map key, the same way a selector segment spells the pair. */
	private static inline function groupKey(kind: String, name: String): String {
		return '$kind:$name';
	}

	/** The group for `key`, created on first use. */
	private static function bucket(buckets: Map<String, Array<QueryNode>>, key: String): Array<QueryNode> {
		final existing: Null<Array<QueryNode>> = buckets[key];
		if (existing != null) return existing;
		final fresh: Array<QueryNode> = [];
		buckets[key] = fresh;
		return fresh;
	}

	/** One selector segment for a node: `Kind` or `Kind:name`. */
	private static function segmentOf(node: QueryNode): String {
		final name: Null<String> = node.name;
		return name != null ? '${node.kind}:$name' : node.kind;
	}

	/**
	 * The `<line>:<col>` fallback address. Kept off the main path on purpose:
	 * `Span.lineCol` counts newlines from byte zero, so deriving it eagerly cost
	 * one full source scan per address for a string almost every call discards.
	 */
	private static function positionOf(source: String, node: QueryNode): String {
		final span: Null<Span> = node.span;
		if (span == null) return '?:?';
		final pos: Position = span.lineCol(source);
		return '${pos.line}:${pos.col}';
	}

}
