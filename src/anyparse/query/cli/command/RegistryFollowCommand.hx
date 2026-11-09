package anyparse.query.cli.command;

import anyparse.proc.ProcessRun;
import anyparse.query.MemberRegistryRename.RegistryFollow;
import anyparse.query.MoveDeclaration.MoveDeclarationData;
import anyparse.query.RegistryFragmentFollow.RewrittenModule;
import anyparse.query.TypePathRegistries.MemberKeys;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.GitRevision;

/**
 * `apq registry-follow` — after a mechanical rewrite of the working tree (`lint --fix`, `fmt`, a move), carry the
 * find/replace fragments of every `move.registries` record over it. It compares against a git revision rather than
 * hooking each writer, so every rewrite is covered by one path.
 */
@:nullSafety(Strict)
final class RegistryFollowCommand implements CliCommand implements LanguageFree {

	public function new() {}

	public function name(): String {
		return 'registry-follow';
	}

	public function summary(): String {
		return 'Re-spell registry find/replace fragments over a mechanical rewrite of the working tree against a git revision';
	}

	public function flags(): CliFlags {
		return new CliFlags(['--write'], ['--lang']);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		var ref: Null<String> = null;
		var write: Bool = false;
		var lang: String = 'haxe';
		for (arg in flags().walk(args)) switch arg.flag {
			case '--write':
				write = true;
			case '--lang':
				lang = arg.value();
			case '-h', '--help':
				usage();
				return ExitCode.EXIT_OK;
			case null:
				if (ref != null) throw new UsageFailure('one <base-ref> only');
				ref = arg.token;
		}
		if (ref == null) throw new UsageFailure('missing <base-ref>');
		final base: String = ref;
		final listed: ProcessRun = GitRevision.diffNameStatus([base], []);
		if (listed.failure != '' || listed.status != 0) {
			CliIo.stderr('apq registry-follow: git diff against "$base" failed: ${listed.failure}${listed.err}\n');
			return ExitCode.EXIT_RUNTIME;
		}
		final entries: Array<ChangedPath> = GitRevision.parseNameStatus(listed.out).filter(e -> isRewritten(e, lang));
		if (entries.length == 0) {
			CliIo.sysPrint('registry-follow: 0 fragment(s) in 0 file(s)\n');
			return ExitCode.EXIT_OK;
		}
		final plugin: GrammarPlugin = CliArgs.pickPluginFor(lang, entries[0].path);
		final modules: Null<Array<RewrittenModule>> = readModules(entries, base, plugin);
		if (modules == null) return ExitCode.EXIT_RUNTIME;
		final declaration: MoveDeclarationData = switch ModuleMoveCli.declarationFor(entries[0].path) {
			case Left(message):
				CliIo.stderr('apq registry-follow: $message\n');
				return ExitCode.EXIT_RUNTIME;
			case Right(found): found;
		};
		final writes: Array<{ path: String, content: String }> = [];
		final notes: Array<String> = [];
		var count: Int = 0;
		for (registry in declaration.registries) {
			final members: Null<MemberKeys> = registry.members;
			if (members != null) for (path in RegistryFiles.of(registry.file)) {
				final followed: RegistryFollow = RegistryFragmentFollow.follow(members, CliIo.readFile(path), modules, plugin);
				for (note in followed.notes) notes.push(note);
				count += followed.count;
				final text: Null<String> = followed.text;
				if (text != null) writes.push({ path: path, content: text });
			}
		}
		if (write) CliIo.writeFiles(writes);
		for (note in notes) CliIo.stderr('apq registry-follow: $note\n');
		CliIo.sysPrint('registry-follow: $count fragment(s) in ${writes.length} file(s)${write ? '' : ' (not written; pass --write)'}\n');
		return notes.length == 0 ? ExitCode.EXIT_OK : ExitCode.EXIT_RUNTIME;
	}

	public function usage(): Void {
		CliIo.sysPrint('Usage: apq registry-follow <base-ref> [--write] [--lang <name>]\n\n');
		CliIo.sysPrint('Carries the find/replace values of every `move.registries` record over what the working tree rewrote against\n');
		CliIo.sysPrint(
			'<base-ref>. A moved file is followed once git reports the rename ('
			+ 'its new path staged). Exit 1 names each fragment it could not carry.\n'
		);
	}

	private static inline function isRewritten(entry: ChangedPath, lang: String): Bool {
		return (entry.status == 'M' || entry.status == 'R') && entry.path.endsWith(CliArgs.sourceExtensionOf(lang));
	}

	/** Both versions of each changed module, or null after naming the one that could not be read. */
	private static function readModules(entries: Array<ChangedPath>, base: String, plugin: GrammarPlugin): Null<Array<RewrittenModule>> {
		final modules: Array<RewrittenModule> = [];
		for (entry in entries) {
			final read: Null<String> = GitRevision.sourceAt(base, entry.basePath);
			if (read == null) {
				CliIo.stderr('apq registry-follow: ${entry.basePath} is not readable at "$base"\n');
				return null;
			}
			final before: String = read;
			final now: String = CliIo.readFile(entry.path);
			try {
				final tree: QueryNode = plugin.parseFile(before);
				final newTree: QueryNode = plugin.parseFile(now);
				modules.push({
					path: ModuleScan.moduleOf(newTree, entry.path).path,
					source: before,
					tree: tree,
					newSource: now,
					newTree: newTree
				});
			} catch (exception: Exception) {
				CliIo.stderr('apq registry-follow: ${entry.path}: ${exception.message}\n');
				return null;
			}
		}
		return modules;
	}

}
