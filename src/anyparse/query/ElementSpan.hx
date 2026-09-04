package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * The bytes an ELEMENT owns, and the bytes removing it must cover. A declaration's node span
 * is narrower than the declaration: the modifier and metadata siblings project BEFORE it, the
 * documentation block is trivia above it, the trailing comment on its line is trivia after it,
 * and the line it sits alone on plus one separating blank line and one separating comma belong
 * to it too the moment it is cut.
 *
 * Every member here answers one of those two questions and nothing else, which is why the
 * DELETE core (`deleteNode` / `deleteNodes`) lives here rather than with the edit applier: a
 * deletion IS a span computation, and the canonicalisation it ends with is one call out.
 */
@:nullSafety(Strict)
final class ElementSpan {

	/**
	 * The source span of the LOGICAL declaration at `node` — a decl together
	 * with the modifier / metadata sibling nodes that precede it. Modifiers
	 * (`public` / `private` / `static` / `inline` / `override` / `macro` /
	 * `extern` / `dynamic`) and `@:meta` project to separate siblings BEFORE
	 * the decl they modify, so an edit on the whole declaration must span from
	 * the FIRST of them, and a cursor that resolves to a MODIFIER sibling
	 * targets the decl that follows it. A cursor on a `@:meta` does NOT — an
	 * annotation is an addressable element in its own right, so it keeps its own
	 * span and the forward walk is skipped; see the body for the two ops that
	 * deleted a whole class through it. Any element that is not part of a
	 * modifier-decl group (a statement, an array / call element, a package
	 * decl) keeps its own span.
	 *
	 * A modifier may also be spelled inside a `#if … #end` region, which projects
	 * as a `Conditional` sibling rather than a modifier one; `isDeclPrefixSibling`
	 * folds such a region into the run so the group still starts at the FIRST
	 * token of the declaration - see `isConditionalModifierRegion` for the
	 * corruption that stopping there produced.
	 *
	 * Shared by `add-element` (insert OUTSIDE the group), `replace-node` and
	 * `patch` (the WHOLE declaration, modifiers included) and `deleteNodes`.
	 */
	public static function declGroupSpan(node: QueryNode, parent: Null<QueryNode>, nodeSpan: Span): Span {
		if (parent == null) return nodeSpan;
		final siblings: Array<QueryNode> = parent.children;
		final i: Int = siblings.indexOf(node);
		if (i < 0) return nodeSpan;

		// An ANNOTATION is an element in its OWN right: `--select 'MetaCall:@:access'`
		// names it, `apq source --select` prints its seventeen bytes alone, and every
		// op echoes it back as the target. Walking FORWARD off it would make the span
		// the whole `[@:meta modifiers… decl]` group, so an edit addressed at the
		// ANNOTATION lands on the declaration below it — `remove-element` on a
		// module-level `@:access` deleted the annotation and the entire class (137
		// lines to 12), and `replace-node` overwrote the class with the replacement
		// annotation, both at rc 0 with a result that still parses. A bare modifier
		// keyword is NOT such an element (its own op is `set-modifier`) and the cursor
		// convention makes it the first token of the declaration it precedes, so that
		// half keeps the walk. The BACKWARD walk below is untouched: removing the decl
		// still carries its whole prefix run, annotations included.
		//
		// A consumer that wants the run START rather than the addressed element must
		// ask `declRunStart` — this function can no longer answer that for an
		// annotation, and two of them were silently getting the wrong answer.
		if (isAnnotationElement(node)) return nodeSpan;

		// The decl is the cursor node, or — when the cursor is on a modifier
		// sibling — the first following sibling that is not a prefix at all.
		var declIndex: Int = i;
		while (declIndex < siblings.length && isDeclPrefixSibling(siblings[declIndex])) declIndex++;
		if (declIndex >= siblings.length) return nodeSpan;

		// Walk back over the modifier / meta run that precedes the decl.
		var startIndex: Int = declIndex;
		while (startIndex > 0 && isDeclPrefixSibling(siblings[startIndex - 1])) startIndex--;

		// No modifier / meta run AND the cursor is the decl itself → not a
		// group; leave the span untouched (statements, list elements).
		if (startIndex == declIndex && declIndex == i) return nodeSpan;

		final startSpan: Null<Span> = siblings[startIndex].span;
		final declSpan: Null<Span> = siblings[declIndex].span;
		return startSpan == null || declSpan == null ? nodeSpan : new Span(startSpan.from, declSpan.to);
	}

