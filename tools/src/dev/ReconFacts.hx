package dev;

import dev.QueueFile.QueueLine;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Result;
import haxe.Exception;
import haxe.crypto.Sha1;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/** What the recon of a queue line is to do, and why. */
enum ReconRoute {

	/** No previous recon: a full one. */
	Full;

	/** A previous recon exists but the line or the touched paths moved under it. */
	Update(why: String);

	/** The previous recon is still current. */
	Skip(why: String);

	/** Another recon of the same line runs. */
	Refused(why: String);

}

/** The route of a recon and the text its stdout carries: the facts, or the reason there are none. */
typedef ReconVerdict = {
	final route: ReconRoute;
	final text: String;
}

/** How often a name is mentioned in the scope: leaf hits and the files holding them. */
typedef MentionCount = {
	final hits: Int;
	final files: Int;
}

/**
 * `dev recon-facts <ID> <worktree>` — the one answer to "what does the recon of a queue line need that a script can collect, and is the
 * recon it already has still good": writes `<worktree>-logs/facts.md` (the line, its touched paths, its owner, the mentions of the
 * names it backticks, the commits that moved the touched paths, its `after:` commits, its sibling lines) and prints the same text after
 * a `route:` line. The exit code is the route: 0 full, 10 update, 11 skip, 12 refused (another recon of the line runs), 2 unreadable.
 * A skip or a refusal prints only the reason and leaves facts.md as it was.
 */
@:nullSafety(Strict)
final class ReconFacts {

	public static inline final USAGE: String =
		'usage: dev recon-facts <ID> <worktree> [--queue <file>] [--engine <apq.js>] [--holder <token>]';
	public static inline final EXIT_FULL: Int = 0;
	public static inline final EXIT_UPDATE: Int = 10;
	public static inline final EXIT_SKIP: Int = 11;
	public static inline final EXIT_REFUSED: Int = 12;

	/** How long a recon's lock keeps another recon of the line out when that recon never wrote its recon.md. */
	private static inline final LOCK_TTL_MS: Float = 60 * 60 * 1000;

