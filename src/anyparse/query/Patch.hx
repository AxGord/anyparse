package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.ReplaceNode.ReplaceTarget;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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
		final groupSpan: Span = RefactorSupport.trailingTrimmedSpan(
			source, RefactorSupport.declGroupSpan(node, TreePath.parentOf(tree, node), span)
		);
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
		return switch RefactorSupport.canonicalize(source, edits, reformat, plugin, optsJson) {
			case Ok(text): verbatimSpliceIntact(source, synthesised, text);
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
		return placed.length == 0 || locate(RefactorSupport.applyEdits(slice, placed), oldText, kind, '', all).error != null
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
		return if (dedented.length == 0)
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
	 * Postcondition: a fragment spliced into a writer-VERBATIM region — a comment
	 * interior, a string literal, a regex literal — has to reach the result with the
	 * SHAPE the caller wrote: the same lines, and the same indentation of each line
	 * RELATIVE to the block's first.
	 *
	 * Everywhere else the writer re-indents what it emits, so a wrong indent is both
	 * invisible and harmless. Inside such a region the indentation IS content: `apq
	 * fmt` re-emits a comment interior verbatim and calls the file canonical, no lint
	 * rule reads a continuation prefix, and a string literal's bytes are the program's
	 * data — so nothing else in this project can see a corruption there.
	 *
	 * Relative, not absolute, because the writer legitimately re-bases a comment line
	 * that sits shallower than its block onto the block's own indent: that moves every
	 * line of the run by ONE amount. The defect this guards moves the FIRST line only,
	 * which no uniform shift can explain.
	 */
	private static function verbatimSpliceIntact(source: String, edits: Array<{ span: Span, text: String }>, result: String): EditResult {
		final regions: Array<Span> = RefactorSupport.collectNonCodeRegions(source);
		final lines: Array<String> = result.replace('\r\n', '\n').split('\n');
		for (edit in edits) {
			final wanted: Array<String> = edit.text.replace('\r\n', '\n').split('\n');
			// A single line carries no relative shape, so there is nothing to lose.
			if (wanted.length < 2 || !insideVerbatim(source, edit.span, regions)) continue;
			// A range stopping mid-line leaves the rest of that line standing behind the
			// replacement, so its last line is not a whole result line to compare against.
			// The line-wise arm owns whole lines and only ends mid-line at the end of the
			// searched slice itself.
			if (!(edit.span.to >= source.length || source.charAt(edit.span.to) == '\n')) continue;
			if (!shapeSurvives(lines, wanted))
				return Err(
					'the replacement reached the result with its indentation changed line by line — it lands inside a comment '
					+ 'or a string literal, where indentation is content; copy the old fragment verbatim from '
					+ '`apq source --select` so the indentation it dropped can be recovered'
				);
		}
		return Ok(result);
	}

	/**
	 * Does `span` overlap one comment / string / regex region without reaching past it
	 * onto another LINE? A whole-line match takes bytes the token does not own with it —
	 * the matched line's indentation in front, and behind a string literal the `;` that
	 * closes the statement — so plain containment would exclude every real case. What
	 * must stay outside is a whole line of code, because that is the text the writer
	 * re-wraps, and a re-wrapped line is not a corruption the shape check can read.
	 */
	private static function insideVerbatim(source: String, span: Span, regions: Array<Span>): Bool {
		for (region in regions) if (span.from < region.to && region.from < span.to) {
			final lead: String = span.from >= region.from ? '' : source.substring(span.from, region.from);
			final tail: String = span.to <= region.to ? '' : source.substring(region.to, span.to);
			if (lead.indexOf('\n') < 0 && tail.indexOf('\n') < 0) return true;
		}
		return false;
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
