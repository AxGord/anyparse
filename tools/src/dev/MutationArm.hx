package dev;

import anyparse.check.oracle.HaxeSpawn;
import anyparse.check.oracle.PendingRuns;
import anyparse.core.PoolLease;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Pool;
import devkit.Result;
import devkit.TmpLifecycle;
import haxe.Exception;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev mutation-arm <ARM>... | --all` — a DECLARED mutation arm (`test/testkit/mutation-arms.json`) turned into a run:
 * each arm's cut rendered into a patch against a scratch worktree, its pins (the `@:killer`s that name it, out of the
 * generated registry) made its expectations, and the manifest handed to `dev mutation-check`. Every arm a copy can stand
 * for is also composed into one background build (`MutationSchemaBuild`). Flags and verdicts: `docs/testing.md`
 * § "Declared arms".
 */
@:nullSafety(Strict)
final class MutationArm {

	public static inline final USAGE: String = 'usage: dev mutation-arm <ARM>... | --all | --list [--jobs N] [--fast] [--keep] [--check-apply] '
		+ '[--apply-only] [--working-tree] [--repo <tree>]';

	/** The arm registry, from the tree's root. */
	public static inline final REGISTRY: String = 'test/testkit/mutation-arms.json';

	/** The prefix `devkit.TmpLifecycle` claims this tool's work directory under. */
	private static inline final WORK_PREFIX: String = 'anyparse-mutarm';

	/** The most rows of one file a render batch takes at once, so the file most arms cut does not hold one batch for the rest. */
	private static inline final RENDER_CHUNK: Int = 16;

	/** The address kind of an arm that names none: a method. */
	private static inline final DEFAULT_KIND: String = 'FnMember';

	/** What one render batch may take before it is killed. */
	private static inline final RENDER_TIMEOUT_MS: Int = 60 * 60 * 1000;

	/** The output a background schema build may write before its driver ends it. */
	private static inline final SCHEMA_BUFFER: Int = 64 * 1024 * 1024;

	/** The width of an `APPLY-FAIL` row's name column, as a verdict row's. */
	private static inline final NAME_WIDTH: Int = 20;

	/** The classpath roots `test-js.hxml` declares, in its order: an arm's type is looked up under each. */
	private static final ROOTS: Array<String> = ['src', 'test', 'tools/src'];

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final repo: String = Repo.resolve(args.option('--repo'));
		final schemaBuild: Null<Array<String>> = args.values('--schema-build', 2);
		if (schemaBuild != null) {
			args.done();
			return MutationSchemaBuild.run(repo, schemaBuild[0], schemaBuild[1]);
		}
		final list: Bool = args.flag('--list');
		final all: Bool = args.flag('--all');
		final checkApply: Bool = args.flag('--check-apply');
		final applyOnly: Bool = args.flag('--apply-only');
		final fast: Bool = args.flag('--fast');
		final keep: Bool = args.flag('--keep');
		final workingTree: Bool = args.flag('--working-tree');
		final jobs: Null<String> = args.option('--jobs');
		final named: Array<String> = args.rest([]);
		if (checkApply && applyOnly) return refuse(['--check-apply builds the cuts and --apply-only does not: pick one']);
		final bins: Null<ArmBinaries> = binaries(repo);
		if (bins == null) return 2;
		if (list) {
			final listed: Result = cmd('node ${bins.test} --list-arms').run();
			Sys.print(listed.out);
			Sys.stderr().writeString(listed.err);
			return listed.ok ? 0 : 1;
		}
		final registry: String = Path.join([repo, REGISTRY]);
		if (!FileSystem.exists(registry)) return refuse(['no arm registry at $registry']);
		final names: Array<String> = named.concat(all ? armNames(File.getContent(registry)) : []);
		if (names.length == 0) return refuse(['no arm named (pass names, or --all)']);
		final snap: Null<String> = workingTree ? snapshot(repo) : 'HEAD';
		if (snap == null) return 2;
		final base: String = snap;
		return run({
			repo: repo,
			registry: registry,
			names: names,
			apq: bins.apq,
			test: bins.test,
			jobs: jobs,
			fast: fast,
			keep: keep,
			checkApply: checkApply,
			applyOnly: applyOnly,
			base: base
		});
	}

	/** The verdict line of an `--apply-only` run: `applies` cuts applied to a scratch copy, `failed` did not. */
	public static function applyTally(applies: Int, failed: Int): String {
		return '${applies + failed} arms: $applies apply, $failed did not apply';
	}

	/** Every arm name the registry `text` declares, in registry order. */
	public static function armNames(text: String): Array<String> {
		final table: ArmTable = Json.parse(text);
		return [for (arm in table.arms ?? []) arm.name];
	}

	/**
	 * The cut of each of `names` as the registry `text` declares it: a `find`/`replace` arm's `hxq patch` payload — one
	 * string or a LIST of them, N pairs in ONE payload whose old / new sections alternate, every pair located against
	 * the ORIGINAL member text — or a `force` arm's forced value, or why the arm cannot be rendered.
	 */
	public static function cuts(text: String, names: Array<String>, registry: String): Map<String, ArmCut> {
		final table: ArmTable = Json.parse(text);
		final byName: Map<String, ArmRecordJson> = [];
		for (arm in table.arms ?? []) if (!byName.exists(arm.name)) byName[arm.name] = arm;
		final out: Map<String, ArmCut> = [];
		for (name in names) {
			final arm: Null<ArmRecordJson> = byName[name];
			if (arm == null) {
				out[name] = Unrenderable('no arm named "$name" in $registry');
				continue;
			}
			final kind: String = arm.kind == null || arm.kind == '' ? DEFAULT_KIND : arm.kind;
			final force: String = arm.force == null ? '' : Std.string(arm.force);
			if (force != '') {
				out[name] = Force(arm.type, arm.method, kind, force);
				continue;
			}
			final finds: Array<String> = strings(arm.find) ?? [];
			final replaces: Array<String> = strings(arm.replace) ?? [for (_ in finds) ''];
			if (finds.length == 0 || finds.length != replaces.length) {
				out[name] = Unrenderable(
					'"$name" declares ${finds.length} find fragment(s) against ${replaces.length} replace(s)'
					+ ' - a multi-pair cut pairs them up'
				);
				continue;
			}
			final sections: Array<String> = [for (i in 0...finds.length) for (s in [finds[i], replaces[i]]) s];
			out[name] = Find(arm.type, arm.method, kind, sections.join('\n====\n') + '\n');
		}
		return out;
	}

	/**
	 * The member source `node` (as `hxq show --select` prints it) up to and including the line its BODY opens on — the
	 * anchor a forced `return` is spliced after — or null when its braces do not balance or its body opens mid-line. The
	 * body's brace is the LAST one that opens at depth 0, and its match must be the member's final one: a return type
	 * may open a brace of its own (`Null<{ … }>`). Braces in a comment, a string, a character or a regex are not code.
	 */
	public static function forceHeader(node: String): Null<String> {
		var depth: Int = 0;
		var open: Int = -1;
		var close: Int = -1;
		var i: Int = 0;
		while (i < node.length) {
			final past: Int = pastNonCode(node, i);
			if (past >= 0) {
				i = past;
				continue;
			}
			final c: Int = node.fastCodeAt(i);
			if (c == '{'.code) {
				if (depth == 0) open = i;
				depth++;
			} else if (c == '}'.code) {
				depth--;
				if (depth == 0) close = i;
			}
			i++;
		}
		if (open < 0 || depth != 0 || close != node.rtrim().length - 1) return null;
		final nl: Int = node.indexOf('\n', open);
		return nl < 0 || node.substring(open + 1, nl).trim() != '' ? null : node.substr(0, nl + 1);
	}

	/** The `hxq patch` payload forcing `value` as the first statement of the member whose header is `header`. */
	public static function forcePayload(header: String, value: String): String {
		return '$header====\n$header\treturn $value;\n';
	}

	/**
	 * The `--list-pins` dump `listing` (`Class#method :: role :: ARM,ARM`) as two tables keyed by arm: the pinned TESTS
	 * (`<fq.Class>.<method>`, the names `MutationVerdict` matches an expectation against) and the pinned CLASSES, each a
	 * sorted, comma-separated list. Derived from the generated registry, never restated in an arm's record.
	 */
	public static function pinTables(listing: String): PinTables {
		final tests: Map<String, Array<String>> = [];
		final classes: Map<String, Array<String>> = [];
		for (line in listing.split('\n')) {
			final fields: Array<String> = line.split(' :: ');
			if (fields.length < 3 || fields[2] == '') continue;
			final hash: Int = fields[0].indexOf('#');
			final cls: String = hash < 0 ? fields[0] : fields[0].substr(0, hash);
			final test: String = hash < 0 ? fields[0] : '$cls.${fields[0].substr(hash + 1)}';
			for (killer in fields[2].split(',')) {
				add(tests, killer, test);
				add(classes, killer, cls);
			}
		}
		return { tests: joined(tests), classes: joined(classes) };
	}

	/**
	 * The render rows `rows` (`<file>\t…`) dealt into at most `batches` batches: a file's rows in chunks of at most
	 * `chunk`, the file with most rows first, each chunk to the batch holding fewest rows so far. Each batch
	 * canonical-gates a file once, however many of its rows it applies.
	 */
	public static function deal(rows: Array<String>, batches: Int, chunk: Int): Array<Array<String>> {
		final byFile: Map<String, Array<String>> = [];
		final files: Array<String> = [];
		for (row in rows) {
			final file: String = row.split('\t')[0];
			if (!byFile.exists(file)) {
				byFile[file] = [];
				files.push(file);
			}
			byFile[file]?.push(row);
		}
		final rank: Map<String, Int> = [for (i => f in files) f => i];
		files.sort((a, b) -> {
			final more: Int = (byFile[b]?.length ?? 0) - (byFile[a]?.length ?? 0);
			more != 0 ? more : (rank[a] ?? 0) - (rank[b] ?? 0);
		});
		final dealt: Array<Array<String>> = [for (_ in 0...Std.int(Math.max(1, batches))) []];
		for (file in files) {
			final own: Array<String> = byFile[file] ?? [];
			var start: Int = 0;
			while (start < own.length) {
				var best: Int = 0;
				for (b in 1...dealt.length) if (dealt[b].length < dealt[best].length) best = b;
				for (row in own.slice(start, start + chunk)) dealt[best].push(row);
				start += chunk;
			}
		}
		return dealt.filter(b -> b.length > 0);
	}

	/** Render every arm of `job`, write the manifest, and run it through `dev mutation-check`; answers the exit status. */
	private static function run(job: ArmJob): Int {
		final dirs: TmpLifecycle = TmpLifecycle.fromEnv();
		final workroot: String = dirs.claimAfterSweep(WORK_PREFIX, job.repo);
		final state: RunState = { schema: null };
		final status: Int = try {
			execute(job, workroot, state);
		} catch (exception: Exception) {
			release(job, dirs, workroot, state, 1);
			throw exception;
		};
		release(job, dirs, workroot, state, status);
		return status;
	}

	private static function execute(job: ArmJob, workroot: String, state: RunState): Int {
		final gen: String = Path.join([workroot, 'gen']);
		final added: Result = cmd('git -C ${job.repo} worktree add --detach --quiet $gen ${job.base}').run();
		if (!added.ok) return refuse(['scratch worktree failed: ${MutationSlot.oneLine(added.err + added.failure)}']);
		// the private engine renders the cuts, through every `hxq` this run starts
		Sys.putEnv('HXQ_BIN', job.apq);
		Sys.putEnv('APQ_NO_CONFIG_WARN', '1');
		final cores: Int = PoolLease.threads() ?? js.node.Os.cpus().length;
		final cuts: Map<String, ArmCut> = cuts(File.getContent(job.registry), job.names, job.registry);
		final targets: Map<String, ArmTarget> = render(job, cuts, gen, workroot, cores);
		final applyFail: Array<String> = [];
		final rendered: Array<String> = [];
		for (name in job.names) {
			switch cuts[name] {
				case Unrenderable(why):
					return refuse([why]);
				case _:
			}
			final failed: Null<String> = targets[name]?.failure;
			if (failed != null) {
				if (!job.checkApply && !job.applyOnly) return refuse([failed]);
				applyFail.push('APPLY-FAIL  ${name.rpad(' ', NAME_WIDTH)} $failed');
				continue;
			}
			rendered.push(name);
		}
		if (job.applyOnly) return reportApplied(rendered.length, applyFail);
		final manifest: String = Path.join([workroot, 'manifest']);
		final lines: Null<Array<String>> = manifestLines(job, rendered, workroot);
		if (lines == null) return 2;
		File.saveContent(manifest, [for (line in lines) '$line\n'].join(''));
		if (!job.checkApply && !isSet('APQ_MUTATION_NO_SCHEMA')) state.schema = schema(job, rendered, targets, gen, workroot);
		// the patches are rendered: the scratch worktree is not held for the length of the run
		cmd('git -C ${job.repo} worktree remove --force $gen').run();
		cmd('git -C ${job.repo} worktree prune').run();
		Sys.println('manifest: $manifest');
		// the corpus harness is not what an arm measures, and a verdict must not depend on the caller's shell
		js.Syntax.code('delete process.env.ANYPARSE_HXFORMAT_FORK');
		var status: Int = 0;
		if (lines.length > 0) {
			status = MutationCheck.run({
				repo: job.repo,
				manifest: manifest,
				jobs: job.jobs,
				keep: job.keep,
				buildOnly: job.checkApply,
				killerFirst: job.fast && !job.checkApply && !isSet('APQ_MUTATION_NO_KILLER_FIRST'),
				schema: state.schema?.dir,
				base: job.base
			});
		} else if (!job.checkApply) {
			Sys.stderr().writeString('dev mutation-arm: nothing to run\n');
			status = 2;
		}
		// after the report, so a cut that never became a patch reads as part of the same census
		for (row in applyFail) Sys.println(row);
		return applyFail.length > 0 ? 1 : status;
	}

	/**
	 * Every arm's cut rendered against the scratch worktree `gen`: its file found by type path, a forced arm's payload
	 * built off the member's own signature, the cuts applied by `apq patch --batch` (read-only: each row prints the
	 * patched file) and diffed into `<name>.patch`. Answers each arm's target, or why it could not be rendered.
	 */
	private static function render(
		job: ArmJob, cuts: Map<String, ArmCut>, gen: String, workroot: String, cores: Int
	): Map<String, ArmTarget> {
		final targets: Map<String, ArmTarget> = [];
		for (name in job.names) switch cuts[name] {
			case Find(type, method, kind, payload):
				final t: ArmTarget = target(job, name, type, method, kind, gen);
				targets[name] = t;
				if (t.failure == null) File.saveContent(Path.join([workroot, '$name.payload']), payload);
			case Force(type, method, kind, _):
				targets[name] = target(job, name, type, method, kind, gen);
			case _:
		}
		forcePayloads(job, cuts, targets, gen, workroot, cores);
		final live: Array<String> = [
			for (name in job.names) if (targets[name]?.failure == null && targets.exists(name)) name
		];
		final rows: Array<String> = [
			for (name in live) {
				final t: Null<ArmTarget> = targets[name];
				if (t != null) [
					t.file,
					t.selector,
					Path.join([workroot, '$name.payload']),
					Path.join([workroot, '$name.new'])
				].join('\t');
			}
		];
		final batches: Array<Array<String>> = deal(rows, cores, RENDER_CHUNK);
		final files: Array<String> = [for (b => _ in batches) Path.join([workroot, 'render-batch.$b'])];
		for (b => batch in batches) File.saveContent(files[b], [for (row in batch) '$row\n'].join(''));
		final applied: Array<Result> = Pool.of(Std.int(Math.max(1, files.length)))
			.map(files, file -> cmd('node ${job.apq} patch --lang haxe --batch $file').at(gen).timeout(RENDER_TIMEOUT_MS));
		for (b => result in applied) File.saveContent('${files[b]}.log', result.out + result.err + result.failure);
		final diffs: Array<Result> = Pool.of(cores).map(live, name -> {
			final file: String = targets[name]?.file ?? '';
			cmd('diff -u --label a/$file --label b/$file ${Path.join([gen, file])} ${Path.join([workroot, '$name.new'])}');
		});
		for (i => name in live) {
			final t: Null<ArmTarget> = targets[name];
			if (t != null) t.failure = patchOf(name, diffs[i], workroot);
		}
		return targets;
	}

	/** Where the arm `name` cuts: the file its `type` lives in under one of `ROOTS` of `gen`, and the member's address. */
	private static function target(job: ArmJob, name: String, type: String, method: String, kind: String, gen: String): ArmTarget {
		final relative: String = type.split('.').join('/') + '.hx';
		final root: Null<String> = ROOTS.find(r -> FileSystem.exists(Path.join([gen, r, relative])));
		return {
			type: type,
			method: method,
			file: root == null ? '' : '$root/$relative',
			selector: '$kind:$method',
			failure: root == null ? '$name names $type, which is under none of src/, test/, tools/src/ at ${job.base}' : null
		};
	}

	/**
	 * The manifest line of each arm of `rendered`: `--check-apply` asks the COMPILER, so its lines carry no expectation;
	 * any other run expects the arm's own pins and, under `--fast`, runs only their classes. Null, refused on stderr, when
	 * an arm has no pin in the generated registry.
	 */
	private static function manifestLines(job: ArmJob, rendered: Array<String>, workroot: String): Null<Array<String>> {
		if (job.checkApply) return [
			for (name in rendered) manifestLine(name, Path.join([workroot, '$name.patch']), 'ALL', '')
		];
		if (rendered.length == 0) return [];
		final pins: PinTables = pinTables(cmd('node ${job.test} --list-pins').text());
		final unpinned: Null<String> = rendered.find(name -> !pins.tests.exists(name));
		if (unpinned == null) return [
			for (name in rendered)
				manifestLine(
					name, Path.join([workroot, '$name.patch']), job.fast ? pins.classes[name] ?? 'ALL' : 'ALL', pins.tests[name] ?? ''
				)
		];
		say([
			'$unpinned: no @:killer in the generated registry names it — rebuild ${job.test}'
		]);
		return null;
	}

	/**
	 * Plan the arms of `rendered` a composed build may stand for — under `src/`, outside `anyparse.macro` (compile-time
	 * code) and outside every file a `@:build` macro reads — and start that build in the background
	 * (`MutationSchemaBuild`). Null when no arm qualifies.
	 */
	private static function schema(
		job: ArmJob, rendered: Array<String>, targets: Map<String, ArmTarget>, gen: String, workroot: String
	): Null<SchemaRun> {
		final dir: String = Path.join([workroot, 'schema']);
		FileSystem.createDirectory(dir);
		final meta: Result = cmd('sh ${Path.join([job.repo, 'bin/hxq'])} meta @:build src --flat --limit 100000').at(gen).run();
		final built: Array<String> = [];
		final file: EReg = ~/^(src\/[^:]*\.hx):/;
		for (line in meta.out.split('\n')) if (file.match(line) && !built.contains(file.matched(1))) built.push(file.matched(1));
		final plan: Array<String> = [];
		final names: Array<String> = [];
		final candidates: Array<String> = [];
		for (name in rendered) {
			final t: Null<ArmTarget> = targets[name];
			if (t == null || !t.file.startsWith('src/') || t.file.startsWith('src/anyparse/macro/') || built.contains(t.file)) continue;
			final id: Int = plan.length + 1;
			plan.push(['$id', t.file, t.selector, Path.join([workroot, '$name.new'])].join('\t'));
			names.push('$id $name');
			candidates.push(name);
		}
		File.saveContent(Path.join([dir, 'candidates']), [for (c in candidates) '$c\n'].join(''));
		if (plan.length == 0) return null;
		File.saveContent(Path.join([dir, 'plan']), [for (p in plan) '$p\n'].join(''));
		File.saveContent(Path.join([dir, 'names']), [for (n in names) '$n\n'].join(''));
		Sys.println('schema: ${plan.length} arm(s) composed into one build');
		final devJs: String = FileSystem.fullPath(js.Node.__filename);
		final build: Command = Command.of([
			js.Node.process.execPath,
			devJs,
			'mutation-arm',
			'--schema-build',
			dir,
			job.base,
			'--repo',
			job.repo
		]);
		return {
			dir: dir,
			batch: HaxeSpawn.startAll([
				{
					cmd: build.argv[0],
					args: build.argv.slice(1),
					cwd: job.repo,
					tethered: true
				}
			], SCHEMA_BUFFER, 1)
		};
	}

	/**
	 * End the background schema build, remove the scratch worktrees, and remove `workroot` after a run whose every arm
	 * was KILLED and which is not kept; any other run keeps it (marked, under `--keep`) and says where.
	 */
	private static function release(job: ArmJob, dirs: TmpLifecycle, workroot: String, state: RunState, status: Int): Void {
		state.schema?.batch.cancel();
		for (tree in [Path.join([workroot, 'schema/tree']), Path.join([workroot, 'gen'])])
			cmd('git -C ${job.repo} worktree remove --force $tree').run();
		cmd('git -C ${job.repo} worktree prune').run();
		if (!job.keep && status == 0) {
			final refused: Null<String> = dirs.discard(workroot, job.repo);
			if (refused != null) Sys.stderr().writeString('dev mutation-arm: $refused\n');
			return;
		}
		if (job.keep) dirs.markKeep(workroot);
		Sys.stderr().writeString('dev mutation-arm: work files kept in $workroot\n');
	}

	/**
	 * The commit `--working-tree` renders against: a `git stash create` snapshot of the working tree (HEAD when it is
	 * clean), each folded-in change named on stderr. Null — refused on stderr — on an untracked file, which the snapshot
	 * would drop, and on a dirty tree `stash create` makes no snapshot of, which would silently measure HEAD.
	 */
	private static function snapshot(repo: String): Null<String> {
		final status: Array<String> = cmd('git -C $repo status --porcelain').lines();
		final untracked: Array<String> = [for (line in status) if (line.startsWith('?? ')) line.substr(3)];
		if (untracked.length > 0) {
			say([
				'--working-tree refuses — untracked file(s) would be silently dropped from the snapshot: ${untracked.join(' ')}'
			]);
			return null;
		}
		final created: Result = cmd('git -C $repo stash create').run();
		final stash: String = created.ok ? created.out.trim() : '';
		final dirty: Array<String> = cmd('git -C $repo status --porcelain --untracked-files=no').lines();
		if (stash == '' && dirty.length > 0) {
			final lines: Array<String> = [
				'--working-tree refuses — the tree is dirty but `git stash create` produced no snapshot, so the run would silently '
					+ 'measure HEAD instead:'
			];
			for (line in (created.err + created.failure).split('\n')) if (line != '') lines.push('  $line');
			final intent: Array<String> = cmd('git -C $repo diff-files --name-only --diff-filter=A').run().lines();
			if (intent.length > 0) {
				lines.push(
					'intent-to-add path(s) are the usual cause — stage them (`git add <path>`) or drop the intent (`git reset <path>`):'
				);
				for (path in intent) lines.push('  $path');
			}
			say(lines);
			return null;
		}
		final base: String = stash == '' ? 'HEAD' : stash;
		if (dirty.length > 0) {
			Sys.stderr().writeString(
				'dev mutation-arm: --working-tree base = $base, folding in ${dirty.length} uncommitted change(s) beyond HEAD:\n'
			);
			for (line in dirty) Sys.stderr().writeString('dev mutation-arm:   $line\n');
		}
		return base;
	}

	/**
	 * The engine that renders the cuts and the runner whose registry names the pins, both of the UNMUTATED tree:
	 * `HXQ_BIN` (a worker's private build, `test.js` beside it) or the tree's own `bin/`. Null, said on stderr, when
	 * either is missing.
	 */
	private static function binaries(repo: String): Null<ArmBinaries> {
		final pinned: Null<String> = Sys.getEnv('HXQ_BIN');
		if (pinned != null && pinned != '' && !FileSystem.exists(pinned)) {
			say(['HXQ_BIN=$pinned not found']);
			return null;
		}
		final apq: String = pinned != null && pinned != '' ? FileSystem.fullPath(pinned) : Path.join([repo, 'bin/apq.js']);
		final bins: ArmBinaries = { apq: apq, test: Path.join([Path.directory(apq), 'test.js']) };
		for (binary in [bins.apq, bins.test]) if (!FileSystem.exists(binary)) {
			say([
				'$binary missing — build it first (haxe bin/apq-js.hxml && haxe test-js.hxml), or point HXQ_BIN at a private engine '
				+ '(node bin/dev.js worker-build <dir> && export HXQ_BIN=<dir>/apq.js — test.js must sit beside it)'
			]);
			return null;
		}
		return bins;
	}

	/** `value` as a list of strings — a string is a list of one — or null when absent. */
	private static function strings(value: Null<Any>): Null<Array<String>> {
		if (value == null) return null;
		if (!Std.isOfType(value, Array)) return [Std.string(value)];
		final list: Array<Any> = value;
		return [for (item in list) Std.string(item)];
	}

	private static function add(table: Map<String, Array<String>>, key: String, value: String): Void {
		final list: Array<String> = table[key] ?? [];
		if (!list.contains(value)) list.push(value);
		table[key] = list;
	}

	private static function joined(table: Map<String, Array<String>>): Map<String, String> {
		final out: Map<String, String> = [];
		for (key => list in table) {
			final sorted: Array<String> = list.copy();
			sorted.sort(Reflect.compare);
			out[key] = sorted.join(',');
		}
		return out;
	}

	/** Print each of `lines` as this tool's refusal; answers the usage-error status. */
	private static function refuse(lines: Array<String>): Int {
		say(lines);
		return 2;
	}

	private static function isSet(name: String): Bool {
		final value: Null<String> = Sys.getEnv(name);
		return value != null && value != '';
	}

	/**
	 * The payload of each forced arm of `targets`, built off the member's own signature as `hxq show` prints it out of
	 * `gen` — taken from the tree rather than stored, so a signature change cannot stale the arm — or why it cannot be.
	 */
	private static function forcePayloads(
		job: ArmJob, cuts: Map<String, ArmCut>, targets: Map<String, ArmTarget>, gen: String, workroot: String, cores: Int
	): Void {
		final forced: Array<String> = [
			for (name in job.names) if (targets[name]?.failure == null && cuts[name]?.match(Force(_, _, _, _)) == true) name
		];
		final hxq: String = Path.join([job.repo, 'bin/hxq']);
		final shown: Array<Result> = Pool.of(cores).map(forced, name -> {
			final t: Null<ArmTarget> = targets[name];
			cmd('sh $hxq show ${t?.file ?? ''} --select ${t?.selector ?? ''}').at(gen);
		});
		for (i => name in forced) {
			final t: Null<ArmTarget> = targets[name];
			final header: Null<String> = shown[i].ok ? forceHeader(shown[i].out) : null;
			switch [t, header, cuts[name]] {
				case [null, _, _]:
				case [t, null, _]:
					t.failure = '$name: could not read the body brace of ${t.type}#${t.method} out of ${t.file} — '
						+ 'the member\'s braces do not balance, or its body opens mid-line';
				case [_, header, Force(_, _, _, value)]:
					File.saveContent(Path.join([workroot, '$name.payload']), forcePayload(header, value));
				case _:
			}
		}
	}

	/**
	 * Arm `name`'s rendered cut made its `<name>.patch` out of the `diff` run against the untouched file; answers why it
	 * could not be: the batch refused the cut, wrote nothing, or the cut changed nothing.
	 */
	private static function patchOf(name: String, diff: Result, workroot: String): Null<String> {
		final out: String = Path.join([workroot, '$name.new']);
		if (FileSystem.exists('$out.err')) return '$name: the cut did not apply — ${MutationSlot.oneLine(File.getContent('$out.err'))}';
		if (!FileSystem.exists(out)) return '$name: the cut did not apply — its batch wrote nothing ($workroot/render-batch.*.log)';
		if (diff.out == '')
			return diff.status == 0
				? '$name: the cut changed nothing — the registry describes the code as it already is'
				: '$name: rendering the cut died before it said why';
		File.saveContent(Path.join([workroot, '$name.patch']), diff.out);
		return null;
	}

	/**
	 * The index just past the comment, string, character or regex literal opening at `i` of `text`, or -1 when none opens
	 * there. A run left open ends the text.
	 */
	private static function pastNonCode(text: String, i: Int): Int {
		final c: Int = text.fastCodeAt(i);
		final d: Int = text.charCodeAt(i + 1) ?? -1;
		if (c == '/'.code && d == '/'.code) {
			final end: Int = text.indexOf('\n', i);
			return end < 0 ? text.length : end + 1;
		}
		if (c == '/'.code && d == '*'.code) {
			final end: Int = text.indexOf('*/', i + 2);
			return end < 0 ? text.length : end + 2;
		}
		if (c == '~'.code && d == '/'.code) return pastQuoted(text, i + 1, '/'.code);
		return c == "'".code || c == '"'.code ? pastQuoted(text, i, c) : -1;
	}

	/** The index just past the run `quote` opens at `i` of `text`, a backslash escaping the character after it. */
	private static function pastQuoted(text: String, i: Int, quote: Int): Int {
		var k: Int = i;
		while (++k < text.length) {
			final q: Int = text.fastCodeAt(k);
			if (q == '\\'.code)
				k++
			else if (q == quote)
				break;
		}
		return k + 1;
	}

	/** Print the rows of the cuts that did not apply and the tally of `applied` that did; answers 1 when any did not. */
	private static function reportApplied(applied: Int, failures: Array<String>): Int {
		for (row in failures) Sys.println(row);
		Sys.println(applyTally(applied, failures.length));
		return failures.length > 0 ? 1 : 0;
	}

	/** Print each of `lines` as this tool's refusal. */
	private static function say(lines: Array<String>): Void {
		for (line in lines) Sys.stderr().writeString('dev mutation-arm: $line\n');
	}

	/** One line of the manifest `dev mutation-check` reads: name, patch, `APQ_TEST` filter, expectations. */
	private static function manifestLine(name: String, patch: String, filter: String, expected: String): String {
		return '$name | $patch | $filter | $expected';
	}

}

