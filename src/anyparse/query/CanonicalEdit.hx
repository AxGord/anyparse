package anyparse.query;

import anyparse.format.comment.CommentLossException;
import anyparse.query.FormatFixedPoint.FormatFixedPointResult;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * Applying a set of source edits and handing the result back CANONICAL — the finalize half of
 * every structural mutation. `applyEdits` is the splice; `canonicalize` is the writer round
 * trip that makes inserted code obey the grammar's own formatting rules; `editKeepingCanonical`
 * is the canonical-in / canonical-out contract for the span-splice ops that emit no new syntax;
 * `stageCrossFileRename` is the all-or-nothing multi-file form.
 *
 * The guards belong here too, because they are conditions on an edit SET rather than on any one
 * edit: `dropContainedEdits` and `editsOverlapAny` keep a batch from spliceing nested or
 * overlapping spans, `docSplittingEdit` is the doc-attribution refusal the re-parse gate cannot see — an
 * insertion between a documentation block and the declaration it documents re-parses perfectly
 * and silently reassigns the doc — and `CommentOwnerGuard` is its sibling on the replacement
 * side, refusing an edit that welds two comment blocks together by deleting the code that stood
 * between them and — for an edit that DECLARES what it quotes verbatim (`CarriedEdit`) — one that
 * moves a comment across code it kept.
 */
@:nullSafety(Strict)
final class CanonicalEdit {