	/**
	 * Remove `node` (with its modifier / meta group, via `declGroupSpan`)
	 * from `source` — the shared DELETE core, the structural inverse of
	 * `AddElement`. `parent` gives the sibling context `declGroupSpan` and
	 * the comma check need. The deletion span is the decl group, extended to
	 * swallow ONE separating comma when the slot is a comma list (a comma
	 * adjacent in source, or `parent` is a `COMMA_CONTAINER_KINDS`) — else
	 * (statement / case / member / import lists) just the group, since each
	 * element is self-terminated and the whole-file re-emit fixes residual
	 * whitespace. Funnels through `canonicalize` with an empty replacement,
	 * so the result is writer-formatted and re-parse-validated exactly like
	 * the insert ops; the source is canonical-gated unless `reformat`.
	 */
	public static function deleteNode(
		source: String, node: QueryNode, parent: Null<QueryNode>, reformat: Bool, plugin: GrammarPlugin, withDoc: Bool = true,
		?optsJson: String
	): EditResult {
		return deleteNodes(source, [{ node: node, parent: parent }], reformat, plugin, withDoc, optsJson);
	}

	/**
	 * Extend a declaration's span back over its leading doc comment, so a replace / remove
	 * can carry (or rewrite) the documentation. Scans back over whitespace from `span.from`;
	 * the block comment immediately above the node is absorbed, then the walk keeps
	 * going back ONLY across further `/**` docs — a stray duplicate left by an earlier
	 * edit — so a stacked duplicate is cleaned up as one unit while a DISTINCT preceding
	 * block comment (a licence header or section banner above the doc) is left intact.
	 * Returns the span unchanged when only whitespace or a non-comment token precedes.
	 * Line-comment (double-slash) doc runs are not handled (v1); the re-parse gate
	 * validates the result either way.
	 *
	 * Two rules decide what that FIRST block is allowed to be. A comment that does not
	 * START its own line trails the PREVIOUS declaration and is never absorbed, for any
	 * caller. And `docOnly` — passed by every caller that DELETES the region rather than
	 * carrying or replacing it — requires the first block to be a `/**` doc as well:
	 * directly above a declaration a plain block comment is a licence header or a section
	 * banner at least as often as it is documentation, and a caller that carries one loses
	 * nothing by guessing wrong while a caller that deletes it cannot get it back.
	 *
	 * Each comment's START comes from `collectCommentTokens` — the lexer's own tokenisation —
	 * never from scanning the text for an opener sequence. A block comment does not nest, so
	 * an opener written INSIDE a doc's text (a backticked example, say) is content; a scan
	 * that searched backwards for one used to cut the doc there, leaving an unterminated
	 * fragment that swallowed the next member's doc, and the same defect made `set-doc`
	 * splice its replacement mid-comment and never converge.
	 */
	public static function docExtendedSpan(source: String, span: Span, regions: Array<LexRegion>, docOnly: Bool = false): Span {
		final tokens: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(regions);
		var from: Int = span.from;
		var first: Bool = true;
		while (true) {
			var i: Int = from - 1;
			while (i >= 0 && SourceText.isSpace(source.fastCodeAt(i))) i--;
			if (i < 0) break;
			// The preceding token must be a BLOCK comment ending exactly here. Asking the
			// lexer which token that is (rather than scanning back for a `/*`) is what keeps
			// an opener written inside the doc's own TEXT from being mistaken for its start.
			final open: Int = SourceComments.commentEndingAt(tokens, i + 1, true);
			if (open < 0) break;
			// A comment sharing its line with preceding CODE trails THAT declaration —
			// `var keep:Int; /* about keep */` reads as keep's note, however adjacent it
			// looks from below — so attribution follows the line the reader sees it on.
			if (!SourceText.startsItsLine(source, open)) break;
			// A caller that DELETES what it absorbs passes `docOnly` and gets `/**` as the
			// proof, because the block directly above a declaration is a licence header or a
			// section banner at least as often as it is documentation, and deleting one of
			// those is unrecoverable. A caller that CARRIES the region (`move-member`) or
			// REPLACES it (`set-doc`) loses nothing by the generous reading and keeps it: for
			// them the first block is the declaration's own comment whatever its opener.
			// Further back the rule is `/**` for everyone — that arm exists to sweep up a
			// stacked duplicate, and a distinct block above the doc is somebody else's.
			if ((docOnly || !first) && !SourceComments.isDocOpener(source, open)) break;
			from = open;
			first = false;
		}
		return from == span.from ? span : new Span(from, span.to);
	}

