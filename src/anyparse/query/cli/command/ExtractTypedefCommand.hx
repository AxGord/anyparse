package anyparse.query.cli.command;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.common.design.ExtractTypedef;
import anyparse.query.CanonicalEdit;
import anyparse.query.ConfigFinder;
import anyparse.query.ExitCode.*;
import anyparse.query.NewFile;
import anyparse.query.cli.CliArgs.FileAddress;

using Lambda;

/**
 * `apq extract-typedef` — name the anonymous structure written at an address as a typedef module and rewrite every
 * occurrence of the same type in the scope to its name.
 *
 * The one-off operation behind `anon-type-dup`'s finding: the name is intent the caller supplies, the equality and the
 * rewrite are `ExtractTypedef`'s. Create-only: a module already at the path is refused, never merged.
 */
@:nullSafety(Strict)
final class ExtractTypedefCommand implements CliCommand implements PostWriteFix implements PositionAddressed {

	private static final OP: String = 'extract-typedef';

	public function new() {}

	public function name(): String {
		return OP;
	}

	public function summary(): String {
		return 'Name an anonymous structure as a typedef module, rewriting its equal occurrences';
	}

	public function flags(): CliFlags {
		return new CliFlags(['--write'], ['--scope']);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runExtractTypedef(args, ctx);
	}

	public function usage(): Void {
		printExtractTypedefUsage();
	}

