package anyparse.query;

import anyparse.query.LineDiff.LineEdits;
import anyparse.query.MemberRegistryRename.RegistryFollow;
import anyparse.query.TypePathRegistries.MemberKeys;
import anyparse.query.TypePathRegistries.MemberRecord;
import anyparse.query.TypePathRegistries.RegistryEdit;
import anyparse.query.TypePathRegistries.StringSlot;
import anyparse.runtime.Span;
import haxe.Exception;

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
private typedef Carried = {
	final find: String;
	final replace: Null<String>;
}

/** One member across the rewrite: its text after it, the node holding it, and the alignments of the text before it. */
private typedef Rewrite = {
	final module: RewrittenModule;
	final target: QueryNode;
	final at: Int;
	final now: String;
	final maps: Array<Array<Int>>;
	final plugin: GrammarPlugin;
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
		members: MemberKeys, json: String, modules: Array<RewrittenModule>, plugin: GrammarPlugin
	): RegistryFollow {
		final edits: Array<RegistryEdit> = [];
		final notes: Array<String> = [];
		for (record in TypePathRegistries.memberRecords(members, json)) {
			final module: Null<RewrittenModule> = modules.find(m -> m.path == record.type);
			final member: Null<StringSlot> = record.member;
			if (module != null && member != null && record.finds.length > 0)
				followRecord(record, member.value, module, plugin, edits, notes);
		}
		return { text: edits.length == 0 ? null : CanonicalEdit.applyEdits(json, edits), count: edits.length, notes: notes };
	}

	private static function followRecord(
		record: MemberRecord, member: String, module: RewrittenModule, plugin: GrammarPlugin, edits: Array<RegistryEdit>,
		notes: Array<String>
	): Void {
		final before: Array<QueryNode> = MemberRegistryRename.selected(module.tree, record.kind, member, plugin);
		final after: Array<QueryNode> = MemberRegistryRename.selected(module.newTree, record.kind, member, plugin);
		if (before.length != 1 || after.length != 1) {
			notes.push('arm ${record.name}: "${record.type}#$member" is not one declaration on both sides of the rewrite — re-aim it');
			return;
		}
		final oldSpan: Null<Span> = before[0].span;
		final newSpan: Null<Span> = after[0].span;
		if (oldSpan == null || newSpan == null) return;
		final now: String = module.newSource.substring(newSpan.from, newSpan.to);
		final maps: Array<Array<Int>> = alignments(module.source.substring(oldSpan.from, oldSpan.to), now);
		final rewrite: Rewrite = {
			module: module,
			target: after[0],
			at: newSpan.from,
			now: now,
			maps: maps,
			plugin: plugin
		};
		for (i in 0...record.finds.length) {
			final find: StringSlot = record.finds[i];
			final replace: Null<StringSlot> = record.replaces.length == record.finds.length ? record.replaces[i] : null;
			if (appliesAsWritten(rewrite, find.value, replace?.value)) continue;
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
			if (carried.find != find.value) edits.push(TypePathRegistries.respell(find, carried.find));
			final newReplace: Null<String> = carried.replace;
			if (replace != null && newReplace != null && newReplace != replace.value)
				edits.push(TypePathRegistries.respell(replace, newReplace));
		}
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
		final inserted: Map<Int, Bool> = [for (i in script.inserted) i => true];
		final deleted: Map<Int, Bool> = [for (d in script.deleted) d.line => true];
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

	/** Whether the record needs no re-spelling: its find still locates and its replace still parses in the rewritten source. */
	private static function appliesAsWritten(rewrite: Rewrite, find: String, replace: Null<String>): Bool {
		final located: Null<Span> = Patch.cutSpan(rewrite.module.newSource, rewrite.module.newTree, rewrite.target, find, rewrite.plugin);
		return located != null && splices(rewrite.module.newSource, located, replace, rewrite.plugin);
	}

	/** Every position an old boundary can land on: both sides of text inserted there, under each alignment, ascending. */
	private static function boundaries(maps: Array<Array<Int>>, at: Int, end: Int): Array<Int> {
		final out: Array<Int> = [];
		for (map in maps) for (p in [startOf(map, at, end), endOf(map, at)]) if (!out.contains(p)) out.push(p);
		out.sort((a, b) -> a - b);
		return out;
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
		final starts: Array<Int> = boundaries(maps, from, now.length);
		starts.reverse();
		for (newFrom in starts) for (newTo in boundaries(maps, from + written.length, now.length)) if (newTo > newFrom) {
			final newFind: String = now.substring(newFrom, newTo);
			final located: Null<Span> = Patch.cutSpan(
				rewrite.module.newSource, rewrite.module.newTree, rewrite.target, newFind, rewrite.plugin
			);
			if (located == null || located.from != rewrite.at + newFrom) continue;
			if (replace == null) return { find: newFind, replace: null };
			for (candidate in replacesOf(find, replace, from, fit, written.length, newFrom, newTo, rewrite))
				if (splices(rewrite.module.newSource, located, candidate, rewrite.plugin)) return { find: newFind, replace: candidate };
		}
		return null;
	}

	/** A replace with what it shares with its find in the new spelling, each boundary choice; the replace as written last. */
	private static function replacesOf(
		find: String, replace: String, from: Int, fit: Array<Int>, writtenLength: Int, newFrom: Int, newTo: Int, rewrite: Rewrite
	): Array<String> {
		final prefix: Int = MemberRegistryRename.sharedPrefix(find, replace);
		final suffix: Int = MemberRegistryRename.sharedSuffix(find, replace, prefix);
		final middle: String = replace.substring(prefix, replace.length - suffix);
		final now: String = rewrite.now;
		final ends: Array<Int> = prefix == 0
			? [newFrom]
			: boundaries(rewrite.maps, from + startOf(fit, prefix, writtenLength), now.length).filter(p -> p >= newFrom && p <= newTo);
		final tails: Array<Int> = suffix == 0
			? [newTo]
			: boundaries(
				rewrite.maps, from + startOf(fit, find.length - suffix, writtenLength), now.length
			).filter(p -> p >= newFrom && p <= newTo);
		tails.reverse();
		final out: Array<String> = [
			for (end in ends) for (tail in tails) if (tail >= end) now.substring(newFrom, end) + middle + now.substring(tail, newTo)
		];
		out.push(replace);
		return out;
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

}
