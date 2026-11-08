package dev;

using Lambda;
using StringTools;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.LexicalRegions;
import anyparse.runtime.Span;

/**
 * What a `hxq changed --diff` report says about the members of each file: the one answer to "which members of a source
 * file did the slice change, or can its report not say". A member whose diff lines differ in comments alone is no change. A file
 * whose change cannot be told member by member (a type's own header, unless likewise comments alone; a type edited or removed as
 * a whole, a conditional block, a parameter, a file that is new, renamed or not read as declarations) has no member list, and a
 * reader of the answer takes every member of it as changed. A layout-only or deleted file names no member.
 */
@:nullSafety(Strict)
final class ChangedMembers {

	/** The group of a declaration row that holds the declaration's name. */
	private static inline final NAME_GROUP: Int = 3;

	/** The indent of the lines `--diff` prints under a declaration row: a row itself is indented by less. */
	private static inline final DIFF_INDENT: String = '        ';

	/**
	 * A line that continues a block comment: the writer emits the star of a doc line one space past the indent, which no operator
	 * line of code does, so a hunk that opens inside a comment is still read as one.
	 */
	private static final DOC_STAR: EReg = ~/^\t* \*/;

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
		final fileRow: EReg = ~/^\S+ (.+?)(?:  <- .+?)?  (layout|imports|renamed|declarations|values|text|new|deleted)(?:  .*)?$/;
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
					case 'imports', 'deleted':
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
				final member: Null<String> = MEMBER_KINDS.contains(kind) ? name : null;
				final sign: String = row.matched(1);
				if (
					HEADER_KINDS.contains(kind)
					|| (TYPE_KINDS.contains(kind) && sign == '+')
					|| ((member != null || TYPE_KINDS.contains(kind)) && sign == '~' && commentsOnly(diff))
				)
					continue;
				if (member != null) {
					members.push(member);
				} else {
					said[path] = null;
					path = null;
				}
			}
		}
		return said;
	}

	/**
	 * Whether a type's header or a member differs in comments alone, from the `--diff` lines under its row: the code of the old side
	 * (context and `-` lines) equals the code of the new side. A report without diff lines proves nothing, so a change it cannot read
	 * stays changed.
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
	 * The lines of one side of a diff that hold code, trimmed, with each `...` gap kept. The lines between two gaps are lexed
	 * as one text, so a block comment a hunk opens ends with the hunk. A line is a comment when no code byte of it lies outside a
	 * comment region (an opener inside a string is text) or when it continues a block comment (`DOC_STAR`), which a hunk may open
	 * inside; a comment that shares its line with code stays code. A fragment cannot show that it opened inside a multi-line string,
	 * so a hunk that does can still misread the lines after it.
	 */
	private static function codeOf(lines: Array<String>): Array<String> {
		final code: Array<String> = [];
		var run: Array<String> = [];
		for (line in lines) {
			if (line.trim() != '...') {
				run.push(line);
				continue;
			}
			for (kept in codeLinesOf(run)) code.push(kept);
			run = [];
			code.push('...');
		}
		for (kept in codeLinesOf(run)) code.push(kept);
		return code;
	}

	/**
	 * The trimmed lines of `whole`, lexed as one text, that hold a byte of code outside every comment. The leading lines that continue
	 * a block comment are dropped first: a hunk may open inside a doc comment, and an apostrophe there would open a string in the lexer.
	 */
	private static function codeLinesOf(whole: Array<String>): Array<String> {
		var lead: Int = 0;
		while (lead < whole.length && DOC_STAR.match(whole[lead])) lead++;
		final run: Array<String> = whole.slice(lead);
		final text: String = run.join('\n');
		final comments: Array<LexRegion> = new HaxeQueryPlugin().lexicalRegions(text).filter(LexicalRegions.isComment);
		final spans: Array<Span> = LexicalRegions.codeSpans(text.length, comments);
		final code: Array<String> = [];
		var from: Int = 0;
		for (line in run) {
			final lineFrom: Int = from;
			final lineTo: Int = from + line.length;
			from = lineTo + 1;
			final held: Bool = spans.exists(
				span ->
					span.from < lineTo
					&& span.to > lineFrom
					&& text.substring(Std.int(Math.max(span.from, lineFrom)), Std.int(Math.min(span.to, lineTo))).trim() != ''
			);
			if (held && !DOC_STAR.match(line)) code.push(line.trim());
		}
		return code;
	}

}
