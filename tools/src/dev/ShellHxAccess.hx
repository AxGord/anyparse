package dev;

using Lambda;
using StringTools;

/**
 * The one answer to "does this shell command read or write a repo `.hx` outside hxq": the command is cut into its pipeline
 * and `&&` / `;` segments (a here-document body and a quoted payload are data, not commands), the working directory is
 * followed through its literal `cd`s, and a path counts only when it lies in a repo tree — the main tree, a `.wt/anyparse/<ID>`
 * worktree, or the agent's own `/tmp/hxqb-<ID>` tree. A `.wt/anyparse/<ID>` worktree is the repo whoever works in
 * it (the engine makes them), while a `/tmp/hxqb-*` directory is only the repo for the slice it is named after,
 * since fixtures are named like slices too. A slice's `-logs` directory, any other `/tmp` path and a path held in a
 * shell variable are not the repo, so a fixture written there is not a bypass.
 */
@:nullSafety(Strict)
final class ShellHxAccess {

	private static final SEGMENT: EReg = ~/\s*(?:&&|\|\||;|\||\n)\s*/g;
	private static final WORD: EReg = ~/\s+/g;
	private static final HEREDOC: EReg = ~/<<-?\s*['"]?\w+/;
	private static final QUOTED: EReg = ~/\$?'[^']*'|"[^"]*"/g;
	private static final OPAQUE: EReg = ~/[\s;&|<>]/;
	private static final CD: EReg = ~/^cd\s+(\S+)/;
	private static final READER: EReg = ~/^(?:cat|sed|head|tail|awk|nl|less|more)\b/;
	private static final EDITOR: EReg = ~/^(?:sed|perl)\b.*\s-[a-zA-Z]*i/;
	private static final REDIRECT: EReg = ~/(?:^|[^0-9&])>>?\s*(\S+)/;
	private static final HX_PATH: EReg = ~/(?:^|\/)(?:src|test|tools\/src)\/\S+\.hx$/;
	private static final SLICE_TREE: EReg = ~/^\/(?:private\/)?tmp\/hxqb-([A-Za-z0-9-]+)(?:\/|$)/;
	private static final OTHER_TMP: EReg = ~/^\/(?:private\/)?tmp\//;
	private static final MAIN_TREE: EReg = ~/^(?:\/[^\/]+)*\/anyparse(?:\/|$)/;
	private static final INTERPRETER: EReg = ~/^(?:python3?|node|perl|ruby)\b/;
	private static final SCRIPT_NAMES_HX: EReg = ~/\.hx['"`]/;
	private static final SCRIPT_WRITES: EReg = ~/open\([^)]*,\s*['"][wa]|write_text|writeFileSync|writeFile\b|\.write\(|File\.write/;

	/** Whether `command`, run in `cwd` by the agent of slice `slice`, reads a repo `.hx` with a pager or a stream editor. */
	public static function reads(command: String, cwd: Null<String>, slice: Null<String>): Bool {
		return readSegment(command, cwd, slice) != null;
	}

	/** The segment of `command` that reads a repo `.hx` with a pager or a stream editor, or null when none does. */
	public static function readSegment(command: String, cwd: Null<String>, slice: Null<String>): Null<String> {
		return find(
			command, cwd,
			(segment, dir) -> READER.match(segment) && !EDITOR.match(segment) && !REDIRECT.match(segment) && touches(segment, dir, slice)
		);
	}

	/** Whether `command` writes a repo `.hx` outside hxq (see `writeSegment`). */
	public static function writes(command: String, cwd: Null<String>, slice: Null<String>): Bool {
		return writeSegment(command, cwd, slice) != null;
	}

	/**
	 * The segment of `command` that writes a repo `.hx` outside hxq, or null: `sed -i` / `perl -i`, a redirect, `tee`, `cp` and
	 * `install` onto it, `mv` / `git mv` of it. An hxq or apq call is never one.
	 */
	public static function writeSegment(command: String, cwd: Null<String>, slice: Null<String>): Null<String> {
		return find(
			command, cwd,
			(segment, dir) -> !viaHxq(segment) && (
				EDITOR.match(segment)
				&& touches(segment, dir, slice)
				|| redirectsIntoRepo(segment, dir, slice)
				|| transfers(segment, dir, slice)
			)
		);
	}

	/**
	 * The interpreter segment of `command` whose script (a here-document or an inline program) names a `.hx` and calls a write,
	 * run in a repo directory, or null. A heuristic: the script text is not parsed.
	 */
	public static function scriptSegment(command: String, cwd: Null<String>, slice: Null<String>): Null<String> {
		return !SCRIPT_NAMES_HX.match(command) || !SCRIPT_WRITES.match(command)
			? null
			: find(
				command, cwd,
				(segment, dir) -> INTERPRETER.match(TokenTranscript.normalize(segment)) && dir != null && isRepoPath(dir, slice)
			);
	}

	/** Whether the absolute `path` lies in a repo tree of the agent of slice `slice`. */
	public static function isRepoPath(path: String, slice: Null<String>): Bool {
		return !path.contains('-logs')
			&& (SLICE_TREE.match(path) ? slice != null && SLICE_TREE.matched(1) == slice : !OTHER_TMP.match(path) && MAIN_TREE.match(path));
	}

	/** The segments of `command` before its first here-document, with every quoted span that holds a separator blanked. */
	private static function segments(command: String): Array<String> {
		final head: String = HEREDOC.match(command) ? command.substr(0, HEREDOC.matchedPos().pos) : command;
		final plain: String = QUOTED.map(head, quoted -> OPAQUE.match(quoted.matched(0)) ? '\'\'' : quoted.matched(0));
		return [for (segment in SEGMENT.split(plain)) segment.trim()].filter(segment -> segment != '');
	}

	private static function viaHxq(segment: String): Bool {
		return TokenTranscript.bashKey(TokenTranscript.normalize(segment)).startsWith('hxq ');
	}

	private static function redirectsIntoRepo(segment: String, dir: Null<String>, slice: Null<String>): Bool {
		return REDIRECT.match(segment) && isRepoHx(resolve(unquote(REDIRECT.matched(1)), dir), slice);
	}

	/** Whether a word of `segment` names a repo `.hx`. */
	private static function touches(segment: String, dir: Null<String>, slice: Null<String>): Bool {
		return WORD.split(segment).exists(word -> isRepoHx(resolve(unquote(word), dir), slice));
	}

	private static function isRepoHx(path: Null<String>, slice: Null<String>): Bool {
		return path != null && HX_PATH.match(path) && isRepoPath(path, slice);
	}

	/** The absolute path `word` names from `dir`, or null when it is held in a variable, in `~`, or `dir` is unknown. */
	private static function resolve(word: String, dir: Null<String>): Null<String> {
		if (word.startsWith('/')) return word;
		if (word.contains('$') || word.startsWith('~') || dir == null) return null;
		return '$dir/${word.startsWith('./') ? word.substr(2) : word}';
	}

	/** The directory after `cd target` from `dir`: unknown (null) when the target is a variable, `~` or `-`. */
	private static function enter(dir: Null<String>, target: String): Null<String> {
		final word: String = unquote(target);
		return word == '-' ? null : resolve(word, dir);
	}

	private static function unquote(word: String): String {
		return word.replace('\'', '').replace('"', '');
	}

	/** The first segment of `command` for which `test` holds, given the directory the segment runs in; null when none does. */
	private static function find(command: String, cwd: Null<String>, test: (String, Null<String>) -> Bool): Null<String> {
		var dir: Null<String> = cwd;
		for (segment in segments(command)) {
			if (CD.match(segment)) {
				dir = enter(dir, CD.matched(1));
			} else if (test(segment, dir)) {
				return segment;
			}
		}
		return null;
	}

	/** Whether `segment` copies onto, writes through `tee` to, or moves a repo `.hx` (`cp`, `install`, `tee`, `mv`, `git mv`). */
	private static function transfers(segment: String, dir: Null<String>, slice: Null<String>): Bool {
		final words: Array<String> = [
			for (word in WORD.split(TokenTranscript.normalize(segment))) if (word != '' && !word.startsWith('-')) word
		];
		final gitMove: Int = words[0] == 'git' ? words.indexOf('mv') : -1;
		final program: String = gitMove >= 0 ? 'mv' : words[0] ?? '';
		final args: Array<String> = words.slice(gitMove >= 0 ? gitMove + 1 : 1);
		final named: Array<String> = switch program {
			case 'cp', 'install': args.slice(args.length - 1);
			case 'mv', 'tee': args;
			case _: [];
		};
		return named.exists(word -> isRepoHx(resolve(unquote(word), dir), slice));
	}

}
