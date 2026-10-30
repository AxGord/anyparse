package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.LexicalRegions.LexRegionKind;
import anyparse.query.ReplaceNode.ReplaceTarget;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * Patch a fragment INSIDE one addressed node — the surgical counterpart of
 * `ReplaceNode` for small edits: instead of resending a whole declaration to
 * change a few lines, the caller supplies the exact old fragment (copied
 * verbatim from `apq source --select`) and its replacement. The old fragment
 * must occur exactly once within the resolved node's source (modifier group
 * included), so the edit cannot land anywhere unintended; the result goes
 * through the same `RefactorSupport.canonicalize` finalize as every
 * writer-emit op — writer-formatted, re-parse-validated and canonical-gated.
 */
@:nullSafety(Strict)
final class Patch {

	/**
	 * Replace the unique occurrence of `oldText` inside the node addressed by
	 * `target` with `newText` — the single-pair form of `patchNodeMany`.
	 */
	public static function patchNode(
		source: String, target: ReplaceTarget, oldText: String, newText: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String,
		all: Bool = false
	): EditResult {
		return patchNodeMany(source, target, [{ oldText: oldText, newText: newText }], reformat, plugin, optsJson, all);
	}

	/**
	 * Apply several fragment pairs to ONE addressed node in a single writer
	 * round-trip. Every pair's old fragment is located against the ORIGINAL
	 * node source (byte-exact first, then line-wise with indentation ignored —
	 * the dedented `apq source --select` form) and must occur exactly once;
	 * the matched ranges must not overlap. The line-wise arm owns whole lines and
	 * re-bases the replacement onto the matched line's indentation, so a fragment
	 * landing in a comment interior or a multi-line string — the two regions the
	 * writer re-emits byte for byte, where no gate would see a wrong indent — keeps
	 * the shape it was written with.
	 *
	 * The call is ALL-OR-NOTHING: one pair that cannot be placed discards the whole
	 * payload, so an `Err` names the offending pair AND says nothing was applied.
	 * Locating against the ORIGINAL is what makes the payload order-independent, and
	 * it is also why a pair written against an earlier pair's OUTPUT can never match
	 * — that case gets a refusal of its own rather than "copy it verbatim".
	 */
	public static function patchNodeMany(
		source: String, target: ReplaceTarget, pairs: Array<{ oldText: String, newText: String }>, reformat: Bool, plugin: GrammarPlugin,
		?optsJson: String, all: Bool = false
	): EditResult {
		if (pairs.length == 0) return Err('no fragment pairs given');
		final tree: QueryNode = switch ParseGate.parse(plugin, source, 'source') {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};

		final node: QueryNode = switch ReplaceNode.resolveTarget(source, tree, target, plugin) {
			case Resolved(n): n;
			case Failed(message): return Err(message);
		};

		final span: Null<Span> = node.span;
		if (span == null) return Err('the resolved ${node.kind} node has no source span to patch');

		// The searchable region is the same modifier-folded slice `apq source
		// --select` prints, so a fragment copied from that output matches as-is.
		final groupSpan: Span = ElementSpan.declEditSpan(source, tree, node, span, plugin.lexicalRegions.bind(source));
		final slice: String = source.substring(groupSpan.from, groupSpan.to);
		final edits: Array<{ span: Span, text: String }> = [];
		// The same edits in SLICE coordinates — what `sequencingRefusal` replays to see
		// the text the pairs placed so far produce.
		final placed: Array<{ span: Span, text: String }> = [];
		// The subset whose indentation THIS op made up rather than copied — the only
		// edits `verbatimSpliceIntact` has anything to say about.
		final synthesised: Array<{ span: Span, text: String }> = [];
		final multi: Bool = pairs.length > 1;
		for (i in 0...pairs.length) {
			final label: String = multi ? 'pair ${i + 1}: ' : '';
			final oldText: String = pairs[i].oldText;
			if (oldText.length == 0)
				return Err(discarded('${label}the old fragment is empty — copy it verbatim from `apq source --select`', multi));
			if (oldText == pairs[i].newText)
				return Err(discarded('${label}the old and new fragments are identical — nothing to change', multi));
			final found: { located: LocateResult, base: Int } = locateWithOwnDoc(
				source, slice, groupSpan, oldText, node.kind, label, all, plugin
			);
			final located: LocateResult = found.located;
			final base: Int = found.base;
			final refusal: Null<String> = located.error;
			if (refusal != null) return Err(discarded(sequencingRefusal(label, refusal, slice, placed, oldText, node.kind, all), multi));
			for (r in located.ranges) {
				final edit: { span: Span, text: String } = {
					span: new Span(base + r.from, base + r.to),
					text: r.dedented ? rebased(pairs[i].newText, r.indent) : pairs[i].newText
				};
				edits.push(edit);
				// `placed` is in the DECLARATION slice's coordinates; a range found in the doc above
				// it has none there, and only the wording of a later pair's refusal reads `placed`.
				if (base == groupSpan.from) placed.push({ span: new Span(r.from, r.to), text: edit.text });
				if (r.dedented) synthesised.push(edit);
			}
		}
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> a.span.from - b.span.from);
		for (i in 1...sorted.length) if (sorted[i].span.from < sorted[i - 1].span.to)
			return Err(discarded('the matched fragments overlap — merge the overlapping pairs into one', multi));
		final orphan: Null<String> = docOrphanRefusal(source, tree, sorted, plugin);
		if (orphan != null) return Err(discarded(orphan, multi));
		return switch CanonicalEdit.canonicalize(source, edits, reformat, plugin, optsJson) {
			case Ok(text, rewrites): verbatimSpliceIntact(source, synthesised, text, rewrites, plugin);
			case failed: failed;
		}
	}

	/**
	 * A multi-pair call is ALL-OR-NOTHING: the first pair that cannot be placed
	 * discards the whole payload, the pairs that already located included. The bare
	 * per-pair refusal names one pair and says nothing about the rest, which reads
	 * as "the others landed" — and a caller who believes that goes on to build on an
	 * edit the file never received. Say what actually happened instead.
	 */
	private static inline function discarded(message: String, multi: Bool): String {
		return multi ? '$message. Nothing was applied — a multi-pair call is all-or-nothing' : message;
	}

	/** How many times `oldText` locates in `slice`, with the exactly-once discipline lifted. */
	private static inline function occurrences(slice: String, oldText: String, kind: String): Int {
		return locate(slice, oldText, kind, '', true).ranges.length;
	}

	/** The repeated-fragment refusal, shared by the byte-exact and dedented arms. */
	private static inline function repeated(label: String, count: Int, kind: String): String {
		return '${label}the old fragment occurs $count times in the resolved $kind node — widen the snippet until it is unique, '
			+ 'or pass --all to rewrite every occurrence';
	}

	private static inline function fail(message: String): LocateResult {
		return { ranges: [], error: message };
	}

	/** The leading horizontal whitespace of `line` — the indentation a dedented fragment dropped. */
	private static inline function leadingSpace(line: String): String {
		return line.substring(0, line.length - line.ltrim().length);
	}

	/**
	 * Whether a comment token is an attached doc block: a `/**` block that starts its own line. A
	 * comment sharing its line with preceding code trails THAT declaration, and a plain banner
	 * comment is not documentation — the attribution `RefactorSupport.docExtendedSpan` applies.
	 */
	private static inline function isDocBlock(source: String, tok: { from: Int, to: Int, isLine: Bool }): Bool {
		return !tok.isLine && SourceText.startsItsLine(source, tok.from) && source.fastCodeAt(tok.from + 2) == '*'.code;
	}

	/**
	 * `locate` over the declaration's slice, and — for a fragment that does not occur there at all
	 * — over the slice widened back over the declaration's OWN leading doc block, which is trivia
	 * before the node. That is what lets the doc-orphan refusal's remedy (widen the fragment over
	 * the doc) work through the very address that was refused, and a type's doc be reached through
	 * `ClassDecl:<T>`. A fragment the declaration holds is matched there alone, so its doc can never
	 * make it ambiguous. `base` is the source offset the ranges are relative to.
	 */
	private static function locateWithOwnDoc(
		source: String, slice: String, groupSpan: Span, oldText: String, kind: String, label: String, all: Bool, plugin: GrammarPlugin
	): { located: LocateResult, base: Int } {
		final located: LocateResult = locate(slice, oldText, kind, label, all);
		if (located.error == null || occurrences(slice, oldText, kind) > 0) return { located: located, base: groupSpan.from };
		final docFrom: Int = ElementSpan.docExtendedSpan(source, groupSpan, plugin.lexicalRegions(source), true).from;
		if (docFrom >= groupSpan.from) return { located: located, base: groupSpan.from };
		final widened: LocateResult = locate(source.substring(docFrom, groupSpan.to), oldText, kind, label, all);
		return widened.error == null ? { located: widened, base: docFrom } : { located: located, base: groupSpan.from };
	}

	/**
	 * Why this payload would move a doc comment onto a declaration it was not written for, or null.
	 *
	 * A declaration's `/** ... *\/` is trivia BEFORE its node, so a payload that keeps the documented
	 * declaration and puts a new one ahead of it splices between the doc and what it documents, and
	 * one that deletes the documented declaration leaves the doc above the next. The writer re-emits
	 * the comment verbatim and `apq patch` reports `wrote <file>`; no build or lint sees the move.
	 *
	 * Each edit watches ONE block: the doc it starts inside, else the doc directly above the
	 * declaration run it starts at (`declGroupStart`, then `docBlockAbove`). The payload is spliced
	 * and reparsed, and a watched block whose owner NAME changed is a transfer when the old name
	 * still stands in the container, when the new owner was already declared there, or when the
	 * bytes the block documents now hold more declarations than before; a changed name with none of
	 * the three is a rename and applies. A fragment that starts AT the block's opening carries the
	 * whole block, so where it lands is the payload's to say — which is why widening the fragment
	 * over the doc is the remedy the refusal names.
	 */
	private static function docOrphanRefusal(
		source: String, tree: QueryNode, sorted: Array<{ span: Span, text: String }>, plugin: GrammarPlugin
	): Null<String> {
		// ONE lexical pass for the whole call. `docExtendedSpan` re-lexes the file on every call,
		// and asking it per edit costs a large share of the op on a big file patched with `--all`.
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(plugin.lexicalRegions(source));
		final shape: RefShape = plugin.refShape();
		final watched: Array<{
			doc: Span,
			node: QueryNode,
			owner: String,
			ownerEnd: Int,
			declared: Int
		}> = [];
		// One entry per BLOCK, not per edit: several edits of one payload can start inside the same
		// block, or in trivia that resolves to the same enclosing type, and each would otherwise
		// re-resolve that one block against the spliced tree below.
		final seen: Array<Int> = [];
		for (edit in sorted) {
			final doc: Null<Span> = enclosingDoc(source, comments, edit.span.from) ?? docBlockAbove(
				source, comments, declGroupStart(source, tree, edit.span.from, shape)
			);
			if (doc == null || seen.contains(doc.to)) continue;
			seen.push(doc.to);
			final node: Null<QueryNode> = docOwnerNode(source, tree, comments, doc.to, shape);
			final owner: Null<String> = node == null ? null : declName(node);
			final ownerSpan: Null<Span> = node?.span;
			if (node == null || owner == null || ownerSpan == null) continue;
			watched.push({
				doc: doc,
				node: node,
				owner: owner,
				ownerEnd: shiftedEnd(sorted, ownerSpan.to),
				declared: declsInRegion(tree, node, new Span(doc.to, containingEnd(sorted, ownerSpan.to)))
			});
		}
		if (watched.length == 0) return null;

		final spliced: String = CanonicalEdit.applyEdits(source, sorted);
		final after: QueryNode = try plugin.parseFile(spliced) catch (exception: Exception) return null;
		final splicedComments: Array<{ from: Int, to: Int, isLine: Bool }> =
			SourceComments.collectCommentTokens(plugin.lexicalRegions(spliced));
		for (w in watched) {
			final docEnd: Int = splicedDocEnd(spliced, splicedComments, sorted, w.doc);
			final ownerNode: Null<QueryNode> = docOwnerNode(spliced, after, splicedComments, docEnd, shape);
			if (ownerNode == null) return orphanRefusal(w.owner);
			final owner: QueryNode = ownerNode;
			final now: Null<String> = declName(owner);
			if (now == null || now == w.owner) continue;
			// A RENAME of the documented declaration reaches this point by construction — the doc's
			// owner name changed because the declaration was renamed — and refusing it made `patch`
			// decline the single most ordinary edit a documented member ever gets. Three signals
			// separate it from a TRANSFER, each covering a hole the others leave:
			//
			// - `stands`: an insertion leaves the original declaration standing beside it, so BOTH
			//   names survive in the container.
			// - `took`: a deletion leaves the doc above a declaration that already stood in the
			//   container, where a rename gives it a name nothing there held.
			// - `grew`: the bytes that held the documented declaration hold more now — the compound
			//   payload that inserts a declaration AND renames the one it stole the doc from. It is
			//   read off that REGION, not the container, because a container grows for reasons that
			//   have nothing to do with this doc.
			final stands: Bool = siblingDeclares(after, owner, w.owner, shape);
			// A documented declaration inside a region also hands the doc on past the region itself.
			final top: QueryNode = regionTop(tree, w.node, shape);
			final took: Bool = siblingDeclares(tree, w.node, now, shape) || siblingDeclares(tree, top, now, shape);
			final grew: Bool = w.declared >= 0 && declsInRegion(after, owner, new Span(docEnd, w.ownerEnd)) > w.declared;
			if (stands || took || grew) return transferRefusal(w.owner, now, stands, took);
		}
		return null;
	}

	/**
	 * Where the position `at` lands in the SPLICED text — moved by the edits that lie entirely
	 * BEFORE it, and, for the one edit that CONTAINS it, mapped onto the end of that edit's
	 * replacement.
	 *
	 * The running total this replaced added EVERY preceding edit's delta, so with several edits
	 * watched against one block the recorded end was pushed past itself onto whatever declaration
	 * the offset landed in, and refusals came in a WINDOW decided by the delta's size: the signature
	 * of a position error, not of a doc that moved.
	 *
	 * For the CONTAINING edit the end of its replacement is right for a declaration that edit
	 * rewrote, and only a fallback for a doc block's end, which `splicedDocEnd` reads off the doc
	 * token over the block's start. Answering `-1` there and dropping the watch was a
	 * fail-OPEN: a first pair rewriting the doc's last two lines and a second turning `function b()
	 * {}` into `function c() {}` above a kept `b` moved the block onto `c` with nothing watched.
	 */
	private static function shiftedEnd(sorted: Array<{ span: Span, text: String }>, at: Int): Int {
		var shifted: Int = at;
		// Arithmetic only — no lex, no tree walk — so rescanning the edit list per watched block
		// stays cheap beside the two lexical passes this guard already pays for.
		for (edit in sorted) if (edit.span.from < at) {
			final to: Int = edit.span.to;
			shifted += edit.text.length - (to - edit.span.from);
			if (to > at) shifted += to - at;
		}
		return shifted;
	}

	/**
	 * The ORIGINAL end of what `shiftedEnd` maps `at` onto: the end of the edit CONTAINING `at`, or
	 * `at` itself when no edit does. `shiftedEnd` answers the end of that edit's REPLACEMENT, so the
	 * baseline count has to be taken over the bytes that replacement consumed — otherwise a fragment
	 * that renames the documented declaration and merely CARRIES a following sibling reads as a
	 * region that grew from one declaration to two.
	 */
	private static function containingEnd(sorted: Array<{ span: Span, text: String }>, at: Int): Int {
		for (edit in sorted) if (edit.span.from < at && edit.span.to > at) return edit.span.to;
		return at;
	}

	/**
	 * `at` advanced past whitespace and any COMMENT tokens that follow it — where the next real
	 * code is. A `//` note prepended between a doc block and its declaration is trivia, not a new
	 * owner, and stopping at it made the guard refuse that edit while naming the enclosing type
	 * as the doc's new owner.
	 */
	private static function skipTrivia(source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, at: Int): Int {
		var i: Int = at;
		while (true) {
			while (i < source.length && SourceText.isSpace(source.fastCodeAt(i))) i++;
			var moved: Bool = false;
			for (tok in comments) if (tok.from == i) {
				i = tok.to;
				moved = true;
				break;
			}
			if (!moved) return i;
		}
	}

	/**
	 * The OUTERMOST node starting at byte `at`, or null when nothing starts there. `Engine.at`
	 * resolves the NARROWEST, which for `public static function f` is the modifier token rather
	 * than the member it prefixes — and every question here is about the member.
	 */
	private static function outermostAt(tree: QueryNode, at: Int): Null<QueryNode> {
		final resolved: Null<QueryNode> = Engine.at(tree, at);
		if (resolved == null) return null;
		var node: QueryNode = resolved;
		while (true) {
			final parent: Null<QueryNode> = TreePath.parentOf(tree, node);
			if (parent == null) break;
			final parentSpan: Null<Span> = parent.span;
			if (parentSpan == null || parentSpan.from != at) break;
			node = parent;
		}
		return node;
	}

	/**
	 * Where the declaration group containing `at` STARTS — `at` folded back over the modifier /
	 * `@:meta` / conditional-region run that belongs to the same declaration
	 * (`RefactorSupport.declGroupSpan`, the same fold `apq source --select` prints).
	 *
	 * Without it the doc lookup asked about the bytes directly above the MATCH, and a doc
	 * separated from its declaration by `@:noCompletion` was invisible — the guard passed an
	 * insert-ahead that orphaned the doc AND the metadata onto the insertion.
	 */
	private static function declGroupStart(source: String, tree: QueryNode, at: Int, shape: RefShape): Int {
		var from: Int = at;
		while (from < source.length && SourceText.isSpace(source.fastCodeAt(from))) from++;
		final node: Null<QueryNode> = outermostAt(tree, from);
		if (node == null) return from;
		final span: Null<Span> = node.span;
		if (span == null) return from;
		// The RUN start, not `declGroupSpan`'s: that function no longer walks forward
		// off an annotation, so it answers an annotation's own offset — and this guard
		// then looked for a `/**` directly above the SECOND annotation of a run, found
		// the first one, and let a doc-stealing insert through at rc 0.
		var current: QueryNode = node;
		var start: Int = ElementSpan.declRunStart(node, TreePath.parentOf(tree, node), span);
		// A run that opens a conditional region is documented by the doc above the REGION, so
		// the lookup climbs out of every region whose first element it is.
		while (true) {
			final parent: Null<QueryNode> = TreePath.parentOf(tree, current);
			final parentSpan: Null<Span> = parent?.span;
			if (parent == null || parentSpan == null || !CondRegionScan.isConditionalKind(parent.kind, shape)) return start;
			if (parent.children[0].span?.from != start) return start;
			current = parent;
			start = ElementSpan.declRunStart(parent, TreePath.parentOf(tree, parent), parentSpan);
		}
	}

	/**
	 * The `/**` block directly above `at`, or null when no attached doc block is there.
	 *
	 * This asks the pre-lexed `comments` list rather than `RefactorSupport.docExtendedSpan`, which re-lexes
	 * the whole file per call, so a big file patched with `--all` pays one whole-file lex per resolved
	 * range. `isDocBlock` is the attribution rule `docExtendedSpan` applies.
	 */
	private static function docBlockAbove(source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, at: Int): Null<Span> {
		var i: Int = at - 1;
		while (i >= 0 && SourceText.isSpace(source.fastCodeAt(i))) i--;
		if (i < 0) return null;
		final tok: Null<{ from: Int, to: Int, isLine: Bool }> = comments.find(t -> t.to == i + 1 && isDocBlock(source, t));
		return tok == null ? null : new Span(tok.from, tok.to);
	}

	/**
	 * The doc block `at` falls strictly inside, or null. An edit starting there starts in trivia, so
	 * the declaration run it would be asked about is whatever ENCLOSES the block — the type around a
	 * member's doc — and a fragment opening on the doc's closing line and inserting a declaration
	 * under it moved the doc with nothing watched.
	 */
	private static function enclosingDoc(source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, at: Int): Null<Span> {
		final tok: Null<{ from: Int, to: Int, isLine: Bool }> = comments.find(t -> t.from < at && at < t.to && isDocBlock(source, t));
		return tok == null ? null : new Span(tok.from, tok.to);
	}

	/**
	 * Where the watched `doc` block ends in the spliced text: the end of the doc token that still
	 * starts where the block started or, when an edit rewrote the block's opening, of the doc token
	 * the arithmetic start now falls inside. `shiftedEnd` of the block's own end answers the end of a
	 * replacement that opened inside the block and ran past it — past every declaration that
	 * replacement wrote — so it is the answer only for a payload that left no doc over the block's
	 * start at all, i.e. rewrote it into something that documents nothing.
	 */
	private static function splicedDocEnd(
		source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, sorted: Array<{ span: Span, text: String }>, doc: Span
	): Int {
		final from: Int = shiftedEnd(sorted, doc.from);
		final starting: Null<{ from: Int, to: Int, isLine: Bool }> = comments.find(t -> t.from == from && isDocBlock(source, t));
		final tok: Null<{ from: Int, to: Int, isLine: Bool }> = starting ?? comments.find(t ->
			t.from < from && from <= t.to && isDocBlock(source, t)
		);
		return tok == null ? shiftedEnd(sorted, doc.to) : tok.to;
	}

	/**
	 * The declaration a doc block ending at `docEnd` documents — the node itself, so a caller can
	 * ask about its NEIGHBOURS and not only its name. Null when no declaration STARTS after the
	 * block — a closing brace, the end of the file — i.e. the block documents nothing.
	 *
	 * The forward skip over the modifier / annotation run is the INNER walk `declGroupSpan` does;
	 * the ENTRY condition is not shared. `declGroupSpan` stops on an annotation element and
	 * answers its own span, while a doc block above an annotation run documents the declaration
	 * under it — so this walk goes past the annotations on purpose.
	 */
	private static function docOwnerNode(
		source: String, tree: QueryNode, comments: Array<{ from: Int, to: Int, isLine: Bool }>, docEnd: Int, shape: RefShape
	): Null<QueryNode> {
		final at: Int = skipTrivia(source, comments, docEnd);
		if (at >= source.length) return null;
		final resolved: Null<QueryNode> = outermostAt(tree, at);
		if (resolved == null || resolved.span?.from != at) return null;
		final node: QueryNode = resolved;
		final parent: Null<QueryNode> = TreePath.parentOf(tree, node);
		return parent == null ? regionOwner(node, shape) : firstOwnerFrom(parent, parent.children.indexOf(node), shape);
	}

	/**
	 * The declaration a doc block above a conditional-compilation region documents: the first one in
	 * the region, past the region's own modifier run, through any nested region; null when the region
	 * declares nothing. The region itself has no name, and reading it as the owner left the doc
	 * unwatched on both sides of the splice.
	 */
	private static function regionOwner(node: QueryNode, shape: RefShape): Null<QueryNode> {
		return CondRegionScan.isConditionalKind(node.kind, shape) ? firstOwnerFrom(node, 0, shape) : node;
	}

	/**
	 * The first declaration among `parent`'s children from index `from` on, through the regions it
	 * meets, or null. A region that declares nothing documents nothing itself: Haxe attaches a doc above
	 * `#if js #end` to the declaration after it, so the walk goes past such a region.
	 */
	private static function firstOwnerFrom(parent: QueryNode, from: Int, shape: RefShape): Null<QueryNode> {
		var i: Int = from;
		while (i >= 0 && i < parent.children.length) {
			final next: Null<QueryNode> = ElementSpan.declAfterPrefixRun(parent.children[i], parent);
			if (next == null) return null;
			final inner: Null<QueryNode> = regionOwner(next, shape);
			if (inner != null) return inner;
			i = parent.children.indexOf(next) + 1;
		}
		return null;
	}

	/** `node`, or the outermost conditional region holding it — the element a doc above that region sits before. */
	private static function regionTop(tree: QueryNode, node: QueryNode, shape: RefShape): QueryNode {
		var top: QueryNode = node;
		while (true) {
			final parent: Null<QueryNode> = TreePath.parentOf(tree, top);
			if (parent == null || !CondRegionScan.isConditionalKind(parent.kind, shape)) return top;
			top = parent;
		}
	}

	/**
	 * Whether any SIBLING of `node` still declares `name` — the discriminator between a
	 * doc TRANSFER and a RENAME, the two edits that both change the name the watched doc
	 * block sits above.
	 *
	 * A transfer pushes a NEW declaration between the doc and its owner, so the owner
	 * stands beside the insertion and both names survive. A rename changes the name in
	 * place, so the old one is gone from the container entirely — nothing was orphaned,
	 * and the doc still documents the same declaration it always did.
	 *
	 * Scoped to the SIBLING set, not the file: renaming `Type.foo` while a different type
	 * in the same module also declares `foo` is a rename, and a file-wide survival test
	 * would refuse it. The one shape this reads as a transfer and is not is an `overload`
	 * extern's repeated member name — renaming one arm of `extern overload function f`
	 * leaves a sibling still called `f`; refusing there is the conservative answer for an
	 * edit whose target is ambiguous by name anyway.
	 */
	private static function siblingDeclares(tree: QueryNode, node: QueryNode, name: String, shape: RefShape): Bool {
		final parent: Null<QueryNode> = TreePath.parentOf(tree, node);
		return parent != null && parent.children.exists(c -> c != node && declaresName(c, name, shape));
	}

	/** Whether `node` declares `name` — itself, or, for a conditional-compilation region, any declaration in any of its branches. */
	private static function declaresName(node: QueryNode, name: String, shape: RefShape): Bool {
		return declName(node) == name
			|| CondRegionScan.isConditionalKind(node.kind, shape)
			&& node.children.exists(c -> declaresName(c, name, shape));
	}

	/**
	 * How many of `node`'s container's DECLARATIONS start inside `region` — a modifier /
	 * annotation prefix is not an element of its own and never counts. `-1` when the node has no
	 * container, i.e. the count carries no signal and the caller must not read one into it.
	 *
	 * The second half of the transfer/rename discriminator: a transfer splits the bytes the
	 * documented declaration occupied into two declarations, a rename leaves them holding one.
	 * Asked separately from the name test because a payload can erase the old name and insert in
	 * the same call, which the name test alone reads as a plain rename — and asked over the
	 * REGION rather than the container, because the container-wide count this replaced could not
	 * tell that growth from an insertion made somewhere else entirely by another pair.
	 */
	private static function declsInRegion(tree: QueryNode, node: QueryNode, region: Span): Int {
		final parent: Null<QueryNode> = TreePath.parentOf(tree, node);
		return parent == null
			? -1
			: parent.children.count(c -> {
				final span: Null<Span> = c.span;
				return !ElementSpan.isDeclPrefixSibling(c) && span != null && span.from >= region.from && span.from < region.to;
			});
	}

	/**
	 * The refusal, naming the block, the declaration it left and the one it landed on — with the
	 * tail the signal that fired actually supports.
	 *
	 * `stands`: the documented declaration is still there beside the insertion, so the transfer is
	 * a fact and the message states it. `took`: the doc landed on a declaration that was already
	 * there, which a deletion of the documented one and a deletion of the other plus a rename onto
	 * its name both produce. Otherwise the payload ALSO erased the old name, and all that is
	 * established is a region that holds more declarations than it did: either the old one was
	 * renamed and a second pushed in under the doc, or a new one was pushed ahead of a rename.
	 */
	private static function transferRefusal(was: String, now: String, stands: Bool, took: Bool): String {
		final why: String = if (stands)
			'the doc would silently transfer to the insertion and `$was` would be left undocumented'
		else if (took)
			'`$now` was already declared there, so the replacement either deleted `$was` and left its doc on `$now`, or deleted '
				+ '`$now` and renamed `$was` onto its name; nothing in the text tells those apart'
		else
			'`$was` is no longer declared there, so the replacement either renamed it, leaving the doc where it belongs, or '
				+ 'pushed `$now` in under the doc ahead of it; nothing in the text tells those apart';
		return 'the edit moves the `/**` block above `$was` onto `$now` — $why. Widen the old fragment upward to include the doc block '
			+ 'and repeat it in the replacement above the declaration it documents, or leave it out when that declaration is deleted; a '
			+ 'fragment that is not in the addressed declaration is also looked for in that declaration\'s own doc, so the same address '
			+ 'reaches it';
	}

	/**
	 * The refusal for a watched block the payload left documenting NOTHING — the documented declaration
	 * gone with no declaration after the block to take it, so the block now sits above a closing brace
	 * or the end of the file. No transfer signal fires there: there is no new owner to compare.
	 */
	private static function orphanRefusal(was: String): String {
		return 'the edit leaves the `/**` block above `$was` documenting nothing — no declaration follows it any more. Widen the old '
			+ 'fragment upward to include the doc block so it goes with the declaration; a fragment that is not in the addressed '
			+ 'declaration is also looked for in that declaration\'s own doc, so the same address reaches it';
	}

	/**
	 * The refusal for a pair the caller SEQUENCED — wrote against the text an earlier
	 * pair produces rather than against the original node. Every pair is located
	 * against the ORIGINAL slice, deliberately: that is what keeps a payload
	 * order-independent and gives the overlap check something to mean. So such a pair
	 * can never match, no matter how faithfully it was copied — and the standing
	 * remedy ("copy it verbatim from `apq source --select`") sends the caller to
	 * re-copy bytes that are already right, which is why the same pairs applied one
	 * per call while the batch refused.
	 *
	 * `failure` back unchanged when the fragment does not locate against the placed
	 * pairs' output either — then the ordinary refusal is the accurate one — and when
	 * it does but the fragment is merely AMBIGUOUS in the original: there the repeated
	 * arm's own remedy (widen THIS pair, or pass --all) still resolves the call in one
	 * go, so it is kept and only the missing fact is added. Replacing it cost the caller
	 * the one instruction that works.
	 *
	 * The spans in `placed` are slice-relative and may overlap each other — the overlap
	 * check runs only once every pair has been located — so the replayed text is not
	 * necessarily an intermediate the op would ever produce. It decides wording only.
	 */
	private static function sequencingRefusal(
		label: String, failure: String, slice: String, placed: Array<{ span: Span, text: String }>, oldText: String, kind: String,
		all: Bool
	): String {
		return placed.length == 0 || locate(CanonicalEdit.applyEdits(slice, placed), oldText, kind, '', all).error != null
			? failure
			: sequencedMessage(label, failure, slice, oldText, kind);
	}

	/**
	 * The refusal for a fragment that DOES match the text the placed pairs produce,
	 * split by what the ORIGINAL holds: nothing, which is the sequencing mistake and
	 * needs the locating rule spelled out; or several, which is plain ambiguity the
	 * repeated arm already knows how to resolve.
	 */
	private static function sequencedMessage(label: String, failure: String, slice: String, oldText: String, kind: String): String {
		return occurrences(slice, oldText, kind) > 0
			? '$failure. An earlier pair does leave exactly one of them standing — but every pair is located against the ORIGINAL '
				+ 'node, so that is not an occurrence this call can address'
			: '${label}the old fragment matches the text the EARLIER PAIRS produce and does not occur in the original $kind node at '
				+ 'all. Every pair is located against the ORIGINAL node — that is what keeps a payload order-independent — so a pair '
				+ 'written against an earlier pair\'s output can never match. Give that pair its own `apq patch` call, or widen the '
				+ 'earlier pair to cover both changes';
	}

	/**
	 * Locate `oldText` within `slice` — byte-exact first, then the dedented
	 * line-wise fallback — enforcing the exactly-once discipline. A failure is
	 * reported through `error` (with the multi-pair `label` prefix).
	 */
	private static function locate(slice: String, oldText: String, kind: String, label: String, all: Bool): LocateResult {
		final exact: Array<Located> = [];
		var at: Int = slice.indexOf(oldText);
		while (at >= 0) {
			exact.push({
				from: at,
				to: at + oldText.length,
				indent: '',
				dedented: false
			});
			at = slice.indexOf(oldText, at + oldText.length);
		}
		if (exact.length > 0) return !all && exact.length > 1 ? fail(repeated(label, exact.length, kind)) : { ranges: exact, error: null };
		final dedented: Array<Located> = findDedented(slice, oldText);
		final anchor: Null<String> = dedented.length == 0 ? midLineAnchor(slice, oldText) : null;
		final tail: Null<String> = dedented.length == 0 && anchor == null ? midLineTail(slice, oldText) : null;
		return if (anchor != null)
			fail(
				'${label}the old fragment does not occur in the resolved $kind node — its first line matches only the TAIL of '
				+ '"$anchor", and the whitespace-insensitive fallback anchors on WHOLE lines, so a fragment starting mid-line has '
				+ 'to match byte for byte. Widen it to whole lines (the replacement is then re-based onto that line\'s own '
				+ 'indentation) or reproduce the whitespace exactly'
			)
		else if (tail != null)
			fail(
				'${label}the old fragment does not occur in the resolved $kind node — its last line matches only the HEAD of '
				+ '"$tail", and the whitespace-insensitive fallback anchors on WHOLE lines, so a fragment ending mid-line has to '
				+ 'match byte for byte. Extend it to the end of that line (the replacement is then re-based onto the first '
				+ 'matched line\'s own indentation) or reproduce the whitespace exactly'
			)
		else if (dedented.length == 0)
			fail('${label}the old fragment does not occur in the resolved $kind node — copy it verbatim from `apq source --select`')
		else if (!all && dedented.length > 1)
			fail(repeated(label, dedented.length, kind))
		else
			{ ranges: dedented, error: null };
	}

	/**
	 * Line-wise, indentation-insensitive occurrence search — `apq source --select`
	 * prints a node DEDENTED, so a multi-line fragment copied from it does not
	 * byte-match the raw file. Each fragment line is compared trimmed against the
	 * slice's lines, and the match covers WHOLE LINES: the indentation of the line
	 * each occurrence STARTS on travels back with it, so the replacement can be
	 * re-based onto that site.
	 *
	 * Splicing at the first line's first non-whitespace byte instead — on the premise
	 * that "the writer re-indents the replacement anyway" — is what corrupted comment
	 * interiors and multi-line string literals. The writer re-indents CODE; a doc
	 * comment's ` * ` continuation and a string's bytes are content it re-emits
	 * verbatim. There the source indentation left standing BEFORE the splice point
	 * and the replacement's own indentation ADDED to it, so the first line of every
	 * such patch came out one level too deep and every gate in the project called the
	 * file clean.
	 */
	private static function findDedented(slice: String, oldText: String): Array<Located> {
		final wanted: Array<String> = [for (l in oldText.split('\n')) l.trim()];
		final lines: Array<String> = slice.split('\n');
		final offsets: Array<Int> = [];
		var acc: Int = 0;
		for (l in lines) {
			offsets.push(acc);
			acc += l.length + 1;
		}
		final found: Array<Located> = [];
		var start: Int = 0;
		while (start <= lines.length - wanted.length) {
			var ok: Bool = true;
			for (j in 0...wanted.length) if (lines[start + j].trim() != wanted[j]) {
				ok = false;
				break;
			}
			if (!ok) {
				start++;
				continue;
			}
			final last: Int = start + wanted.length - 1;
			found.push({
				from: offsets[start],
				to: offsets[last] + lines[last].length,
				indent: leadingSpace(lines[start]),
				dedented: true
			});
			// Matches cannot overlap — resume past this one so `--all` never
			// produces two edits over the same lines.
			start += wanted.length;
		}
		return found;
	}

	/**
	 * `text` re-based so its FIRST line lands at `siteIndent` — the indentation of the
	 * source line the fragment matched — and every following line shifts with it by the
	 * same amount. The inverse of the dedent `apq source --select` applied to what the
	 * caller copied, and it reads the replacement's OWN first-line indentation rather
	 * than the old fragment's, so a caller who mixed the two forms still gets the first
	 * line placed where the matched line was. A replacement already indented at least as
	 * deep as the site keeps what it was given. An EMPTY line stays empty: shifting it
	 * would only add trailing whitespace.
	 */
	private static function rebased(text: String, siteIndent: String): String {
		final lines: Array<String> = text.split('\n');
		final own: String = leadingSpace(lines[0]);
		if (own.length >= siteIndent.length) return text;
		final shift: String = siteIndent.substring(0, siteIndent.length - own.length);
		return [for (line in lines) line == '' ? line : shift + line].join('\n');
	}

	/**
	 * Postcondition: a fragment spliced into a STRING or REGEX literal has to reach the
	 * result with the SHAPE the caller wrote — the same lines, and the same indentation
	 * of each line relative to the block's first. There the bytes are the program's data
	 * and the writer re-emits them one for one, so nothing else in this project can see a
	 * corruption: `apq fmt` calls the file canonical either way, no lint rule reads a
	 * continuation prefix, and this is the only gate that class of damage has.
	 *
	 * A COMMENT used to be checked the same way and is not any more. The text this function's own comment
	 * carried — that the writer's re-base "moves every line of the run by ONE amount" — is FALSE for a
	 * comment: the writer owns a comment line's leading whitespace outright, re-indenting each line of the
	 * block onto the declaration's indent and writing the project's indent character. So a well-formed
	 * payload written with a space gutter into a tab-indented site was CORRECTED on the way through and
	 * then refused as corrupt. What a caller can still lose inside a comment survives `trim()` (the ` * `
	 * gutter, a code sample's own indentation after it) and no writer behaviour was found that changes
	 * THAT. Half an assertion with no reachable failing input is not a safety net, so the comment case
	 * leaves rather than being kept as one.
	 */
	private static function verbatimSpliceIntact(
		source: String, edits: Array<{ span: Span, text: String }>, result: String, rewrites: Null<Int>, plugin: GrammarPlugin
	): EditResult {
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		final lines: Array<String> = result.replace('\r\n', '\n').split('\n');
		for (edit in edits) {
			final wanted: Array<String> = edit.text.replace('\r\n', '\n').split('\n');
			// A single line carries no relative shape, so there is nothing to lose.
			if (wanted.length < 2) continue;
			final region: Null<LexRegionKind> = insideVerbatim(source, edit.span, regions);
			// A COMMENT is not one of them, however verbatim its TEXT is: its per-line LEADING whitespace
			// belongs to the writer, which re-indents each line of a block onto the declaration's indent.
			// This function's own doc records why asserting on that produced false refusals and no
			// reachable true one.
			if (region != StringLit && region != RegexLit) continue;
			// A range stopping mid-line leaves the rest of that line standing behind the
			// replacement, so its last line is not a whole result line to compare against.
			// The line-wise arm owns whole lines and only ends mid-line at the end of the
			// searched slice itself.
			if (!(edit.span.to >= source.length || source.charAt(edit.span.to) == '\n')) continue;
			if (!shapeSurvives(lines, wanted))
				return Err(
					'the replacement reached the result with its indentation changed line by line — it lands inside a string '
					+ 'or regex literal, where indentation is content; copy the old fragment verbatim from '
					+ '`apq source --select` so the indentation it dropped can be recovered'
				);
		}
		// `rewrites` is carried THROUGH, not dropped: this postcondition re-wraps
		// `canonicalize`'s `Ok`, and a re-wrap that forgets the count makes `patch` — the
		// default small-edit op — the one seam that absorbs the writer defect in silence.
		return Ok(result, rewrites);
	}

	/**
	 * Does `span` overlap one comment / string / regex region without reaching past it
	 * onto another LINE? A whole-line match takes bytes the token does not own with it —
	 * the matched line's indentation in front, and behind a string literal the `;` that
	 * closes the statement — so plain containment would exclude every real case. What
	 * must stay outside is a whole line of code, because that is the text the writer
	 * re-wraps, and a re-wrapped line is not a corruption the shape check can read.
	 */
	private static function insideVerbatim(source: String, span: Span, regions: Array<LexRegion>): Null<LexRegionKind> {
		for (region in regions) if (span.from < region.to && region.from < span.to) {
			final lead: String = span.from >= region.from ? '' : source.substring(span.from, region.from);
			final tail: String = span.to <= region.to ? '' : source.substring(region.to, span.to);
			if (lead.indexOf('\n') < 0 && tail.indexOf('\n') < 0) return region.kind;
		}
		return null;
	}

	/**
	 * Does `lines` hold `wanted` as a consecutive run with the same trimmed text per line
	 * and ONE shared indentation shift across the run? A blank line aligns with anything.
	 */
	private static function shapeSurvives(lines: Array<String>, wanted: Array<String>): Bool {
		for (start in 0...lines.length - wanted.length + 1) {
			var shift: Int = 0;
			var measured: Bool = false;
			var ok: Bool = true;
			for (j in 0...wanted.length) {
				final want: String = wanted[j].trim();
				if (lines[start + j].trim() != want) {
					ok = false;
					break;
				}
				if (want == '') continue;
				final delta: Int = leadingSpace(lines[start + j]).length - leadingSpace(wanted[j]).length;
				if (!measured) {
					shift = delta;
					measured = true;
				} else if (delta != shift) {
					ok = false;
					break;
				}
			}
			if (ok) return true;
		}
		return false;
	}

	/**
	 * The source line a failed fragment's FIRST line anchors inside, or `null` when
	 * that line is not a mid-line tail. Both matching arms are blind to this shape and
	 * for opposite reasons: the byte-exact arm is a substring search, so a fragment
	 * whose whitespace was reformatted anywhere misses; the dedent-tolerant arm
	 * compares TRIMMED WHOLE LINES, so a first line that is only the tail of a source
	 * line (`alpha` of `return 'alpha`) never anchors. The standing refusal then sends
	 * the caller to `apq source --select`, whose output is DEDENTED — exactly the form
	 * that cannot match — so following the advice reproduces the failure. The remedy is
	 * to widen the fragment to whole lines, which this probe exists to name; it only
	 * reports, and never produces a range to splice.
	 *
	 * `midLineTail` below is the mirror, with its own fixtures: the two
	 * probes are asked in that order and only one can answer, since an occurrence
	 * truncated at BOTH ends matches the first arm on its first line and never reaches
	 * the second.
	 */
	private static function midLineAnchor(slice: String, oldText: String): Null<String> {
		final wanted: Array<String> = [for (l in oldText.split('\n')) l.trim()];
		if (wanted.length < 2 || wanted[0] == '') return null;
		final lines: Array<String> = slice.split('\n');
		for (start in 0...lines.length - wanted.length + 1) {
			final first: String = lines[start];
			// A PROPER tail: an equal-length match is a whole line, which `findDedented` already tried.
			if (first.length <= wanted[0].length || first.substring(first.length - wanted[0].length) != wanted[0]) continue;
			var ok: Bool = true;
			for (j in 1...wanted.length) if (lines[start + j].trim() != wanted[j]) {
				ok = false;
				break;
			}
			if (ok) return first.trim();
		}
		return null;
	}

	/**
	 * The mirror probe: a fragment whose LAST line stops mid-line, so it matches only
	 * the HEAD of a source line while every line above it matches whole.
	 *
	 * The shape this exists for: a fragment copied down to
	 * `private static function rootMemoValue` — the signature's first words, cut before
	 * the parameter list — is refused by both arms for the same reason `midLineAnchor`
	 * exists, and the standing message ("copy it verbatim from `apq source --select`")
	 * describes a fragment that WAS copied verbatim, just not far enough. Nothing in it
	 * says the fallback anchors on whole lines, which is the one fact that resolves it.
	 *
	 * Reports only, like its sibling: it never produces a range to splice, because a
	 * partial-line match is exactly the ambiguity the whole-line rule exists to refuse.
	 *
	 * A deliberate limit, and why the two probes are separate rather than one: each allows
	 * a partial line at ONE end and requires every other line to match whole, so a fragment
	 * truncated at BOTH ends reaches neither and keeps the generic remedy
	 * (`testFragmentTruncatedAtBothEndsReachesNeitherProbe`). Widening either to both ends at
	 * once would have to guess which end the caller meant.
	 */
	private static function midLineTail(slice: String, oldText: String): Null<String> {
		final wanted: Array<String> = [for (l in oldText.split('\n')) l.trim()];
		final last: Int = wanted.length - 1;
		if (wanted.length < 2 || wanted[last] == '') return null;
		final lines: Array<String> = slice.split('\n');
		for (start in 0...lines.length - wanted.length + 1) {
			var ok: Bool = true;
			for (j in 0...last) if (lines[start + j].trim() != wanted[j]) {
				ok = false;
				break;
			}
			if (!ok) continue;
			final tail: String = lines[start + last].trim();
			// A PROPER head: an equal-length match is a whole line, which `findDedented` already tried.
			if (tail.length > wanted[last].length && tail.substring(0, wanted[last].length) == wanted[last]) return tail;
		}
		return null;
	}

	/**
	 * The name a declaration goes by, read through a nameless folding WRAPPER: `final class C`
	 * projects as `FinalDecl(ClassForm C)`, and its wrapper — the node a doc block sits above —
	 * carries no name of its own. Reading `node.name` alone skipped every watch on such a
	 * declaration, so a `typedef` inserted ahead of a documented `final class` took its doc at rc 0.
	 */
	private static function declName(node: QueryNode): Null<String> {
		return node.name ?? RefactorSupport.typeDeclOf(node)?.name;
	}

}

/**
 * One located occurrence of a fragment inside the searched slice: the byte
 * range `[from, to)` the replacement takes over, and how it was found.
 *
 * `indent` is the indentation of the line the occurrence STARTS on — where the
 * dedent-tolerant arm has to re-base the replacement, because it matched trimmed
 * lines and owns whole ones. `dedented` says which arm found it: the byte-exact
 * arm splices the caller's own bytes between two mid-line neighbours and
 * synthesises no indentation at all, so nothing about it needs re-basing or
 * checking. A dedent match at column 0 also has an empty `indent`, which is why
 * the arm is a flag of its own and not read off the indentation.
 */
private typedef Located = {
	from: Int,
	to: Int,
	indent: String,
	dedented: Bool
};

/**
 * What `locate` answers: the ranges it placed, or the refusal that says why it placed none.
 * Exactly one of the two carries the answer — a non-null `error` comes with an empty `ranges`
 * and discards the whole payload.
 */
private typedef LocateResult = {
	ranges: Array<Located>,
	error: Null<String>
};
