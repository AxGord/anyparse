package anyparse.query;

import anyparse.query.LineDiff.LineEdits;
import anyparse.query.MemberRegistryRename.RegistryFollow;
import anyparse.query.TokenSpans.TokenSpan;
import anyparse.query.TypePathRegistries.MemberKeys;
import anyparse.query.TypePathRegistries.MemberRecord;
import anyparse.query.TypePathRegistries.RegistryEdit;
import anyparse.query.TypePathRegistries.StringSlot;
import anyparse.runtime.Span;
import haxe.Exception;

using anyparse.util.Groups;
using anyparse.util.Strings;
using Lambda;

/** One module a mechanical rewrite changed: its source and tree before and after. */
typedef RewrittenModule = {
	final path: String;
	final source: String;
	final tree: QueryNode;
	final newSource: String;
	final newTree: QueryNode;
}

/** A find and its paired replace in the new spelling. */
private typedef Carried = { final find: String; final replace: Null<String>; }

/** One member across the rewrite: its text after it, the node holding it, and the alignments of the text before it. */
private typedef Rewrite = {
	final module: RewrittenModule;
	final target: QueryNode;
	final at: Int;
	final oldAt: Int;
	final tokens: Array<TokenSpan>;
	final literals: Array<Span>;
	final now: String;
	final maps: Array<Array<Int>>;
	final plugin: GrammarPlugin;
	final exists: Null<String -> Bool>;
}

/**
 * The one answer to "how does a registry's find/replace fragment follow a rewrite that re-spelled the code it cuts":
 * a find that still applies stays; otherwise the characters of the member before and after are aligned and a find
 * becomes the text its two ends now bound. A replace keeps its own middle and takes the find's new spelling for what the
 * two share, so a paren the rewrite put inside a fragment reaches both halves; the parser chooses where a boundary is ambiguous.
 */
@:nullSafety(Strict)
final class RegistryFragmentFollow {

	/** Past this many edited characters in one member the two versions are no longer a respelling worth aligning. */
	private static inline final MAX_EDITS: Int = 4096;

	/** The registry document with every fragment of a rewritten member re-spelled; a fragment that cannot be carried is named. */
	public static function follow(
		members: MemberKeys, json: String, modules: Array<RewrittenModule>, plugin: GrammarPlugin, ?exists: Null<String -> Bool>
	): RegistryFollow {
		final edits: Array<RegistryEdit> = [];
		final notes: Array<String> = [];
		for (record in TypePathRegistries.memberRecords(members, json)) {
			final module: Null<RewrittenModule> = modules.find(m -> m.path == record.type);
			final member: Null<StringSlot> = record.member;
			if (module != null && member != null && record.finds.length > 0)
				followRecord(record, member.value, module, plugin, exists, edits, notes);
		}
		return { text: edits.length == 0 ? null : CanonicalEdit.applyEdits(json, edits), count: edits.length, notes: notes };
	}

	/** Whether the carried spelling would turn an arm that cut something into one whose find equals its replace. */
	private static inline function cutsNothing(find: String, replace: Null<String>, carried: Carried): Bool {
		return replace != null && find != replace && carried.find == (carried.replace ?? replace);
	}

