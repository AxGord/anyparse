package anyparse.query.cli.command;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.NewFile.NewFileResult;
import anyparse.query.NewFile.NewFileSpec;
import anyparse.query.cli.CliContext;
import haxe.io.Path;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * Parsed options for `apq new` — `lang`, the `kind` of declaration to scaffold and its shape (`asClass` / `iface` / `underlying` / `extendsList` / `fields` / bodies), the target `path`, and `write` / `open` flags. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
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

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runNew(args);
	}

	public function usage(): Void {
		printNewUsage();
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
			path: null,
			errExit: code
		};
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
	 * The class name for a new file: its basename without the `.hx` extension.
	 */
	public static function newFileClassName(path: String): String {
		final base: String = Path.withoutDirectory(path);
		return base.endsWith('.hx') ? base.substr(0, base.length - 3) : base;
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

	/**
	 * Resolve an `--implements` argument to the interface's source plus the
	 * import the new file needs. A qualified `pkg.Name` maps to
	 * `<srcRoot>/pkg/Name.hx` (import emitted only when its package differs from
	 * the new file's); a simple `Name` is taken as a sibling in the new file's
	 * own directory (same package, no import). Returns null when the file does
	 * not exist.
	 * Resolve an `--implements` argument to the interface's source, its
	 * fully-qualified module path, and its simple name. A qualified `pkg.Name`
	 * maps to `<srcRoot>/pkg/Name.hx`; a simple `Name` is taken as a sibling in
	 * the new file's own directory (its module path is then the new file's
	 * package + `.Name`). Returns null when the file does not exist. The module
	 * path lets the caller carry the interface's sibling sub-types and decide the
	 * interface import.
	 */
	private static function resolveInterface(
		iface: String, newPath: String
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
			final file: String = '${srcRoot + iface.split('.').join('/')}.hx';
			return !FileSystem.exists(file) ? null : { source: CliIo.readFile(file), ifaceModule: iface, simple: simple };
		}
		final file: String = '${Path.directory(FileSystem.absolutePath(newPath))}/$iface.hx';
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
	private static function runNew(args: Array<String>): Int {
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
		final hasIntent: Bool = o.raw || o.asClass || o.iface != null || o.kind != 'class' || o.extendsList.length > 0 || o.fields.length
			> 0;
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
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		return executeNew(o, filePath, plugin, optsJson);
	}

	/** Shared tail for `apq new`: report stub warnings, then write the file or emit to stdout. */
	private static function emitNew(filePath: String, result: EditResult, stubbed: Array<String>, write: Bool): Int {
		switch result {
			case Ok(text, rewrites):
				CliEdit.warnRewrites('new', filePath, rewrites);
				for (m in stubbed) CliIo.stderr('apq new: $m() left as a NotImplementedException stub\n');
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq new: wrote $filePath\n');
				} else
					CliEdit.previewEdit('new', filePath, text);
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq new: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printNewUsage(): Void {
		CliIo.sysPrint(
			'Usage: apq new <path> (--class | --implements <iface> | --kind <k> | --raw -) [--extends <T>]... [--open] ['
			+ '--underlying <T>] [--from <T>]... [--to <T>]... [--field <m>]... [--bodies -] [--write]\n'
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
		CliIo.sysPrint('  --write             Write the new file (default: emit to stdout)\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Assemble a NEW module and canonicalise it through the writer (parses-or-\n');
		CliIo.sysPrint('fails, byte-canonical, atomic). The path must not already exist — modify\n');
		CliIo.sysPrint('an existing file with the structural ops / apq fmt. An unparseable result\n');
		CliIo.sysPrint('(e.g. a malformed @@ body) exits non-zero with nothing written.\n');
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
		var path: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--class':
					asClass = true;
				case '--kind':
					kind = CliArgs.expectValue(args, ++i, '--kind');
					// An explicit `--kind class` is intent, same as `--class`;
					// without this it collapses to the default and runNew's
					// hasIntent check rejects it.
					if (kind == 'class') asClass = true;
				case '--extends':
					extendsList.push(CliArgs.expectValue(args, ++i, '--extends'));
				case '--underlying':
					underlying = CliArgs.expectValue(args, ++i, '--underlying');
				case '--from':
					fromList.push(CliArgs.expectValue(args, ++i, '--from'));
				case '--to':
					toList.push(CliArgs.expectValue(args, ++i, '--to'));
				case '--open':
					open = true;
				case '--raw':
					raw = true;
					if (i + 1 < args.length && args[i + 1] == '-') i++;

				case '--implements':
					iface = CliArgs.expectValue(args, ++i, '--implements');
				case '--field':
					fields.push(CliArgs.expectValue(args, ++i, '--field'));
				case '--bodies':
					bodiesArg = CliArgs.expectValue(args, ++i, '--bodies');
				case '--from-file':
					bodiesFromFile = CliArgs.expectValue(args, ++i, '--from-file');
				case '--write':
					write = true;
				case '-h', '--help':
					printNewUsage();
					return newParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq new: unknown option "$a"\n');
						return newParseExit(EXIT_USAGE);
					}
					if (path == null)
						path = a;
					else {
						CliIo.stderr('apq new: unexpected extra argument "$a"\n');
						return newParseExit(EXIT_USAGE);
					}
			}
			i++;
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
			path: path,
			errExit: null
		};
	}

	private static function executeNew(o: NewOpts, filePath: String, plugin: GrammarPlugin, optsJson: Null<String>): Int {
		if (o.raw) {
			final content: Null<String> = CliArgs.resolveCodeArg('new', '-', null);
			return content == null ? EXIT_RUNTIME : emitNew(filePath, NewFile.createRaw(content, plugin, optsJson), [], o.write);
		}

		var bodiesRaw: Null<String> = null;
		if (o.bodiesArg == '-' || o.bodiesFromFile != null) {
			final resolved: Null<String> = CliArgs.resolveCodeArg('new', o.bodiesArg == '-' ? '-' : null, o.bodiesFromFile);
			if (resolved == null) return EXIT_RUNTIME;
			bodiesRaw = resolved;
		} else if (o.bodiesArg != null)
			bodiesRaw = o.bodiesArg;

		final className: String = newFileClassName(filePath);
		final pkg: String = derivePackage(filePath);

		var ifaceSimple: Null<String> = null;
		var ifaceModule: Null<String> = null;
		var ifaceSource: Null<String> = null;
		final iface: Null<String> = o.iface;
		if (iface != null) {
			final resolved: Null<{ source: String, ifaceModule: String, simple: String }> = resolveInterface(iface, filePath);
			if (resolved == null) {
				CliIo.stderr('apq new: could not locate interface "$iface" (expected a .hx beside the new file or at its package path)\n');
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
		return emitNew(filePath, res.result, res.stubbed, o.write);
	}

}
