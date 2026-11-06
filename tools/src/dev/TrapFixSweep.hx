package dev;

import anyparse.grammar.json.JValue;
import dev.SweepCatalog;
import dev.SweepProbe;
import dev.SweepTrap;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.RawJson;
import devkit.Result;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * `dev trap-fix-sweep [--rule <id>]... [--catalog <json>]` — every autofix rule over every trap of a catalog (by default
 * the name-resolution traps, `test/traps/resolve.json`): each probe's project that compiles and runs under `--interp` is
 * run as written, formatted, run again, `lint --fix`ed on a copy (`--rule` narrows the rules, else `--all`) under a
 * `compilerOracle` typechecking it, so the risky and oracle-assisted fixes are swept too, then run again. A probe the
 * formatter changed is `FORMAT-CHANGED`; one whose output or build the fix changed is `BROKE` (no longer compiles) or
 * `CHANGED` (prints otherwise); `SAME`, `SKIPPED` for a project that does not run as written, `ERROR` for an engine run
 * that failed. Exits 1 on any `FORMAT-CHANGED`, `BROKE`, `CHANGED` or `ERROR`.
 */
@:nullSafety(Strict)
final class TrapFixSweep {

	public static inline final USAGE: String =
		'usage: dev trap-fix-sweep [--rule <id>]... [--catalog <json>] — every probe formatted and fixed under its own compilerOracle';

	/** The verdict of a probe the formatter alone changed: it no longer runs, or prints otherwise. */
	public static inline final FORMAT_CHANGED: String = 'FORMAT-CHANGED';

	/** The build each probe's `apq.json` names as its `compilerOracle`: the probe's main class, typechecked. */
	private static inline final ORACLE_HXML: String = 'build.hxml';

	/** The catalog swept when the caller names none, from the tree's root. */
	private static inline final DEFAULT_CATALOG: String = 'test/traps/resolve.json';

	/** The flag naming one rule to sweep, on this command's line and on the `lint` it runs. */
	private static inline final RULE_FLAG: String = '--rule';