	/**
	 * Cut a declaration's TRAILING trivia — whitespace and whole comment tokens —
	 * off the end of `span`, so a replace / remove / patch covers only the bytes the
	 * declaration owns.
	 *
	 * A ctor annotated `@:trailOpt` whose optional trail token is ABSENT (a `typedef`
	 * or a `final class` written without the `;`, a brace-terminated statement) ends
	 * its parse span where the parser stopped looking for that token — past the blank
	 * line and past the NEXT declaration's doc comment. The parser re-stashes that
	 * run as the following node's LEADING trivia, so the bytes belong to the
	 * neighbour; splicing over the raw span silently deleted a doc block nobody
	 * addressed, and left `Patch` able to match a fragment inside it.
	 *
	 * Each comment's start comes from `collectCommentTokens` — the lexer's own
	 * tokenisation — for the same reason `docExtendedSpan` reads it there: a `/*`
	 * written inside a comment's TEXT is content, not an opener.
	 */
	public static function trailingTrimmedSpan(source: String, span: Span, regions: () -> Array<LexRegion>): Span {
		// The loop below can only move `to` when the span's LAST byte is whitespace, or the `/` that
		// closes a block comment; anything else — `}`, `;`, `)`, an identifier byte — is the node's own
		// last token and the answer is `span` unchanged. Testing that one byte first keeps the
		// whole-file comment lex off the common path, which matters because a caller may ask once per
		// MATCH: `ast --select 'IdentExpr' --source` over `Cli.hx` asks 14337 times, and the lex is
		// O(file). Measured on that query: 23.8s -> 0.4s, with `--select 'FnMember' --source` 1.08s ->
		// 0.34s and every window byte-identical. That guard is also why `regions` is a PROVIDER rather
		// than the array every other helper here takes: an eager `plugin.lexicalRegions(source)` at the
		// call site would pay the lex the guard exists to avoid, on the same 14337 asks.
		if (span.to <= span.from || span.to > source.length) return span;
		final lastByte: Int = source.fastCodeAt(span.to - 1);
		if (!SourceText.isSpace(lastByte) && lastByte != '/'.code) return span;
		final tokens: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(regions());
		var to: Int = span.to;
		while (true) {
			var i: Int = to - 1;
			while (i >= span.from && SourceText.isSpace(source.fastCodeAt(i))) i--;
			if (i < span.from) break;
			to = i + 1;
			final open: Int = SourceComments.commentEndingAt(tokens, to, false);
			// A comment reaching back to (or past) the span's own start is the node
			// itself, not trailing trivia — leave the span alone.
			if (open <= span.from) break;
			to = open;
		}
		return to >= span.to ? span : new Span(span.from, to);
	}

	/**
	 * Extend `span` to the whole physical line when the element is ALONE on
	 * it — swallow the leading indentation (same-line whitespace back to the
	 * line start) and the trailing newline. Without this, deleting a
	 * statement / member / import leaves its line as blank whitespace, which
	 * the trivia-preserving writer keeps as an empty line. When the element
	 * shares its line with other content (it does not start AND end the line)
	 * the span is returned unchanged, so a sibling on the same line is not
	 * touched — the writer re-emit then tidies the residual spacing.
	 *
	 * See `lineDeletionSpan` below for the BACKWARD-only variant, which the case-arm deletions use.
	 */
	public static function lineExtendedSpan(source: String, span: Span): Span {
		var from: Int = span.from;
		while (from > 0) {
			final c: Int = source.fastCodeAt(from - 1);
			if (c == ' '.code || c == '\t'.code)
				from--
			else
				break;
		}
		final startsLine: Bool = from == 0 || source.fastCodeAt(from - 1) == '\n'.code;

		var to: Int = span.to;
		while (to < source.length && SourceText.isHorizontalSpace(source.fastCodeAt(to))) to++;
		final endsLine: Bool = to >= source.length || source.fastCodeAt(to) == '\n'.code;
		if (endsLine && to < source.length) to++;

		return startsLine && endsLine ? new Span(from, to) : span;
	}