	/**
	 * Apply a set of source edits, end-to-start. Edits are sorted
	 * descending by `span.from` and spliced from the highest offset down,
	 * so each splice leaves all lower offsets valid. Two edits at ONE offset are ordered by span
	 * WIDTH, widest first, because a zero-width insert applied before the removal it shares an
	 * offset with splices its text into the range that removal is about to take — and `Array.sort`
	 * is documented as NOT stable, so array order cannot be the tie-break even where a target
	 * happens to give it (js does, `java/_std/Array.hx` quicksorts). The caller guarantees the edits
	 * do not overlap. Each edit replaces `[span.from, span.to)`
	 * with `text` (empty `text` deletes the range). Generalises the
	 * splice loop both refactoring operations need.
	 */
	public static function applyEdits(source: String, edits: Array<{ span: Span, text: String }>): String {
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from != a.span.from ? b.span.from - a.span.from : b.span.to - a.span.to);
		var result: String = source;
		for (edit in sorted) result = result.substring(0, edit.span.from) + edit.text + result.substring(edit.span.to);
		return result;
	}

	/**
	 * Finalize a structural mutation through the WRITER, so inserted /
	 * replaced code is formatted by the grammar's own rules rather than
	 * kept as-is. The shared tail of `AddMember` / `AddImport` /
	 * `ReplaceNode`:
	 *
	 *  1. Canonical gate — unless `reformat`, the source must already be
	 *     writer-canonical (`writeRoundTrip(source) == source`). A
	 *     non-canonical file is refused, because a whole-file rewrite would
	 *     also reflow its unrelated hand-wrapping into a surprise diff. The
	 *     mutation commands' `--reformat` opts into that canonicalisation;
	 *     `lint --fix` — which shares this gate — has no such flag, so the
	 *     refusal message leads with `apq fmt --write`, the remedy every
	 *     caller's user can reach.
	 *  2. Splice the caller's edits (raw text) into the source.
	 *  3. Re-emit the WHOLE spliced file through `writeRoundTrip` (the
	 *     trivia / comment-preserving pipeline) until the output stops
	 *     changing — `FormatFixedPoint.run`, the loop `apq fmt` owns. This
	 *     BOTH validates (an unparseable splice throws → `Err`) AND
	 *     canonically formats the inserted code together with the rest of
	 *     the file. It is the FIXED POINT rather than one round trip because
	 *     the gate in step 1 is a ONE-pass test and the next op applies it to
	 *     what this one wrote; a spliced file the writer settles only on its
	 *     second rewrite would pass out of here and be refused there. A file
	 *     that never settles is a fourth `Err` — the bytes are left alone
	 *     rather than churned.
	 *
	 * The caller supplies only the edit position + raw text; indentation
	 * and layout of the result are the writer's job. Requires a grammar
	 * with a writer (`writeRoundTrip` non-null); a writer-less grammar is
	 * refused.
	 *
	 * `optsJson` is the project's writer-config JSON (an `hxformat.json`
	 * discovered near the edited file); passed to EVERY `writeRoundTrip` call —
	 * the canonical gate's one and each pass of the fixed-point loop — so the
	 * gate and the result agree on the project style. `null` → the plugin's
	 * compiled defaults.
	 */
	public static function canonicalize(
		source: String, edits: Array<{ span: Span, text: String }>, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String,
		?carried: Array<CarriedEdit>
	): EditResult {
		if (!reformat) {
			final canon: Null<String> =
				try plugin.writeRoundTrip(source, optsJson) catch (exception: ParseError) return Err('source does not parse: $exception')
				catch (exception: CommentLossException) return Err(
					'this file cannot be rewritten without losing the comment `${exception.comment}`'
				)
				catch (exception: Exception) return Err('source does not parse: ${exception.message}');
			if (canon == null) return Err('the "${plugin.langName()}" grammar has no writer — cannot writer-format the result');
			// The remedy names `apq fmt --write` FIRST and `--reformat` only as a
			// conditional: this gate is shared with `lint --fix`, which has no
			// `--reformat` flag, and an unconditional "re-run with --reformat" sent that
			// user after a flag their command rejects.
			if (canon != source)
				return Err(
					'file is not in canonical form — format it first ('
					+ '`apq fmt --write <file>`); a command that accepts `--reformat` can canonicalise the whole file in place instead'
				);
		}

		// A re-parse gate cannot see a deletion that empties a brace-less construct's body
		// slot: the result parses, because the construct pulls the FOLLOWING statement in.
		// Measured — `remove-element` on the body of `if (flag) log.push("in-branch");` wrote
		// `if (flag) log.push("after");` and reported success, and `lint --fix`'s
		// `unused-local` reached the same result from `if (c) var y: Int = 1;`. Both compile.
		// This is the ONLY structural question the gate asks, and it is asked HERE because
		// every writer-emit op and every `--fix` wave funnels through this one function.
		final emptied: Null<String> = BodySlotGuard.emptiedSlot(source, edits, plugin);
		if (emptied != null) return Err(emptied);

		// The second question, asked here for the same reason as the first: a doc
		// comment re-attributed by an insert survives every gate this project owns —
		// the result parses, it is byte-canonical, and no lint rule reads a comment's
		// owner. `add-element --before` did exactly that for as long as it has
		// existed, and the loss was found by a human re-reading a file, not by a run.
		//
		// "Every writer-emit op" is the seventeen that reach a write THROUGH here —
		// every addressed op, plus both `lint --fix` paths and `FixVerifier`. S50 wrote
		// down that the whole MOVE and EXTRACT family bypasses this; S51 measured it and
		// found that wrong. `ExtractInterface`, `ExtractSuperclass` and
		// `IntroduceParameterObject` reach here through `editKeepingCanonical`, and
		// `NewFile` has no edit list to ask about — it round-trips a whole file. The
		// three that genuinely splice with `applyEdits` and never arrive are
		// `MoveMember`, `MoveSymbol` (`apq move`) and `InheritanceMove`
		// (pull-up / push-down).
		//
		// The question finds nothing on either side, and that is a fact about the
		// OFFSETS rather than the routing: every insertion that family makes lands at the
		// end of a member list or at the end of the module, so the byte after it is a `}`
		// or EOF and the positive criterion below never fires.
		// `unit.query.MoveExtractDocCensusTest` pins that by outcome, per op, so an offset
		// change is what flips it.
		//
		// One real limit, in `editKeepingCanonical` rather than here: on a source that is
		// NOT writer-canonical it answers `Ok(applyEdits(...))` on the `Err` path, so a
		// refusal this function returns — this one included — is discarded for those
		// three callers. The guard is advisory on a drifted file.
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		final splitDoc: Null<String> = docSplittingEdit(source, edits, regions);
		if (splitDoc != null) return Err(splitDoc);

		final spliced: String = applyEdits(source, edits);

		// The third question, and the last thing this seam can ask that the re-parse cannot: a
		// comment left standing above code it never documented. `docSplittingEdit` above covers the
		// INSERT that steals a doc; this covers the REPLACEMENT that hoists a comment past the
		// statement it explains, which is what `prefer-ternary-return`'s march up a guard cascade did
		// to this repo's own `MemberOrder.reorderRefusal` — two per-gate explanations stacked above a
		// seven-level ternary pyramid, one of them the note warning against that transformation.
		// Asked on the SPLICE rather than the settled text: the writer re-emits a comment interior
		// verbatim and never moves one across code, so the fixed-point loop below can only re-indent
		// what this already judged.
		final detached: Null<String> = CommentOwnerGuard.detachedComment(source, edits, spliced, regions, plugin);
		if (detached != null) return Err(detached);

		// The fourth question, and the one that needs the caller's COOPERATION: an edit that
		// quotes source fragments verbatim and moves a comment across one of them. The three
		// above are decidable from the two texts; this one is not, because an in-place rewrite
		// changes the same bytes a hoist does — so the edit has to declare what it carried, and
		// only an edit that does gets the answer. Every other caller passes nothing and is judged
		// exactly as before.
		final hoisted: Null<String> = carried == null ? null : CommentOwnerGuard.hoistedComment(source, edits, carried, regions);
		if (hoisted != null) return Err(hoisted);

		// ω-canonical-fixed-point: the result has to satisfy the gate the NEXT
		// writer-emit op puts on it, and that gate is `writeRoundTrip(s) == s`
		// after ONE pass. The writer does not always land there in one: a wrap
		// decision that reads the source line layout the writer itself rewrote
		// needs two, which is why `apq fmt` loops and warns. A single round trip
		// here therefore reported `wrote <file>` and left a file its own
		// `fmt --list` immediately called drifted — measured on Pony's
		// `tools/src/module/Unpack.hx` under its committed `hxformat.json`:
		// `apq add-member --reformat` succeeded, and the very next `add-member`
		// on the same file refused with `file is not in canonical form`.
		//
		// So the result goes through the SAME loop `fmt` uses, and refuses the same
		// way: a result that never settles is an error, not a written file — and it
		// reports the same way too: `Ok` carries `rewrites`, so a caller that wrote a
		// file the writer needed two passes to settle can say so in `fmt`'s own words
		// (`FormatFixedPoint.rewritesNote`). That half used to be MUTE, because
		// `EditResult.Ok` had nowhere to carry a count; the argument is optional, so
		// the ~280 sites that match `Ok(text)` never noticed it arrive.
		//
		// BYTE-INERT, not free. The output is identical wherever the writer already
		// converges, but the confirming pass is not skipped there: `run` short-cuts
		// only when its input is ALREADY canonical, and the spliced text never is —
		// that is what makes it spliced. (With an EMPTY edit set it can be: `applyEdits`
		// hands back `source` unchanged, so a canonical source takes the short-cut and
		// answers `rewrites: 0`. That is the shape the unit tests drive.) Measured on
		// this tree's 3 800-line `RefactorSupport.hx`, `apq add-member` went 700 ms to
		// 850 ms, +21%. No
		// cheap early-out exists, because the second pass IS the proof and the
		// gate's own round trip above says nothing about the splice.
		//
		// The `!reformat` gate above stays ONE pass, and the reason is cost, not
		// disagreement: a source that passes it is by definition a fixed point
		// (`writeRoundTrip(source) == source` is exactly `run`'s pass-1 short-cut),
		// so looping there would answer the same and buy a round trip.
		final fixedPoint: FormatFixedPointResult = try FormatFixedPoint.run(
			text -> plugin.writeRoundTrip(text, optsJson), spliced
		) catch (exception: ParseError) return Err('result does not parse: $exception')
		catch (exception: CommentLossException) return Err(
			'the edit cannot be applied without losing the comment `${exception.comment}` (it may sit anywhere in the file)'
		)
		catch (exception: Exception) return Err('result does not parse: ${exception.message}');
		final settled: Null<String> = fixedPoint.text;
		return if (settled == null)
			Err('the "${plugin.langName()}" grammar has no writer — cannot writer-format the result')
		else if (fixedPoint.converged)
			Ok(settled, fixedPoint.rewrites)
		else
			// Names the WRITER, because the user has no move that fixes this: `apq fmt
			// --write` refuses the same file for the same reason, so pointing at it —
			// the remedy the gate above offers — would send them in a circle.
			Err(
				'the writer cannot settle this file, so the edit was not written (${fixedPoint.failure})'
				+ ' — edit it with ordinary tools and report the construct'
			);
	}

	/**
	 * Splice `edits` into `source` and hand back the result CANONICAL — but only when
	 * `source` was already the writer's fixed point.
	 *
	 * The contract every writer-EMIT op states and the span-splice ops never did:
	 * canonical in, canonical out. A format-preserving op that only moves bytes can
	 * still leave a canonical file drifted, because the splice changes what the writer
	 * would have decided — ` implements IFoo` pushes a class header past the line limit
	 * and the writer would have wrapped it there. So a canonical input goes through
	 * `canonicalize`, the same fixed-point loop the file such an op CREATES already
	 * gets, and a drifted input keeps the plain splice: reformatting a file the user
	 * never formatted is not a span-splice op's business, and refusing it would decline
	 * work these ops have always done.
	 *
	 * A refusal about the RESULT — an emptied body slot, a parse failure, a comment
	 * loss, a splice the writer cannot settle — propagates as `Err`. A source the
	 * writer cannot round-trip AT ALL falls back to the splice like a merely-drifted
	 * one, because `isWriterCanonical` catches and answers `false` for it: that is the
	 * pre-existing behaviour of these ops and this helper does not narrow it.
	 * `isWriterCanonical` re-asks the input gate rather than matching on the message
	 * text, which would break the day the wording changes.
	 */
	public static function editKeepingCanonical(
		source: String, edits: Array<{ span: Span, text: String }>, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		return switch canonicalize(source, edits, false, plugin, optsJson) {
			case Ok(text, rewrites):
				Ok(text, rewrites);
			// The FALLBACK below carries no `rewrites` argument: the writer loop never ran on
			// that path, and `null` is what `EditResult.Ok` documents for it. A `0` would read
			// as a measurement.
			case Err(message): isWriterCanonical(source, plugin, optsJson) ? Err(message) : Ok(applyEdits(source, edits));
		};
	}

	/**
	 * Does `source` already satisfy the one-pass canonical gate `canonicalize` puts on
	 * its input?
	 *
	 * `false` means the writer does not agree this source is already its output — either
	 * because it is drifted, or because it cannot round-trip the source at all (a parse
	 * failure, a comment loss, a grammar with no writer: the `catch` answers `false` for
	 * every one). Either way the refusal is about the TREE and says nothing about an
	 * edit. `true` means the input passed that gate, so a `canonicalize` refusal is
	 * about the RESULT — an emptied body slot, a splice that does not parse, a splice
	 * the writer cannot settle.
	 *
	 * Two consumers read it with OPPOSITE consequences and both are correct, because it
	 * is a factual query and not a safety veto: `editKeepingCanonical` reads `false` as
	 * "proceed with the plain splice", `FixVerifier.verifyEntry` reads it as "this
	 * verdict is not the check's to own" (`SourceNotCanonical`). Asked by re-running
	 * the gate rather than by matching on the message text, which would break the day
	 * the wording changes.
	 */
	public static function isWriterCanonical(source: String, plugin: GrammarPlugin, ?optsJson: String): Bool {
		return try plugin.writeRoundTrip(source, optsJson) == source catch (_: Exception) false;
	}

	/**
	 * Stage a cross-file rename all-or-nothing: canonicalize each file's edit
	 * `slice` through `canon` and return every file's rewritten source ONLY when
	 * EVERY slice canonicalizes to a genuinely-changed result. Any `Err`, any
	 * missing source (`sourceOf` returns null), or any no-op slice reverts the
	 * WHOLE set (returns null) — the multi-file counterpart of a single
	 * `canonicalize`, so a partial application can never reach disk. Pure:
	 * `sourceOf` supplies each file's current source and `canon` performs the
	 * per-file canonicalization (`file, source, edits`), both injected by the
	 * caller.
	 */
	public static function stageCrossFileRename(
		slices: Array<{ file: String, edits: Array<{ span: Span, text: String }> }>, sourceOf: (String) -> Null<String>,
		canon: (String, String, Array<{ span: Span, text: String }>) -> EditResult
	): Null<Array<{ file: String, source: String }>> {
		final out: Array<{ file: String, source: String }> = [];
		for (slice in slices) {
			final src: Null<String> = sourceOf(slice.file);
			if (src == null) return null;
			switch canon(slice.file, src, slice.edits) {
				case Ok(text):
					if (text == src) return null;
					out.push({ file: slice.file, source: text });
				case Err(_):
					return null;
			}
		}
		return out.length == 0 ? null : out;
	}

	/**
	 * The doc-attribution invariant every writer-emit op passes through, and the
	 * ONE thing the re-parse gate cannot see: a `/**` block documents the next LINE
	 * of code, so an edit that inserts a new line of code between the two hands the
	 * documentation to the insertion and leaves the declaration bare. The result
	 * parses, it is byte-canonical, `fmt --list` is clean and every lint rule is
	 * silent — the loss shows up only when a human reads the file again.
	 *
	 * Only a ZERO-WIDTH insertion can do it. An edit that COVERS text owns what it
	 * covers: `set-doc` replaces the block, `comment-rewrite` splices inside it,
	 * `remove-element --keep-doc` deliberately leaves it behind, and a `rename`
	 * over a doc'd member rewrites the very line the doc points at. Requiring a
	 * line break in the inserted text is what separates the two remaining
	 * insertion shapes: `add-element` splices a whole element and always carries
	 * one, while a fixer that prepends a modifier (`private `) stays on the
	 * owner's own line and changes nothing about who is documented.
	 *
	 * Returns the refusal message, or null when no edit splits a doc from its owner.
	 * The backward half is `docExtendedSpan` itself, not a copy of its walk: that
	 * function IS the attribution rule this enforces, so asking it is what keeps the
	 * two from drifting — an earlier draft re-implemented the walk and had already
	 * lost its chain arm.
	 */
	public static function docSplittingEdit(
		source: String, edits: Array<{ span: Span, text: String }>, regions: Array<LexRegion>
	): Null<String> {
		for (edit in edits) {
			final at: Int = edit.span.from;
			// Ordered cheapest-first on purpose: the two span/text tests are free, and
			// `docExtendedSpan` lexes the whole file. `canonicalize` is called once per
			// file per `lint --fix` pass with an EMPTY edit set, and this must not make
			// that call pay for a lex.
			if (edit.span.to != at || edit.text.indexOf('\n') < 0 || edit.text.trim().length == 0) continue;
			if (ElementSpan.docExtendedSpan(source, new Span(at, at), regions, true).from == at) continue;
			var j: Int = at;
			while (j < source.length && SourceText.isSpace(source.fastCodeAt(j))) j++;
			// A POSITIVE criterion, because the harmful side is open-ended: a doc can
			// only be stolen from something a doc can document, and a declaration opens
			// with a word, an annotation or a directive in every grammar this tool has.
			// Everything else — end of file, and the byte that CLOSES the body a block
			// was left orphaned inside — steals nothing. That second case is not
			// hypothetical: `add-member` appends before the closer, and refusing there
			// blocked a real file of this repo (`src/anyparse/check/PreferReadOnlyField.hx`,
			// which ends on an orphaned `/** … */`) with a remedy `add-member` cannot
			// perform — it has no addressing options at all.
			final next: Int = j >= source.length ? -1 : source.fastCodeAt(j);
			if (!SourceText.isIdentStartChar(next) && next != '@'.code && next != '#'.code) continue;
			final eol: Int = source.indexOf('\n', j);
			final owner: String = (eol < 0 ? source.substring(j) : source.substring(j, eol)).trim();
			final shown: String = owner.length <= SourceText.REGION_EXCERPT_CHARS
				? owner
				: '${owner.substr(0, SourceText.REGION_EXCERPT_CHARS)}…';
			return 'the insert would land between a doc comment and "$shown", the declaration it documents, so the doc would '
				+ 'document the insert instead — anchor it on the doc\'s own opener, or on the previous sibling.';
		}
		return null;
	}

	/**
	 * Drop every edit whose span is fully contained in another edit's span,
	 * keeping the outer (larger) one. Span-deletion edits from independent sources
	 * — several checks batched by `apq lint --fix`, or one check's nested findings
	 * (a dead run inside a dead run) — can nest; applying nested deletions blindly
	 * corrupts the source. Removing the contained edit is correct for deletions:
	 * the outer deletion already subsumes it. Equal spans keep the earliest index.
	 */
	public static function dropContainedEdits(edits: Array<{ span: Span, text: String }>): Array<{ span: Span, text: String }> {
		return [for (i in 0...edits.length) if (!isContainedEdit(edits, i)) edits[i]];
	}

	/**
	 * Whether any edit in `candidate` overlaps (intersects) any edit in `accepted` —
	 * the cross-check guard the `--fix` loop uses to keep a check's edits atomic. A
	 * check whose edits intersect an already-accepted check's edits is deferred whole
	 * to the next fixed-point pass, so a partial application (e.g. a signature edit
	 * without its matching call-site edit) can never land.
	 */
	public static function editsOverlapAny(
		candidate: Array<{ span: Span, text: String }>, accepted: Array<{ span: Span, text: String }>
	): Bool {
		return candidate.exists(c -> accepted.exists(a -> c.span.from < a.span.to && a.span.from < c.span.to));
	}

	/** True when `edits[i]` is contained in another edit (the outer one is kept). */
	public static function isContainedEdit(edits: Array<{ span: Span, text: String }>, i: Int): Bool {
		final e: Span = edits[i].span;
		// A zero-length edit is an INSERT, not a rewrite of existing bytes. The ONE
		// geometry that composes safely through `applyEdits`' right-to-left splice —
		// verified on neko/js/interp — is an insert AT another edit's `.to` (right
		// after a deleted region: the observed prefer-static-extension `using` insert
		// at the boundary of unused-import's delete, which the old unconditional
		// containment test dropped, breaking the check's atomic edit set). The unsafe
		// geometries keep the old drop: strictly INSIDE a span (the splice corrupts —
		// the insert text vanishes and trailing deleted bytes leak back), AT a span's
		// `.from` (splice order diverges across targets), and a same-point tie with an
		// earlier insert (relative order is sort-stability-dependent).
		if (e.from == e.to) {
			for (j in 0...edits.length) if (j != i) {
				final o: Span = edits[j].span;
				if (o.from < o.to && o.from <= e.from && e.from < o.to) return true;
				if (o.from == o.to && o.from == e.from && j < i) return true;
			}
			return false;
		}
		for (j in 0...edits.length) if (j != i) {
			final o: Span = edits[j].span;
			final contains: Bool = o.from <= e.from && e.to <= o.to;
			final strictlyBigger: Bool = o.from < e.from || e.to < o.to;
			if (contains && (strictlyBigger || j < i)) return true;
		}
		return false;
	}

}

