package anyparse.query.cli.command;

import anyparse.proc.ProcessRun;
import anyparse.query.MemberRegistryRename.RegistryFollow;
import anyparse.query.MoveDeclaration.MoveDeclarationData;
import anyparse.query.RegistryFragmentFollow.RewrittenModule;
import anyparse.query.TypePathRegistries.MemberKeys;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.GitRevision;

using Lambda;

/** One file a write op rewrote: the text it held before the op and the text the op wrote. */
typedef WrittenSource = { final path: String; final before: String; final after: String; }

/** A document of a registry that declares member records, with its text. */
private typedef MemberDocument = { final members: MemberKeys; final path: String; final json: String; }

/** What following the registries over rewritten modules produced: the documents to write, the fragments moved, the notes. */
private typedef RegistriesFollowed = {
	final writes: Array<{ path: String, content: String }>;
	final count: Int;
	final notes: Array<String>;
}

/**
 * `apq registry-follow` — carry the find/replace fragments of every `move.registries` record over a rewrite of the working
 * tree, compared against a git revision. `lint --fix`, `fmt --write`, `move`, `move-member`, `rename`,
 * `extract-var`, `extract-constant` and the writer-emit ops behind `CliEdit.finishEdit` carry their own write through
 * `followWrite`; the command is for a rewrite none of them made, such as a hand edit of an arm's member.
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
		final followed: RegistriesFollowed = followDocuments(memberDocuments(declaration), modules, plugin);
		if (write) CliIo.writeFiles(followed.writes);
		for (note in followed.notes) CliIo.stderr('apq registry-follow: $note\n');
		final tail: String = write ? '' : ' (not written; pass --write)';
		CliIo.sysPrint('registry-follow: ${followed.count} fragment(s) in ${followed.writes.length} file(s)$tail\n');
		return followed.notes.length == 0 ? ExitCode.EXIT_OK : ExitCode.EXIT_RUNTIME;
	}

	public function usage(): Void {
		CliIo.sysPrint('Usage: apq registry-follow <base-ref> [--write] [--lang <name>]\n\n');
		CliIo.sysPrint('Carries the find/replace values of every `move.registries` record over what the working tree rewrote against\n');
		CliIo.sysPrint(
			'<base-ref>. A moved file is followed once git reports the rename ('
			+ 'its new path staged). Exit 1 names each fragment it could not carry.\n'
		);
	}

	/**
	 * Carry the registry fragments over what a write op (`lint --fix`, `fmt --write`, `move`) has just written, from the two
	 * texts the op held rather than a git revision, and write the re-spelled documents. A fragment that cannot be carried is
	 * named on stderr and the op's exit is left as it was: its own write stands either way.
	 */
	public static function followWrite(op: String, written: Array<WrittenSource>, plugin: GrammarPlugin): Void {
		final changed: Array<WrittenSource> = written.filter(w -> w.before != w.after);
		if (changed.length == 0) return;
		final declaration: MoveDeclarationData = switch ModuleMoveCli.declarationFor(changed[0].path) {
			case Left(message):
				CliIo.stderr('apq $op: registry-follow: $message\n');
				return;
			case Right(found): found;
		};
		final documents: Array<MemberDocument> = memberDocuments(declaration);
		final typesOf: Array<Array<String>> = [
			for (d in documents)
				[
					for (record in TypePathRegistries.memberRecords(d.members, d.json)) if (record.finds.length > 0) record.type
				]
		];
		final types: Array<String> = [for (list in typesOf) for (t in list) t];
		final modules: Array<RewrittenModule> = [];
		for (w in changed) {
			final base: String = RefactorSupport.moduleNameOf(w.path);
			if (!types.exists(t -> t == base || t.endsWith('.$base'))) continue;
			try {
				final newTree: QueryNode = plugin.parseFile(w.after);
				final path: String = ModuleScan.moduleOf(newTree, w.path).path;
				if (types.contains(path)) modules.push({
					path: path,
					source: w.before,
					tree: plugin.parseFile(w.before),
					newSource: w.after,
					newTree: newTree
				});
			} catch (exception: Exception) {
				CliIo.stderr('apq $op: registry-follow: ${w.path}: ${exception.message}\n');
			}
		}
		if (modules.length == 0) return;
		// Only a document holding a record of a rewritten module is followed: the rest cannot change.
		final reached: Array<MemberDocument> = [
			for (i in 0...documents.length) if (typesOf[i].exists(t -> modules.exists(m -> m.path == t))) documents[i]
		];
		final followed: RegistriesFollowed = followDocuments(reached, modules, plugin);
		CliIo.writeFiles(followed.writes);
		for (note in followed.notes) CliIo.stderr('apq $op: registry-follow: $note\n');
		if (followed.count > 0)
			CliIo.stderr('apq $op: registry-follow: ${followed.count} fragment(s) in ${followed.writes.length} file(s)\n');
	}

	/**
	 * Write `writes` through `CliIo` and carry the registry fragments of the source files among them over the rewrite, each
	 * against the text it held before; a file the set creates has no before and carries nothing.
	 */
	public static function writeFollowed(op: String, writes: Array<{ path: String, content: String }>, plugin: GrammarPlugin): Void {
		final ext: String = CliArgs.sourceExtensionOf(plugin.langName());
		final written: Array<WrittenSource> = [
			for (w in writes)
				if (w.path.endsWith(ext) && ConfigFinder.fileExists(w.path))
					{ path: w.path, before: CliIo.readFile(w.path), after: w.content }
		];
		CliIo.writeFiles(writes);
		followWrite(op, written, plugin);
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

	/** Every document of a registry that declares member records, with its text. */
	private static function memberDocuments(declaration: MoveDeclarationData): Array<MemberDocument> {
		final out: Array<MemberDocument> = [];
		for (registry in declaration.registries) {
			final declared: Null<MemberKeys> = registry.members;
			if (declared == null) continue;
			// Re-bound: a narrowed local never reaches an anonymous-structure literal whose field is non-nullable.
			final members: MemberKeys = declared;
			for (path in RegistryFiles.of(registry.file)) out.push({ members: members, path: path, json: CliIo.readFile(path) });
		}
		return out;
	}

	/** The documents re-spelled over `modules`: what to write, how many fragments moved, and each one that could not be carried. */
	private static function followDocuments(
		documents: Array<MemberDocument>, modules: Array<RewrittenModule>, plugin: GrammarPlugin
	): RegistriesFollowed {
		final writes: Array<{ path: String, content: String }> = [];
		final notes: Array<String> = [];
		var count: Int = 0;
		for (d in documents) {
			final followed: RegistryFollow = RegistryFragmentFollow.follow(d.members, d.json, modules, plugin);
			for (note in followed.notes) notes.push(note);
			count += followed.count;
			final text: Null<String> = followed.text;
			if (text != null) writes.push({ path: d.path, content: text });
		}
		return { writes: writes, count: count, notes: notes };
	}

}