	/**
	 * Give back ONE blank line when a whole-line deletion is flanked by a blank line on
	 * BOTH sides — the separator the removed declaration owned. Every member of a
	 * writer-canonical type is flanked that way, because the writer blank-separates
	 * members, so without this a member deletion turns the single blank the author wrote
	 * into a doubled run. Nothing downstream reports that: the writer re-emits the run up
	 * to `emptyLines.maxAnywhereInFile`, so the result stays writer-canonical and
	 * `fmt --list` stays clean, and no check reads blank lines. Under a config that caps
	 * the run at one the writer collapses it and the same wrong span is merely hidden —
	 * which is why the span, not the writer, is where this belongs.
	 *
	 * Flanked on ONE side only, nothing is given back, and that asymmetry is the point: a
	 * lone blank on one side is a GROUP boundary, and consuming it would move the survivor
	 * below into the group above — an edit the deletion was never asked to make. A
	 * boundary that is not a blank line counts as no blank for the same test — but do
	 * NOT read that as "the first / last member of a body is left alone". Under a config
	 * whose `classEmptyLines.beginType` / `endType` are 0 it is; under one that sets them
	 * to 1, as this project does, the brace-side gap IS a blank line and IS consumed.
	 * Those two positions come out right because `classEmptyLines` decides that gap and
	 * the writer re-normalises it either way, not because the brace reads as a boundary.
	 *
	 * A run that was ALREADY doubled stays doubled — one line back out of a pair still
	 * leaves a pair once the other side is counted. Collapsing such a run is a different
	 * edit and not a deletion's to make.
	 *
	 * Applies to a PURE deletion only, which is why it is called by `deleteNodes` and
	 * `CheckScan.deletionEdit` rather than folded into `lineExtendedSpan`: most of that
	 * helper's two dozen consumers splice replacement text into the line they widened, and
	 * giving back a separator there would swallow a line the replacement still needs. The
	 * callers are `deleteNodes`, `CheckScan.deletionEdit`, the collapsed-`if` arm of
	 * `CheckScan.ifShapeEdit`, and the three `cutSpanOf` move helpers. That is NOT every
	 * pure deletion in the tree: the statement-level check fixers (`unused-local`,
	 * `dead-code`, `self-assignment` and a dozen more) each build their own
	 * `{ span: lineExtendedSpan(…), text: '' }` inline, with no shared helper to route
	 * through, and still leave the doubled run. Auditing those is a slice of its own —
	 * they differ in what a "separator" means for a statement.
	 */
	public static function blankExtendedSpan(source: String, span: Span): Span {
		// Only a cut that owns whole lines can be flanked by lines at all: `from` must sit at a
		// line start and `to` just past a line end. That is exactly what `lineExtendedSpan`
		// produces when it extended, and never when it declined to, so this is also the test
		// that keeps a mid-line span (a comma-list element, a node sharing its line) out.
		if (span.from <= 0 || source.fastCodeAt(span.from - 1) != '\n'.code) return span;
		if (span.to <= span.from || span.to > source.length || source.fastCodeAt(span.to - 1) != '\n'.code) return span;

		// `span.from - 1` is the newline that ended the line above, so the line itself starts
		// before it; it is blank when only horizontal space separates that newline from the
		// previous one (or from the start of the file).
		var above: Int = span.from - 2;
		while (above >= 0 && SourceText.isHorizontalSpace(source.fastCodeAt(above))) above--;
		if (above >= 0 && source.fastCodeAt(above) != '\n'.code) return span;

		var below: Int = span.to;
		while (below < source.length && SourceText.isHorizontalSpace(source.fastCodeAt(below))) below++;
		// End of file is not a blank line — there is no separator left to give back.
		return below < source.length && source.fastCodeAt(below) == '\n'.code ? new Span(span.from, below + 1) : span;
	}

