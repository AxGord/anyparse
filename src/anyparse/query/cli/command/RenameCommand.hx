package anyparse.query.cli.command;

import anyparse.query.CrossRename;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.Rename;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq rename` — scope-correct, format-preserving symbol rename.
 *
 * A `--scope` EDIT: the answer depends on files other than the one it rewrites, so the
 * scope is collected first and the result leaves through `CliEdit`'s write / preview tail.
 */
@:nullSafety(Strict)
final class RenameCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'rename';
	}

	public function summary(): String {
		return 'Scope-correct, format-preserving symbol rename';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runRename(args);
	}

	public function usage(): Void {
		printRenameUsage();
	}

	/**
	 * `apq rename <file> <line>:<col> <newName> [--write]` — scope-correct,
	 * format-preserving rename of the binding identified by the symbol at
	 * `<line>:<col>`. Position-based so the EXACT binding is selected
	 * (`apq refs <name> --reads` shows distinct bindings for shadowed
	 * names). Reuses the `refs` resolver to collect the binding's full
	 * occurrence set, then span-rewrites only those identifier tokens.
	 *
	 * `<line>:<col>` uses the same column convention `apq refs` PRINTS, so
	 * a coordinate copied straight from `apq refs --decls` output selects
	 * the intended binding. Without `--write` the rewritten source is
	 * emitted to stdout; with `--write` it overwrites the file in place.
	 * A cursor that is not on a renameable identifier, or a rewrite that
	 * fails to re-parse, exits non-zero with the source untouched.
	 */
	private static function runRename(args: Array<String>): Int {
		// noqa: complexity
		var lang: String = 'haxe';
		var write: Bool = false;
		var scope: Null<String> = null;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var selectExpr: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var newName: Null<String> = null;
		var qualifyShadowed: Bool = false;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--select':
					selectExpr = CliArgs.expectValue(args, ++i, '--select');
				case '--match':
					matchExpr = CliArgs.expectValue(args, ++i, '--match');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '--write':
					write = true;
				case '--scope':
					scope = CliArgs.expectValue(args, ++i, '--scope');
				case '--qualify-shadowed':
					qualifyShadowed = true;
				case '-h', '--help':
					printRenameUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq rename: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null && selectExpr == null && matchExpr == null && newName == null && CliArgs.isPosSpec(a))
						posSpec = a;
					else if (newName == null)
						newName = a;
					else {
						CliIo.stderr('apq rename: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || (posSpec == null && selectExpr == null && matchExpr == null) || newName == null) {
			CliIo.stderr("apq rename: expected <file> (<line>:<col> | --select '<sel>' | --match '<pattern>') <newName>\n");
			printRenameUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final newNameStr: String = newName;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq rename: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		final op: String = 'rename';
		final pos: Null<Position> = CliEdit.resolveAddressPos(op, source, plugin, posSpec, selectExpr, matchExpr, nth, true);
		if (pos == null) return EXIT_RUNTIME;

		if (scope != null) return runRenameScope(filePath, source, pos.line, pos.col, newNameStr, scope, write, plugin);
		// A TYPE name lives in the type namespace, which `Rename` (value bindings) does not
		// index - route it through the op `--scope` uses, with the cursor file as the scope.
		if (cursorOnTypeDecl(source, pos.line, pos.col, plugin))
			return runRenameTypeInFile(filePath, source, pos.line, pos.col, newNameStr, write, plugin);
		// Same for a MEMBER: value-binding resolution binds a name lexically, never through a
		// receiver's type, so `Rename` rewrote the declaration and left every `obj.member` access
		// on the old name - a rewrite that does not compile.
		if (cursorOnMemberDecl(source, pos.line, pos.col, plugin))
			return runRenameMemberInFile(filePath, source, pos.line, pos.col, newNameStr, write, plugin);

		final shape: RefShape = plugin.refShape();
		final result: RenameResult = Rename.rename(source, pos.line, pos.col, newNameStr, plugin, shape, qualifyShadowed, filePath);
		switch result {
			case Ok(text):
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq rename: wrote $filePath\n');
				} else
					CliEdit.previewEdit(op, filePath, text);
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq rename: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq rename <file> <l>:<c> <newName> --scope <dir>` — cross-file
	 * TYPE rename. The cursor's binding MUST be a type declaration; that
	 * type is renamed across every `.hx` file under `<dir>` (plus the
	 * cursor file if it sits outside the scope). Reads the scope files
	 * from disk, drives the pure `CrossRename.crossRenameType`, and on
	 * success either writes each changed file (`--write`) or prints a
	 * per-file occurrence summary. The whole rewrite is atomic — the
	 * pure op validates every rewritten file before returning, so a
	 * write either touches all changed files or none.
	 */
	private static function runRenameScope(
		filePath: String, source: String, line: Int, col: Int, newName: String, scope: String, write: Bool, plugin: GrammarPlugin
	): Int {
		final expanded: ExpandedInputs = CliArgs.expandInputs([scope], '.hx');
		final paths: Array<String> = expanded.paths;
		// The cursor file's declaration must be covered even if it sits
		// outside the scope directory — add it when expandInputs missed it.
		if (!paths.contains(filePath)) paths.push(filePath);
		if (paths.length == 0) {
			CliIo.stderr('apq rename: --scope $scope matched no .hx files\n');
			return EXIT_RUNTIME;
		}

		final scopeFiles: Array<{ file: String, source: String }> = [];
		for (path in paths) {
			if (path == filePath) {
				scopeFiles.push({ file: path, source: source });
				continue;
			}
			final fileSource: String = try CliIo.readSourceForParse(path) catch (exception: Exception) {
				CliIo.stderr('apq rename: $path: ${exception.message}\n');
				return EXIT_RUNTIME;
			};
			scopeFiles.push({ file: path, source: fileSource });
		}

		final typeRefShape: TypeRefShape = plugin.typeRefShape();
		final refShape: RefShape = plugin.refShape();
		// Dispatch on what the cursor lands on: a TYPE declaration renames
		// through CrossRename, a MEMBER declaration through CrossRenameMember.
		final result: CrossRenameResult = cursorOnTypeDecl(source, line, col, plugin)
			? CrossRename.crossRenameType(filePath, source, line, col, newName, scopeFiles, plugin, typeRefShape, refShape)
			: CrossRenameMember.crossRenameMember(filePath, source, line, col, newName, scopeFiles, plugin, refShape);
		switch result {
			case Ok(changes, advisory):
				var totalOccurrences: Int = 0;
				for (c in changes) totalOccurrences += c.count;
				if (write) {
					CliIo.writeFiles([for (c in changes) { path: c.file, content: c.newSource }]);
					CliIo.stderr('apq rename: wrote ${changes.length} file(s), $totalOccurrences occurrence(s)\n');
				} else {
					for (c in changes) CliIo.sysPrint('${c.file}: ${c.count} occurrence(s)\n');
					CliIo.sysPrint('total: ${changes.length} file(s), $totalOccurrences occurrence(s)\n');
					CliIo.stderr('apq rename: NOTHING written — this is a preview; re-run with --write to apply\n');
				}
				if (advisory != null) CliIo.stderr('apq rename: $advisory\n');
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq rename: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * Does the cursor sit on a TYPE declaration? The single question BOTH rename
	 * dispatches ask - the in-file path routes a type cursor to `runRenameTypeInFile`,
	 * the `--scope` path to `CrossRename` - so a second copy could drift and send the
	 * same cursor down two different ops.
	 */
	private static function cursorOnTypeDecl(source: String, line: Int, col: Int, plugin: GrammarPlugin): Bool {
		return try {
			final tree: QueryNode = plugin.parseFile(source);
			RefactorSupport.resolveTypeDeclAtCursor(tree, Span.offsetOf(source, line, col), source) != null;
		} catch (exception: Exception) false;
	}

	/**
	 * The member twin of `cursorOnTypeDecl`. It asks the resolver `CrossRenameMember` itself uses, so
	 * the in-file branch and the `--scope` branch cannot disagree about what a member cursor is.
	 */
	private static function cursorOnMemberDecl(source: String, line: Int, col: Int, plugin: GrammarPlugin): Bool {
		return try {
			final tree: QueryNode = plugin.parseFile(source);
			CrossRenameMember.isMemberDeclAtCursor(tree, Span.offsetOf(source, line, col), source, plugin.refShape());
		} catch (exception: Exception) false;
	}

	/**
	 * `apq rename <file> <addr> <newName>` with the cursor on a TYPE declaration and no
	 * `--scope` - the type-namespace rename confined to the cursor file.
	 *
	 * `Rename` resolves through the VALUE namespace, so on a type it rewrites the
	 * declaration's name token and nothing else: `:T`, `new T()`, `extends T` and
	 * `T.CONST` are type positions it never binds. The correct occurrence set is
	 * `CrossRename`'s, so this runs that same op with the cursor file as the whole scope.
	 *
	 * The file scope is a real limitation, not a residual: a type referenced from ANOTHER
	 * file keeps the old name there. Like every occurrence `CrossRename` leaves behind,
	 * that dangles into a compile error rather than a silent semantic change - and the
	 * advisory says so, pointing at `--scope`.
	 */
	private static function runRenameTypeInFile(
		filePath: String, source: String, line: Int, col: Int, newName: String, write: Bool, plugin: GrammarPlugin
	): Int {
		return emitInFileRename(
			CrossRename.crossRenameType(
				filePath, source, line, col, newName, [{ file: filePath, source: source }],
				plugin, plugin.typeRefShape(), plugin.refShape()
			),
			write
		);
	}

	/**
	 * In-file rename of a MEMBER declaration, through the op `--scope` uses with the cursor file as
	 * the whole scope. The member namespace resolves accesses via the receiver's declared type, which
	 * the value-binding rename cannot do.
	 */
	private static function runRenameMemberInFile(
		filePath: String, source: String, line: Int, col: Int, newName: String, write: Bool, plugin: GrammarPlugin
	): Int {
		return emitInFileRename(
			CrossRenameMember.crossRenameMember(
				filePath, source, line, col, newName, [{ file: filePath, source: source }], plugin, plugin.refShape()
			),
			write
		);
	}

	/**
	 * Emit the ONE file change an in-file cross-rename produces, type or member: write it or print
	 * it, then the file-scope advisory and whatever the op itself reported.
	 */
	private static function emitInFileRename(result: CrossRenameResult, write: Bool): Int {
		switch result {
			case Ok(changes, advisory):
				// The scope is one file and an empty change set is `Err`, so there is exactly one.
				if (changes.length != 1) throw new Exception('in-file rename produced ${changes.length} file change(s)');
				final change: FileChange = changes[0];
				if (write) {
					CliIo.writeFile(change.file, change.newSource);
					CliIo.stderr('apq rename: wrote ${change.file}, ${change.count} occurrence(s)\n');
				} else {
					// The one preview tail that spells the notice itself: this op's name already
					// occurs twice as a bare literal, and a third would read as an extractable
					// constant rather than as the CLI vocabulary it is.
					CliIo.sysPrint(change.newSource);
					CliIo.stderr('apq rename: ${change.file} NOT written — this is a preview on stdout; re-run with --write to apply\n');
				}
				CliIo.stderr(
					'apq rename: in-file rename - references in OTHER files keep the old name; pass --scope <dir> to cover them\n'
				);
				if (advisory != null) CliIo.stderr('apq rename: $advisory\n');
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq rename: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printRenameUsage(): Void {
		CliIo.sysPrint(
			"Usage: apq rename <file> (<line>:<col> | --select '<sel>' | --match '<pattern>') <newName> [--write] [--scope <dir>]\n"
		);
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		CliIo.sysPrint('  --scope <dir>       Cross-file rename of a TYPE or a MEMBER across <dir>\n');
		CliIo.sysPrint('  --qualify-shadowed  Insert `this.` instead of refusing a capture: on the\n');
		CliIo.sysPrint('                      member access when a PARAMETER of the same name\n');
		CliIo.sysPrint('                      captures it, and on the captured references when a\n');
		CliIo.sysPrint('                      renamed LOCAL shadows a member. Reaching an INHERITED\n');
		CliIo.sysPrint('                      member needs a resolution scope, which this in-file op\n');
		CliIo.sysPrint('                      carries none of - there it repairs only a member of the\n');
		CliIo.sysPrint('                      enclosing type (`apq lint --fix` has the wider scope)\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Scope-correct, format-preserving rename of the binding identified by\n');
		CliIo.sysPrint('the symbol at <line>:<col>. The position selects the EXACT binding —\n');
		CliIo.sysPrint('a shadowing param / loop var / field with the same name is left\n');
		CliIo.sysPrint('untouched. <line>:<col> uses the same column convention `apq refs`\n');
		CliIo.sysPrint('prints, so a coordinate copied from `apq refs --decls` selects the\n');
		CliIo.sysPrint('intended binding. The rewrite is verified to re-parse; a cursor not on\n');
		CliIo.sysPrint('a renameable identifier, or an unparseable result, exits non-zero with\n');
		CliIo.sysPrint('the file untouched.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A cursor on a TYPE declaration renames the TYPE namespace (the forms\n');
		CliIo.sysPrint('listed under --scope below), confined to <file>: references in other\n');
		CliIo.sysPrint('files keep the old name and dangle into a compile error. Pass --scope\n');
		CliIo.sysPrint('to cover them; the in-file form is for a type no other file names, and\n');
		CliIo.sysPrint('for one whose simple name --scope would reject as ambiguous.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A cursor on a MEMBER declaration takes the same route through the\n');
		CliIo.sysPrint('MEMBER namespace, also confined to <file>: value-binding resolution\n');
		CliIo.sysPrint('binds a name lexically and never through a receiver type, so without\n');
		CliIo.sysPrint('it the declaration was rewritten and every obj.member access left on\n');
		CliIo.sysPrint('the old name. The refusals listed under --scope apply here too.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('With --scope <dir> the cursor selects a TYPE or a MEMBER declaration.\n');
		CliIo.sysPrint('On a TYPE declaration (class /\n');
		CliIo.sysPrint('interface / enum / typedef / abstract) that type is renamed across\n');
		CliIo.sysPrint('every .hx file under <dir> — type positions, new T, cast, extends /\n');
		CliIo.sysPrint('implements, type params, the decl name, import / using segments,\n');
		CliIo.sysPrint('qualified positions naming the type through its module path\n');
		CliIo.sysPrint('(pkg.Mod.T, and Mod.T from the module own package), and\n');
		CliIo.sysPrint('static-receiver accesses (T.staticMethod() / T.CONST / pkg.Mod.CONST\n');
		CliIo.sysPrint('whose receiver is not a value binding). Type-namespace only: bare\n');
		CliIo.sysPrint('Class<T> value uses (var c = T;) and aliased imports are NOT rewritten\n');
		CliIo.sysPrint('(a missed form dangles into a compile error, never a silent change).\n');
		CliIo.sysPrint('Renaming the MAIN type of a module renames the module path with it —\n');
		CliIo.sysPrint('rename the FILE to match by hand. The rename refuses\n');
		CliIo.sysPrint('if the type is declared in more than one file under scope, if any scope\n');
		CliIo.sysPrint('file does not parse, or if any rewritten file fails to re-parse — the\n');
		CliIo.sysPrint('write is atomic. Without --write a per-file occurrence summary is printed.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('On a MEMBER declaration (field / method, e.g. --select FnMember:foo)\n');
		CliIo.sysPrint('that member is renamed across scope: the decl, in-type references, and\n');
		CliIo.sysPrint('qualified accesses — Src.member / pkg.Src.member for a static member\n');
		CliIo.sysPrint('(a dotted receiver must name the declaring module WHOLE, the same\n');
		CliIo.sysPrint('spellings the type rename accepts, so other.Src.member is left alone),\n');
		CliIo.sysPrint('obj.member whose receiver resolves to the source type for an instance\n');
		CliIo.sysPrint('member. Receivers whose type does not resolve, a dotted static receiver\n');
		CliIo.sysPrint('spelling no legal path to the declaring module, super-access,\n');
		CliIo.sysPrint('using-extension calls, and overrides are left as loud compile errors.\n');
		CliIo.sysPrint('An enum-abstract VALUE also renames where Haxe resolves it from the\n');
		CliIo.sysPrint('EXPECTED type: a bare VALUE in RETURN position whose enclosing function\n');
		CliIo.sysPrint('declares the abstract as its return type (one Null<..> wrapper unwrapped,\n');
		CliIo.sysPrint('the annotation resolved from the READING file by whole path, never by\n');
		CliIo.sysPrint('last segment), reached through the type-transparent slots under a return\n');
		CliIo.sysPrint('— parentheses, both ternary and if-expression arms, and the last\n');
		CliIo.sysPrint('statement of a switch-expression arm. A nested function owns its own\n');
		CliIo.sysPrint('return type and stops the proof; a member the enclosing type or an\n');
		CliIo.sysPrint('ancestor declares shadows the expected-type reading and is left alone.\n');
		CliIo.sysPrint('An expected-type value OUTSIDE return position (x == VALUE, an annotated\n');
		CliIo.sysPrint('assignment, a typed argument) or one in a function with no return\n');
		CliIo.sysPrint('annotation is not proven and is left for the compiler to reject.\n');
		CliIo.sysPrint('A member a #if region\n');
		CliIo.sysPrint('declares once per branch is one logical member: every branch declaration\n');
		CliIo.sysPrint('moves in the same edit set. Refuses an override member,\n');
		CliIo.sysPrint('a member an ancestor under scope declares (an implementation of an\n');
		CliIo.sysPrint('abstract or interface method carries no override modifier, so the\n');
		CliIo.sysPrint('keyword alone never saw it), a name already declared on the type, or a\n');
		CliIo.sysPrint('type declared more than once under scope.\n');
	}

}
