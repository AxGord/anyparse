package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.ReplaceNode.ReplaceTarget;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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
		source: String, target: ReplaceTarget, oldText: String, newText: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		return patchNodeMany(source, target, [{ oldText: oldText, newText: newText }], reformat, plugin, optsJson);
	}

	/**
	 * Apply several fragment pairs to ONE addressed node in a single writer
	 * round-trip. Every pair's old fragment is located against the ORIGINAL
	 * node source (byte-exact first, then line-wise with indentation ignored —
	 * the dedented `apq source --select` form) and must occur exactly once;
	 * the matched ranges must not overlap. Returns `Ok(rewritten)` or an `Err`
	 * naming the offending pair.
	 */
	public static function patchNodeMany(
		source: String, target: ReplaceTarget, pairs: Array<{ oldText: String, newText: String }>, reformat: Bool, plugin: GrammarPlugin,
		?optsJson: String
	): EditResult {
		if (pairs.length == 0) return Err('no fragment pairs given');
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final node: QueryNode = switch ReplaceNode.resolveTarget(source, tree, target, plugin) {
			case Resolved(n): n;
			case Failed(message): return Err(message);
		};

		final span: Null<Span> = node.span;
		if (span == null) return Err('the resolved ${node.kind} node has no source span to patch');

		// The searchable region is the same modifier-folded slice `apq source
		// --select` prints, so a fragment copied from that output matches as-is.
		final groupSpan: Span = RefactorSupport.declGroupSpan(node, RefactorSupport.parentOf(tree, node), span);
		final slice: String = source.substring(groupSpan.from, groupSpan.to);
		final edits: Array<{ span: Span, text: String }> = [];
		for (i in 0...pairs.length) {
			final label: String = pairs.length > 1 ? 'pair ${i + 1}: ' : '';
			final oldText: String = pairs[i].oldText;
			if (oldText.length == 0) return Err('${label}the old fragment is empty — copy it verbatim from `apq source --select`');
			if (oldText == pairs[i].newText) return Err('${label}the old and new fragments are identical — nothing to change');
			final located: { from: Int, to: Int, error: Null<String> } = locate(slice, oldText, node.kind, label);
			final failure: Null<String> = located.error;
			if (failure != null) return Err(failure);
			edits.push({
				span: new Span(groupSpan.from + located.from, groupSpan.from + located.to),
				text: pairs[i].newText
			});
		}
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> a.span.from - b.span.from);
		for (i in 1...sorted.length) if (sorted[i].span.from < sorted[i - 1].span.to)
			return Err('the matched fragments overlap — merge the overlapping pairs into one');
		return RefactorSupport.canonicalize(source, edits, reformat, plugin, optsJson);
	}

	/**
	 * Locate `oldText` within `slice` — byte-exact first, then the dedented
	 * line-wise fallback — enforcing the exactly-once discipline. A failure is
	 * reported through `error` (with the multi-pair `label` prefix).
	 */
	private static function locate(
		slice: String, oldText: String, kind: String, label: String
	): { from: Int, to: Int, error: Null<String> } {
		final first: Int = slice.indexOf(oldText);
		if (first >= 0) return slice.indexOf(oldText, first + 1) >= 0
			? fail(
				'${label}the old fragment occurs ${countOccurrences(slice, oldText)} times in the resolved $kind node — widen the snippet until it is unique'
			)
			: {
				from: first,
				to: first + oldText.length,
				error: null
			};
		final dedented: { from: Int, to: Int, count: Int } = findDedented(slice, oldText);
		return dedented.count == 0
			? fail('${label}the old fragment does not occur in the resolved $kind node — copy it verbatim from `apq source --select`')
			: dedented.count > 1
				? fail(
					'${label}the old fragment occurs ${dedented.count} times in the resolved $kind node — widen the snippet until it is unique'
				)
				: {
					from: dedented.from,
					to: dedented.to,
					error: null
				};
	}

	private static inline function fail(message: String): { from: Int, to: Int, error: Null<String> } {
		return { from: -1, to: -1, error: message };
	}

	/**
	 * Line-wise, indentation-insensitive occurrence search — `apq source --select`
	 * prints a node DEDENTED, so a multi-line fragment copied from it does not
	 * byte-match the raw file. Each fragment line is compared trimmed against the
	 * slice's lines; the matched range runs from the first line's first
	 * non-whitespace byte to the last line's last non-whitespace byte (the writer
	 * re-indents the replacement anyway). `from`/`to` describe the FIRST match;
	 * `count` is the total so the caller can enforce uniqueness.
	 */
	private static function findDedented(slice: String, oldText: String): { from: Int, to: Int, count: Int } {
		final wanted: Array<String> = [for (l in oldText.split('\n')) StringTools.trim(l)];
		final lines: Array<String> = slice.split('\n');
		final offsets: Array<Int> = [];
		var acc: Int = 0;
		for (l in lines) {
			offsets.push(acc);
			acc += l.length + 1;
		}
		var count: Int = 0;
		var from: Int = -1;
		var to: Int = -1;
		for (start in 0...(lines.length - wanted.length + 1)) {
			var ok: Bool = true;
			for (j in 0...wanted.length) if (StringTools.trim(lines[start + j]) != wanted[j]) {
				ok = false;
				break;
			}
			if (!ok) continue;
			count++;
			if (count != 1) continue;
			final firstLine: String = lines[start];
			final lastLine: String = lines[start + wanted.length - 1];
			from = offsets[start] + (firstLine.length - StringTools.ltrim(firstLine).length);
			to = offsets[start + wanted.length - 1] + StringTools.rtrim(lastLine).length;
		}
		return { from: from, to: to, count: count };
	}

	private static function countOccurrences(haystack: String, needle: String): Int {
		var count: Int = 0;
		var i: Int = haystack.indexOf(needle);
		while (i >= 0) {
			count++;
			i = haystack.indexOf(needle, i + 1);
		}
		return count;
	}

}