	private static function followRecord(
		record: MemberRecord, member: String, module: RewrittenModule, plugin: GrammarPlugin, exists: Null<String -> Bool>,
		edits: Array<RegistryEdit>, notes: Array<String>
	): Void {
		final before: Array<QueryNode> = MemberRegistryRename.selected(module.tree, record.kind, member, plugin);
		final after: Array<QueryNode> = MemberRegistryRename.selected(module.newTree, record.kind, member, plugin);
		if (before.length != 1 || after.length != 1) {
			// A member that took its name in this rewrite (a rename whose registry record was renamed beside it) has no old
			// side to align, and nothing to carry while every find still cuts it as written.
			if (after.length == 1 && [ for (i in 0...record.finds.length) applies(record, i, module, after[0], plugin) ].foreach(a -> a))
				return;
			notes.push('arm ${record.name}: "${record.type}#$member" is not one declaration on both sides of the rewrite — re-aim it');
			return;
		}
		final oldSpan: Null<Span> = Patch.cutRegion(module.source, module.tree, before[0], plugin);
		final newSpan: Null<Span> = Patch.cutRegion(module.newSource, module.newTree, after[0], plugin);
		if (oldSpan == null || newSpan == null) return;
		final now: String = module.newSource.substring(newSpan.from, newSpan.to);
		final maps: Array<Array<Int>> = alignments(module.source.substring(oldSpan.from, oldSpan.to), now);
		final rewrite: Rewrite = {
			module: module,
			target: after[0],
			at: newSpan.from,
			oldAt: oldSpan.from,
			tokens: plugin.tokenSpans(module.source, 0, module.source.length),
			literals: literalSpans(module.source, plugin),
			now: now,
			maps: maps,
			plugin: plugin,
			exists: exists
		};
		for (i in 0...record.finds.length)
			if (applies(record, i, module, after[0], plugin)) {
				requalify(record, i, rewrite, before[0], edits, notes);
			} else {
				final find: StringSlot = record.finds[i];
				final replace: Null<StringSlot> = replaceOf(record, i);
				final cut: Null<Span> = Patch.cutSpan(module.source, module.tree, before[0], find.value, plugin);
				if (cut == null) {
					notes.push('arm ${record.name}: its find occurs on neither side of the rewrite — re-aim it');
					continue;
				}
				if (maps.length == 0 || cut.from < oldSpan.from || cut.to > oldSpan.to) {
					notes.push('arm ${record.name}: its find cannot be aligned across the rewrite — re-aim it');
					continue;
				}
				final written: String = module.source.substring(cut.from, cut.to);
				final carried: Null<Carried> = carry(rewrite, find.value, replace?.value, written, cut.from - oldSpan.from);
				if (carried == null) {
					notes.push('arm ${record.name}: no re-spelling of its cut applies to the rewritten source — re-aim it');
					continue;
				}
				final newReplace: Null<String> = carried.replace;
				// An arm whose find equals its replace cuts nothing and breaks the build; naming it beats writing it.
				if (cutsNothing(find.value, replace?.value, carried)) {
					notes.push('arm ${record.name}: following the rewrite would leave its find equal to its replace — re-aim it by hand');
					continue;
				}
				if (carried.find != find.value) edits.push(TypePathRegistries.respell(find, carried.find));
				if (replace != null && newReplace != null && newReplace != replace.value)
					edits.push(TypePathRegistries.respell(replace, newReplace));
			}
	}

	/**
	 * A find that still applies may edit the last segment of a qualified path whose package the rewrite changed: its replace
	 * then names the old package's type before and the new package's after. When the old one still names a module the find
	 * takes the qualifier segments that changed and the replace the old ones, so the cut resolves where it did; otherwise the
	 * pair stays when the new one names a module, and the arm is named when neither does. Nothing is judged without `exists`.
	 */
	private static function requalify(
		record: MemberRecord, i: Int, rewrite: Rewrite, before: QueryNode, edits: Array<RegistryEdit>, notes: Array<String>
	): Void {
		final exists: Null<String -> Bool> = rewrite.exists;
		final find: StringSlot = record.finds[i];
		final replace: Null<StringSlot> = replaceOf(record, i);
		if (exists == null || replace == null) return;
		if (!SourceText.isDottedName(find.value) || !SourceText.isDottedName(replace.value)) return;
		final module: RewrittenModule = rewrite.module;
		final oldCut: Null<Span> = Patch.cutSpan(module.source, module.tree, before, find.value, rewrite.plugin);
		final newCut: Null<Span> = Patch.cutSpan(module.newSource, module.newTree, rewrite.target, find.value, rewrite.plugin);
		if (oldCut == null || newCut == null) return;
		final was: String = SourceText.qualifierBefore(module.source, oldCut.from);
		final now: String = SourceText.qualifierBefore(module.newSource, newCut.from);
		if (was == now) return;
		if (!exists(was + replace.value)) {
			if (exists(now + replace.value)) return;
			notes.push(
				'arm ${record.name}: its find edits the last segment of "$now${find.value}", whose package the rewrite changed, and '
				+ 'neither "$was${replace.value}" nor "$now${replace.value}" names a module — re-aim it'
			);
			return;
		}
		final wasSegments: Array<String> = was.split('.');
		final nowSegments: Array<String> = now.split('.');
		var shared: Int = 0;
		while (shared < wasSegments.length - 1 && shared < nowSegments.length - 1 && wasSegments[shared] == nowSegments[shared]) shared++;
		final newFind: String = nowSegments.slice(shared).join('.') + find.value;
		final newReplace: String = wasSegments.slice(shared).join('.') + replace.value;
		final located: Null<Span> = Patch.cutSpan(module.newSource, module.newTree, rewrite.target, newFind, rewrite.plugin);
		if (located == null || !splices(module.newSource, located, newReplace, rewrite.plugin)) {
			notes.push('arm ${record.name}: no re-spelling of its cut names "$was${replace.value}" in the rewritten source — re-aim it');
			return;
		}
		edits.push(TypePathRegistries.respell(find, newFind));
		edits.push(TypePathRegistries.respell(replace, newReplace));
	}

