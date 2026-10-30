package anyparse.query.merge;

/**
 * One version of a container as a three-way merge reads it: the text before its first keyed child, the children in
 * order, the text between two of them, and the text after the last — `head + children.join(separator) + tail` is the
 * container's text.
 */
typedef MergeTree = {
	final head: String;
	final children: Array<MergeChild>;
	final separator: String;
	final tail: String;
}

/** One child of a container: its key, unique among its siblings, its text, and its own children when it has any. */
typedef MergeChild = {
	final key: String;

	/** The blank lines leading the child: its spacing, not its content, so a change of them alone changes nothing. */
	final lead: String;

	final text: String;
	final tree: Null<MergeTree>;

	/** The statement that adds this child at the grammar's own seat (an import), or null when its place is its neighbours'. */
	final seat: Null<String>;
}

/** A place both sides changed differently: its key and what each side did there. */
typedef MergeConflict = {
	final key: String;
	final ours: SideChange;
	final theirs: SideChange;
}

/** What one side did to a place. */
enum abstract SideChange(String) to String {
	final Added = 'added';
	final Changed = 'changed';
	final Removed = 'removed';
}

/** A line merge of one place's base, ours and theirs texts: the merged text when it is clean, else null. */
typedef LineMerge = (base:String, ours:String, theirs:String) -> Null<String>;

/** What `KeyedMerge.merge` makes of three versions. */
typedef MergeOutcome = {
	/** The merged text, a conflict left between `<<<<<<<` / `=======` / `>>>>>>>` lines. */
	final text: String;

	final conflicts: Array<MergeConflict>;

	/** The seat statements of the children only theirs added, left out of `text` for the caller to place. */
	final seated: Array<String>;

	/** How the two sides were combined, one phrase per container where both contributed. */
	final notes: Array<String>;
}

/** How a place both sides changed differently is settled, once someone has chosen. */
enum abstract MergeChoice(String) to String {
	final Ours = 'ours';
	final Theirs = 'theirs';

	/** Ours' text, then theirs'. */
	final Both = 'both';

	/** The choice `word` spells, or null when it spells none. */
	public static function ofWord(word: String): Null<MergeChoice> {
		return switch word {
			case 'ours': Ours;
			case 'theirs': Theirs;
			case 'both': Both;
			case _: null;
		};
	}
}

/**
 * The three-way merge of keyed trees: a child one side changed and the other left alone takes the change, a child only one
 * side added or removed is added or removed, children both sides added keep ours first, and a child both sides changed
 * differently is merged child by child when all three versions hold children, else it is a conflict — settled by a choice
 * when the caller made one for its key, else by the caller's line merge of that place when it is clean, else left
 * between conflict markers. A container from which both sides removed one child while either added another is one such
 * place as a whole: a rename is a removal and an addition by key, so two renames, or a rename against a deletion, are
 * never united. Children are matched by key, never by
 * position, so an insertion on one side moves nothing on the other. Grammar-agnostic: the trees come from
 * `DeclarationTree` or `RecordTree`.
 */
@:nullSafety(Strict)
final class KeyedMerge {

	/** The key of a whole document. */
	public static inline final ROOT: String = '(module)';

	private final _conflicts: Array<MergeConflict> = [];
	private final _seated: Array<String> = [];
	private final _notes: Array<String> = [];
	private final _choices: Map<String, MergeChoice>;
	private final _lineMerge: Null<LineMerge>;

	private function new(choices: Map<String, MergeChoice>, lineMerge: Null<LineMerge>) {
		_choices = choices;
		_lineMerge = lineMerge;
	}

	private function tree(key: String, base: MergeTree, ours: MergeTree, theirs: MergeTree): String {
		if (replacedOnBothSides(base, ours, theirs)) return settle(key, textOf(base), textOf(ours), textOf(theirs), Changed, Changed) ?? '';
		final head: String = stretch(headKey(key), base.head, ours.head, theirs.head);
		final tail: String = stretch(tailKey(key), base.tail, ours.tail, theirs.tail);
		final out: Array<MergeChild> = [];
		final oursAdded: Array<String> = [];
		for (child in ours.children) {
			final old: Null<MergeChild> = find(base, child.key);
			final other: Null<MergeChild> = find(theirs, child.key);
			if (old == null && other == null) oursAdded.push(child.key);
			final text: Null<String> = childText(child.key, old, child, other);
			if (text != null) out.push(placed(child.key, leadOf(old, child, other), text));
		}
		var theirsAdded: Int = 0;
		for (i => child in theirs.children) if (find(ours, child.key) == null) {
			final old: Null<MergeChild> = find(base, child.key);
			// ours removed it: gone unless theirs changed it
			if (old != null && old.text == child.text) continue;
			final seat: Null<String> = child.seat;
			if (old == null && seat != null) {
				_seated.push(seat);
				continue;
			}
			final text: Null<String> = old == null ? child.text : settle(child.key, old.text, null, child.text, Removed, Changed);
			if (text == null) continue;
			if (old == null) theirsAdded++;
			out.insert(seatAfter(out, theirs, i, oursAdded), placed(child.key, child.lead, text));
		}
		if (oursAdded.length > 0 && theirsAdded > 0) _notes.push('both sides added in $key');
		return head + [for (child in out) child.lead + child.text].join(separatorOf([ours, theirs, base])) + tail;
	}

