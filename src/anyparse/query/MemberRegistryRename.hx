package anyparse.query;

import anyparse.query.CrossRename.FileChange;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.TypePathRegistries.MemberKeys;
import anyparse.query.TypePathRegistries.MemberRecord;
import anyparse.query.TypePathRegistries.RegistryEdit;
import anyparse.query.TypePathRegistries.StringSlot;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/** One module a member rename changed: its source before and after, and the spans the op proved to be the member. */
private typedef RenamedModule = {
	final path: String;
	final source: String;
	final tree: QueryNode;
	final newSource: String;
	final newTree: QueryNode;
	final edited: Array<Span>;
}

/** A performed member rename as a registry reads it. */
typedef MemberRename = {
	final oldName: String;
	final newName: String;
	final modules: Array<RenamedModule>;
}

/** A registry document after a rename: its new text (null when no record changed), the values changed, and the records named. */
typedef RegistryFollow = {
	final text: Null<String>;
	final count: Int;
	final notes: Array<String>;
}

/**
 * The one answer to "which values of a declared member registry follow a member rename": what the op's own edit set
 * proved, never a second reading of the name. A record is read as the applier of its cut reads it, a `<kind>:<member>`
 * address and fragments `Patch` locates in the ORIGINAL source, so a token of a find follows exactly when the token it
 * located has an edit. A replace never occurs in the source, so it follows its paired find. A record that cannot be mapped
 * stays as written and is named: the rename itself holds, and a stale cut loses nothing.
 */
@:nullSafety(Strict)
final class MemberRegistryRename {

	/** How a member of the enclosing instance is spelled with a receiver. */
	private static inline final SELF_RECEIVER: String = 'this.';

	/** The access operator a receiver spells before a member. */
	private static inline final ACCESS: Int = '.'.code;

	/**
	 * The rename the op's `changes` performed over `sources`, the originals it read; null when it changed nothing.
	 * Throws the plugin's error on a source that does not parse.
	 */
	public static function of(
		changes: Array<FileChange>, sources: Array<{ file: String, source: String }>, newName: String, plugin: GrammarPlugin
	): Null<MemberRename> {
		var oldName: Null<String> = null;
		final modules: Array<RenamedModule> = [];
		for (change in changes) {
			final original: Null<{ file: String, source: String }> = sources.find(s -> s.file == change.file);
			if (original == null || change.edits.length == 0) continue;
			final span: Span = change.edits[0].span;
			oldName = original.source.substring(span.from, span.to);
			final tree: QueryNode = plugin.parseFile(original.source);
			modules.push({
				path: ModuleScan.moduleOf(tree, change.file).path,
				source: original.source,
				tree: tree,
				newSource: change.newSource,
				newTree: plugin.parseFile(change.newSource),
				edited: change.edits.map(edit -> edit.span)
			});
		}
		return oldName == null ? null : { oldName: oldName, newName: newName, modules: modules };
	}

	/**
	 * The document `json` of a registry laid out as `members`, followed over `rename`. Throws the JSON parser's error on a
	 * document that does not parse.
	 */
	public static function follow(members: MemberKeys, json: String, rename: MemberRename, plugin: GrammarPlugin): RegistryFollow {
		final edits: Array<RegistryEdit> = [];
		final notes: Array<String> = [];
		for (record in TypePathRegistries.memberRecords(members, json)) {
			for (held in record.opaque) if (tokensOf(held.slot.value, rename.oldName).length > 0)
				notes.push(
					'arm ${record.name}: its "${held.key}" value spells "${rename.oldName}", which a rename does not follow — re-aim it'
				);
			final module: Null<RenamedModule> = rename.modules.find(m -> m.path == record.type);
			final member: Null<StringSlot> = record.member;
			if (module == null)
				nameUnprovenReplaces(record, rename.oldName, notes);
			else if (member != null)
				followRecord(record, member, module, rename, plugin, edits, notes);
		}
		return {
			text: edits.length == 0 ? null : CanonicalEdit.applyEdits(json, edits),
			count: edits.length,
			notes: notes
		};
	}

	private static inline function unprovenReplace(record: MemberRecord, old: String): String {
		return 'arm ${record.name}: its replace spells "$old" where the find proves nothing about it — re-aim it';
	}

	private static inline function isEdited(module: RenamedModule, at: Int): Bool {
		return module.edited.exists(e -> e.from == at);
	}

