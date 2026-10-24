package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Result;
import haxe.Exception;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The acceptance matrices of the two hxq hooks, whose installed copies live under `.claude/hooks/` — gitignored, so no
 * suite test reaches them. Each case varies ONE thing and names the verdict the hook must give; the exit status is the
 * number of failing cases, 77 when there is no hook to probe (an absent per-machine file is not a failure).
 *
 * `gate-probe` drives the PreToolUse edit/read gate (`.claude/hooks/hxq-gate.sh`, or `HXQ_GATE_HOOK`): it classified a
 * command by scanning its whole text once, so payload prose and `git -C … diff -- F.hx` were denied as reads; the deny
 * and warn cases are here so that fix cannot widen into a hole. `lint-warn-probe` drives the PostToolUse nudge
 * (`tools/hooks/hxq-lint-warn.sh`, or `HXQ_LINT_WARN_HOOK`): its early exits, its tree resolution, and the delta — a
 * first touch shows what is standing, a second says nothing new, and a NEW finding still reaches the reader.
 */
@:nullSafety(Strict)
final class HookProbe {

	public static inline final GATE_USAGE: String = 'usage: dev gate-probe [--repo <tree>]';
	public static inline final LINT_WARN_USAGE: String = 'usage: dev lint-warn-probe [--repo <tree>]';

	/** The status of a probe with no hook to run. */
	private static inline final NO_HOOK: Int = 77;

	/** The extension spelled apart, so no line of this file reads as a command on a `.hx` file to a gate scanning it. */
	private static inline final X: String = '.hx';

	private static inline final ALLOW: String = 'allow';
	private static inline final DENY: String = 'deny';
	private static inline final WARN: String = 'warn';
	private static inline final SILENT: String = 'silent';
	private static inline final SPEAKS: String = 'speaks';

	/** The width of the verdict column: the longest verdict of the matrix. */
	private static inline final GATE_WIDTH: Int = 5;

	private static inline final LINT_WARN_WIDTH: Int = 6;

	/** The session id of every lint-warn probe payload, so its snapshot can be cleared before a run. */
	private static inline final SESSION: String = 'probe-session';

	public static function gate(argv: Array<String>): Int {
		final found: Null<String> = hookOf(argv, 'HXQ_GATE_HOOK', '.claude/hooks/hxq-gate.sh');
		if (found == null) return NO_HOOK;
		final hook: String = found;
		final h: String = 'head';
		final g: String = 'grep';
		final s: String = 'sed';
		final cli: String = 'src/anyparse/query/Cli$X';
		final matrix: Matrix = new Matrix(GATE_WIDTH);
		function probe(want: String, command: String): Void {
			final run: Result = Command.of([hook]).input(Json.stringify({ tool_name: 'Bash', tool_input: { command: command } })).run();
			final out: String = run.out + run.err;
			matrix.check(want, out == '' ? ALLOW : decision(out), command);
		}
		Sys.println('-- T470: payload text is DATA, not a command --');
		probe(ALLOW, 'hxq comment-rewrite \'the $h of the list\' \'the front of the list\' $cli --write');
		probe(ALLOW, 'hxq comment-rewrite \'we $g the tree\' \'we walk the tree\' $cli --write');
		probe(ALLOW, 'hxq set-doc src/anyparse/check/scan/NullFlow$X --select \'FnMember:x\' \'reads the $h then walks\'');
		probe(ALLOW, 'hxq patch $cli --select \'FnMember:x\' --write \'a $s b\'');
		probe(ALLOW, 'hxq lit \'$h\' src/anyparse/query/ShardPlan$X --limit 3');
		Sys.println('-- git -C is VCS inspection --');
		probe(ALLOW, 'git -C /tmp/w diff -- $cli');
		probe(ALLOW, 'rtk proxy git -C /tmp/w diff -- $cli | $h -60');
		probe(ALLOW, 'git --no-pager log -p -- $cli');
		probe(ALLOW, 'git diff -- $cli');
		Sys.println('-- real readers must stay denied --');
		probe(DENY, 'cat $cli');
		probe(DENY, 'cat \'$cli\'');
		probe(DENY, '$h -5 $cli');
		probe(DENY, '$s -n \'1,20p\' $cli');
		probe(DENY, '$g -n \'foo\' $cli');
		probe(DENY, 'awk \'NR<5\' $cli');
		probe(DENY, '$g -rn \'foo\' src/');
		probe(DENY, '$s -n \'141,148p\' /Users/axg/dev/libs/Pony/src/pony/text/ParseBoy$X');
		probe(DENY, 'find src -name \'*$X\' -exec cat {} +');
		Sys.println('-- hxq output truncation must stay a warning --');
		probe(WARN, 'hxq source $cli --range 1:20 | $h -3');
		probe(WARN, 'hxq ast $cli | $h -3');
		Sys.println('-- other allowed shapes --');
		probe(ALLOW, 'find src -name \'*$X\' | $h -5');
		probe(ALLOW, 'cat /tmp/scratch$X');
		probe(ALLOW, 'git ls-files | $g \'$X$$\' | $h -5');
		probe(ALLOW, 'hxq patch $cli --select \'FnMember:f\' --write - <<\'EOF\'');
		return matrix.end();
	}

