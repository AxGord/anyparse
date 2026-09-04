package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.LexicalRegions.LexRegionKind;
import anyparse.query.ReplaceNode.ReplaceTarget;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

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
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err('source does not parse: $exception')
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

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
			final located: { ranges: Array<Located>, error: Null<String> } = locate(slice, oldText, node.kind, label, all);
			final failure: Null<String> = located.error;
			if (failure != null) return Err(discarded(sequencingRefusal(label, failure, slice, placed, oldText, node.kind, all), multi));
			for (r in located.ranges) {
				final edit: { span: Span, text: String } = {
					span: new Span(groupSpan.from + r.from, groupSpan.from + r.to),
					text: r.dedented ? rebased(pairs[i].newText, r.indent) : pairs[i].newText
				};
				edits.push(edit);
				placed.push({ span: new Span(r.from, r.to), text: edit.text });
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

	private static inline function fail(message: String): { ranges: Array<Located>, error: Null<String> } {
		return { ranges: [], error: message };
	}

	/** The leading horizontal whitespace of `line` — the indentation a dedented fragment dropped. */
	private static inline function leadingSpace(line: String): String {
		return line.substring(0, line.length - line.ltrim().length);
	}

	/**
	 * Why this pair would ORPHAN a doc comment, or null when it would not.
	 *
	 * A declaration's `/** ... *\/` is trivia BEFORE its node, so a fragment copied from
	 * `apq source --select` starts at the declaration KEYWORD and the doc sits above the
	 * match. A payload that keeps that declaration and puts a NEW one ahead of it therefore
	 * splices between the doc and what it documents: the doc silently transfers to the
	 * insertion and the documented declaration is left bare. `apq patch` reported `wrote
	 * <file>`, the build stayed green, and no gate in this project could see it — the writer
	 * re-emits the comment verbatim and `fragmented-doc-comment` only fires when the
	 * insertion happens to carry a doc of its own.
	 *
	 * The shape is exact, so the refusal is: an ATTACHED `/**` block ends directly above the
	 * match (`RefactorSupport.docExtendedSpan`, the same attachment model `set-doc` and
	 * `move-member` use — a plain banner comment is not a doc and never triggers this), and
	 * the new text still holds the old fragment's opening line but no longer OPENS with it.
	 * An ordinary in-place edit does not repeat that line ahead of itself, and a payload that
	 * drops the line entirely is replacing the declaration the doc belongs to, which is not an
	 * orphan.
	 *
	 * The remedy in the message is verified, not suggested: widening the old fragment upward
	 * to include the doc block makes the doc part of the match, so it travels with the
	 * declaration and the insertion lands above the whole unit.
	 */
	private static function docOrphanRefusal(
		source: String, tree: QueryNode, sorted: Array<{ span: Span, text: String }>, plugin: GrammarPlugin
	): Null<String> {
		// ONE lexical pass for the whole call. `docExtendedSpan` re-lexes the file on every call, and
		// asking it per edit cost ~19% on a 17 000-line file with 135 ranges under `--all`.
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(plugin.lexicalRegions(source));
		final watched: Array<{ shifted: Int, owner: String, declared: Int }> = [];
		var delta: Int = 0;
		for (edit in sorted) {
			final end: Int = docBlockEnd(source, comments, declGroupStart(source, tree, edit.span.from));
			if (end >= 0) {
				final node: Null<QueryNode> = docOwnerNode(source, tree, comments, end);
				final owner: Null<String> = node?.name;
				if (node != null && owner != null)
					watched.push({ shifted: end + delta, owner: owner, declared: declSiblingCount(tree, node) });
			}
			delta += edit.text.length - (edit.span.to - edit.span.from);
		}
		if (watched.length == 0) return null;

		final spliced: String = CanonicalEdit.applyEdits(source, sorted);
		final after: QueryNode = try plugin.parseFile(spliced) catch (exception: Exception) return null;
		final splicedComments: Array<{ from: Int, to: Int, isLine: Bool }> =
			SourceComments.collectCommentTokens(plugin.lexicalRegions(spliced));
		for (w in watched) {
			final ownerNode: Null<QueryNode> = docOwnerNode(spliced, after, splicedComments, w.shifted);
			if (ownerNode == null) continue;
			final owner: QueryNode = ownerNode;
			final now: Null<String> = owner.name;
			// A RENAME of the documented declaration reaches this point by construction —
			// the doc's owner name changed because the declaration was renamed, not because
			// a new one was pushed between them — and refusing it made `patch` decline the
			// single most ordinary edit a documented member ever gets. Two independent
			// signals separate it from a TRANSFER, and each covers the other's hole:
			//
			// - `siblingDeclares`: a transfer leaves the original declaration standing
			//   beside the insertion, so BOTH names survive in the container.
			// - the container GREW: a transfer adds a declaration, a rename does not. This
			//   half is what catches the COMPOUND payload that inserts a declaration AND
			//   renames the one it stole the doc from — there the old name is gone, so the
			//   name test alone reads it as a rename and lets the theft through at rc 0.
			//
			// A payload that renames the documented declaration and adds an unrelated one to
			// the same container in one call is refused by the second signal even though
			// nothing was orphaned. That is the conservative side of a guard whose whole
			// purpose is to refuse, and the refusal's own remedy — widen the fragment over
			// the doc block — applies unchanged.
			final grew: Bool = w.declared >= 0 && declSiblingCount(after, owner) > w.declared;
			if (now != null && now != w.owner && (siblingDeclares(after, owner, w.owner) || grew))
				return 'the edit moves the `/**` block above `${w.owner}` onto `$now` — the doc would '
					+ 'silently transfer to the insertion and `${w.owner}` would be left undocumented. Widen the old fragment upward to '
					+ 'include the doc block and repeat it in the replacement, so the doc travels with the declaration it documents; a '
					+ 'declaration\'s doc is trivia OUTSIDE its node, so that widening needs an address that contains it — the enclosing '
					+ '`--select \'ClassDecl:<Type>\'`, not the member itself';
		}
		return null;
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
	private static function declGroupStart(source: String, tree: QueryNode, at: Int): Int {
		var from: Int = at;
		while (from < source.length && SourceText.isSpace(source.fastCodeAt(from))) from++;
		final node: Null<QueryNode> = outermostAt(tree, from);
		if (node == null) return from;
		final span: Null<Span> = node.span;
		// The RUN start, not `declGroupSpan`'s: that function no longer walks forward
		// off an annotation, so it answers an annotation's own offset — and this guard
		// then looked for a `/**` directly above the SECOND annotation of a run, found
		// the first one, and let a doc-stealing insert through at rc 0.
		return span == null ? from : ElementSpan.declRunStart(node, TreePath.parentOf(tree, node), span);
	}

	/**
	 * Where the `/**` block directly above `at` ends, or -1 when no attached doc block is there.
	 *
	 * This asks the pre-lexed `comments` list rather than `RefactorSupport.docExtendedSpan`, which
	 * re-lexes the whole file per call: a 17 000-line file patched with `--all` resolves 135
	 * ranges, and one lex each cost ~19% of the op. `startsItsLine` is the same attribution rule
	 * `docExtendedSpan` applies — a comment sharing its line with preceding code trails THAT
	 * declaration — and the `/**` test is its `docOnly` clause, which keeps a plain banner comment
	 * from counting as documentation.
	 */
	private static function docBlockEnd(source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, at: Int): Int {
		var i: Int = at - 1;
		while (i >= 0 && SourceText.isSpace(source.fastCodeAt(i))) i--;
		if (i < 0) return -1;
		for (tok in comments) if (
			tok.to == i + 1 && !tok.isLine && SourceText.startsItsLine(source, tok.from) && source.fastCodeAt(tok.from + 2) == '*'.code
		)
			return tok.to;
		return -1;
	}

	/**
	 * The declaration a doc block ending at `docEnd` documents — the node itself, so a caller can
	 * ask about its NEIGHBOURS and not only its name.
	 *
	 * The forward skip over the modifier / annotation run is the INNER walk `declGroupSpan` does;
	 * the ENTRY condition is not shared. `declGroupSpan` stops on an annotation element and
	 * answers its own span, while a doc block above an annotation run documents the declaration
	 * under it — so this walk goes past the annotations on purpose.
	 */
	private static function docOwnerNode(
		source: String, tree: QueryNode, comments: Array<{ from: Int, to: Int, isLine: Bool }>, docEnd: Int
	): Null<QueryNode> {
		final at: Int = skipTrivia(source, comments, docEnd);
		if (at >= source.length) return null;
		final resolved: Null<QueryNode> = outermostAt(tree, at);
		if (resolved == null) return null;
		final node: QueryNode = resolved;
		final parent: Null<QueryNode> = TreePath.parentOf(tree, node);
		if (parent == null) return node;
		final siblings: Array<QueryNode> = parent.children;
		var i: Int = siblings.indexOf(node);
		if (i < 0) return node;
		while (i < siblings.length && ElementSpan.isDeclPrefixSibling(siblings[i])) i++;
		return i < siblings.length ? siblings[i] : null;
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
	private static function siblingDeclares(tree: QueryNode, node: QueryNode, name: String): Bool {
		final parent: Null<QueryNode> = TreePath.parentOf(tree, node);
		return parent != null && parent.children.exists(c -> c != node && c.name == name);
	}

	/**
	 * How many DECLARATIONS `node`'s container holds — every sibling that is not a modifier /
	 * annotation prefix, since those are not elements of their own. `-1` when the node has no
	 * container, i.e. the count carries no signal and the caller must not read one into it.
	 *
	 * The second half of the transfer/rename discriminator: a transfer ADDS a declaration to the
	 * container, a rename does not. Asked separately from the name test because a payload can
	 * erase the old name and insert in the same call, which the name test alone reads as a plain
	 * rename.
	 */
	private static function declSiblingCount(tree: QueryNode, node: QueryNode): Int {
		final parent: Null<QueryNode> = TreePath.parentOf(tree, node);
		return parent == null ? -1 : parent.children.count(c -> !ElementSpan.isDeclPrefixSibling(c));
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
	private static function locate(
		slice: String, oldText: String, kind: String, label: String, all: Bool
	): { ranges: Array<Located>, error: Null<String> } {
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
	 * A COMMENT used to be checked the same way and is not any more. The text this
	 * function's own comment carried — that the writer's re-base "moves every line of the
	 * run by ONE amount" — is FALSE for a comment: the writer owns a comment line's
	 * leading whitespace outright, re-indenting each line of the block onto the
	 * declaration's indent and writing the project's indent character. So a well-formed
	 * payload written with a space gutter into a tab-indented site was CORRECTED on the
	 * way through and then refused as corrupt — measured on the pre-fix build, 302 of 343
	 * leading-whitespace combinations over one three-line member doc. What a caller can
	 * still lose inside a comment survives `trim()` (the ` * ` gutter, a code sample's own
	 * indentation after it) and no writer behaviour was found that changes THAT: 343 of
	 * 343 combinations and 1018 real doc blocks of this repo came back with their trimmed
	 * lines intact. Half an assertion with no reachable failing input is not a safety net,
	 * so the comment case leaves rather than being kept as one.
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
			// A COMMENT is not one of them, however verbatim its TEXT is: its per-line
			// LEADING whitespace belongs to the writer, which re-indents each line of a
			// block onto the declaration's indent and writes the project's indent
			// character. Measured on the base build, that made a well-formed payload
			// written with a space gutter into a tab-indented site read as the corruption
			// this check exists to catch — 302 of 343 leading-whitespace combinations over
			// one three-line member doc were refused. Everything a caller can still lose
			// inside a comment survives `trim()` (the ` * ` gutter, a code sample's own
			// indentation after it), and no writer behaviour was found that changes THAT:
			// 343 of 343 combinations and 1018 real doc blocks of this repo came back with
			// their trimmed lines intact. A check with no reachable failing input is not a
			// safety net, so a comment leaves here rather than being half-asserted.
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
	 * `midLineTail` below is the mirror, added by S68 with its own fixtures: the two
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
	 * The shape the campaign actually hit: a fragment copied down to
	 * `private static function rootMemoValue` — the signature's first words, cut before
	 * the parameter list — is refused by both arms for the same reason `midLineAnchor`
	 * exists, and the standing message ("copy it verbatim from `apq source --select`")
	 * describes a fragment that WAS copied verbatim, just not far enough. Nothing in it
	 * says the fallback anchors on whole lines, which is the one fact that resolves it.
	 *
	 * Reports only, like its sibling: it never produces a range to splice, because a
	 * partial-line match is exactly the ambiguity the whole-line rule exists to refuse.
	 *
	 * Measured limit, and it is why the two probes are separate rather than one: each allows a
	 * partial line at ONE end and requires every other line to match whole, so a fragment
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