	/**
	 * The two alignments of `old` to `now` a shortest edit script can give, one searched from each end, so an ambiguous
	 * character is bracketed by them; each holds for an old character the index of its new twin or -1. Empty past `MAX_EDITS`.
	 */
	private static function alignments(old: String, now: String): Array<Array<Int>> {
		final forward: Null<Array<Int>> = alignment(old.split(''), now.split(''));
		final tail: Array<String> = old.split('');
		final nowTail: Array<String> = now.split('');
		tail.reverse();
		nowTail.reverse();
		final reversed: Null<Array<Int>> = alignment(tail, nowTail);
		if (forward == null || reversed == null) return [];
		reversed.reverse();
		return [forward, reversed.map(j -> j < 0 ? -1 : now.length - 1 - j)];
	}

	private static function alignment(old: Array<String>, now: Array<String>): Null<Array<Int>> {
		final script: Null<LineEdits> = LineDiff.edits(old, now, MAX_EDITS);
		if (script == null) return null;
		final inserted: Map<Int, Bool> = [ for (i in script.inserted) i => true ];
		final deleted: Map<Int, Bool> = [ for (d in script.deleted) d.line => true ];
		final map: Array<Int> = [];
		var j: Int = 0;
		for (i in 0...old.length) {
			if (deleted.exists(i)) {
				map.push(-1);
				continue;
			}
			while (inserted.exists(j)) j++;
			map.push(j++);
		}
		return map;
	}

	/** Whether `record`'s `i`-th fragment needs no re-spelling: its find still locates in `target` and its replace still parses there. */
	private static function applies(record: MemberRecord, i: Int, module: RewrittenModule, target: QueryNode, plugin: GrammarPlugin): Bool {
		final located: Null<Span> = Patch.cutSpan(module.newSource, module.newTree, target, record.finds[i].value, plugin);
		return located != null && splices(module.newSource, located, replaceOf(record, i)?.value, plugin);
	}

	/** The replace paired with `record`'s `i`-th find; none when the record's finds and replaces do not pair up. */
	private static function replaceOf(record: MemberRecord, i: Int): Null<StringSlot> {
		return record.replaces.length == record.finds.length ? record.replaces[i] : null;
	}

	/** Where a cut starting at `at` now starts: text the rewrite put at the boundary stays outside the cut. */
	private static function startOf(map: Array<Int>, at: Int, end: Int): Int {
		for (k in at ... map.length) if (map[k] >= 0) return map[k];
		return end;
	}

	/** Where a cut ending at `at` now ends: text the rewrite put at the boundary stays outside the cut. */
	private static function endOf(map: Array<Int>, at: Int): Int {
		var k: Int = at - 1;
		while (k >= 0) {
			if (map[k] >= 0) return map[k] + 1;
			k--;
		}
		return 0;
	}

	/**
	 * The new spelling the grammar accepts. Candidates go from the least text taken to the most, the first splice that
	 * parses wins: balance is the parser's question, and a find whose re-spelling cannot be confirmed stays named.
	 */
	private static function carry(rewrite: Rewrite, find: String, replace: Null<String>, written: String, from: Int): Null<Carried> {
		final fit: Null<Array<Int>> = alignment(find.split(''), written.split(''));
		if (fit == null) return null;
		final now: String = rewrite.now;
		final maps: Array<Array<Int>> = rewrite.maps;
		final starts: Array<Int> = cutBoundaries(maps, from, now.length, true);
		starts.reverse();
		// An indent-tolerant cut starts at its line's indentation, which the find never spelled: the carried find leaves it out too.
		final dedent: Bool = fit.length > 0 && fit[0] > 0 && written.substring(0, fit[0]).trim() == '';
		for (newFrom in starts) for (newTo in cutBoundaries(maps, from + written.length, now.length, false)) if (
			newTo > newFrom && keepsEdit(find, replace, fit, written, from, rewrite, newFrom, newTo)
		) {
			final spelled: String = now.substring(newFrom, newTo);
			final newFind: String = dedent ? spelled.ltrim() : spelled;
			final located: Null<Span> = Patch.cutSpan(
				rewrite.module.newSource, rewrite.module.newTree, rewrite.target, newFind, rewrite.plugin
			);
			final lead: Int = spelled.length - newFind.length;
			if (located == null || (located.from != rewrite.at + newFrom && located.from != rewrite.at + newFrom + lead)) continue;
			if (replace == null) return { find: newFind, replace: null };
			if (!staysOneNode(
				rewrite, new Span(rewrite.oldAt + from + (dedent ? fit[0] : 0), rewrite.oldAt + from + written.length), located
			))
				continue;
			for (built in replacesOf(find, replace, from, fit, written.length, newFrom, newTo, rewrite)) {
				final candidate: String = dedent ? built.ltrim() : built;
				if (splices(rewrite.module.newSource, located, candidate, rewrite.plugin)) return { find: newFind, replace: candidate };
			}
		}
		return null;
	}