	/** What ours' `mine` becomes, given its `old` text in the base and `other` in theirs; null when it goes. */
	private function childText(key: String, old: Null<MergeChild>, mine: MergeChild, other: Null<MergeChild>): Null<String> {
		if (other == null) return if (old == null)
			mine.text
		else if (old.text == mine.text)
			null
		else
			settle(key, old.text, mine.text, null, Changed, Removed);
		if (other.text == mine.text || old != null && old.text == other.text) return mine.text;
		if (old != null && old.text == mine.text) return other.text;
		final oldTree: Null<MergeTree> = old?.tree;
		final mineTree: Null<MergeTree> = mine.tree;
		final otherTree: Null<MergeTree> = other.tree;
		if (oldTree != null && mineTree != null && otherTree != null) return tree(key, oldTree, mineTree, otherTree);
		final did: SideChange = old == null ? Added : Changed;
		return settle(key, old?.text, mine.text, other.text, did, did);
	}

	/** The three-way merge of one unkeyed stretch of text. */
	private function stretch(key: String, old: String, mine: String, other: String): String {
		if (mine == other || old == other) return mine;
		if (old == mine) return other;
		return settle(key, old, mine, other, Changed, Changed) ?? '';
	}

	/**
	 * The text a place both sides changed differently takes: the caller's choice for `key`, else the line merge of its
	 * `old`, `mine` and `other` texts when that is clean, else both versions between conflict markers, recorded. Null when
	 * the choice keeps a side that removed it.
	 */
	private function settle(
		key: String, old: Null<String>, mine: Null<String>, other: Null<String>, ours: SideChange, theirs: SideChange
	): Null<String> {
		final lineMerge: Null<LineMerge> = _lineMerge;
		if (_choices[key] == null && lineMerge != null && old != null && mine != null && other != null) {
			final merged: Null<String> = lineMerge(old, mine, other);
			if (merged != null) {
				_notes.push('line-merged $key');
				return merged;
			}
		}
		return switch _choices[key] {
			case Ours: mine;
			case Theirs: other;
			case Both: if (mine == null)
				other
			else if (other == null)
				mine
			else
				'${lineOf(mine)}$other';
			case null:
				_conflicts.push({ key: key, ours: ours, theirs: theirs });
				'<<<<<<< ours $key\n${lineOf(mine ?? '')}=======\n${lineOf(other ?? '')}>>>>>>> theirs $key\n';
		};
	}

	/** The key of the stretch before a container's first child. */
	public static inline function headKey(key: String): String {
		return '$key (head)';
	}

	/** The key of the stretch after a container's last child. */
	public static inline function tailKey(key: String): String {
		return '$key (tail)';
	}

	/**
	 * `base` merged with the changes of `ours` and of `theirs`; `choices` settles a conflict by its key, and `lineMerge`
	 * is tried on a place nobody chose for before it becomes a conflict.
	 */
	public static function merge(
		base: MergeTree, ours: MergeTree, theirs: MergeTree, ?choices: Map<String, MergeChoice>, ?lineMerge: LineMerge
	): MergeOutcome {
		final run: KeyedMerge = new KeyedMerge(choices ?? [], lineMerge);
		final text: String = run.tree(ROOT, base, ours, theirs);
		return {
			text: text,
			conflicts: run._conflicts,
			seated: run._seated,
			notes: run._notes
		};
	}

	/** The spacing ours' `mine` takes: theirs' when ours kept the base's, else ours'. */
	private static inline function leadOf(old: Null<MergeChild>, mine: MergeChild, other: Null<MergeChild>): String {
		return other != null && old != null && mine.lead == old.lead ? other.lead : mine.lead;
	}

	/**
	 * Whether both sides removed a child of the base while either side added a child — what two different renames, a
	 * rename against a deletion, or two replacements of one element look like by key.
	 */
	private static function replacedOnBothSides(base: MergeTree, ours: MergeTree, theirs: MergeTree): Bool {
		return base.children.exists(c -> find(ours, c.key) == null && find(theirs, c.key) == null)
			&& (ours.children.exists(c -> find(base, c.key) == null) || theirs.children.exists(c -> find(base, c.key) == null));
	}

	/** The text `tree` was read from. */
	private static function textOf(tree: MergeTree): String {
		return tree.head + [for (child in tree.children) child.lead + child.text].join(tree.separator) + tree.tail;
	}

	/**
	 * Where in `out` a child theirs holds at `index` goes: right after the nearest of its predecessors in theirs that `out`
	 * holds, past the children ours added there, so a run both sides added keeps ours first.
	 */
	private static function seatAfter(out: Array<MergeChild>, theirs: MergeTree, index: Int, oursAdded: Array<String>): Int {
		var at: Int = 0;
		var k: Int = index - 1;
		while (k >= 0) {
			final before: String = theirs.children[k].key;
			final found: Int = indexOf(out, before);
			if (found >= 0) {
				at = found + 1;
				break;
			}
			k--;
		}
		while (at < out.length && oursAdded.contains(out[at].key)) at++;
		return at;
	}

	private static function indexOf(children: Array<MergeChild>, key: String): Int {
		for (i => child in children) if (child.key == key) return i;
		return -1;
	}

	private static function find(tree: MergeTree, key: String): Null<MergeChild> {
		return tree.children.find(child -> child.key == key);
	}

	private static function placed(key: String, lead: String, text: String): MergeChild {
		return {
			key: key,
			lead: lead,
			text: text,
			tree: null,
			seat: null
		};
	}

	/** The separator of the first version that has two children to read it between, else ours'. */
	private static function separatorOf(versions: Array<MergeTree>): String {
		for (version in versions) if (version.children.length > 1) return version.separator;
		return versions[0].separator;
	}

	/** `text` ending in a line break, unless it is empty. */
	private static function lineOf(text: String): String {
		return text == '' || text.endsWith('\n') ? text : '$text\n';
	}

}