	public static function lintWarn(argv: Array<String>): Int {
		final repo: String = Repo.resolve(new Args(argv).option('--repo'));
		final found: Null<String> = hookOf(argv, 'HXQ_LINT_WARN_HOOK', 'tools/hooks/hxq-lint-warn.sh');
		if (found == null) return NO_HOOK;
		final hook: String = found;
		final matrix: Matrix = new Matrix(LINT_WARN_WIDTH);
		// one payload shaped like the Bash PostToolUse event: the merged capture lands under `stdout`
		function nudge(command: String, output: String): String {
			final payload: String = Json.stringify({
				session_id: SESSION,
				cwd: repo,
				tool_name: 'Bash',
				tool_input: { command: command },
				tool_response: { stdout: output, stderr: '' }
			});
			return additionalContext(cmd('sh $hook').input(payload).run().out);
		}
		function probe(want: String, label: String, command: String, output: String): Void {
			matrix.check(want, nudge(command, output) == '' ? SILENT : SPEAKS, label);
		}
		final cli: String = '$repo/src/anyparse/query/Cli$X';
		Sys.println('-- early exit: the response never says a write happened --');
		probe(SILENT, 'a read-only query', 'hxq refs foo src/', 'src/a$X:1:1: foo');
		probe(SILENT, 'an op that changed nothing', 'hxq fmt src/ --write', 'apq fmt: rewrote 0 file(s)');
		probe(SILENT, 'the word \'wrote\' in PROSE', 'hxq lit \'wrote\' src/', 'apq lit: 3 hits');
		probe(SILENT, 'a git command that printed a path', 'git diff -- $cli', 'diff --git a/src b/src');
		Sys.println('-- early exit: nothing resolvable to lint --');
		probe(SILENT, 'a write to a path outside every worktree', 'hxq patch /elsewhere/Z$X --write', 'apq patch: wrote /elsewhere/Z$X');
		final gone: String = '$repo/src/NoSuchFileAtAll$X';
		probe(SILENT, 'a write to a file that no longer exists', 'hxq patch $gone --write', 'apq patch: wrote $gone');
		probe(SILENT, 'a non-.hx write', 'hxq new docs/x.md --write', 'apq new: wrote docs/x.md');
		Sys.println('-- the nudge itself (needs a built engine in this tree) --');
		if (!FileSystem.exists('$repo/bin/apq.js')) {
			Sys.println('skip        no $repo/bin/apq.js — build it to probe the nudge itself');
			return matrix.end();
		}
		// the snapshot is keyed by the session id, a constant here: cleared, or the previous run is the "first touch"
		removeTree('${LintWarn.cacheRoot()}/${LintWarn.digest(SESSION)}');
		// `Cli.hx` carries standing findings on any tree: a first touch speaks, a second against its snapshot must not
		final first: String = nudge('hxq patch $cli --write', 'apq patch: wrote $cli');
		matrix.check(SPEAKS, first == '' ? SILENT : SPEAKS, 'a first touch shows what is standing');
		final second: String = nudge('hxq patch $cli --write', 'apq patch: wrote $cli');
		matrix.check(SILENT, second == '' ? SILENT : SPEAKS, 'a second touch with no new finding says nothing', second);
		// The floor under the delta: a hook gone permanently silent after its first touch passes every case above, so one
		// case proves the other direction — a finding the snapshot lacks still reaches the reader, the standing ones do not.
		final third: String = newFinding(repo, nudge);
		final added: Bool = ~/magic number 4242[\s\S]*1 finding\(s\) this edit added/.match(third);
		matrix.check(SPEAKS, added ? SPEAKS : third == '' ? SILENT : 'other', 'a NEW finding reaches the reader, and only it', third);
		return matrix.end();
	}