	/**
	 * Whether a written cut that was exactly one node still is one in the carried spelling. A replace is rebuilt from the edit
	 * its find carried, so a rewrite that split the node the edit belonged to (an arm with several patterns became two arms)
	 * leaves no single place the edit mirrors: the arm is named instead of getting the edit on one half.
	 */
	private static function staysOneNode(rewrite: Rewrite, written: Span, located: Span): Bool {
		return TreePath.withSpan(rewrite.module.tree, written) == null || TreePath.withSpan(rewrite.module.newTree, located) != null;
	}

	/**
	 * Whether a character of `find` that its replace changes (the whole find without a replace, the two around a pure insertion)
	 * still stands inside the carried cut `[newFrom, newTo)`: a cut whose edited text the rewrite deleted has nothing left to edit.
	 */
	private static function keepsEdit(
		find: String, replace: Null<String>, fit: Array<Int>, written: String, from: Int, rewrite: Rewrite, newFrom: Int, newTo: Int
	): Bool {
		var lo: Int = 0;
		var hi: Int = find.length;
		if (replace != null) {
			lo = MemberRegistryRename.sharedPrefix(find, replace);
			hi = find.length - MemberRegistryRename.sharedSuffix(find, replace, lo);
			if (hi <= lo) {
				hi = lo < find.length ? lo + 1 : lo;
				lo = lo > 0 ? lo - 1 : lo;
			}
		}
		return rewrite.maps.exists(map -> holdsIn(map, find, fit, written, from, rewrite, lo, hi, newFrom, newTo));
	}

	/**
	 * Whether one alignment carries the cut whole into `[newFrom, newTo)`: an edited character stands inside, no kept character
	 * of the cut lands outside, and at least half of its non-blank characters are kept, so a cut the rewrite moved apart or
	 * mostly deleted is not re-spelled as the text that happens to stand around its remains.
	 */
	private static function holdsIn(
		map: Array<Int>, find: String, fit: Array<Int>, written: String, from: Int, rewrite: Rewrite, lo: Int, hi: Int, newFrom: Int,
		newTo: Int
	): Bool {
		var edited: Bool = false;
		var solids: Int = 0;
		var kept: Int = 0;
		for (k in 0...find.length) {
			final solid: Bool = find.charAt(k).trim() != '';
			if (solid) solids++;
			final w: Int = fit[k];
			if (w >= 0 && map[from + w] < 0 && k >= lo && k < hi && replacedToken(map, written, from, rewrite, w)) edited = true;
			if (w < 0 || map[from + w] < 0) continue;
			final p: Int = map[from + w];
			if (p < newFrom || p >= newTo) return false;
			if (solid) kept++;
			if (k >= lo && k < hi) edited = true;
		}
		return edited && kept * 2 >= solids;
	}

	/**
	 * Whether the run of cut characters around `written[w]` that the rewrite deleted is one token replaced in place: inside one
	 * string or regex literal, or inside one token of the old source by its grammar's token reader. A deleted phrase, call or
	 * bracket pair is not one token.
	 */
	private static function replacedToken(map: Array<Int>, written: String, from: Int, rewrite: Rewrite, w: Int): Bool {
		var lo: Int = w;
		while (lo > 0 && map[from + lo - 1] < 0) lo--;
		var hi: Int = w + 1;
		while (hi < written.length && map[from + hi] < 0) hi++;
		final start: Int = rewrite.oldAt + from + lo;
		final end: Int = rewrite.oldAt + from + hi;
		return rewrite.literals.exists(literal -> literal.from <= start && end <= literal.to)
			|| rewrite.tokens.filter(token -> token.from < end && start < token.to).length == 1;
	}