	/** Whether `edit` overlaps `cut` without lying inside it: the fragment's edge cuts the renamed token. */
	private static inline function straddles(edit: Span, cut: Span): Bool {
		return edit.from < cut.to && cut.from < edit.to && (edit.from < cut.from || edit.to > cut.to);
	}

	/**
	 * The notes of one record on a module the rename left alone. A replace there is named only for a receiver-qualified
	 * spelling its find lacks: a bare or `this.` spelling in an unedited module is that module's own member unless it is
	 * inherited, and the source cannot say which, so it stays silent.
	 */
	private static function nameUnprovenReplaces(record: MemberRecord, old: String, notes: Array<String>): Void {
		if (record.replaces.length != record.finds.length) return;
		for (i in 0...record.finds.length) {
			final replace: String = record.replaces[i].value;
			if (tokensOf(record.finds[i].value, old).length == 0 && tokensOf(replace, old).exists(at -> !isSelfSpelling(replace, at)))
				notes.push(
					'arm ${record.name}: its replace spells "$old" on a receiver the rename cannot read — re-aim it if that is this member'
				);
		}
	}

	/** The edits and notes of one record whose module the rename changed. */
	private static function followRecord(
		record: MemberRecord, member: StringSlot, module: RenamedModule, rename: MemberRename, plugin: GrammarPlugin,
		edits: Array<RegistryEdit>, notes: Array<String>
	): Void {
		final old: String = rename.oldName;
		final renamed: Bool = member.value == old
			&& selected(module.tree, record.kind, old, plugin).exists(node -> nameEdited(module, node, old));
		if (renamed) edits.push(TypePathRegistries.spliceOf(member, 0, member.value.length, rename.newName));
		final targets: Array<QueryNode> = selected(module.tree, record.kind, member.value, plugin);
		if (targets.length != 1) return;
		final target: QueryNode = targets[0];
		final newMember: String = renamed ? rename.newName : member.value;
		final newTargets: Array<QueryNode> = selected(module.newTree, record.kind, newMember, plugin);
		for (i in 0...record.finds.length) {
			final find: StringSlot = record.finds[i];
			final cut: Null<Span> = Patch.cutSpan(module.source, module.tree, target, find.value, plugin);
			if (cut == null) continue;
			final inFind: Array<Int> = tokensOf(find.value, old);
			final inSource: Array<Int> = tokensOf(module.source.substring(cut.from, cut.to), old);
			if (inFind.length != inSource.length || module.edited.exists(e -> straddles(e, cut))) {
				notes.push('arm ${record.name}: its find cannot be carried over the rename of "$old" — re-aim it');
				continue;
			}
			final verdicts: Array<Bool> = inSource.map(at -> isEdited(module, cut.from + at));
			for (k => at in inFind) if (verdicts[k]) edits.push(TypePathRegistries.spliceOf(find, at, at + old.length, rename.newName));
			final rewritten: String = spliced(find.value, [for (k => at in inFind) if (verdicts[k]) at], old, rename.newName);
			if (newTargets.length != 1 || Patch.cutSpan(module.newSource, module.newTree, newTargets[0], rewritten, plugin) == null)
				notes.push('arm ${record.name}: its find no longer occurs in "${record.type}#$newMember" — re-aim it');
			if (record.replaces.length != record.finds.length) continue;
			final replace: StringSlot = record.replaces[i];
			final replaced: Null<Array<Bool>> = replaceVerdicts(
				find.value, inFind, verdicts, replace.value, old, holdsRenamedMember.bind(module, target, old, plugin)
			);
			if (replaced == null) {
				notes.push(unprovenReplace(record, old));
				continue;
			}
			for (k => at in tokensOf(replace.value, old)) if (replaced[k])
				edits.push(TypePathRegistries.spliceOf(replace, at, at + old.length, rename.newName));
		}
	}

	/** Every node the applier's address `<kind>:<name>` selects in `tree`; none for an address that does not parse. */
	private static function selected(tree: QueryNode, kind: String, name: String, plugin: GrammarPlugin): Array<QueryNode> {
		return try {
			Engine.select(tree, Selector.parse('$kind:$name'), plugin.selectKindEquivalence());
		} catch (_: Exception) {
			[];
		};
	}

