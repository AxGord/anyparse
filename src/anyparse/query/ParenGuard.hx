package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * One edit staged for `ParenGuard.guard`: `text` replaces `span` in the source,
 * and each entry of `holes` is a range WITHIN `text` that was spliced in from
 * somewhere else (a captured metavariable's source, an inlined initializer)
 * rather than written by the template author.
 *
 * The whole `text` is a splice too — it lands in a source context the template
 * never saw — so `guard` treats `[0, text.length)` as an implicit hole and the
 * caller does not list it.
 */
typedef GuardedEdit = {
	span: Span,
	text: String,
	holes: Array<Span>
};

/**
 * Minimal parenthesisation for a TEXT splice.
 *
 * ## The problem
 *
 * Splicing source text into a hole is not precedence-preserving. `apq rewrite
 * 'final a = $A;' 'final a = $A * 2;'` over `final a = v + 1;` used to emit
 * `final a = v + 1 * 2;` — the capture `v + 1` re-parsed as two operands of two
 * different operators, so the output computes `v + 2` where the template says
 * `(v + 1) * 2`. Re-parseable, silent, and a different program. The mirror
 * hazard is the whole replacement landing in an operator context the pattern
 * matched inside: `rewrite 'f($A)' '$A + 1'` over `q * f(1)` emitted
 * `q * 1 + 1`.
 *
 * Measured over the Haxe grammar, 400 of 1530 (capture shape x template
 * context) pairs change meaning that way, and 17.9% of the nodes a `$x` could
 * bind in an 806-file corpus are of a paren-sensitive kind.
 *
 * ## The mechanism, and why it is not a precedence table
 *
 * A precedence table would have to live in the core and be re-declared by every
 * grammar. The parser already IS that table, so this class asks it instead: for
 * each splice site it builds the two candidate texts, parses them, and compares
 * what came back.
 *
 * A splice is FAITHFUL when the output tree still holds a node spanning exactly
 * the spliced characters and structurally equal to the one the parenthesised
 * spelling produces there. `v + 1` spliced into `@ * 2` yields
 * `Add(v, Mul(1, 2))`, in which nothing spans `v + 1` — unfaithful, so the pair
 * is kept. `-1` spliced into the same hole yields `Mul(Neg(1), 2)`, in which
 * `Neg` spans `-1` exactly — faithful, so `(-1) * 2` is NOT written. That is the
 * minimality rule: a pair appears only where its absence is observable in the
 * tree, so `(a) * 2` never happens.
 *
 * The consequences of asking the parser rather than a table:
 *
 *  - **No grammar declaration beyond the two it already needs.** `parenKind`
 *    and `parenDelimiters` say what a grouping node looks like and how to spell
 *    one. A grammar declaring neither gets today's raw splice, unchanged.
 *  - **An illegal pair is self-limiting.** A metavariable bound to a NAME
 *    (`final $x = 1`) cannot take parentheses at all; the probe simply fails to
 *    parse and the site is left bare. Nothing has to know which positions are
 *    name positions.
 *  - **A pair that parses but re-reads is refused too.** A type annotation
 *    accepts `final x:(Int) = 1`, and its content still spans `Int` without the
 *    pair, so the site is faithful bare and stays bare.
 *
 * ## Cost
 *
 * Whole-file parses, all of them: one per distinct template POSITION to
 * establish which positions can take a pair at all (positions, not sites —
 * legality is a property of where the hole sits in the template, and every match
 * shares one template), one for the reference shapes, one for the raw splice.
 * That is the whole bill when nothing needs a pair, which is the common case and
 * the point at which the output is byte-identical to the unguarded splice. Sites
 * that DO need one cost a further parse apiece, but only where an edit carries
 * two pairs and one might therefore be redundant.
 *
 * Measured on TM's `FileSystemBase.hx` (2226 lines, 57 matches) against the
 * unguarded 0.36s: 0.45s when no pair is needed, 0.48s when twenty are.
 */
@:nullSafety(Strict)
final class ParenGuard {

	/**
	 * A ceiling on the minimisation probes. Each is a whole-file parse, and the
	 * pass is a readability refinement over an already-correct result, so a
	 * pathological match count degrades to "one redundant pair" rather than to a
	 * command that appears to hang.
	 */
	private static inline final MAX_MINIMIZE_PROBES: Int = 64;

	/**
	 * How many times the repair pass may add pairs and re-ask. Each round can
	 * only turn a `false` into a `true` in the wrap decision, so the loop is
	 * already bounded by the site count; this bounds the PARSES instead, and two
	 * rounds have never both been needed on any probe written for this class.
	 */
	private static inline final REPAIR_ROUNDS: Int = 3;

	/**
	 * Rewrite `edits` so every spliced fragment parses in its new context as the
	 * node it was, adding the fewest grouping pairs that achieves it.
	 *
	 * Returns plain span/text edits for `RefactorSupport.canonicalize`. Every
	 * failure mode — a grammar with no grouping node, a source or probe that
	 * does not parse, an edit set the probes cannot verify — returns the input
	 * edits unchanged, so this can only ever ADD parentheses to a result the
	 * caller would otherwise have produced.
	 *
	 * `edits` must be non-overlapping; `holes` must be non-overlapping and
	 * within `[0, text.length)`. Both hold for `Rewrite` (matches are pruned to
	 * non-overlapping spans, and a metavariable expands once per occurrence).
	 */
	public static function guard(source: String, edits: Array<GuardedEdit>, plugin: GrammarPlugin): Array<{ span: Span, text: String }> {
		final plain: Array<{ span: Span, text: String }> = [for (e in edits) { span: e.span, text: e.text }];
		final shape: RefShape = plugin.refShape();
		final declared: Null<ParenDelimiters> = shape.parenDelimiters;
		if (shape.parenKind == null || declared == null) return plain;
		final delims: ParenDelimiters = declared;

		final sites: Array<Site> = enumerateSites(edits);
		if (sites.length == 0) return plain;

		final legal: Array<Bool> = legalPositions(source, edits, sites, delims, plugin);
		if (!legal.contains(true)) return plain;

		// Reference shapes: what each site's content parses as when every
		// legal position is parenthesised. A site with no node at its own
		// span there is unverifiable and is left alone.
		final allLegal: Array<Bool> = [for (s in sites) legal[s.position]];
		final refBuild: Null<Variant> = buildAndParse(source, edits, allLegal, delims, plugin);
		if (refBuild == null) return plain;
		final refTree: Null<QueryNode> = refBuild.tree;
		if (refTree == null) return plain;
		final probe: Probe = {
			source: source,
			edits: edits,
			delims: delims,
			plugin: plugin,
			sites: sites,
			allLegal: allLegal,
			refs: [
				for (i in 0...sites.length) nodeAtSpan(refBuild.text, refTree, refBuild.spans[i])
			],
			refText: refBuild.text,
			refPairs: refBuild.pairs
		};

		// Fast path: the raw splice is already faithful everywhere. The same
		// probe also names the sites that are NOT, so the needy set costs no
		// parse of its own.
		final bare: Null<Array<Bool>> = faithful(probe, [for (_ in sites) false]);
		if (bare != null && !bare.contains(false)) return plain;

		// A raw splice that does not parse AT ALL is today's loud failure
		// (`rewrite: result does not parse`), not a silent one — but the pairs
		// are just as much its remedy, so start from all of them and let
		// minimisation take back what it can. `a is C` spliced into `$A < 5`
		// reads `C < 5` as a type parameter and is unparseable; `(a is C) < 5`
		// is the rewrite the user asked for.
		final wrap: Array<Bool> = bare == null ? allLegal.copy() : [for (i in 0...sites.length) allLegal[i] && !bare[i]];
		var mask: Null<Array<Bool>> = wrap.contains(true) ? faithful(probe, wrap) : bare;
		if (mask == null) return plain;
		mask = repair(probe, wrap, mask);
		if (mask == null) return plain;

		final minimal: Array<Bool> = minimize(probe, wrap, mask);
		return !minimal.contains(true) ? plain : buildVariant(source, edits, minimal, delims).edits;
	}

	private static inline function spanKey(from: Int, to: Int): String {
		return '$from:$to';
	}

	private static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

	/**
	 * Which template POSITIONS can hold a pair at all — one probe apiece, and the
	 * answer is shared by every match of that position, since every match of one
	 * `rewrite` expands the same template. A statement replacement cannot be
	 * wrapped; neither can a metavariable bound to a NAME. Nothing here has to
	 * KNOW that: the probe simply fails to parse.
	 */
	private static function legalPositions(
		source: String, edits: Array<GuardedEdit>, sites: Array<Site>, delims: ParenDelimiters, plugin: GrammarPlugin
	): Array<Bool> {
		return [
			for (p in 0...maxPosition(sites) + 1) parseVariant(
				source, edits, ([for (s in sites) s.position == p]: Array<Bool>), delims, plugin
			) != null
		];
	}

	/**
	 * A site can fail for damage done OUTSIDE itself. `final a = $A[0];` over
	 * `a is C` leaves the capture's own `Is` node intact and orphans the `[0]`, so
	 * only the ROOT site notices — and a statement cannot take a pair. When a
	 * failing site cannot be wrapped, wrap the splices INSIDE it instead; that is
	 * what rescues `(a is C)[0]`. Mutates `wrap`; returns the final verdict mask,
	 * or null when a variant stopped parsing.
	 */
	private static function repair(probe: Probe, wrap: Array<Bool>, initial: Array<Bool>): Null<Array<Bool>> {
		var mask: Null<Array<Bool>> = initial;
		var rounds: Int = 0;
		while (mask != null && mask.contains(false) && rounds < REPAIR_ROUNDS) {
			var changed: Bool = false;
			for (i in 0...wrap.length) if (!mask[i]) {
				if (probe.allLegal[i]) {
					if (!wrap[i]) {
						wrap[i] = true;
						changed = true;
					}
				} else if (wrapInside(probe, wrap, i))
					changed = true;
			}
			if (!changed) break;
			rounds++;
			mask = faithful(probe, wrap);
		}
		return mask;
	}

	/** Give a pair to every legal splice nested inside site `i`. */
	private static function wrapInside(probe: Probe, wrap: Array<Bool>, i: Int): Bool {
		var changed: Bool = false;
		for (j in 0...wrap.length) {
			final inside: Bool = probe.sites[j].edit == probe.sites[i].edit && probe.sites[j].position > probe.sites[i].position;
			if (!inside || !probe.allLegal[j] || wrap[j]) continue;
			wrap[j] = true;
			changed = true;
		}
		return changed;
	}

	/**
	 * Take back every pair the neighbours made redundant. A site is only needy
	 * RELATIVE to its neighbours, so with those now parenthesised each pair is
	 * offered back, innermost first (a hole sits inside its edit's root, so a
	 * higher position index is the inner one). The test is "no site got worse",
	 * not "every site is faithful": a site nothing can rescue — a capture the
	 * context re-reads whatever is written around it — must not freeze the pairs
	 * around every OTHER site.
	 *
	 * Only an edit carrying TWO pairs has anything to minimise: edits occupy
	 * disjoint regions, so a pair in one cannot rescue a site in another, and a
	 * lone pair was added precisely because its site was unfaithful without it.
	 * Skipping the rest is what keeps the common case at one probe per nesting
	 * rather than one per match (measured on a 2226-line file with 57 matches:
	 * 0.74s -> 0.48s, against 0.36s unguarded).
	 */
	private static function minimize(probe: Probe, wrap: Array<Bool>, initial: Array<Bool>): Array<Bool> {
		final perEdit: Map<Int, Int> = [];
		for (i in 0...wrap.length) if (wrap[i]) perEdit[probe.sites[i].edit] = (perEdit[probe.sites[i].edit] ?? 0) + 1;
		final order: Array<Int> = [for (i in 0...probe.sites.length) i];
		order.sort((a, b) -> probe.sites[b].position - probe.sites[a].position);
		var best: Array<Bool> = wrap;
		var mask: Array<Bool> = initial;
		var probes: Int = 0;
		for (i in order) {
			if (!best[i] || (perEdit[probe.sites[i].edit] ?? 0) < 2 || probes >= MAX_MINIMIZE_PROBES) continue;
			final trial: Array<Bool> = best.copy();
			trial[i] = false;
			probes++;
			final trialMask: Null<Array<Bool>> = faithful(probe, trial);
			if (trialMask == null || !noWorse(trialMask, mask)) continue;
			best = trial;
			mask = trialMask;
		}
		return best;
	}

	/**
	 * One splice site: which edit it belongs to, its template `position`
	 * (0 = the whole replacement, 1..n = the holes in source order) and the
	 * range it occupies inside that edit's text.
	 */
	private static function enumerateSites(edits: Array<GuardedEdit>): Array<Site> {
		final sites: Array<Site> = [];
		for (e => edit in edits) {
			sites.push({
				edit: e,
				position: 0,
				from: 0,
				to: edit.text.length
			});
			final holes: Array<Span> = edit.holes.copy();
			holes.sort((a, b) -> a.from - b.from);
			for (h in 0...holes.length) sites.push({
				edit: e,
				position: h + 1,
				from: holes[h].from,
				to: holes[h].to
			});
		}
		return sites;
	}

	private static function maxPosition(sites: Array<Site>): Int {
		var top: Int = 0;
		for (s in sites) if (s.position > top) top = s.position;
		return top;
	}

	/**
	 * Assemble the spliced source for one wrap decision, recording where each
	 * site's CONTENT (the spliced characters, never the pair around them) ended
	 * up. The edits are returned too — the caller hands them to
	 * `canonicalize`, which re-derives the same text.
	 */
	private static function buildVariant(source: String, edits: Array<GuardedEdit>, wrap: Array<Bool>, delims: ParenDelimiters): Variant {
		final order: Array<Int> = [for (e in 0...edits.length) e];
		order.sort((a, b) -> edits[a].span.from - edits[b].span.from);
		final sites: Array<Site> = enumerateSites(edits);
		final spans: Array<Null<Span>> = [for (_ in sites) null];
		final pairs: Map<String, Bool> = [];
		final openLen: Int = delims.open.length;
		final out: StringBuf = new StringBuf();
		final outEdits: Array<{ span: Span, text: String }> = [];
		var cursor: Int = 0;
		var length: Int = 0;
		for (e in order) {
			final edit: GuardedEdit = edits[e];
			out.add(source.substring(cursor, edit.span.from));
			length += edit.span.from - cursor;
			cursor = edit.span.to;
			final piece: StringBuf = new StringBuf();
			var pieceLen: Int = 0;
			final rootIndex: Int = indexOfSite(sites, e, 0);
			if (wrap[rootIndex]) {
				piece.add(delims.open);
				pieceLen += openLen;
			}
			final rootOpen: Int = length + pieceLen - (wrap[rootIndex] ? openLen : 0);
			final rootFrom: Int = length + pieceLen;
			final holes: Array<Span> = edit.holes.copy();
			holes.sort((a, b) -> a.from - b.from);
			var at: Int = 0;
			for (h => hole in holes) {
				piece.add(edit.text.substring(at, hole.from));
				pieceLen += hole.from - at;
				final holeIndex: Int = indexOfSite(sites, e, h + 1);
				if (wrap[holeIndex]) {
					piece.add(delims.open);
					pieceLen += openLen;
				}
				final holeOpen: Int = length + pieceLen - (wrap[holeIndex] ? openLen : 0);
				final holeFrom: Int = length + pieceLen;
				piece.add(edit.text.substring(hole.from, hole.to));
				pieceLen += hole.to - hole.from;
				spans[holeIndex] = new Span(holeFrom, length + pieceLen);
				if (wrap[holeIndex]) {
					piece.add(delims.close);
					pieceLen += delims.close.length;
					pairs[spanKey(holeOpen, length + pieceLen)] = true;
				}
				at = hole.to;
			}
			piece.add(edit.text.substring(at));
			pieceLen += edit.text.length - at;
			spans[rootIndex] = new Span(rootFrom, length + pieceLen);
			if (wrap[rootIndex]) {
				piece.add(delims.close);
				pieceLen += delims.close.length;
				pairs[spanKey(rootOpen, length + pieceLen)] = true;
			}
			final pieceText: String = piece.toString();
			out.add(pieceText);
			length += pieceLen;
			outEdits.push({ span: edit.span, text: pieceText });
		}
		out.add(source.substring(cursor));
		return {
			text: out.toString(),
			spans: [for (s in spans) s ?? new Span(0, 0)],
			pairs: pairs,
			edits: outEdits,
			tree: null
		};
	}

	private static function indexOfSite(sites: Array<Site>, edit: Int, position: Int): Int {
		for (i in 0...sites.length) if (sites[i].edit == edit && sites[i].position == position) return i;
		return 0;
	}

	private static function parseVariant(
		source: String, edits: Array<GuardedEdit>, wrap: Array<Bool>, delims: ParenDelimiters, plugin: GrammarPlugin
	): Null<QueryNode> {
		final variant: Variant = buildVariant(source, edits, wrap, delims);
		return try plugin.parseFile(variant.text) catch (_: Exception) null;
	}

	private static function buildAndParse(
		source: String, edits: Array<GuardedEdit>, wrap: Array<Bool>, delims: ParenDelimiters, plugin: GrammarPlugin
	): Null<Variant> {
		final variant: Variant = buildVariant(source, edits, wrap, delims);
		final tree: Null<QueryNode> = try plugin.parseFile(variant.text) catch (_: Exception) null;
		return tree == null ? null : {
			text: variant.text,
			spans: variant.spans,
			pairs: variant.pairs,
			edits: variant.edits,
			tree: tree
		};
	}

	/**
	 * Per-site verdict under one wrap decision: does each site with a reference
	 * still hold that shape? Null when the variant does not parse at all.
	 */
	private static function faithful(probe: Probe, wrap: Array<Bool>): Null<Array<Bool>> {
		final built: Null<Variant> = buildAndParse(probe.source, probe.edits, wrap, probe.delims, probe.plugin);
		if (built == null) return null;
		final tree: Null<QueryNode> = built.tree;
		if (tree == null) return null;
		final out: Array<Bool> = [];
		for (i in 0...probe.refs.length) {
			final reference: Null<QueryNode> = probe.refs[i];
			if (reference == null) {
				out.push(true);
				continue;
			}
			final found: Null<QueryNode> = nodeAtSpan(built.text, tree, built.spans[i]);
			out.push(found != null && sameIgnoringInserted(found, built.text, built.pairs, reference, probe.refText, probe.refPairs));
		}
		return out;
	}

	/** Is `trial` faithful wherever `current` was — i.e. did dropping a pair cost nothing? */
	private static function noWorse(trial: Array<Bool>, current: Array<Bool>): Bool {
		for (i in 0...current.length) if (current[i] && !trial[i]) return false;
		return true;
	}

	/**
	 * `RefactorSupport.structurallyEqual`, blind to the pairs the GUARD wrote.
	 *
	 * The reference shapes are read off the variant where every legal position is
	 * parenthesised, so an outer site's reference contains the pairs its inner
	 * sites were given. Minimisation then drops some of those, and a strict
	 * comparison would read the drop as a changed shape and put the pair straight
	 * back — the check would defeat exactly the step it exists to verify.
	 *
	 * The blindness is keyed by SPAN, not by node kind, because a grammar can
	 * parse the same two characters into more than one grouping ctor: Haxe's
	 * expression pair is `ParenExpr` and its TYPE pair is `Parens`, and a
	 * kind-keyed test that knew only the first put a `final abc:(Int)` back
	 * every time. Each variant knows exactly where it wrote a pair, so nothing
	 * has to be declared: a pair the INPUT wrote is at no such span, appears on
	 * both sides, and cancels.
	 */
	private static function sameIgnoringInserted(
		a: QueryNode, aText: String, aPairs: Map<String, Bool>, b: QueryNode, bText: String, bPairs: Map<String, Bool>
	): Bool {
		final left: QueryNode = unwrapInserted(a, aText, aPairs);
		final right: QueryNode = unwrapInserted(b, bText, bPairs);
		if (left.kind != right.kind || left.name != right.name) return false;
		final leftType: Null<QueryNode> = left.type;
		final rightType: Null<QueryNode> = right.type;
		if (leftType == null || rightType == null) {
			if (leftType != rightType) return false;
		} else if (!sameIgnoringInserted(leftType, aText, aPairs, rightType, bText, bPairs))
			return false;
		if (left.children.length != right.children.length) return false;
		for (k in 0...left.children.length) if (!sameIgnoringInserted(left.children[k], aText, aPairs, right.children[k], bText, bPairs))
			return false;
		return true;
	}

	private static function unwrapInserted(node: QueryNode, text: String, pairs: Map<String, Bool>): QueryNode {
		var at: QueryNode = node;
		while (at.children.length == 1) {
			final own: Null<Span> = at.span;
			if (own == null || !pairs.exists(spanKey(trimmedFrom(text, own), trimmedTo(text, own)))) break;
			at = at.children[0];
		}
		return at;
	}

	/**
	 * The OUTERMOST node covering exactly `span`, or null when the text is not a
	 * node of its own — which is precisely what an operator having bound across
	 * the splice looks like.
	 *
	 * "Exactly" is measured after trimming whitespace off both ends of the node's
	 * span. Spans are tight around TOKENS but a node's may run over the trivia
	 * that follows its last one (`v + 2 + 1` reports its left `Add` as
	 * `v + 2 `, one past the `2`), and a byte-equal test would read that as "no
	 * node here" and keep a pair nothing needs.
	 */
	private static function nodeAtSpan(text: String, node: QueryNode, span: Span): Null<QueryNode> {
		final own: Null<Span> = node.span;
		if (own != null) {
			if (trimmedFrom(text, own) == span.from && trimmedTo(text, own) == span.to) return node;
			if (own.from > span.from || own.to < span.to) return null;
		}
		for (child in node.children) {
			final hit: Null<QueryNode> = nodeAtSpan(text, child, span);
			if (hit != null) return hit;
		}
		return null;
	}

	private static function trimmedFrom(text: String, span: Span): Int {
		var at: Int = span.from;
		while (at < span.to && isSpace(text.fastCodeAt(at))) at++;
		return at;
	}

	private static function trimmedTo(text: String, span: Span): Int {
		var at: Int = span.to;
		while (at > span.from && isSpace(text.fastCodeAt(at - 1))) at--;
		return at;
	}

}

/** How to spell a grouping pair, as `RefShape.parenDelimiters` declares it. */
private typedef ParenDelimiters = {
	open: String,
	close: String
};

/** Everything the per-wrap probes need, assembled once. */
private typedef Probe = {
	source: String,
	edits: Array<GuardedEdit>,
	delims: ParenDelimiters,
	plugin: GrammarPlugin,
	sites: Array<Site>,
	allLegal: Array<Bool>,
	refs: Array<Null<QueryNode>>,
	refText: String,
	refPairs: Map<String, Bool>
};

/** @see `ParenGuard.enumerateSites` */
private typedef Site = {
	edit: Int,
	position: Int,
	from: Int,
	to: Int
};

/**
 * One assembled candidate: its text, each site's content span in it, the spans
 * of the pairs the guard itself wrote (delimiters included), the edits that
 * produce it, and its parse.
 */
private typedef Variant = {
	text: String,
	spans: Array<Span>,
	pairs: Map<String, Bool>,
	edits: Array<{ span: Span, text: String }>,
	tree: Null<QueryNode>
};
