package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.TempDir;
import haxe.DynamicAccess;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * `dev trap-fix-sweep [--rule <id>]... [--catalog <json>]` — every autofix rule over every trap of a catalog (by default
 * the name-resolution traps, `test/traps/resolve.json`): each probe's project that compiles and runs under `--interp` is
 * formatted, `lint --fix`ed on a copy (`--rule` narrows the rules, else `--all`), then compiled and
 * run again. The fix runs `--no-oracle`, so only the SAFE fixes are swept: a risky or
 * oracle-assisted fix — the name-resolving ones among them — never runs here. A probe whose output or
 * build the fix changed is a rule that changed what a program means: `BROKE` (no longer compiles), `CHANGED` (prints
 * otherwise), `SAME`, `SKIPPED` for a project that does not run as written, and
 * `ERROR` for an engine run that failed. Exits 1 on any `BROKE`, `CHANGED` or `ERROR`.
 */
@:nullSafety(Strict)
final class TrapFixSweep {

	public static inline final USAGE: String =
		'usage: dev trap-fix-sweep [--rule <id>]... [--catalog <json>] — safe fixes only (--no-oracle): no risky or oracle-assisted fix is swept';

	/** The catalog swept when the caller names none, from the tree's root. */
	private static inline final DEFAULT_CATALOG: String = 'test/traps/resolve.json';

	/** The flag naming one rule to sweep, on this command's line and on the `lint` it runs. */
	private static inline final RULE_FLAG: String = '--rule';

	/** Whether a verdict fails the sweep: a fix that changed what a program means, or an engine run that failed. */
	public static inline function fails(verdict: String): Bool {
		return verdict == 'BROKE' || verdict == 'CHANGED' || verdict == 'ERROR';
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
		final read: SweepCatalog = Json.parse(File.getContent(catalog));
		for (trap in read.traps) for (probe in trap.probes) {
			final swept: SweptProbe = sweepProbe(trap, probe, engine, ruleArgs);
			if (fails(swept.verdict)) moved++;
			Sys.println('${swept.verdict} ${swept.edits} edit(s) ${trap.name} ${probe.file}');
		}
		Sys.println(
			'trap-fix-sweep: $moved probe(s) whose meaning a fix changed or whose fix failed — safe fixes only (--no-oracle): '
			+ 'the risky and oracle-assisted fixes, the name-resolving ones among them, are not swept'
		);
		return moved == 0 ? 0 : 1;
	}

	/**
	 * One probe's verdict: `SKIPPED` when the project did not run as written, `ERROR` when the engine's `lint --fix` itself
	 * failed (a crash, a refusal, a reverted safe pass) — never read as a fix that changed nothing — `BROKE` when the fixed
	 * project no longer runs, `CHANGED` when it prints otherwise, else `SAME`.
	 */
	public static function verdictOf(ran: Bool, fixed: Bool, rerun: Bool, sameOutput: Bool): String {
		return if (!ran)
			'SKIPPED'
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

	/** The verdict of one probe: its project run before and after the fix, in a scratch directory of its own. */
	private static function sweepProbe(trap: SweepTrap, probe: SweepProbe, engine: String, ruleArgs: Array<String>): SweptProbe {
		final dir: TempDir = TempDir.create();
		for (file in trap.files.keys()) write(dir, file, trap.files.get(file) ?? []);
		final own: Null<Array<String>> = probe.text;
		if (own != null) write(dir, probe.file, own);
		final main: String = Path.withoutExtension(probe.file).split('/').join('.');
		// the fixer declines every edit in a file the writer would rewrite, so the project is made canonical first
		final formatted: Result = cmd('node $engine fmt --write . --lang haxe').at(dir.path).run();
		final before: Result = cmd('haxe -cp . -main $main --interp').at(dir.path).run();
		final fix: Null<Result> = before.ok && formatted.ok
			? cmd('node $engine lint . --lang haxe $ruleArgs --fix --no-oracle').at(dir.path).run()
			: null;
		final after: Null<Result> = fix != null && fix.ok ? cmd('haxe -cp . -main $main --interp').at(dir.path).run() : null;
		dir.dispose();
		return {
			verdict: verdictOf(before.ok, fix?.ok ?? false, after?.ok ?? false, after?.out == before.out),
			edits: fix == null ? '-' : editsOf('${fix.out}${fix.err}')
		};
	}

	private static function write(dir: TempDir, file: String, lines: Array<String>): Void {
		final path: String = dir.file(file);
		FileSystem.createDirectory(Path.directory(path));
		File.saveContent(path, lines.join('\n') + '\n');
	}

}

/** A trap catalog, as `test/traps/resolve.json` spells one. */
private typedef SweepCatalog = {
	final traps: Array<SweepTrap>;
}

/** One mini project of a catalog. */
private typedef SweepTrap = {
	final name: String;
	final files: DynamicAccess<Array<String>>;
	final probes: Array<SweepProbe>;
}

/** One probe of a trap: the file it asks in, written as `text` when given. */
private typedef SweepProbe = {
	final file: String;
	final ?text: Array<String>;
}

/** One probe swept: its verdict (`TrapFixSweep.verdictOf`) and the edits the fix reported, `-` where none ran. */
private typedef SweptProbe = {
	final verdict: String;
	final edits: String;
}
