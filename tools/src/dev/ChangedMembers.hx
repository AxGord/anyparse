package dev;

/**
 * What a `hxq changed` report says about the members of each file: the one answer to "which members of a source file did the
 * slice change, or can its report not say". A file whose change cannot be told member by member (a type's own header, a type
 * edited or removed as a whole, a conditional block, a parameter, a file that is new, renamed or not read as declarations) has no
 * member list, and a reader of the answer takes every member of it as changed. A layout-only file is not in the answer.
 */
@:nullSafety(Strict)
final class ChangedMembers {

	/** The group of a declaration row that holds the declaration's name. */
	private static inline final NAME_GROUP: Int = 3;

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
		final row: EReg = ~/^ +([-+~]) (\S+?)(?::(\S+))?(?: .*)?$/;
		var path: Null<String> = null;
		var members: Array<String> = [];
		for (line in report.split('\n')) {
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
				if (HEADER_KINDS.contains(kind) || row.matched(1) == '+' && TYPE_KINDS.contains(kind)) continue;
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

}