/**
 * Outcome of a source-mutation operation: `Ok` carries the rewritten source
 * and, when the producer measured one, how many writer round trips the
 * finalise took (`rewrites`); `Err` a human-readable diagnostic. Shared by
 * the structural INSERT / REPLACE ops (`AddMember` / `AddImport` /
 * `ReplaceNode`), which all funnel their finalize through
 * `RefactorSupport.canonicalize` and therefore return the same shape.
 *
 * `rewrites` is `null` from any producer that never ran the writer loop — an
 * `Ok` built straight from a splice — and the argument is OPTIONAL so the
 * ~280 `case Ok(text)` sites that do not care keep matching unchanged. A
 * value above 1 says the WRITER needed a second pass on this content, which
 * is the defect `apq fmt` reports and every mutation op used to swallow: the
 * op wrote a file its own `fmt --list` would call drifted, and nobody was
 * told.
 */
enum EditResult {

	Ok(text: String, ?rewrites: Int);
	Err(message: String);

}

/**
 * One edit's VERBATIM CARRY: the source ranges whose text that edit's replacement quotes byte
 * for byte. `edit` is the span of the edit this describes — the edits reaching one
 * `canonicalize` are pairwise disjoint, so a span identifies one across any filtering or
 * reordering the caller does between building the declaration and making the call — and
 * `spans` are the carried ranges IN THE ORDER THEY APPEAR IN THE REPLACEMENT, which is what
 * lets the guard locate them by a single left-to-right scan instead of guessing.
 *
 * Why an edit has to SAY this rather than have it derived: a replacement is text, and the
 * question `CommentOwnerGuard.hoistedComment` asks — did a comment move across code that
 * SURVIVED — is not decidable from the two texts, because an ordinary in-place rewrite changes
 * the same bytes an out-of-order one does. The declaration is what tells the two apart, and it
 * is cheap exactly where it matters: a fix that assembles its replacement out of source
 * fragments already holds those spans (`PreferTernaryReturn.buildEdit` passes the same three to
 * `preservedComments`), while a fix that emits fresh syntax carries nothing and declares
 * nothing.
 *
 * Purely OPT-IN, and inert without a declaration: an edit set that declares no carry is judged
 * exactly as it was before this type existed.
 */
typedef CarriedEdit = {
	final edit: Span;
	final spans: Array<Span>;
}