	/**
	 * Extend `span` BACKWARD over its own line's leading indentation and the newline before it, so
	 * deleting the result removes the whole line rather than leaving a blank one. The backward-only
	 * twin of `lineExtendedSpan`, which sweeps in BOTH directions and refuses when the element shares
	 * its line: this one takes the leading blanks unconditionally and never touches what follows, so a
	 * deletion whose caller has already proved the region behind the element is its own can hand the
	 * trailing text to the writer to re-canonicalise.
	 *
	 * It stops at the first non-whitespace, which is why each caller refuses outright when a comment
	 * stands anywhere in the region its deletion disturbs: a comment BEFORE the deleted node would
	 * survive to document whatever follows it, and one TRAILING it is trivia outside the span that the
	 * writer would re-attach elsewhere.
	 */
	public static function lineDeletionSpan(source: String, span: Span): Span {
		var from: Int = span.from;
		while (from > 0) {
			final c: Int = source.fastCodeAt(from - 1);
			if (c != ' '.code && c != '\t'.code) break;
			from--;
		}
		if (from > 0 && source.fastCodeAt(from - 1) == '\n'.code) {
			from--;
			if (from > 0 && source.fastCodeAt(from - 1) == '\r'.code) from--;
		}
		return new Span(from, span.to);
	}

	/**
	 * Is the element at `span` immediately adjacent to a `,` — the next
	 * non-whitespace byte after `span.to`, or the previous before `span.from`,
	 * is a comma? True ⇒ the element sits in a comma-separated list (catches a
	 * comma container not in `COMMA_CONTAINER_KINDS`, for any list with at
	 * least two elements). Shared by `add-element` and `deleteNode`.
	 */
	public static function adjacentToComma(source: String, span: Span): Bool {
		var i: Int = span.to;
		while (i < source.length && SourceText.isSpace(source.fastCodeAt(i))) i++;
		if (i < source.length && source.fastCodeAt(i) == ','.code) return true;

		var j: Int = span.from - 1;
		while (j >= 0 && SourceText.isSpace(source.fastCodeAt(j))) j--;
		return j >= 0 && source.fastCodeAt(j) == ','.code;
	}

