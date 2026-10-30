package anyparse.query.merge;

/**
 * A file read as a `MergeTree` by the declarations that own its lines (`DeclarationLines`): a container is the module or
 * a declaration holding named members, its head and tail the lines it owns itself before its first and after its last
 * child, and a line it owns between two children leads the child below it, so the concatenation of a tree is the file
 * it was read from. A header statement standing alone in its block carries itself as its seat, so one only theirs added
 * is placed where the grammar places a fresh one rather than beside a neighbour.
 */
@:nullSafety(Strict)
final class DeclarationTree {

	/** The tree of `version`. */
	public static function of(version: FileVersion): MergeTree {
		return container(version, -1, 0, version.lines.length, '');
	}

	/**
	 * Whether a conditional-compilation directive starting at one of `offsets` stands between declarations — owned by the
	 * module or by a declaration that holds members, or among the lines leading a declaration — rather than inside one
	 * declaration's own lines, where a merge keeps it with that declaration.
	 */
	public static function conditionalBetween(version: FileVersion, offsets: Array<Int>): Bool {
		for (offset in offsets) {
			final line: Int = lineAt(version, offset);
			final holder: Int = version.owner[line];
			if (holder < 0 || line < version.units[holder].first || version.units.exists(u -> u.parent == holder)) return true;
		}
		return false;
	}

	/** The container `holder` (-1 for the module) over the lines `from` to `to`, `lead` the lines its parent gave it. */
	private static function container(version: FileVersion, holder: Int, from: Int, to: Int, lead: String): MergeTree {
		final children: Array<MergeChild> = [];
		final seen: Map<String, Int> = [];
		var head: Null<String> = null;
		var own: String = lead;
		var line: Int = from;
		while (line < to) {
			if (version.owner[line] == holder) {
				own += lineText(version, line);
				line++;
				continue;
			}
			final top: Int = topUnder(version, version.owner[line], holder);
			var end: Int = line;
			while (end < to && version.owner[end] != holder && topUnder(version, version.owner[end], holder) == top) end++;
			if (head == null) {
				head = own;
				own = '';
			}
			children.push(childOf(version, top, line, end, own, seen));
			own = '';
			line = end;
		}
		return {
			head: head ?? own,
			children: children,
			separator: '',
			tail: head == null ? '' : own
		};
	}

	/** The child `top` over the lines `from` to `end`, led by the lines `prefix` its container owns above it. */
	private static function childOf(
		version: FileVersion, top: Int, from: Int, end: Int, prefix: String, seen: Map<String, Int>
	): MergeChild {
		final unit: OwnerUnit = version.units[top];
		final name: String = unit.header ? '${unit.node.kind} ${unit.key}' : unit.key;
		final count: Int = seen[name] ?? 0;
		seen[name] = count + 1;
		var whole: String = prefix;
		for (line in from ... end) whole += lineText(version, line);
		final lead: String = blankLead(whole);
		final written: Array<String> = [
			for (line in from ... end) if (version.lines[line].trim() != '') version.lines[line].trim()
		];
		final tree: Null<MergeTree> = version.units.exists(u -> u.parent == top) ? container(version, top, from, end, prefix) : null;
		return {
			key: count == 0 ? name : '$name#${count + 1}',
			lead: lead,
			text: whole.substr(lead.length),
			tree: tree == null ? null : {
				head: tree.head.substr(lead.length),
				children: tree.children,
				separator: tree.separator,
				tail: tree.tail
			},
			seat: unit.header && ModuleScan.IMPORT_DECL_KINDS.contains(unit.node.kind) && written.length == 1 ? written[0] : null
		};
	}

	/** The child of `holder` that is `unit` or encloses it. */
	private static function topUnder(version: FileVersion, unit: Int, holder: Int): Int {
		var at: Int = unit;
		while (at >= 0 && version.units[at].parent != holder) at = version.units[at].parent;
		return at;
	}

	/** Line `line` of `version` with the break that ends it — none after the last. */
	private static function lineText(version: FileVersion, line: Int): String {
		return line < version.lines.length - 1 ? '${version.lines[line]}\n' : version.lines[line];
	}

	/** The blank lines `text` opens with, their breaks included. */
	private static function blankLead(text: String): String {
		var end: Int = 0;
		var at: Int = 0;
		while (at < text.length) {
			final c: Int = text.fastCodeAt(at);
			if (c == '\n'.code)
				end = at + 1
			else if (c != ' '.code && c != '\t'.code && c != '\r'.code)
				break;
			at++;
		}
		return text.substr(0, end);
	}

	/** The line of `version` holding `offset`. */
	private static function lineAt(version: FileVersion, offset: Int): Int {
		var line: Int = 0;
		while (line + 1 < version.starts.length && version.starts[line + 1] <= offset) line++;
		return line;
	}

}
