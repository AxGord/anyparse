package anyparse.query.cli;

import anyparse.check.CompilerOracle;
import anyparse.check.LintConfig;
import anyparse.query.ConfigFinder.ConfigChain;
import anyparse.query.ExitCode.*;
import anyparse.query.ModuleMove.ModuleMoveOutcome;
import anyparse.query.ModuleMove.ModuleMoveResult;
import anyparse.query.ModuleMove.ModuleRelocation;
import anyparse.query.ModulePathTokens.ModuleRename;
import anyparse.query.MoveDeclaration.MoveDeclarationData;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.cli.command.MoveCommand;
import haxe.ds.Either;
import haxe.io.Path;

using Lambda;

/** Parsed `apq move <file>... --to <dir>` options. */
private typedef ModuleMoveOpts = {
	final moves: Array<ModuleRelocation>;
	final scopes: Array<String>;
	final write: Bool;
	final verify: Bool;
	final mirror: Bool;
	final lang: String;
}

/** The file contents a written relocation replaced, and the files it created — what a rollback restores. */
private typedef WrittenState = {
	final restore: Array<{ path: String, content: String }>;
	final created: Array<String>;
}

/**
 * `apq move <file>... --to <dir> [<file>... --to <dir>]... [--scope <dir>]... [--write] [--verify] [--no-mirror]` — the
 * module form of `move`: whole modules relocated to another package by `ModuleMove`, with the project's declared texts,
 * registries, sorted lists and test mirrors read from the `move` section of its `apqlint.json` (`MoveDeclaration`).
 *
 * The write is all or nothing: every changed file is staged and committed together, the relocated originals deleted after.
 * `--verify` typechecks every configured `compilerOracle` build before and after the write and puts every file back when a
 * build that typechecked before does not after.
 */
@:nullSafety(Strict)
final class ModuleMoveCli {

	/** Whether `args` ask for the module form (`--to`). */
	public static inline function isModuleForm(args: Array<String>): Bool {
		return args.contains('--to');
	}