	/**
	 * For each `old` token of `replace`, whether it follows: a token in the prefix or the suffix `replace` shares with `find`
	 * takes the verdict of its counterpart there; any other is the mutation's own, and takes the verdict all of `find`'s tokens
	 * agree on. A find with no token proves nothing, so an own token then follows only as the enclosing instance's member of
	 * a type holding a renamed declaration (`holdsRenamed`). Null when some token has no verdict.
	 */
	private static function replaceVerdicts(
		find: String, inFind: Array<Int>, verdicts: Array<Bool>, replace: String, old: String, holdsRenamed: () -> Bool
	): Null<Array<Bool>> {
		final prefix: Int = sharedPrefix(find, replace);
		final suffix: Int = sharedSuffix(find, replace, prefix);
		final out: Array<Bool> = [];
		for (at in tokensOf(replace, old)) {
			final inPrefix: Int = at + old.length <= prefix ? inFind.indexOf(at) : -1;
			final inSuffix: Int = at >= replace.length - suffix ? inFind.indexOf(at + find.length - replace.length) : -1;
			final shared: Int = inPrefix >= 0 ? inPrefix : inSuffix;
			final verdict: Null<Bool> = if (shared >= 0)
				verdicts[shared]
			else if (verdicts.length == 0) {
				isSelfSpelling(replace, at) && holdsRenamed() ? true : null;
			} else if (verdicts.exists(v -> v != verdicts[0])) {
				null;
			} else {
				verdicts[0];
			};
			if (verdict == null) return null;
			out.push(verdict);
		}
		return out;
	}

	/** Whether the token at `at` of `text` is spelled with no receiver, or with the enclosing instance as its receiver. */
	private static function isSelfSpelling(text: String, at: Int): Bool {
		if (at == 0 || text.fastCodeAt(at - 1) != ACCESS) return true;
		final from: Int = at - SELF_RECEIVER.length;
		return from >= 0 && text.substring(from, at) == SELF_RECEIVER && (from == 0 || !SourceText.isIdentChar(text.fastCodeAt(from - 1)));
	}

	/** Whether the top-level type around `target` declares a member named `name` whose name the rename edited. */
	private static function holdsRenamedMember(module: RenamedModule, target: QueryNode, name: String, plugin: GrammarPlugin): Bool {
		final at: Int = target.span?.from ?? -1;
		for (node in module.tree.children) {
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (decl == null || at < decl.fullSpan.from || at >= decl.fullSpan.to) continue;
			var held: Bool = false;
			MemberBranchScan.eachTypeMember(
				decl, plugin.refShape(), module.source, n -> n.name == name,
				(member, _) -> if (nameEdited(module, member, name)) held = true, plugin.lexicalRegions.bind(module.source)
			);
			return held;
		}
		return false;
	}

	/** Whether the first `name` token of the declaration `node`, its own name, carries an edit of the rename. */
	private static function nameEdited(module: RenamedModule, node: QueryNode, name: String): Bool {
		final span: Null<Span> = node.span;
		return span != null && isEdited(module, SourceText.identTokenOffset(module.source, span, name));
	}

	/** The offset of every identifier token `name` of `text`, the text's own ends counting as boundaries. */
	private static function tokensOf(text: String, name: String): Array<Int> {
		final out: Array<Int> = [];
		var at: Int = SourceText.identTokenOffset(text, new Span(0, text.length), name);
		while (at >= 0) {
			out.push(at);
			at = SourceText.identTokenOffset(text, new Span(at + name.length, text.length), name);
		}
		return out;
	}

	/** `text` with the `old` tokens at `offsets` (ascending) replaced by `name`. */
	private static function spliced(text: String, offsets: Array<Int>, old: String, name: String): String {
		final out: StringBuf = new StringBuf();
		var from: Int = 0;
		for (at in offsets) {
			out.add(text.substring(from, at));
			out.add(name);
			from = at + old.length;
		}
		out.add(text.substring(from));
		return out.toString();
	}

	private static function sharedPrefix(a: String, b: String): Int {
		var n: Int = 0;
		while (n < a.length && n < b.length && a.fastCodeAt(n) == b.fastCodeAt(n)) n++;
		return n;
	}

	/** The shared suffix of `a` and `b`, left of neither's first `prefix` code units. */
	private static function sharedSuffix(a: String, b: String, prefix: Int): Int {
		var n: Int = 0;
		while (n < a.length - prefix && n < b.length - prefix && a.fastCodeAt(a.length - 1 - n) == b.fastCodeAt(b.length - 1 - n)) n++;
		return n;
	}

}