	private static function runExtractTypedef(args: Array<String>, ctx: CliContext): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var scope: Null<String> = null;
		var spec: Null<String> = null;
		var path: Null<String> = null;
		for (arg in new ExtractTypedefCommand().flags().walk(args)) switch arg.flag {
			case '--lang':
				lang = arg.value();
			case '--scope':
				scope = arg.value();
			case '--write':
				write = true;
			case '-h', '--help':
				printExtractTypedefUsage();
				return EXIT_OK;
			case null:
				if (spec == null) {
					spec = arg.token;
				} else if (path == null) {
					path = arg.token;
				} else {
					CliIo.stderr('apq extract-typedef: unexpected argument "${arg.token}"\n');
					return EXIT_USAGE;
				}
		}
		if (spec == null || path == null) {
			CliIo.stderr('apq extract-typedef: expected <file>:<line>[:<col>] <pkg.Name>\n');
			printExtractTypedefUsage();
			return EXIT_USAGE;
		}
		final at: Null<FileAddress> = locate(spec);
		if (at == null) return EXIT_USAGE;
		final file: String = at.file;
		final root: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		if (CliArgs.refuseDataGrammar(OP, root)) return EXIT_RUNTIME;
		final scopes: Array<String> = [scope ?? file];
		final unmatched: Array<String> = CliArgs.expandFor(lang, scopes).unmatched;
		if (unmatched.length > 0) {
			CliIo.stderr('apq extract-typedef: ${CliArgs.noFilesMatched(lang, unmatched)}\n');
			return EXIT_RUNTIME;
		}
		final files: Null<Array<{ file: String, source: String }>> = CliArgs.collectScopeFiles(OP, lang, scopes[0], [file]);
		final held: Null<{ file: String, source: String }> = files?.find(f -> f.file == file);
		if (files == null || held == null) return EXIT_RUNTIME;
		final plugin: GrammarPlugin = ProjectResolution.hostOver(root, file, files, ctx.ledger);
		return switch ExtractTypedef.extract(files, plugin, file, at.line, at.col, path) {
			case Done(slices, rewritten, skipped):
				for (note in skipped) CliIo.stderr('apq extract-typedef: left as written $note\n');
				land(slices, files, rewritten, path, write, plugin, ctx);
			case Declined(reason):
				CliIo.stderr('apq extract-typedef: $reason\n');
				EXIT_RUNTIME;
		};
	}

	/** `spec` as the file and the 1-based position it addresses, or null after saying why it is none. */
	private static function locate(spec: String): Null<FileAddress> {
		final at: Null<FileAddress> = CliArgs.addressOf(spec);
		if (at == null) {
			CliIo.stderr('apq extract-typedef: "$spec" is not <file>:<line>[:<col>]\n');
			return null;
		}
		final col: Null<Int> = at.col;
		if (at.line < 1 || (col != null && col < 1)) {
			CliIo.stderr('apq extract-typedef: "$spec" is not a 1-based position\n');
			return null;
		}
		return at;
	}

	/** Settle the slices into canonical files all-or-nothing, then preview them or write them. */
	private static function land(
		slices: Array<CrossFileEdits>, files: Array<{ file: String, source: String }>, rewritten: Int, path: String, write: Bool,
		plugin: GrammarPlugin, ctx: CliContext
	): Int {
		final creates: Array<{ file: String, text: String }> = [];
		final edited: Array<CrossFileEdits> = [];
		for (slice in slices) {
			final whole: Null<String> = slice.create;
			if (whole == null)
				edited.push(slice)
			else
				creates.push({ file: slice.file, text: whole });
		}
		for (made in creates) if (ConfigFinder.fileExists(made.file)) {
			CliIo.stderr(
				'apq extract-typedef: ${made.file} already exists — the name $path is taken (create-only, as `apq new` is); '
				+ 'pick another name\n'
			);
			return EXIT_RUNTIME;
		}
		var failure: String = 'the writer refused the result';
		final created: Null<Array<{ file: String, source: String }>> =
			CanonicalEdit.stageCrossFileCreates(creates, ConfigFinder.fileExists, (file, text) -> {
				final built: EditResult = NewFile.createRaw(text, plugin, CliArgs.discoverFormatConfig(file, ctx.ledger));
				switch built {
					case Err(message):
						failure = '$file: $message';
					case Ok(_, _):
				}
				built;
			});
		final updated: Null<Array<{ file: String, source: String }>> = created == null
			? null
			: CanonicalEdit.stageCrossFileRename(
				edited.map(s -> { file: s.file, edits: s.edits }), file -> files.find(f -> f.file == file)?.source,
				(file, source, edits) -> {
					final settled: EditResult = CanonicalEdit.canonicalize(
						source, edits, false, plugin, CliArgs.discoverFormatConfig(file, ctx.ledger)
					);
					switch settled {
						case Err(message):
							failure = '$file: $message';
						case Ok(_, _):
					}
					settled;
				}
			);
		if (created == null || updated == null) {
			CliIo.stderr('apq extract-typedef: $failure — nothing written\n');
			return EXIT_RUNTIME;
		}
		if (!write) {
			for (made in created) CliIo.sysPrint('${made.file}: created\n');
			for (changed in updated) CliIo.sysPrint('${changed.file}: updated\n');
			CliIo.sysPrint('total: ${created.length + updated.length} file(s), $rewritten occurrence(s) rewritten to $path\n');
			CliIo.stderr('apq extract-typedef: NOTHING written — this is a preview; re-run with --write to apply\n');
			return EXIT_OK;
		}
		final writes: Array<{ path: String, content: String }> = created.concat(updated)
			.map(made -> { path: made.file, content: made.source });
		RegistryFollowCommand.writeFollowed(OP, writes, plugin);
		CliIo.stderr('apq extract-typedef: wrote ${writes.length} file(s), $rewritten occurrence(s) rewritten to $path\n');
		if (ctx.postWriteFix) for (changed in updated)
			CliEdit.postWriteFix(changed.file, files.find(f -> f.file == changed.file)?.source, changed.source, plugin, ctx.ledger);
		return EXIT_OK;
	}

	private static function printExtractTypedefUsage(): Void {
		CliIo.sysPrint('Usage: apq extract-typedef <file>:<line>[:<col>] <pkg.Name> [options]\n\n');
		CliIo.sysPrint('Name the anonymous structure written at the address as `typedef Name = <structure>` in a new module\n');
		CliIo.sysPrint('<pkg>/Name.hx, and rewrite every occurrence of the same type in the scope to `Name`, with the imports each\n');
		CliIo.sysPrint('file needs. The same type means the same fields (name, optionality, written type, any order), every type\n');
		CliIo.sysPrint('name denoting the same declaration, and no type parameter of the enclosing code among them; an equal-looking\n');
		CliIo.sysPrint('occurrence that fails a part is left as written and listed. The address is the structure containing the\n');
		CliIo.sysPrint('position, or with no column the one structure starting on the line.\n\n');
		CliIo.sysPrint('Refused: a name that is not pkg.Name, a type or module of that name already there, an address with no\n');
		CliIo.sysPrint('structure of named, typed fields (extended, class-notation and #if-guarded ones are not keyed), a structure\n');
		CliIo.sysPrint('that names a type parameter, a file or edit the writer cannot settle. Nothing is written then.\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --scope <dir>      Files to search for occurrences (default: only the addressed file)\n');
		CliIo.sysPrint('  --write            Apply in place (default: print a per-file summary)\n');
		CliIo.sysPrint('  --lang <name>      Grammar plugin (default: by file extension)\n');
	}

}