	/** Run the module form of `move`. */
	public static function run(args: Array<String>): Int {
		final opts: Null<ModuleMoveOpts> = parseArgs(args);
		if (opts == null) return EXIT_USAGE;
		if (opts.moves.length == 0) {
			CliIo.stderr('apq move: no module to move — give <file>... --to <dir>\n');
			return EXIT_USAGE;
		}
		final declaration: MoveDeclarationData = switch declarationFor(opts.moves[0].from) {
			case Left(message):
				CliIo.stderr('apq move: $message\n');
				return EXIT_RUNTIME;
			case Right(d): d;
		};
		final scopes: Array<String> = opts.scopes.length > 0 ? opts.scopes : declaration.scope;
		if (scopes.length == 0) {
			CliIo.stderr('apq move: no --scope given and the project declares no "move.scope"\n');
			return EXIT_USAGE;
		}
		for (m in opts.moves) if (ConfigFinder.fileExists(m.to)) {
			CliIo.stderr('apq move: ${m.to} already exists\n');
			return EXIT_RUNTIME;
		}
		final scopeFiles: Array<{ file: String, source: String }> = readAll(
			CliArgs.expandInputs(scopes, '.hx').paths.map(ConfigFinder.absolute)
		);
		final scopePaths: Array<String> = [for (e in scopeFiles) e.file];
		final textPaths: Array<String> = textFilesOf(declaration).filter(p -> !scopePaths.contains(p));
		final strayModules: Array<String> = textPaths.filter(p -> Path.extension(p) == 'hx');
		final textFiles: Array<{ file: String, source: String }> = readAll(textPaths.filter(p -> Path.extension(p) != 'hx'));
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(opts.lang));
		final result: ModuleMoveResult = ModuleMove.run({
			moves: opts.moves,
			scopeFiles: scopeFiles,
			textFiles: textFiles,
			registries: declaration.registries,
			sortedLists: declaration.sortedLists,
			mirrors: opts.mirror ? declaration.mirrors : []
		}, plugin);
		return switch result {
			case Refused(reasons):
				for (r in reasons) CliIo.stderr('apq move: $r\n');
				CliIo.stderr('apq move: refused — ${reasons.length} reason(s), nothing written\n');
				EXIT_RUNTIME;
			case Moved(outcome):
				final stray: Array<String> = strayMentions(strayModules, outcome.renames);
				if (stray.length > 0) {
					for (s in stray) CliIo.stderr('apq move: $s\n');
					CliIo.stderr('apq move: refused — module text outside --scope spells a moved path, nothing written\n');
					return EXIT_RUNTIME;
				}
				emit(opts, outcome, scopeFiles, plugin);
		};
	}

	/** The move declaration of the nearest `apqlint.json` above `file` that carries one, or an empty one. */
	private static function declarationFor(file: String): Either<String, MoveDeclarationData> {
		final chain: ConfigChain = ConfigFinder.findUpAll(file, 'apqlint.json', ConfigFinder.PROJECT_ROOT_MARKERS);
		for (doc in chain.documents) switch MoveDeclaration.read(doc.content, Path.directory(doc.path)) {
			case Left(message):
				return Left('${doc.path}: "move" section: $message');
			case Right(found) if (found != null):
				return Right(found);
			case Right(_):
		}
		return Right(MoveDeclaration.empty());
	}

	/** Every declared text file: a listed file as is, a listed directory's files of a declared extension; minus exclusions. */
	private static function textFilesOf(d: MoveDeclarationData): Array<String> {
		final out: Array<String> = [];
		for (entry in d.text) {
			final found: Array<String> = ConfigFinder.fileExists(entry) ? [entry] : [
				for (ext in d.textExtensions.concat(['hx'])) for (p in Glob.expand(entry, '.$ext')) p
			];
			for (p in found) {
				final abs: String = ConfigFinder.absolute(p);
				if (!out.contains(abs) && !d.textExclude.exists(x -> abs == x || abs.startsWith('$x/'))) out.push(abs);
			}
		}
		for (r in d.registries) if (!out.contains(r.file)) out.push(r.file);
		return out;
	}

	/** Each of `paths` with its text. */
	private static function readAll(paths: Array<String>): Array<{ file: String, source: String }> {
		return [for (p in paths) { file: p, source: CliIo.readSourceForParse(p) }];
	}

	/** One line per module OUTSIDE the scope that spells a relocated path — its references would be left unproven. */
	private static function strayMentions(paths: Array<String>, renames: Array<ModuleRename>): Array<String> {
		final out: Array<String> = [];
		for (p in paths) {
			final text: String = CliIo.readFile(p);
			for (r in renames) if (ModulePathTokens.edits(text, [r]).length > 0)
				out.push('$p spells ${r.oldPath} but is outside --scope — widen the scope to cover it');
		}
		return out;
	}

	/** Print the preview, or write (and with `--verify`, prove) the relocation. */
	private static function emit(
		opts: ModuleMoveOpts, outcome: ModuleMoveOutcome, scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): Int {
		if (!opts.write) return preview(outcome);
		final originalOf: Map<String, String> = [for (e in scopeFiles) e.file => e.source];
		for (m in outcome.moves) originalOf[m.to] = originalOf[m.from] ?? '';
		final canonical: Array<MoveChange> = [for (c in outcome.changes) canonicalOf(c, originalOf, plugin)];
		final judging: Null<Array<OracleConfig>> = opts.verify ? judgingConfigs(outcome.moves[0].from) : [];
		if (judging == null) return EXIT_RUNTIME;
		final state: WrittenState = write(canonical, outcome.removed);
		final failed: Array<String> = opts.verify ? failedAfter(judging) : [];
		if (failed.length > 0) {
			rollback(state);
			for (f in failed) CliIo.stderr('apq move: --verify: $f\n');
			CliIo.stderr('apq move: --verify: the tree does not typecheck after the move — every file put back\n');
			return EXIT_RUNTIME;
		}
		for (i in outcome.imports) CliIo.stderr('apq move: import added: $i\n');
		final verified: String = opts.verify ? ', verified' : '';
		CliIo.stderr('apq move: moved ${outcome.moves.length} module(s), wrote ${canonical.length} file(s)$verified\n');
		return EXIT_OK;
	}

	/** A module change canonicalised when the text it replaces was writer-canonical; any other text as is. */
	private static function canonicalOf(change: MoveChange, originalOf: Map<String, String>, plugin: GrammarPlugin): MoveChange {
		final original: Null<String> = originalOf[change.file];
		if (Path.extension(change.file) != 'hx' || original == null) return change;
		final opts: Null<String> = CliArgs.discoverFormatConfig(change.file);
		return CanonicalEdit.isWriterCanonical(original, plugin, opts)
			? MoveCommand.fixedPointChange('move', change, plugin, opts)
			: change;
	}

	/** Write every change together, then delete the relocated originals; what a rollback needs to undo it. */
	private static function write(changes: Array<MoveChange>, removed: Array<String>): WrittenState {
		final restore: Array<{ path: String, content: String }> = [];
		final created: Array<String> = [];
		for (c in changes) if (ConfigFinder.fileExists(c.file))
			restore.push({ path: c.file, content: CliIo.readFile(c.file) });
		else
			created.push(c.file);
		for (r in removed) restore.push({ path: r, content: CliIo.readFile(r) });
		CliIo.writeFiles([for (c in changes) { path: c.file, content: c.newSource }]);
		final state: WrittenState = { restore: restore, created: created };
		for (r in removed) if (!CliIo.deletePath(r)) {
			rollback(state);
			throw new Exception('apq move: could not delete $r after writing its new copy — every file put back');
		}
		return state;
	}

	/** Put every file `state` recorded back as it was. */
	private static function rollback(state: WrittenState): Void {
		CliIo.writeFiles(state.restore);
		for (c in state.created) CliIo.deletePath(c);
	}

	/** `args` read, or null after printing why they cannot be. */
	private static function parseArgs(args: Array<String>): Null<ModuleMoveOpts> {
		final moves: Array<ModuleRelocation> = [];
		final scopes: Array<String> = [];
		final pending: Array<String> = [];
		var write: Bool = false;
		var verify: Bool = false;
		var mirror: Bool = true;
		var lang: String = 'haxe';
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--to':
					final dir: String = ConfigFinder.absolute(CliArgs.expectValue(args, ++i, '--to'));
					if (pending.length == 0) {
						CliIo.stderr('apq move: --to $dir follows no module\n');
						return null;
					}
					for (p in pending) moves.push({ from: p, to: Path.join([dir, Path.withoutDirectory(p)]) });
					pending.resize(0);
				case '--scope':
					scopes.push(ConfigFinder.absolute(CliArgs.expectValue(args, ++i, '--scope')));
				case '--write':
					write = true;
				case '--verify':
					verify = true;
				case '--no-mirror':
					mirror = false;
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case _ if (a.startsWith('-')):
					CliIo.stderr('apq move: unknown option "$a" in the module form\n');
					return null;
				case _:
					pending.push(ConfigFinder.absolute(a));
			}
			i++;
		}
		if (pending.length <= 0) return {
			moves: moves,
			scopes: scopes,
			write: write,
			verify: verify,
			mirror: mirror,
			lang: lang
		};
		CliIo.stderr('apq move: ${pending.join(', ')} given no --to <dir>\n');
		return null;
	}

	/** The preview of `outcome`: every relocation, every updated file, every import the move would add. */
	private static function preview(outcome: ModuleMoveOutcome): Int {
		final moved: Array<String> = [for (m in outcome.moves) m.to];
		for (m in outcome.moves) CliIo.sysPrint('${m.from} -> ${m.to}\n');
		for (c in outcome.changes) if (!moved.contains(c.file)) CliIo.sysPrint('${c.file}: updated\n');
		for (i in outcome.imports) CliIo.sysPrint('import added: $i\n');
		CliIo.sysPrint('total: ${moved.length} module(s) moved, ${outcome.changes.length - moved.length} file(s) updated\n');
		CliIo.stderr('apq move: NOTHING written — this is a preview; re-run with --write to apply\n');
		return EXIT_OK;
	}

	/**
	 * The configured builds that typecheck now, near `file` — the ones a failure after the move is attributable to; null
	 * (after saying why) when there are none.
	 */
	private static function judgingConfigs(file: String): Null<Array<OracleConfig>> {
		final oracles: Array<OracleConfig> = LintConfig.discover(file).compilerOracles();
		if (oracles.length == 0) {
			CliIo.stderr('apq move: --verify needs a "compilerOracle" in apqlint.json — nothing written\n');
			return null;
		}
		final out: Array<OracleConfig> = [];
		for (i => outcome in CompilerOracle.typecheckEach(oracles, false)) switch outcome {
			case Confirmed:
				out.push(oracles[i]);
			case _:
				CliIo.stderr('apq move: --verify: ${oracles[i].hxml} does not typecheck before the move — it judges nothing\n');
		}
		if (out.length > 0) return out;
		CliIo.stderr('apq move: --verify: no configured build typechecks before the move — nothing written\n');
		return null;
	}

	/** One line per build of `judging` that does not typecheck now. */
	private static function failedAfter(judging: Array<OracleConfig>): Array<String> {
		final out: Array<String> = [];
		for (i => outcome in CompilerOracle.typecheckEach(judging, false)) switch outcome {
			case Confirmed:
			case Rejected(errors):
				out.push('${judging[i].hxml}: $errors');
			case Unavailable(reason):
				out.push('${judging[i].hxml}: unavailable after the move: $reason');
			case null:
				out.push('${judging[i].hxml}: no verdict');
		}
		return out;
	}

}