	/** Whether a verdict fails the sweep: a format or a fix that changed what a program means, or an engine run that failed. */
	public static inline function fails(verdict: String): Bool {
		return verdict == 'BROKE' || verdict == 'CHANGED' || verdict == 'ERROR' || verdict == FORMAT_CHANGED;
	}

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final rules: Array<String> = [];
		var rule: Null<String> = args.option(RULE_FLAG);
		while (rule != null) {
			rules.push(rule);
			rule = args.option(RULE_FLAG);
		}
		final repo: String = Repo.resolve(null);
		final catalog: String = args.option('--catalog') ?? Path.join([repo, DEFAULT_CATALOG]);
		args.done();
		final ruleArgs: Array<String> = rules.length == 0 ? ['--all'] : [for (r in rules) for (word in [RULE_FLAG, r]) word];
		final engine: String = Path.join([repo, 'bin', 'apq.js']);
		var moved: Int = 0;
		for (swept in sweep(catalog, engine, ruleArgs)) {
			if (fails(swept.verdict)) moved++;
			Sys.println('${swept.verdict} ${swept.edits} edit(s) ${swept.trap} ${swept.file} [${swept.exercised.join(', ')}]');
		}
		Sys.println('trap-fix-sweep: $moved probe(s) whose meaning the formatter or a fix changed, or whose engine run failed');
		return moved == 0 ? 0 : 1;
	}

	/**
	 * Every probe of the catalog at `catalog` swept with the engine `engine` (an absolute path) and the rule flags
	 * `ruleArgs`, in catalog order.
	 */
	public static function sweep(catalog: String, engine: String, ruleArgs: Array<String>): Array<SweptProbe> {
		final read: SweepCatalog = SweepCatalogParser.parse(File.getContent(catalog));
		return [
			for (trap in read.traps) for (probe in trap.probes) sweepProbe(trap, probe, engine, ruleArgs)
		];
	}

	/**
	 * One probe's verdict: `SKIPPED` when the project did not run as written, `FORMAT-CHANGED` when formatting it changed
	 * whether it runs or what it prints (`formatKept` false), `ERROR` when the engine's `fmt` or `lint --fix` itself failed
	 * (a crash, a refusal, a reverted safe pass) — never read as a fix that changed nothing — `BROKE` when the fixed
	 * project no longer runs, `CHANGED` when it prints otherwise, else `SAME`.
	 */
	public static function verdictOf(ran: Bool, formatKept: Bool, fixed: Bool, rerun: Bool, sameOutput: Bool): String {
		return if (!ran)
			'SKIPPED'
		else if (!formatKept)
			FORMAT_CHANGED
		else if (!fixed)
			'ERROR'
		else if (!rerun)
			'BROKE'
		else if (sameOutput)
			'SAME'
		else
			'CHANGED';
	}

	/** The edit count a `lint --fix` transcript reports (`N edit(s)`), or `?` when it reports none — what shows a fix ran. */
	public static function editsOf(transcript: String): String {
		final count: EReg = ~/([0-9]+) edit\(s\)/;
		return count.match(transcript) ? count.matched(1) : '?';
	}

	/** The rules a `lint --fix` transcript's census names as having produced an edit (`exercised: a, b`), none when absent. */
	public static function exercisedOf(transcript: String): Array<String> {
		final line: EReg = ~/^\s*exercised: (.+)$/m;
		return line.match(transcript) ? line.matched(1).split(', ') : [];
	}

	/**
	 * What a run printed, each line stripped of the `<file>:<line>: ` a `trace` prefixes: the line a call sits on is the
	 * layout's, which the formatter and a fix may move without changing what the program says.
	 */
	public static function printed(out: String): String {
		return ~/^[^\s:]+\.hx:[0-9]+: /gm.replace(out, '');
	}

	/**
	 * Each file of `trap`'s project with its text, `probe`'s file written as the probe gives it: a file's lines joined by
	 * newlines, each line ended. The one reading of a catalog's files, for the sweep and for the resolution traps' test.
	 */
	public static function filesOf(trap: SweepTrap, probe: SweepProbe): Map<String, String> {
		final out: Map<String, String> = [];
		switch trap.files {
			case JObject(entries):
				for (entry in entries) out[entry.key] = (RawJson.strings(entry.value) ?? []).join('\n') + '\n';
			case _:
		}
		final own: Null<Array<String>> = probe.text;
		if (own != null) out[probe.file] = own.join('\n') + '\n';
		return out;
	}

	/**
	 * The verdict of one probe: its project run as written, after the formatter, and after the fix, in a scratch directory of
	 * its own whose `build.hxml` typechecks it — the `compilerOracle` its `apq.json` declares, so the risky and
	 * oracle-assisted fixes run where a typecheck verifies them.
	 */
	private static function sweepProbe(trap: SweepTrap, probe: SweepProbe, engine: String, ruleArgs: Array<String>): SweptProbe {
		final dir: TempDir = TempDir.create();
		for (file => text in filesOf(trap, probe)) write(dir, file, text);
		final main: String = Path.withoutExtension(probe.file).split('/').join('.');
		File.saveContent(dir.file(ORACLE_HXML), '-cp .\n-main $main\n--no-output\n');
		File.saveContent(dir.file('apq.json'), '{\n\t"compilerOracle": "$ORACLE_HXML"\n}\n');
		final raw: Result = cmd('haxe -cp . -main $main --interp').at(dir.path).run();
		// the fixer declines every edit in a file the writer would rewrite, so the project is made canonical first
		final formatted: Result = cmd('node $engine fmt --write . --lang haxe').at(dir.path).run();
		final before: Null<Result> = raw.ok && formatted.ok ? cmd('haxe -cp . -main $main --interp').at(dir.path).run() : null;
		final formatKept: Bool = !formatted.ok || (before != null && before.ok && printed(before.out) == printed(raw.out));
		final fix: Null<Result> = raw.ok && formatted.ok && formatKept
			? cmd('node $engine lint . --lang haxe $ruleArgs --fix').at(dir.path).run()
			: null;
		final after: Null<Result> = fix != null && fix.ok ? cmd('haxe -cp . -main $main --interp').at(dir.path).run() : null;
		dir.dispose();
		final transcript: String = fix == null ? '' : '${fix.out}${fix.err}';
		return {
			trap: trap.name,
			file: probe.file,
			verdict: verdictOf(
				raw.ok, formatKept, fix?.ok ?? false, after?.ok ?? false, after != null && printed(after.out) == printed(raw.out)
			),
			edits: fix == null ? '-' : editsOf(transcript),
			exercised: exercisedOf(transcript)
		};
	}

	private static function write(dir: TempDir, file: String, text: String): Void {
		final path: String = dir.file(file);
		FileSystem.createDirectory(Path.directory(path));
		File.saveContent(path, text);
	}

}

/**
 * One probe swept: its trap and file, its verdict (`TrapFixSweep.verdictOf`), the edits the fix reported (`-` where none
 * ran) and the rules that made them.
 */
typedef SweptProbe = {
	final trap: String;
	final file: String;
	final verdict: String;
	final edits: String;
	final exercised: Array<String>;
}