	private static inline final MAX_COMMITS: Int = 20;
	private static inline final MAX_NAMES: Int = 12;
	private static inline final OWNER_TOP: Int = 5;
	private static inline final BODY_CHARS: Int = 500;
	private static inline final TEXT_CHARS: Int = 3000;
	private static inline final SUBJECT_CHARS: Int = 110;
	private static inline final HASH_CHARS: Int = 12;
	private static final NONE: String = 'none\n';
	private static final FALLBACK_SCOPE: Array<String> = ['src', 'test', 'tools'];
	private static final BACKTICKED: EReg = ~/`([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)`/;
	private static final TRAILER: EReg = ~/^(Co-Authored-By|Slice|Review-Rounds|Tokens):/;
	private static final HIT_LINE: EReg = ~/^\s+(\d+:\d+):/;
	private static final SECTION_NAME: EReg = ~/^=== (.*) ===$/;
	private static final HEAD_FIELD: EReg = ~/^head: (\S+)$/m;
	private static final HASH_FIELD: EReg = ~/^line-hash: (\S+)$/m;

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final queue: Null<String> = args.option('--queue');
		final engine: Null<String> = args.option('--engine');
		final holder: Null<String> = args.option('--holder');
		final positional: Array<String> = args.positionals(['<ID>', '<worktree>']);
		final verdict: ReconVerdict = run(positional[0], Path.removeTrailingSlashes(positional[1]), queue, engine, holder);
		Sys.print(verdict.text);
		return exitCode(verdict.route);
	}

	public static function exitCode(route: ReconRoute): Int {
		return switch route {
			case Full: EXIT_FULL;
			case Update(_): EXIT_UPDATE;
			case Skip(_): EXIT_SKIP;
			case Refused(_): EXIT_REFUSED;
		}
	}

	/**
	 * The route of the recon of line `id` for the worktree `tree` and the text to print. A full or update route writes facts.md and
	 * takes the line's lock (`holder`, the token of the run the recon belongs to, or none).
	 */
	public static function run(id: String, tree: String, queue: Null<String>, engine: Null<String>, holder: Null<String>): ReconVerdict {
		final queueFile: String = queue ?? Path.join([Path.directory(commonDir(tree)), '.claude/batch/queue.yaml']);
		final line: Null<QueueLine> = QueueFile.find(File.getContent(queueFile), id);
		if (line == null) throw new Exception('$queueFile has no line $id');
		final logs: String = '$tree-logs';
		final recon: String = Path.join([logs, 'recon.md']);
		final facts: String = Path.join([logs, 'facts.md']);
		final lock: String = Path.join([logs, 'recon.lock']);
		final head: String = GateTree.gitIn(tree, ['rev-parse', 'main']).trim();
		final hash: String = lineHash(line);
		final route: ReconRoute = lockHeld(lock, recon, holder) ?? previous(tree, line, hash, head, recon, facts);
		switch route {
			case Skip(why), Refused(why):
				return { route: route, text: '${verdictLine(route)}$why\n' };
			case _:
		}
		final rendered: String = body(tree, queueFile, line, route, head, hash, engine, previousHead(facts));
		FileSystem.createDirectory(logs);
		File.saveContent(facts, rendered);
		File.saveContent(lock, 'holder ${holder ?? 'none'}\n');
		return { route: route, text: verdictLine(route) + rendered + verdictLine(route) };
	}

	/**
	 * The count of mentions per name in the output `output` of `apq mentions <names> -- <scope>`: the union of its `uses`, `refs` and
	 * `lit` hits, each position once, and the files holding them (the sections list different positions, `lit` is not a superset).
	 */
	public static function countMentions(output: String, names: Array<String>): Map<String, MentionCount> {
		final spots: Map<String, Map<String, String>> = [];
		var current: String = names[0] ?? '';
		var file: String = '';
		for (row in output.split('\n')) {
			if (SECTION_NAME.match(row)) {
				current = SECTION_NAME.matched(1);
			} else if (!row.startsWith('#') && !row.startsWith(' ') && row.endsWith(':')) {
				file = row;
			} else if (HIT_LINE.match(row)) {
				final spot: Map<String, String> = spots[current] ?? [];
				spot['$file${HIT_LINE.matched(1)}'] = file;
				spots[current] = spot;
			}
		}
		final counts: Map<String, MentionCount> = [];
		for (n in names) {
			final spot: Map<String, String> = spots[n] ?? [];
			final holding: Array<String> = [];
			for (path in spot) if (!holding.contains(path)) holding.push(path);
			final count: MentionCount = { hits: spot.count(), files: holding.length };
			counts[n] = count;
		}
		return counts;
	}

	/** The names a line's text puts in backticks and the tools can look up: identifiers, a dotted path by its last segment. */
	public static function backtickedNames(text: String): Array<String> {
		final names: Array<String> = [];
		var rest: String = text;
		while (BACKTICKED.match(rest)) {
			final path: String = BACKTICKED.matched(1);
			final name: String = path.substr(path.lastIndexOf('.') + 1);
			if (name.length > 2 && !names.contains(name)) names.push(name);
			rest = BACKTICKED.matchedRight();
		}
		return names.slice(0, MAX_NAMES);
	}

	/** Short hash of what a recon reads of the line: its text, touches and owner. */
	public static function lineHash(line: QueueLine): String {
		return Sha1.encode('${line.text}\n${line.touches.join(',')}\n${line.owner}').substr(0, HASH_CHARS);
	}

	/**
	 * Where the tools look for the line: its touched directories and `.hx` files that exist; a line that touches none of them
	 * (most queue lines name no `touches:`) gets the project's source roots, so its names are still counted.
	 */
	public static function mentionScope(tree: String, touches: Array<String>): Array<String> {
		final touched: Array<String> = touches.filter(path -> hxScope(tree, path));
		return touched.length > 0 ? touched : FALLBACK_SCOPE.filter(dir -> FileSystem.exists(Path.join([tree, dir])));
	}

	/** The line that names the route: first, and last when facts follow, because an exec keeps the tail of a long output. */
	private static function verdictLine(route: ReconRoute): String {
		return 'route: ${name(route)} (exit ${exitCode(route)})\n';
	}

	private static function name(route: ReconRoute): String {
		return switch route {
			case Full: 'full';
			case Update(_): 'update';
			case Skip(_): 'skip';
			case Refused(_): 'refused';
		}
	}

	private static function commonDir(tree: String): String {
		return GateTree.gitIn(tree, ['rev-parse', '--path-format=absolute', '--git-common-dir']).trim();
	}

	/**
	 * Refused while the lock of the line is younger than the TTL and no recon.md was written
	 * since; never against its own holder token, so a retry of the same run re-takes it.
	 */
	private static function lockHeld(lock: String, recon: String, holder: Null<String>): Null<ReconRoute> {
		if (!FileSystem.exists(lock)) return null;
		final taken: Float = FileSystem.stat(lock).mtime.getTime();
		if (FileSystem.exists(recon) && FileSystem.stat(recon).mtime.getTime() >= taken) return null;
		if (Date.now().getTime() - taken >= LOCK_TTL_MS) return null;
		final owner: String = File.getContent(lock).trim().substr('holder '.length);
		return holder != null && owner == holder
			? null
			: Refused('another recon of this line runs (holder $owner, lock younger than an hour); lock: $lock');
	}

	private static function previousHead(facts: String): Null<String> {
		return FileSystem.exists(facts) && HEAD_FIELD.match(File.getContent(facts)) ? HEAD_FIELD.matched(1) : null;
	}

	/** Whether the recon.md already there is still good, judged by the head and the line hash facts.md recorded beside it. */
	private static function previous(tree: String, line: QueueLine, hash: String, head: String, recon: String, facts: String): ReconRoute {
		if (!FileSystem.exists(recon)) return Full;
		final recorded: Null<String> = previousHead(facts);
		final text: String = FileSystem.exists(facts) ? File.getContent(facts) : '';
		if (recorded == null || !HASH_FIELD.match(text)) return Update('recon.md has no recorded base (facts.md missing)');
		// facts.md is written when a recon starts; a recon.md older than it belongs to a recon that did not finish
		if (FileSystem.stat(recon).mtime.getTime() < FileSystem.stat(facts).mtime.getTime())
			return Update('recon.md is older than facts.md: the recon that followed those facts did not finish');
		if (HASH_FIELD.matched(1) != hash) return Update('the queue line (text, touches or owner) changed since the previous recon');
		final moved: Null<Array<String>> = commitsOf(tree, ['$recorded..$head'], line.touches);
		if (moved == null) return Update('the previous base $recorded is not reachable from main');
		if (moved.length > 0)
			return Update('${moved.length} commit(s) on main touched the touched paths since the previous base $recorded');
		return Skip('the previous recon.md stands: base $recorded, same line, no commit touched ${line.touches.join(', ')} since');
	}

	/** The commits of `range` touching `paths` as `<hash> <date> <subject>`; null when git cannot answer; none when `paths` is empty. */
	private static function commitsOf(tree: String, range: Array<String>, paths: Array<String>): Null<Array<String>> {
		if (paths.length == 0) return [];
		final format: String = '--format=%h %ad %s';
		final run: Result = cmd('git -C $tree log $range --date=short $format -- $paths').run();
		return run.ok ? [
			for (row in run.lines()) if (row != '') row.length > SUBJECT_CHARS ? '${row.substr(0, SUBJECT_CHARS)}...' : row
		] : null;
	}

	private static function body(
		tree: String, queueFile: String, line: QueueLine, route: ReconRoute, head: String, hash: String, engine: Null<String>,
		previousHead: Null<String>
	): String {
		final out: StringBuf = new StringBuf();
		final newest: String = line.notes.fold((note, newest) -> note.date > newest ? note.date : newest, '');
		final since: Array<String> = if (line.base != '')
			['${line.base}..main']
		else if (newest != '')
			['main', '--since=$newest 00:00:00']
		else
			['main', '-n', '$MAX_COMMITS'];
		final sinceDate: String = line.base != ''
			? GateTree.gitIn(tree, ['show', '-s', '--format=%ad', '--date=short', line.base]).trim()
			: newest;
		out.add('# recon facts ${line.id}\n\nhead: $head\nline-hash: $hash\nroute: ${name(route)}${switch route {
			case Update(why): ' ($why)';
			case _: '';
		}}\n\n');
		out.add(
			'## line\nstatus: ${line.status}\nafter: '
			+ line.after.join(', ')
			+ '\nowner: ${line.owner}\ntouches: '
			+ line.touches.join(', ')
			+ '\n\n${cut(line.text)}\n\n'
		);
		out.add('## touches\n');
		for (path in line.touches) out.add('- $path: ${FileSystem.exists(Path.join([tree, path])) ? 'exists' : 'MISSING'}\n');
		final scope: Array<String> = mentionScope(tree, line.touches);
		final hxq: Null<String> = engineOf(tree, engine);
		out.add('\n## owner (hxq owner "${line.owner}")\n');
		out.add(
			hxq == null
				? 'no hxq engine found\n'
				: scope.length == 0 || line.owner == '' ? 'the line has no owner to ask for\n' : owners(tree, hxq, line.owner, scope)
		);
		out.add('\n## mentions of the backticked names (hxq mentions: type positions, value bindings and leaves, each position once)\n');
		out.add(
			hxq == null
				? 'no hxq engine found\n'
				: scope.length == 0 ? 'no source directory to ask\n' : mentions(tree, hxq, backtickedNames(line.text), scope)
		);
		out.add('\n## commits on main touching the touched paths\nbase: ${baseSaid(line, newest)}\n');
		out.add(commitLines(commitsOf(tree, since, line.touches)));
		if (previousHead != null) {
			out.add('\n## since the previous recon ($previousHead)\n');
			out.add(commitLines(commitsOf(tree, ['$previousHead..$head'], line.touches)));
		}
		out.add('\n## after\n');
		out.add(line.after.length == 0 ? NONE : line.after.map(id -> afterLine(tree, queueFile, id)).join(''));
		out.add('\n## siblings with the same owner that ended or run since ${sinceDate == '' ? 'the start' : sinceDate}\n');
		out.add(siblings(queueFile, line, sinceDate));
		return out.toString();
	}

	private static function baseSaid(line: QueueLine, newest: String): String {
		if (line.base != '') return 'the line\'s recorded commit ${line.base}';
		if (newest != '')
			return 'date $newest'
				+ ', the newest note of the line (the line records no base commit: it was queued before the queue tools wrote one)';
		return 'none: the line has no note and records no commit';
	}

	private static function commitLines(commits: Null<Array<String>>): String {
		if (commits == null) return 'git could not answer\n';
		if (commits.length == 0) return NONE;
		final shown: Array<String> = commits.slice(0, MAX_COMMITS).map(row -> '- $row\n');
		return shown.join('') + (commits.length > MAX_COMMITS ? '- (+${commits.length - MAX_COMMITS} more)\n' : '');
	}

	private static function hxScope(tree: String, path: String): Bool {
		final full: String = Path.join([tree, path]);
		return FileSystem.exists(full) && (FileSystem.isDirectory(full) || path.endsWith('.hx'));
	}

	private static function engineOf(tree: String, given: Null<String>): Null<String> {
		if (given != null) return given;
		final env: Null<String> = Sys.getEnv('HXQ_BIN');
		if (env != null && FileSystem.exists(env)) return env;
		for (dir in [tree, Path.directory(commonDir(tree))]) {
			final engine: String = Path.join([dir, 'bin/apq.js']);
			if (FileSystem.exists(engine)) return engine;
		}
		return null;
	}

	private static function owners(tree: String, engine: String, owner: String, scope: Array<String>): String {
		final top: String = '$OWNER_TOP';
		final run: Result = cmd('node $engine owner $owner $scope --limit $top').at(tree).run();
		return run.ok ? run.out : 'hxq owner failed: ${run.firstError()}\n';
	}

	private static function mentions(tree: String, engine: String, names: Array<String>, scope: Array<String>): String {
		if (names.length == 0) return 'the line backticks no name\n';
		final run: Result = cmd('node $engine mentions $names -- $scope').at(tree).run();
		if (!run.ok) return 'hxq mentions failed: ${run.firstError()}\n';
		final counts: Map<String, MentionCount> = countMentions(run.out, names);
		return names.map(n -> '- $n: ${counts[n]?.hits ?? 0} in ${counts[n]?.files ?? 0} file(s)\n').join('');
	}

	private static function afterLine(tree: String, queueFile: String, id: String): String {
		final other: Null<QueueLine> = QueueFile.find(File.getContent(queueFile), id);
		final state: String = other == null ? 'not a queue line' : 'queue status ${other.status}';
		final pattern: String = '--grep=^Slice: $id$$';
		final format: String = '--format=%h %s%n%b';
		final run: Result = cmd('git -C $tree log main -n 1 $pattern $format').run();
		final message: String = run.ok ? run.out.split('\n').filter(row -> !TRAILER.match(row) && row.trim() != '').join(' ') : '';
		final shown: String = message.length > BODY_CHARS ? '${message.substr(0, BODY_CHARS)}...' : message;
		return '- $id ($state): ${shown == '' ? 'no commit on main carries `Slice: $id`' : shown}\n';
	}

	private static function siblings(queueFile: String, line: QueueLine, sinceDate: String): String {
		final same: Array<QueueLine> = line.owner == ''
			? []
			: QueueFile.read(File.getContent(queueFile)).filter(
				other ->
					other.id != line.id
					&& other.owner == line.owner
					&& (other.status == 'running' || (other.ended != '' && other.ended >= sinceDate))
			);
		return same.length == 0
			? NONE
			: same.map(other ->
				'- ${other.id}: ${other.status}${other.ended == '' ? '' : ' ' + other.ended}, touches ${other.touches.join(', ')}\n'
			)
				.join('');
	}

	/** `text` as far as the facts keep it: the recon reads the whole line in the queue. */
	private static function cut(text: String): String {
		return text.length > TEXT_CHARS
			? '${text.substr(0, TEXT_CHARS)} ... (cut at $TEXT_CHARS characters; the queue line has the rest)'
			: text;
	}

}