	/**
	 * A replace with what it shares with its find in the new spelling, each boundary
	 * choice; the replace as written last, unless a choice was refused, so a fragment that
	 * cannot be re-spelled is named instead of rewritten.
	 * A shared part ends and starts as a cut does, so a separator the rewrite replaced at its edge (a space become a line
	 * break) comes with it and the two parts never join.
	 */
	private static function replacesOf(
		find: String, replace: String, from: Int, fit: Array<Int>, writtenLength: Int, newFrom: Int, newTo: Int, rewrite: Rewrite
	): Array<String> {
		final prefix: Int = MemberRegistryRename.sharedPrefix(find, replace);
		final suffix: Int = MemberRegistryRename.sharedSuffix(find, replace, prefix);
		final middle: String = replace.substring(prefix, replace.length - suffix);
		final now: String = rewrite.now;
		final ends: Array<Int> = prefix == 0
			? [newFrom]
			: cutBoundaries(rewrite.maps, from + startOf(fit, prefix, writtenLength), now.length, false)
				.filter(p -> p >= newFrom && p <= newTo);
		final tails: Array<Int> = suffix == 0
			? [newTo]
			: cutBoundaries(rewrite.maps, from + startOf(fit, find.length - suffix, writtenLength), now.length, true)
				.filter(p -> p >= newFrom && p <= newTo);
		tails.reverse();
		final out: Array<String> = [];
		var refused: Bool = false;
		for (end in ends) for (tail in tails) if (tail >= end) {
			final head: String = now.substring(newFrom, end);
			final rest: String = now.substring(tail, newTo);
			final built: String = head + middle + rest;
			final headKept: Bool = head.length == 0 || sameJoint(replace, prefix, now, end, built, head.length);
			final restKept: Bool = rest.length == 0
				|| sameJoint(replace, replace.length - suffix, now, tail, built, head.length + middle.length);
			if (headKept && restKept)
				out.push(built);
			else
				refused = true;
		}
		if (!refused) out.push(replace);
		return out;
	}

	/**
	 * Whether a join of a rebuilt replace is inside an identifier exactly where the written `replace` and the new text have one: a
	 * piece cut through a token of the new text, or two pieces glued into a name the replace never spelled,
	 * still parses as another name.
	 */
	private static function sameJoint(replace: String, at: Int, now: String, nowAt: Int, built: String, builtAt: Int): Bool {
		final inside: Bool = insideToken(replace, at);
		return insideToken(now, nowAt) == inside && insideToken(built, builtAt) == inside;
	}

	/** Whether the character before `at` and the one at `at` both belong to one identifier. */
	private static function insideToken(text: String, at: Int): Bool {
		return at > 0 && at < text.length && text.fastCodeAt(at - 1).isIdentChar() && text.fastCodeAt(at).isIdentChar();
	}

	/** Whether the cut still leaves the module parseable: a fragment cut through a new paren group needs it in `replace`. */
	private static function splices(source: String, at: Span, replace: Null<String>, plugin: GrammarPlugin): Bool {
		if (replace == null) return true;
		return try {
			plugin.parseFile(source.substring(0, at.from) + replace + source.substring(at.to));
			true;
		} catch (_: Exception) {
			false;
		};
	}

	/**
	 * The positions a cut's own start (`isStart`) or end at `at` can land on. A boundary character of the cut that the rewrite
	 * deleted was replaced in place, so its replacement belongs inside the cut: only the wide side of the boundary is kept.
	 */
	private static function cutBoundaries(maps: Array<Array<Int>>, at: Int, end: Int, isStart: Bool): Array<Int> {
		final out: Array<Int> = [];
		for (map in maps) {
			final edge: Int = isStart ? at : at - 1;
			final replaced: Bool = edge >= 0 && edge < map.length && map[edge] < 0;
			final wide: Int = isStart ? endOf(map, at) : startOf(map, at, end);
			final candidates: Array<Int> = replaced ? [wide] : [startOf(map, at, end), endOf(map, at)];
			out.pushAllUnique(candidates);
		}
		out.sort((a, b) -> a - b);
		return out;
	}

	/** The string and regex literals of `source`, which the lexer scans whole while the tree may project only their contents as leaves. */
	private static function literalSpans(source: String, plugin: GrammarPlugin): Array<Span> {
		return [ for (region in plugin.lexicalRegions(source)) if (!LexicalRegions.isComment(region)) new Span(region.from, region.to) ];
	}

}