	private static inline function removeTree(path: String): Void {
		js.Syntax.code("require('fs').rmSync({0}, { recursive: true, force: true })", path);
	}

	/** The hook a probe drives: `env` when set, else `relative` in the tree; null, said, when there is none. */
	private static function hookOf(argv: Array<String>, env: String, relative: String): Null<String> {
		final args: Args = new Args(argv);
		final repo: String = Repo.resolve(args.option('--repo'));
		args.done();
		final hook: String = Sys.getEnv(env) ?? '$repo/$relative';
		if (FileSystem.exists(hook)) return hook;
		Sys.println('no hook at $hook — nothing to probe (set $env to point at one)');
		return null;
	}

	/**
	 * The nudge for an edit that adds a finding to a file whose standing ones the hook has already seen: a scratch class
	 * in `repo`, touched once, then edited to carry a magic number, then removed.
	 */
	private static function newFinding(repo: String, nudge: (String, String) -> String): String {
		final scratch: String = '$repo/.hxq-probe-lint-warn';
		final file: String = '$scratch/Probe197$X';
		final wrote: String = 'apq patch: wrote $file';
		return try {
			FileSystem.createDirectory(scratch);
			File.saveContent(file, probeClass(''));
			// the first touch only seeds the snapshot the second is measured against
			nudge('hxq patch $file --write', wrote); // noqa: unused-return-value
			File.saveContent(file, probeClass(' + 4242'));
			final body: String = nudge('hxq patch $file --write', wrote);
			removeTree(scratch);
			body;
		} catch (exception: Exception) {
			removeTree(scratch);
			throw exception;
		};
	}

	/** The verdict a gate hook's output gives: its `permissionDecision`, `warn` for anything else it said, `` for no JSON. */
	private static function decision(out: String): String {
		return try {
			final said: HookAnswer = Json.parse(out);
			said.hookSpecificOutput?.permissionDecision ?? WARN;
		} catch (exception: Exception) '';
	}

	/** The `additionalContext` a nudge hook answered, or `` when it said nothing a harness would show. */
	private static function additionalContext(out: String): String {
		return try {
			final said: HookAnswer = Json.parse(out);
			said.hookSpecificOutput?.additionalContext ?? '';
		} catch (exception: Exception) '';
	}

	/** The probe class, whose one method returns `7777` followed by `tail`. */
	private static function probeClass(tail: String): String {
		return 'class Probe197 {\n\n\tpublic function new() {}\n\n\tpublic function f(): Int {\n\t\treturn 7777$tail;\n\t}\n\n}\n';
	}

}

/** One acceptance matrix's run: a row per case, the failures counted. */
@:nullSafety(Strict)
private final class Matrix {

	private final _width: Int;

	private var _fails: Int = 0;

	public function new(width: Int) {
		_width = width;
	}

	/** Print the row of the case `label`, which wanted `want` and got `got`; `detail` follows a failure's row. */
	public function check(want: String, got: String, label: String, detail: String = ''): Void {
		if (got == want) {
			Sys.println('ok   ${got.rpad(' ', _width)} $label');
			return;
		}
		Sys.println('FAIL want=$want got=$got  $label${detail == '' ? '' : ':\n$detail'}');
		_fails++;
	}

	/** Print the tally; answers the failure count, the probe's exit status. */
	public function end(): Int {
		Sys.println('fails=$_fails');
		return _fails;
	}

}

/** What a hook prints on stdout, the fields a probe reads. */
typedef HookAnswer = {
	var ?hookSpecificOutput: { var ?permissionDecision: String; var ?additionalContext: String; };
}