	/**
	 * Remove EVERY node in `targets` from `source` in one canonicalisation — the multi-node
	 * form of `deleteNode`, which is this with a single target.
	 *
	 * One call rather than a fold of single deletions because each `deleteNode` returns
	 * REWRITTEN source: the second call would have to re-parse it and re-resolve its target,
	 * and the writer may by then have moved the very span the caller measured. Collecting the
	 * spans against ONE tree and handing them to `canonicalize` together keeps every span in
	 * the coordinate system it was computed in.
	 *
	 * That is also why OVERLAP is refused rather than tolerated. `applyEdits` splices each span
	 * independently, so a target nested inside another (a member and the region holding it, or
	 * two nested regions) makes the second splice run on coordinates the first already shifted —
	 * it deletes unrelated code, and the re-parse does not catch it because the wreckage usually
	 * still parses. A caller that means to remove a node and its container passes the CONTAINER
	 * alone. Spans widened to their line can also collide between neighbours that share a
	 * line, which the same check catches.
	 *
	 * Each cut is widened once more, over ONE flanking blank line, so the deletion gives
	 * back the separator the declaration owned (`blankExtendedSpan`). Two targets
	 * separated by exactly one blank line then produce TOUCHING spans rather than
	 * overlapping ones — the earlier cut ends where the later one begins — so a run of
	 * adjacent declarations closes to a single blank however many of them one call
	 * removes, and the disjointness check above still passes.
	 */
	public static function deleteNodes(
		source: String, targets: Array<{ node: QueryNode, parent: Null<QueryNode> }>, reformat: Bool, plugin: GrammarPlugin,
		withDoc: Bool = true, ?optsJson: String
	): EditResult {
		if (targets.length == 0) return Err('no node to remove');
		final edits: Array<{ span: Span, text: String }> = [];
		// Hoisted, and LAZY: the scan is O(file) and every target asks it of the same source, but
		// `trailingTrimmedSpan`'s one-byte guard answers most targets without needing it at all. The
		// memo is a local of this call — run-scoped by construction, never a process-lifetime cache.
		var scanned: Null<Array<LexRegion>> = null;
		final regionsOf: () -> Array<LexRegion> = () -> {
			final cached: Null<Array<LexRegion>> = scanned;
			if (cached != null) return cached;
			final fresh: Array<LexRegion> = plugin.lexicalRegions(source);
			scanned = fresh;
			return fresh;
		};
		for (target in targets) {
			final nodeSpan: Null<Span> = target.node.span;
			if (nodeSpan == null) return Err('the node to remove has no source span');
			final group: Span = trailingTrimmedSpan(source, declGroupSpan(target.node, target.parent, nodeSpan), regionsOf);
			// A declaration's doc comment is trivia OUTSIDE its node span, so the group span
			// stops short of it and the block is left in the file — where it silently becomes
			// the documentation of whatever declaration follows. Removing it WITH the node is
			// therefore the default; `withDoc = false` is the deliberate opt-out for a caller
			// that keeps the comment on purpose. The line/comma extension then runs on top.
			//
			// A `@:meta` is the exception, and it is the same defect as the forward walk
			// `declGroupSpan` no longer takes: the doc above an annotation documents the
			// DECLARATION under it, which is staying. Removing an `@:access` off a real
			// 79-line Pony class took the class's own `/** … */` with it — orphaning nothing,
			// just deleting documentation the caller never addressed.
			final span: Span = withDoc && !isAnnotationElement(target.node) ? docExtendedSpan(source, group, regionsOf(), true) : group;

			var isComma: Bool = adjacentToComma(source, span);
			final parent: Null<QueryNode> = target.parent;
			if (!isComma && parent != null) isComma = MemberKinds.COMMA_CONTAINER_KINDS.contains(parent.kind);

			// A comma list has no blank separators, so only the line branch gives one back.
			final cut: Span = isComma ? commaExtendedSpan(source, span) : blankExtendedSpan(source, lineExtendedSpan(source, span));
			edits.push({ span: cut, text: '' });
		}
		// A target nested in another — a member and the region holding it, two nested regions — is
		// dropped in favour of the outer one, which removes it anyway. `isContainedEdit` is the same
		// containment test `lint --fix` uses to keep an edit set atomic, and it already carries which
		// geometries survive `applyEdits`' right-to-left splice.
		final kept: Array<{ span: Span, text: String }> = [for (i => edit in edits) if (!CanonicalEdit.isContainedEdit(edits, i)) edit];
		final ordered: Array<{ span: Span, text: String }> = kept.copy();
		ordered.sort((a, b) -> a.span.from - b.span.from);
		// What is left must be disjoint. Node spans never partially overlap, but a span widened to
		// its whole line does when two targets share a line — splicing those would delete the shared
		// text twice over and take the survivor with it.
		for (i in 1...ordered.length) if (ordered[i].span.from < ordered[i - 1].span.to)
			return Err('the nodes to remove share a line — removing them together would delete more than the two');
		return CanonicalEdit.canonicalize(source, kept, reformat, plugin, optsJson);
	}

	/**
	 * Whether `sibling` belongs to the prefix run a declaration carries BEFORE
	 * itself - a plain modifier / `@:meta` sibling, or a conditional-modifier
	 * region (`isConditionalModifierRegion`). The walk-back test `declGroupSpan`
	 * runs in both directions.
	 */
	public static function isDeclPrefixSibling(sibling: QueryNode): Bool {
		return MemberKinds.MODIFIER_META_KINDS.contains(sibling.kind) || CondRegionScan.isConditionalModifierRegion(sibling);
	}

	/**
	 * Where the `[@:meta modifiers… decl]` run containing `node` STARTS — the
	 * backward half of `declGroupSpan`, with no forward step and no annotation
	 * exception.
	 *
	 * `declGroupSpan` cannot answer this any more. Its forward walk is conditional
	 * now, so an annotation there reports its OWN start, and the two consumers that
	 * were quietly relying on the run start broke in the same commit that narrowed
	 * it: `Patch`'s doc-orphan guard looked for a `/**` directly above the SECOND
	 * annotation of a run, found the first annotation instead, and let a
	 * doc-stealing insert through at rc 0; `set-doc` spliced its block BETWEEN the
	 * two annotations and produced the stacked pair `fragmented-doc-comment`
	 * reports. Both ask what a doc block above the run would document, and that is
	 * the run — whichever member of it the cursor happened to land on.
	 */
	public static function declRunStart(node: QueryNode, parent: Null<QueryNode>, nodeSpan: Span): Int {
		if (parent == null) return nodeSpan.from;
		final siblings: Array<QueryNode> = parent.children;
		final i: Int = siblings.indexOf(node);
		if (i < 0) return nodeSpan.from;
		var startIndex: Int = i;
		while (startIndex > 0 && isDeclPrefixSibling(siblings[startIndex - 1])) startIndex--;
		final startSpan: Null<Span> = siblings[startIndex].span;
		return startSpan == null ? nodeSpan.from : startSpan.from;
	}

