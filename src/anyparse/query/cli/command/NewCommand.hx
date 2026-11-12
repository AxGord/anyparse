package anyparse.query.cli.command;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ExitCode.*;
import anyparse.query.NewFile.NewFileResult;
import anyparse.query.NewFile.NewFileSpec;
import anyparse.query.PackageDocumentCarry.RegistryDocument;
import anyparse.query.TypePathRegistries.TypePathRegistry;
import haxe.ds.Either;
import haxe.io.Path;

using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * Parsed options for `apq new` — `lang`, the `kind` of declaration to scaffold and its shape (`asClass`
 * / `iface` / `underlying` / `extendsList` / `fields` / bodies), the target `path`, and `write` /
 * `open` flags. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef NewOpts = {
	var lang: String;
	var write: Bool;
	var asClass: Bool;
	var open: Bool;
	var raw: Bool;
	var kind: String;
	var iface: Null<String>;
	var underlying: Null<String>;
	var bodiesArg: Null<String>;
	var bodiesFromFile: Null<String>;
	var extendsList: Array<String>;
	var fromList: Array<String>;
	var toList: Array<String>;
	var fields: Array<String>;
	var arms: Array<String>;
	var armsDir: Null<String>;
	var path: Null<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq new` — create a new module — final class / implements <iface> (canonical).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class NewCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'new';
	}

	public function summary(): String {
		return 'Create a new module — final class / implements <iface> (canonical)';
	}

	public function flags(): CliFlags {
		// `--raw -` names stdin, the only source `--raw` reads; a bare `--raw` reads it too.
		return new CliFlags(['--class', '--open', '--write'], [
			'--arm',
			'--arm-file',
			'--arms-dir',
			'--bodies',
			'--extends',
			'--field',
			'--from',
			'--from-file',
			'--implements',
			'--kind',
			'--to',
			'--underlying'
		]).withOptional('--raw', token -> token == '-');
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runNew(args, ctx.ledger);
	}

	public function usage(): Void {
		printNewUsage();
	}

	/**
	 * `apq new <path> (--class | --implements <iface>) [--field <m>]...
	 * [--bodies -] [--write]` — create a new module deterministically: derive
	 * the package + class name from <path>, assemble the scaffold (interface
	 * method stubs with sliced signatures, or verbatim `--field` members), and
	 * run it through the writer so the result is canonical-or-rejected and the
	 * file is never written on a parse failure. Create-only: an existing path
	 * is refused. `--bodies -` reads `@@ <method>` sections from stdin (see
	 * `NewFile`); a method without a section is left as a NotImplementedException
	 * stub (reported on stderr). Without `--write` the source goes to stdout.
	 * The class name for a new file: its basename without its extension, whichever grammar registers it.
	 */
	public static function newFileClassName(path: String): String {
		return Path.withoutExtension(Path.withoutDirectory(path));
	}

	/**
	 * Derive the Haxe package for `path` from its location under a `src/` or
	 * `test/` source root: the directory segments below that root, dot-joined
	 * (`.../src/anyparse/check/Foo.hx` → `anyparse.check`). A file directly in
	 * a root, or outside any root, is package-less (`''`).
	 */
	public static function derivePackage(path: String): String {
		final dir: String = '${Path.directory(FileSystem.absolutePath(path))}/';
		for (root in ['/src/', '/test/']) {
			final at: Int = dir.lastIndexOf(root);
			if (at < 0) continue;
			var tail: String = dir.substr(at + root.length);
			if (tail.endsWith('/')) tail = tail.substr(0, tail.length - 1);
			return tail == '' ? '' : tail.split('/').join('.');
		}
		return '';
	}

	private static inline function newParseExit(code: Int): NewOpts {
		return {
			lang: '',
			write: false,
			asClass: false,
			open: false,
			raw: false,
			kind: 'class',
			iface: null,
			underlying: null,
			bodiesArg: null,
			bodiesFromFile: null,
			extendsList: [],
			fromList: [],
			toList: [],
			fields: [],
			arms: [],
			armsDir: null,
			path: null,
			errExit: code
		};
	}

	/**
	 * Resolve an `--implements` argument to the interface's source plus the
	 * import the new file needs. A qualified `pkg.Name` maps to
	 * `<srcRoot>/pkg/Name.hx` (import emitted only when its package differs from
	 * the new file's); a simple `Name` is taken as a sibling in the new file's
	 * own directory (same package, no import). Returns null when the file does
	 * not exist.
	 * Resolve an `--implements` argument to the interface's source, its
	 * fully-qualified module path, and its simple name. A qualified `pkg.Name`
	 * maps to `<srcRoot>/pkg/Name<ext>`, `<ext>` the source extension of the new file's grammar; a simple `Name` is taken as a sibling in
	 * the new file's own directory (its module path is then the new file's
	 * package + `.Name`). Returns null when the file does not exist. The module
	 * path lets the caller carry the interface's sibling sub-types and decide the
	 * interface import.
	 */
	private static function resolveInterface(
		iface: String, newPath: String, ext: String
	): Null<{ source: String, ifaceModule: String, simple: String }> {
		final dot: Int = iface.lastIndexOf('.');
		if (dot >= 0) {
			final simple: String = iface.substr(dot + 1);
			final dir: String = '${Path.directory(FileSystem.absolutePath(newPath))}/';
			var srcRoot: Null<String> = null;
			for (root in ['/src/', '/test/']) {
				final at: Int = dir.lastIndexOf(root);
				if (at < 0) continue;
				srcRoot = dir.substr(0, at + root.length);
				break;
			}
			if (srcRoot == null) return null;
			final file: String = srcRoot + iface.split('.').join('/') + ext;
			return FileSystem.exists(file) ? { source: CliIo.readFile(file), ifaceModule: iface, simple: simple } : null;
		}
		final file: String = '${Path.directory(FileSystem.absolutePath(newPath))}/$iface$ext';
		if (!FileSystem.exists(file)) return null;
		final newPkg: String = derivePackage(newPath);
		return { source: CliIo.readFile(file), ifaceModule: newPkg == '' ? iface : '$newPkg.$iface', simple: iface };
	}

	/**
	 * `apq new <path> (--class | --implements <iface> | --kind <k> | --raw -)
	 * [--extends <T>]... [--open] [--underlying <T>] [--from <T>]... [--to <T>]...
	 * [--field <m>]... [--bodies -] [--write]` — create a new module
	 * deterministically. The structured path derives the package + class name from
	 * <path> and assembles the scaffold (interface stubs / `--field` / `@@`
	 * sections incl. `@@ members`); `--raw -` instead takes the COMPLETE file from
	 * stdin (the validated atomic equivalent of a raw write, for shapes no spec
	 * covers). Either way the writer round-trip canonicalises + re-parse-validates,
	 * and the file is never written on a parse failure. Create-only: an existing
	 * path is refused. Without `--write` the source goes to stdout.
	 */
	private static function runNew(args: Array<String>, ledger: RunLedger): Int {
		final o: NewOpts = parseNewArgs(args);
		if (o.errExit != null) return o.errExit;
		final path: Null<String> = o.path;
		if (path == null) {
			CliIo.stderr('apq new: expected <path>\n');
			printNewUsage();
			return EXIT_USAGE;
		}
		if (!o.raw && ['class', 'interface', 'enum', 'typedef', 'abstract'].indexOf(o.kind) < 0) {
			CliIo.stderr('apq new: --kind must be class|interface|enum|typedef|abstract (got "${o.kind}")\n');
			return EXIT_USAGE;
		}
		final hasIntent: Bool = o.raw
			|| o.asClass
			|| o.iface != null
			|| o.kind != 'class'
			|| o.extendsList.length > 0
			|| o.fields.length > 0;
		if (!hasIntent) {
			CliIo.stderr('apq new: specify --class / --implements <iface> / --kind <k> / --raw -\n');
			return EXIT_USAGE;
		}
		final filePath: String = path;
		if (FileSystem.exists(filePath)) {
			CliIo.stderr('apq new: $filePath already exists (create-only; use the ops / fmt to modify)\n');
			return EXIT_RUNTIME;
		}

		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		// A scaffold is a type declaration; a grammar whose reference shape names no type-declaration kind (a data grammar)
		// has none to scaffold, and saying so beats the parse failure of a Haxe-shaped scaffold read in that grammar.
		if (!o.raw && plugin.refShape().typeDeclKinds == null) {
			CliIo.stderr('apq new: grammar "${o.lang}" declares no types to scaffold — create the file with --raw -\n');
			return EXIT_USAGE;
		}
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath, ledger);
		return executeNew(o, filePath, plugin, optsJson);
	}

	/** Shared tail for `apq new`: report stub warnings, then write the file or emit to stdout. */
	private static function emitNew(
		filePath: String, result: EditResult, stubbed: Array<String>, armDocuments: Array<RegistryDocument>, write: Bool
	): Int {
		switch result {
			case Ok(text, rewrites):
				CliEdit.warnRewrites('new', filePath, rewrites);
				for (m in stubbed) CliIo.stderr('apq new: $m() left as a NotImplementedException stub\n');
				if (write) {
					CliIo.writeFiles(
						[{ path: filePath, content: text }].concat(armDocuments.map(d -> { path: d.file, content: d.source }))
					);
					CliIo.stderr('apq new: wrote $filePath\n');
					for (d in armDocuments) CliIo.stderr('apq new: wrote ${d.file}\n');
				} else {
					CliEdit.previewEdit('new', filePath, text);
					for (d in armDocuments) CliIo.stderr('apq new: would write ${d.file}\n');
				}
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq new: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printNewUsage(): Void {
		CliIo.sysPrint(
			'Usage: apq new <path> (--class | --implements <iface> | --kind <k> | --raw -) [--extends <T>]... [--open] ['
			+ '--underlying <T>] [--from <T>]... [--to <T>]... [--field <m>]... [--bodies -] [--arm <json> | --arm-file <f>]... ['
			+ '--arms-dir <d>] [--write]\n'
		);
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --kind <k>          class (default) | interface | enum | typedef | abstract\n');
		CliIo.sysPrint('  --class             Shorthand for --kind class\n');
		CliIo.sysPrint('  --raw -            Read the COMPLETE file from stdin (validated atomic\n');
		CliIo.sysPrint('                      write; for shapes no spec covers, e.g. multi-type files)\n');
		CliIo.sysPrint('  --implements <i>    (class) implement interface <i> — stub every method\n');
		CliIo.sysPrint('                      with its real signature (simple name = same package,\n');
		CliIo.sysPrint('                      or a qualified pkg.Name)\n');
		CliIo.sysPrint('  --extends <T>       (class) superclass / (interface, typedef) extension;\n');
		CliIo.sysPrint('                      repeatable for interface/typedef; a qualified pkg.T is imported\n');
		CliIo.sysPrint('  --underlying <T>    (abstract) the underlying type — required for --kind abstract\n');
		CliIo.sysPrint('  --from <T> / --to <T>  (abstract) implicit-cast clauses (repeatable)\n');
		CliIo.sysPrint('  --open              Emit a non-final class (default: final)\n');
		CliIo.sysPrint('  --field <member>    Add a verbatim member (repeatable)\n');
		CliIo.sysPrint('  --bodies -          Read @@ sections from stdin: @@ <method> bodies,\n');
		CliIo.sysPrint('                      @@ members (a free-form member block), @@ imports, @@ doc;\n');
		CliIo.sysPrint('                      an unfilled interface method gets a NotImplementedException stub\n');
		CliIo.sysPrint('  --arm <json>        Add a mutation-arm record (repeatable) to the arm registry, beside the module: one\n');
		CliIo.sysPrint('                      object {name,type,method,note + force | find,replace}, appended to the document of its\n');
		CliIo.sysPrint('                      type\'s package (made when absent); a name already taken is refused. Written with the\n');
		CliIo.sysPrint('                      module in one step, or neither is\n');
		CliIo.sysPrint('  --arm-file <f>      Same, the record read from file <f>\n');
		CliIo.sysPrint('  --arms-dir <d>      The registry directory (default: the byPackage "arms.type" registry of apq.json "move")\n');
		CliIo.sysPrint('  --write             Write the new file (default: emit to stdout)\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: by file extension)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Assemble a NEW module and canonicalise it through the writer (parses-or-\n');
		CliIo.sysPrint('fails, byte-canonical, atomic). The path must not already exist — modify\n');
		CliIo.sysPrint('an existing file with the structural ops / apq fmt. An unparseable result\n');
		CliIo.sysPrint('(e.g. a malformed @@ body) exits non-zero with nothing written. A missing\n');
		CliIo.sysPrint('directory on the path is created (mkdir -p), and removed again when the\n');
		CliIo.sysPrint('write fails. With --write the module is then typechecked against the configured\n');
		CliIo.sysPrint('builds; one that needs a type not yet written is put back — write it ahead of\n');
		CliIo.sysPrint('its dependencies with --no-verify, or create the dependency first.\n');
	}

	private static function parseNewArgs(args: Array<String>): NewOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var asClass: Bool = false;
		var open: Bool = false;
		var raw: Bool = false;
		var kind: String = 'class';
		var iface: Null<String> = null;
		var underlying: Null<String> = null;
		var bodiesArg: Null<String> = null;
		var bodiesFromFile: Null<String> = null;
		final extendsList: Array<String> = [];
		final fromList: Array<String> = [];
		final toList: Array<String> = [];
		final fields: Array<String> = [];
		final arms: Array<String> = [];
		var armsDir: Null<String> = null;
		var path: Null<String> = null;

		for (arg in new NewCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '--class':
					asClass = true;
				case '--kind':
					kind = arg.value();
					// An explicit `--kind class` is intent, same as `--class`;
					// without this it collapses to the default and runNew's
					// hasIntent check rejects it.
					if (kind == 'class') asClass = true;
				case '--extends':
					extendsList.push(arg.value());
				case '--underlying':
					underlying = arg.value();
				case '--from':
					fromList.push(arg.value());
				case '--to':
					toList.push(arg.value());
				case '--open':
					open = true;
				case '--raw':
					raw = true;

				case '--implements':
					iface = arg.value();
				case '--field':
					fields.push(arg.value());
				case '--arm':
					arms.push(arg.value());
				case '--arm-file':
					final armPath: String = arg.value();
					if (!FileSystem.exists(armPath)) {
						CliIo.stderr('apq new: --arm-file $armPath does not exist\n');
						return newParseExit(EXIT_USAGE);
					}
					arms.push(CliIo.readFile(armPath));
				case '--arms-dir':
					armsDir = arg.value();
				case '--bodies':
					bodiesArg = arg.value();
				case '--from-file':
					bodiesFromFile = arg.value();
				case '--write':
					write = true;
				case '-h', '--help':
					printNewUsage();
					return newParseExit(EXIT_OK);
				case null:
					if (path == null) {
						path = a;
					} else {
						CliIo.stderr('apq new: unexpected extra argument "$a"\n');
						return newParseExit(EXIT_USAGE);
					}
			}
		}
		return {
			lang: lang,
			write: write,
			asClass: asClass,
			open: open,
			raw: raw,
			kind: kind,
			iface: iface,
			underlying: underlying,
			bodiesArg: bodiesArg,
			bodiesFromFile: bodiesFromFile,
			extendsList: extendsList,
			fromList: fromList,
			toList: toList,
			fields: fields,
			arms: arms,
			armsDir: armsDir,
			path: path,
			errExit: null
		};
	}

	private static function executeNew(o: NewOpts, filePath: String, plugin: GrammarPlugin, optsJson: Null<String>): Int {
		final armDocuments: Array<RegistryDocument> = switch armDocumentsOf(o, filePath) {
			case Left(message):
				CliIo.stderr('apq new: $message\n');
				return EXIT_RUNTIME;
			case Right(documents): documents;
		}
		if (o.raw) {
			final content: Null<String> = CliArgs.resolveCodeArg('new', '-', null);
			return content == null
				? EXIT_RUNTIME
				: emitNew(filePath, NewFile.createRaw(content, plugin, optsJson), [], armDocuments, o.write);
		}

		var bodiesRaw: Null<String> = null;
		if (o.bodiesArg == '-' || o.bodiesFromFile != null) {
			final resolved: Null<String> = CliArgs.resolveCodeArg('new', o.bodiesArg == '-' ? '-' : null, o.bodiesFromFile);
			if (resolved == null) return EXIT_RUNTIME;
			bodiesRaw = resolved;
		} else if (o.bodiesArg != null) {
			bodiesRaw = o.bodiesArg;
		}

		final className: String = newFileClassName(filePath);
		final pkg: String = derivePackage(filePath);

		var ifaceSimple: Null<String> = null;
		var ifaceModule: Null<String> = null;
		var ifaceSource: Null<String> = null;
		final iface: Null<String> = o.iface;
		if (iface != null) {
			final ext: String = CliArgs.sourceExtensionOf(o.lang);
			final resolved: Null<{ source: String, ifaceModule: String, simple: String }> = resolveInterface(iface, filePath, ext);
			if (resolved == null) {
				CliIo.stderr(
					'apq new: could not locate interface "$iface" (expected a $ext file beside the new file or at its package path)\n'
				);
				return EXIT_RUNTIME;
			}
			ifaceSimple = resolved.simple;
			ifaceModule = resolved.ifaceModule;
			ifaceSource = resolved.source;
		}

		final spec: NewFileSpec = {
			className: className,
			pkg: pkg,
			fields: o.fields,
			kind: o.kind,
			isFinal: !o.open,
			extendsList: o.extendsList,
			underlying: o.underlying,
			fromList: o.fromList,
			toList: o.toList,
			ifaceSimple: ifaceSimple,
			ifaceModule: ifaceModule,
			ifaceSource: ifaceSource,
			bodiesRaw: bodiesRaw
		};
		final res: NewFileResult = NewFile.create(spec, plugin, optsJson);
		return emitNew(filePath, res.result, res.stubbed, armDocuments, o.write);
	}

	/**
	 * The arm-registry documents `--arm` / `--arm-file` add to: the directory is `--arms-dir`, else the project's
	 * byPackage `arms.type` registry of the `move` section. Computed before anything is written, so a refused record
	 * leaves the new module uncreated.
	 */
	private static function armDocumentsOf(o: NewOpts, filePath: String): Either<String, Array<RegistryDocument>> {
		if (o.arms.length == 0) return Right([]);
		final given: Null<String> = o.armsDir;
		final directory: String = switch given == null ? registryDirectory(filePath) : Right(given) {
			case Left(message): return Left(message);
			case Right(found): found;
		}
		final existing: Array<RegistryDocument> = RegistryFiles.of(directory).map(file -> { file: file, source: CliIo.readFile(file) });
		return ArmRecords.add(directory, existing, o.arms);
	}

	/** The directory of the project's byPackage arm registry: the `move.registries` entry keyed `arms.type`. */
	private static function registryDirectory(filePath: String): Either<String, String> {
		return switch ModuleMoveCli.declarationFor(filePath) {
			case Left(message): Left(message);
			case Right(declaration):
				final registry: Null<TypePathRegistry> = declaration.registries.find(r ->
					r.byPackage == true && r.keys.contains(ArmRecords.REGISTRY_KEY)
				);
				registry == null
					? Left('no byPackage "${ArmRecords.REGISTRY_KEY}" registry in the "move" section of apq.json — pass --arms-dir <dir>')
					: Right(registry.file);
		}
	}

}
