package dev;

using Lambda;
using StringTools;

/**
 * What a `hxq changed --diff` report says about the members of each file: the one answer to "which members of a source
 * file did the slice change, or can its report not say". A file whose change cannot be told member by member (a type's own header,
 * unless the diff lines under it differ in comments alone; a type edited or removed as a whole, a conditional block, a parameter,
 * a file that is new, renamed or not read as declarations) has no member list, and a reader of the answer takes every member of it
 * as changed. A layout-only file is not in the answer.
 */
@:nullSafety(Strict)
final class ChangedMembers {

	/** The group of a declaration row that holds the declaration's name. */
	private static inline final NAME_GROUP: Int = 3;

	/** The indent of the lines `--diff` prints under a declaration row: a row itself is indented by less. */
	private static inline final DIFF_INDENT: String = '        ';

	/** The kinds of a declaration row that name one member, whose change reaches that member alone. */
	private static final MEMBER_KINDS: Array<String> = [
		'FnMember',
		'VarMember',
		'FinalMember',
		'VarField',
		'FinalField',
		'ParamCtor',
		'SimpleCtor'
	];

	/** The kinds of a row that names a type of the file: adding one changes no member that was there. */
	private static final TYPE_KINDS: Array<String> = [
		'ClassDecl',
		'ClassForm',
		'InterfaceDecl',
		'AbstractDecl',
		'EnumDecl',
		'TypedefDecl'
	];

	/**
	 * The import rows of a file: they are read by the members that changed. A `(module)` row is no import:
	 * it is a difference no declaration's own lines show (a member reorder), so it leaves the file unnamed.
	 */
	private static final HEADER_KINDS: Array<String> = ['import', 'using'];

	/**
	 * The members each file of `report` changed, by path: a file whose report cannot name them maps to null, and a file whose only
	 * change is its imports to none. A file the report does not list is not in the answer either, and its reader widens to all.
	 */
	public static function of(report: String): Map<String, Null<Array<String>>> {
		final said: Map<String, Null<Array<String>>> = [];
		final fileRow: EReg = ~/^\S+ (.+?)(?:  <- .+?)?  (layout|imports|renamed|declarations|values|text|new)(?:  .*)?$/;
		final row: EReg = ~/^ {4}([-+~]) (\S+?)(?::(\S+))?(?: .*)?$/;
		var path: Null<String> = null;
		var members: Array<String> = [];
		final lines: Array<String> = report.split('\n');
		var at: Int = 0;
		while (at < lines.length) {
			final line: String = lines[at++];
			if (fileRow.match(line)) {
				final file: String = fileRow.matched(1);
				path = null;
				switch fileRow.matched(2) {
					case 'layout':
					case 'imports':
						said[file] = [];
					case 'declarations':
						path = file;
						members = [];
						said[file] = members;
					case _:
						said[file] = null;
				}
			} else if (path != null && row.match(line)) {
				final kind: String = row.matched(2);
				final name: Null<String> = row.matched(NAME_GROUP);
				final diff: Array<String> = [
					while (at < lines.length && lines[at].startsWith(DIFF_INDENT)) lines[at++].substr(DIFF_INDENT.length)
				];
				final onType: Bool = TYPE_KINDS.contains(kind);
				if (HEADER_KINDS.contains(kind) || onType && (row.matched(1) == '+' || row.matched(1) == '~' && commentsOnly(diff)))
					continue;
				if (name != null && MEMBER_KINDS.contains(kind)) {
					members.push(name);
				} else {
					said[path] = null;
					path = null;
				}
			}
		}
		return said;
	}

	/**
	 * Whether a type's header differs in comments alone, from the `--diff` lines under its row: the code of the old side (context and
	 * `-` lines) equals the code of the new side. A report without diff lines proves nothing, so a header it cannot read stays changed.
	 */
	private static function commentsOnly(diff: Array<String>): Bool {
		if (diff.length == 0) return false;
		final before: Array<String> = [];
		final after: Array<String> = [];
		for (line in diff) {
			final text: String = line == '...' ? line : line.substr(2);
			if (line.startsWith('  ') || line == '...') {
				before.push(text);
				after.push(text);
			} else if (line.startsWith('- ')) {
				before.push(text);
			} else if (line.startsWith('+ ')) {
				after.push(text);
			} else {
				return false;
			}
		}
		final old: Array<String> = codeOf(before);
		final now: Array<String> = codeOf(after);
		return old.length == now.length && [for (i in 0...old.length) old[i] == now[i]].foreach(same -> same);
	}

	/**
	 * The lines of one side of a header diff that hold code, trimmed, with each `...` gap kept. A line is a comment when it opens `//`
	 * or `/*`, is inside a block comment, or continues one (starts `*`); a block comment that shares its line with code stays code, so
	 * the comparison can only widen.
	 */
	private static function codeOf(lines: Array<String>): Array<String> {
		final code: Array<String> = [];
		var inBlock: Bool = false;
		for (line in lines) {
			final text: String = line.trim();
			if (text == '...') {
				inBlock = false;
				code.push(text);
				continue;
			}
			final close: Int = text.indexOf('*/');
			if (inBlock || text.startsWith('/*')) {
				inBlock = close < 0;
				if (close < 0 || close == text.length - 2) continue;
			} else if (text.startsWith('//') || text.startsWith('*')) {
				continue;
			}
			if (text != '') code.push(text);
		}
		return code;
	}

}