/** One arm's cut as its record declares it. */
enum ArmCut {
	/** `find`/`replace`: the `hxq patch` payload. */
	Find(type: String, method: String, kind: String, payload: String);

	/** `force`: the value the member returns first thing. */
	Force(type: String, method: String, kind: String, value: String);

	/** An arm the registry does not hold, or whose pairs do not pair up. */
	Unrenderable(why: String);
}

/** One record of the arm registry as its JSON holds it: `find`/`replace` are one string or a list, `force` a scalar. */
typedef ArmRecordJson = {
	var name: String;
	var type: String;
	var method: String;
	var ?kind: String;
	var ?force: Any;
	var ?find: Any;
	var ?replace: Any;
}

/** The arm registry as its JSON holds it. */
typedef ArmTable = {
	var ?arms: Array<ArmRecordJson>;
}

/** Where one arm cuts, and why it could not be rendered once that is known. */
typedef ArmTarget = {
	var type: String;
	var method: String;
	var file: String;
	var selector: String;
	var failure: Null<String>;
}

/** The pinned tests and classes of every arm, each a sorted comma-separated list. */
typedef PinTables = {
	var tests: Map<String, String>;
	var classes: Map<String, String>;
}

/** One `dev mutation-arm` run. */
typedef ArmJob = {
	var repo: String;
	var registry: String;
	var names: Array<String>;

	/** The engine that renders the cuts, and the runner whose registry names the pins. */
	var apq: String;

	var test: String;
	var jobs: Null<String>;
	var fast: Bool;
	var keep: Bool;
	var checkApply: Bool;

	/** Render and apply every cut to a scratch copy and stop: no build, no suite. */
	var applyOnly: Bool;

	/** The commit the cuts are rendered against and every slot is made from. */
	var base: String;
}

/** The engine and the runner a run reads the unmutated tree through. */
typedef ArmBinaries = {
	var apq: String;
	var test: String;
}

/** The composed build running in the background: its directory, and the batch whose job it is. */
typedef SchemaRun = {
	var dir: String;
	var batch: PendingRuns;
}

/** What `release` must end whatever way the run went. */
typedef RunState = {
	var schema: Null<SchemaRun>;
}