	/**
	 * The span an EDIT of `node` covers, and the bytes a READ of it should hand back:
	 * `declGroupSpan` folds in the modifier / `@:meta` run the grammar projects as siblings of a
	 * declaration, then `trailingTrimmedSpan` drops the run a `@:trailOpt` decl written without its
	 * terminator swallows past its own closing brace.
	 *
	 * ONE spelling, because the promise the ops make is that they agree byte-for-byte:
	 * `replace-node` overwrites this, `patch` searches inside it, `apq source --select` prints it
	 * widened to whole lines, and `ast --select --source` prints it exactly. Four hand-copies of
	 * the two calls made that promise prose; a fifth read the bare node span and the two reads of
	 * one declaration disagreed, which is what let a replacement copied out of one of them drop the
	 * declaration's `@:keep` at rc 0.
	 *
	 * `MoveSymbol` and `removeElement` still call the two halves themselves: the first needs the
	 * UNTRIMMED group end and the modifier run separately, the second already holds the parent.
	 */
	public static function declEditSpan(
		source: String, tree: QueryNode, node: QueryNode, nodeSpan: Span, regions: () -> Array<LexRegion>
	): Span {
		return trailingTrimmedSpan(source, declGroupSpan(node, TreePath.parentOf(tree, node), nodeSpan), regions);
	}

	/**
	 * Is `node` an ANNOTATION — an element a caller addresses in its own right, as
	 * opposed to a bare modifier keyword whose only meaning is the declaration it
	 * precedes? A `@:meta` is one, and so is a `#if … #end` region holding nothing
	 * but annotations: the grammar's own `HxMetadata` enum counts `Conditional`
	 * among its FOUR metadata forms, and `remove-element --select 'Conditional'` on
	 * `#if debug @:access(foo.Bar) #end` above a class emptied the whole file at
	 * rc 0. A region holding a MODIFIER is deliberately NOT one — `#if debug public
	 * #end` reads as the declaration's first token exactly like a bare `public`.
	 *
	 * `META_KINDS`'s third member, `PlainMeta`, is UNPINNED and unpinnable: it is
	 * the enum's declared fallthrough for spellings the structural branches cannot
	 * claim, and every spelling `HxMetaRaw`'s own doc names as its reason to exist
	 * — a string embedding parens, four levels of nesting, a dotted name, a
	 * colon-less `@name` — parses as `MetaCall` or `Meta` today. Dropping it from
	 * the set flips nothing in 13266 tests; dropping `MetaCall` flips four. It stays
	 * for grammar-completeness, not for coverage.
	 */
	private static function isAnnotationElement(node: QueryNode): Bool {
		return MemberKinds.META_KINDS.contains(node.kind)
			|| (node.kind == MemberKinds.CONDITIONAL_REGION_KIND && node.children.length > 0
				&& node.children.foreach(c -> MemberKinds.META_KINDS.contains(c.kind)));
	}

	/**
	 * Extend `span` to also remove ONE separating comma so a comma list stays
	 * well-formed after the element is cut: the trailing comma (preferred) —
	 * the next non-whitespace byte after `span.to` — else the leading comma
	 * before `span.from` (the element was last). A single-element list has
	 * neither and the span is returned unchanged (`[a]` → `[]`). Surrounding
	 * whitespace is left to the writer re-emit.
	 */
	private static function commaExtendedSpan(source: String, span: Span): Span {
		var i: Int = span.to;
		while (i < source.length && SourceText.isSpace(source.fastCodeAt(i))) i++;
		if (i < source.length && source.fastCodeAt(i) == ','.code) return new Span(span.from, i + 1);

		var j: Int = span.from - 1;
		while (j >= 0 && SourceText.isSpace(source.fastCodeAt(j))) j--;
		return j >= 0 && source.fastCodeAt(j) == ','.code ? new Span(j, span.to) : span;
	}

}
