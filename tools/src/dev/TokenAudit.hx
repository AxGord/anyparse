package dev;

import anyparse.ds.Set;
import anyparse.grammar.json.JsonFormat;
import dev.SliceStats.Landing;
import dev.TokenTranscript.AgentReading;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Table;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev token-audit [<dir>...]` — where the tokens of a batch of agents went, read from their Claude Code transcripts (the
 * `*.output` links of a session's `tasks/` directory, or the `*.jsonl` files of its `subagents/` directory): per tool, hxq
 * subcommand, dev command, git subcommand and plugin call the calls and the size of what they sent and got back; per agent role
 * (the opening of its first prompt) and tool the same with the three largest calls; per model the turns and usage with a priced
 * estimate; per slice the cost (and per landed slice with `--landed`); the cache rewrites with the idle gap before each; and
 * the reads and writes of repo `.hx` that went round hxq. `--json <file>` writes the whole reading for a before/after diff.
 *
 * With no `<dir>` it reads the `subagents/` of every session of the repo's Claude Code project (`--project <dir>` names another),
 * which a restart does not empty the way it does `tasks/`. `--since <rev>` makes the window `<rev>..HEAD`: only agents that began
 * after that commit, plus every agent of a slice that landed inside it. A landing (what `SliceStats.landings` reads: a merge of its
 * branch or a commit with its `Slice` trailer) marks a slice landed only when an agent of that slice began at or before it, so an
 * older landing of a reused id never marks a later slice that closed without a commit. `--since` windows by agent start, so one
 * slice's cost is `--slice <ID>` with no `--since`. `--slice <ID>` prints that slice's one cost line (agents, turns, generated tokens,
 * cost, landed) and exits 1 when no agent of it was read. This is the meter only; the readings live in the journal, never in a doc.
 */
@:nullSafety(Strict)
final class TokenAudit {

	public static inline final USAGE: String =
		'usage: dev token-audit [<dir>...] [--project <dir>] [--since <rev>] [--slice <ID>] [--json <file>] [--top <n>] [--landed] [--repo <tree>]';

	/** How many rows of a long table the text report prints, unless `--top` says otherwise. */
	private static inline final DEFAULT_TOP: Int = 25;

	private static inline final THOUSAND: Float = 1000;
	private static inline final MS_PER_SECOND: Float = 1000;
	private static inline final SUBAGENTS: String = 'subagents';
	private static final TRANSCRIPT: EReg = ~/\.(output|jsonl)$/;

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final jsonFile: Null<String> = args.option('--json');
		final top: Int = Std.parseInt(args.option('--top') ?? '') ?? DEFAULT_TOP;
		final repo: Null<String> = args.option('--repo');
		final since: Null<String> = args.option('--since');
		final slice: Null<String> = args.option('--slice');
		final project: Null<String> = args.option('--project');
		final landed: Bool = args.flag('--landed') || since != null || slice != null;
		final dirs: Array<String> = args.rest([]);
		final tree: String = Repo.resolve(repo);
		final sources: Array<String> = dirs.length > 0 ? dirs : subagentDirs(project ?? projectOf(tree));
		final from: Float = since == null ? 0 : commitMillis(tree, since);
		final read: Array<AgentReading> = readDirectories(sources);
		final ids: Null<Array<String>> = landed
			? landedIds(SliceStats.landings(tree, since == null ? 'HEAD' : '$since..HEAD', null), read)
			: null;
		final agents: Array<AgentReading> = startedFrom(read, from, ids ?? []);
		final report: AuditReport = TokenReport.summarize(agents, ids);
		if (jsonFile != null) File.saveContent(jsonFile, '${TokenReportWriter.write(report, JsonFormat.instance.defaultWriteOptions)}\n');
		if (slice == null) {
			Sys.println(render(report, top));
			return 0;
		}
		final line: Null<String> = sliceLine(report, slice);
		if (line == null) {
			Sys.stderr().writeString('token-audit: no agent of slice $slice in the window\n');
			return 1;
		}
		Sys.println(line);
		return 0;
	}

	/**
	 * The agents of every transcript file under `dirs`; a file named twice
	 * (links to one transcript) counts once, a dangling link is skipped.
	 */
	public static function readDirectories(dirs: Array<String>): Array<AgentReading> {
		final seen: Set<String> = new Set<String>();
		final agents: Array<AgentReading> = [];
		for (dir in dirs) {
			final names: Array<String> = FileSystem.readDirectory(dir);
			names.sort(Reflect.compare);
			for (name in names) if (TRANSCRIPT.match(name)) {
				final real: Null<String> = try FileSystem.fullPath(Path.join([dir, name])) catch (_: Exception) null;
				if (real == null || seen.has(real) || !FileSystem.exists(real)) continue;
				seen.add(real);
				agents.push(
					TokenTranscript.read(Path.withoutExtension(Path.withoutDirectory(real)), File.getContent(real), describe(real))
				);
			}
		}
		return agents;
	}

	/** The text report: totals, then the tool, model, slice, rewrite and bypass tables. */
	public static function render(report: AuditReport, top: Int): String {
		final rewrites: RewriteSummary = report.rewrites;
		final bypass: BypassSummary = report.bypass;
		final landed: Null<LandedSummary> = report.landed;
		final lines: Array<String> = [
			'agents ${report.agents}; turns ${report.turns}; estimated cost ${usd(report.cost)}',
			'tool input ${thousands(report.toolInTok)}, tool output ${thousands(report.toolOutTok)}',
			'',
			Table.render(['tool', 'calls', 'out k-tok', 'avg out', 'in k-tok', '>2k', '>5k'], report.tools.slice(0, top).map(toolCells)),
			'',
			roleLines(report.roles.slice(0, top)),
			'',
			Table.render(['model', 'turns', 'input', 'output', 'cache read', 'cache write', 'cost usd'], report.models.map(modelCells)),
			'',
			Table.render(['slice', 'agents', 'turns', 'out', 'cost usd', 'landed'], report.slices.slice(0, top).map(sliceCells))
		];
		if (landed != null)
			lines.push('landed slices ${landed.slices}; cost ${usd(landed.cost)}; per landed slice ${usd(landed.perSlice)}');
		lines.push('');
		lines.push('cache writes: initial ${thousands(rewrites.initialTokens)}, appended ${thousands(rewrites.appendTokens)}');
		lines.push('rewrites: ${rewrites.rewrites} of ${rewrites.turns} turn(s), ${thousands(rewrites.rewriteTokens)} written');
		lines.push('rewrites cost over a cache read: ${usd(rewrites.extraCost)}');
		lines.push('rewrite gap: median ${Math.round(rewrites.gapMedianSeconds)}s, max ${Math.round(rewrites.gapMaxSeconds)}s');
		lines.push('rewrite gap buckets: <=5m ${rewrites.within5m}, <=1h ${rewrites.to1h}, over 1h ${rewrites.over1h}');
		if (rewrites.worst.length > 0)
			lines.push(Table.render(['rewrite', 'slice', 'context', 'gap s', 'extra usd'], rewrites.worst.slice(0, top).map(rewriteCells)));
		lines.push('');
		lines.push('write payloads ${thousands(bypass.writePayloadTok)}, leading blanks ${thousands(bypass.indentTok)}');
		lines.push('executed: shell reads of repo .hx ${bypass.shellHxReads}; writes outside hxq ${bypass.hxWrites}');
		lines.push('script writes (heuristic) ${bypass.scriptWrites}');
		lines.push('denied by the gate hook (never ran): reads ${bypass.deniedReads}; writes ${bypass.deniedWrites}');
		for (sample in bypass.readSamples.slice(0, top)) lines.push('  read   $sample');
		for (sample in bypass.writeSamples.slice(0, top)) lines.push('  write  $sample');
		for (sample in bypass.scriptSamples.slice(0, top)) lines.push('  script $sample');
		lines.push('');
		for (note in report.assumptions) lines.push('* $note');
		return lines.join('\n');
	}

	/**
	 * The directories of `project` (a Claude Code project directory) that hold subagent transcripts: the `subagents/` of every
	 * session in it, so a restart that dropped a session's `tasks/` links loses nothing. Throws `UsageError` when `project` is no
	 * directory.
	 */
	public static function subagentDirs(project: String): Array<String> {
		if (!FileSystem.exists(project) || !FileSystem.isDirectory(project)) throw new UsageError('no project directory $project');
		final names: Array<String> = FileSystem.readDirectory(project);
		names.sort(Reflect.compare);
		return [
			for (name in names) if (FileSystem.exists(Path.join([project, name, SUBAGENTS]))) Path.join([project, name, SUBAGENTS])
		];
	}

	/** The Claude Code project directory of the tree `tree`: its path with every character outside `[A-Za-z0-9]` turned into `-`. */
	public static function projectOf(tree: String): String {
		final home: String = Sys.getEnv('CLAUDE_CONFIG_DIR') ?? Path.join([Sys.getEnv('HOME') ?? '', '.claude']);
		return Path.join([home, 'projects', ~/[^A-Za-z0-9]/g.replace(tree, '-')]);
	}

	/**
	 * The agents of `agents` that began at or after `from` (ms since the epoch) or whose slice is in `landed`, so a slice that
	 * landed inside the window keeps its whole cost; all of them when `from` is not positive.
	 */
	public static function startedFrom(agents: Array<AgentReading>, from: Float, landed: Array<String>): Array<AgentReading> {
		return from <= 0
			? agents
			: agents.filter(a -> a.turns.length > 0 && (a.turns[0].start >= from || (a.slice != null && landed.contains(a.slice))));
	}

	/**
	 * The cost line of slice `slice` in `report`, or null when no agent of it was read. The output is the tokens the slice's
	 * agents generated, summed over their turns: a count that does not grow with the context each round re-reads.
	 */
	public static function sliceLine(report: AuditReport, slice: String): Null<String> {
		for (row in report.slices) if (row.slice == slice)
			return 'slice ${row.slice}: agents ${row.agents}; turns ${row.turns}; output ${row.output} tok; cost ${usd(row.cost)}; '
				+ 'landed ${row.landed ? 'yes' : 'no'}';
		return null;
	}

	/**
	 * The ids of `landings` that count as landed: a landing counts for a slice only when an agent of that slice began at or before
	 * it, so an older landing of a reused id never marks a later slice that closed without one.
	 */
	public static function landedIds(landings: Array<Landing>, agents: Array<AgentReading>): Array<String> {
		return [
			for (l in landings)
				if (agents.exists(a -> a.slice == l.id && a.turns.length > 0 && a.turns[0].start <= l.landed * MS_PER_SECOND)) l.id
		];
	}

	private static inline function usd(amount: Float): String {
		return '$$${amount}';
	}

	/** The role × tool table of `rows`, each row followed by its largest calls. */
	private static function roleLines(rows: Array<RoleToolRow>): String {
		final table: Array<String> = Table.render(
			['role', 'tool', 'calls', 'out k-tok', '>5k'],
			rows.map(row -> [row.role, row.key, '${row.calls}', thousands(row.outTok), '${row.over5k}'])
		)
			.split('\n');
		final lines: Array<String> = [table[0]];
		for (i => row in rows) {
			lines.push(table[i + 1]);
			for (big in row.biggest) lines.push('    ${big.outTok} tok  ${big.call}');
		}
		return lines.join('\n');
	}

	/** The one-line task of the agent whose transcript is `file`, from the `.meta.json` beside it; null when there is none. */
	private static function describe(file: String): Null<String> {
		final meta: String = '${Path.withoutExtension(file)}.meta.json';
		if (!FileSystem.exists(meta)) return null;
		final parsed: Null<AgentMeta> = try AgentMetaParser.parse(File.getContent(meta)) catch (_: Exception) null;
		return parsed?.description;
	}

	private static function toolCells(row: ToolRow): Array<String> {
		return [
			row.key,
			'${row.calls}',
			thousands(row.outTok),
			'${row.avgOutTok}',
			thousands(row.inTok),
			'${row.over2k}',
			'${row.over5k}'
		];
	}

	private static function modelCells(row: ModelRow): Array<String> {
		return [
			row.model,
			'${row.turns}',
			thousands(row.input),
			thousands(row.output),
			thousands(row.cacheRead),
			thousands(row.cacheWrite),
			'${row.cost}'
		];
	}

	private static function sliceCells(row: SliceCost): Array<String> {
		return [
			row.slice,
			'${row.agents}',
			'${row.turns}',
			thousands(row.output),
			'${row.cost}',
			row.landed ? 'yes' : '-'
		];
	}

	private static function rewriteCells(row: Rewrite): Array<String> {
		return [
			row.agent,
			row.slice ?? TokenReport.OTHER,
			thousands(row.context),
			'${Math.round(row.gapSeconds)}',
			'${row.extraCost}'
		];
	}

	/** `tokens` in thousands, with a `k`. */
	private static function thousands(tokens: Int): String {
		return '${Math.round(tokens / THOUSAND)}k';
	}

	/** The commit time of `rev` in `tree`, in ms since the epoch. */
	private static function commitMillis(tree: String, rev: String): Float {
		final seconds: Float = Std.parseFloat(cmd('git -C $tree log -1 --format=%ct $rev').check().out.trim());
		return seconds * MS_PER_SECOND;
	}

}
