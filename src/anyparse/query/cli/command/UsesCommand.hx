package anyparse.query.cli.command;

import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.Uses.UsesHit;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.CliWalk;
import anyparse.query.format.Text;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

/**
 * Parsed options for `apq uses` — `lang`, the `wantDoc` / `wantSource` output toggles, `flat`, `limit`, the type `name`, and `inputSpecs`. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef UsesOpts = {
	var lang: String;
	var wantDoc: Bool;
	var wantSource: Bool;
	var flat: Bool;
	var limit: Int;
	var name: Null<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq uses` — type references (field/param/type-param positions).
 *
 * A multi-file WALK: the path specs go through `CliArgs`, the files through `CliWalk`,
 * and an empty result answers `ctx.emptyExit` so a script can tell "found nothing"
 * from "ran fine".
 */
@:nullSafety(Strict)
final class UsesCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'uses';
	}

	public function summary(): String {
		return 'Type references (field/param/type-param positions)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runUses(args, ctx);
	}

	public function usage(): Void {
		printUsesUsage();
	}

	private static inline function usesParseExit(code: Int): UsesOpts {
		return {
			lang: '',
			wantDoc: false,
			wantSource: false,
			flat: false,
			limit: -1,
			name: null,
			inputSpecs: [],
			errExit: code
		};
	}

	private static function runUses(args: Array<String>, ctx: CliContext): Int {
		final o: UsesOpts = parseUsesArgs(args);
		if (o.errExit != null) return o.errExit;
		final name: Null<String> = o.name;
		if (name == null) {
			CliIo.stderr('apq uses: missing <type-name> argument\n');
			printUsesUsage();
			return EXIT_USAGE;
		}
		if (o.inputSpecs.length == 0) {
			CliIo.stderr('apq uses: missing <file-or-dir-or-glob> argument\n');
			printUsesUsage();
			return EXIT_USAGE;
		}
		final nameStr: String = name;

		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		final shape: TypeRefShape = plugin.typeRefShape();

		final expanded: ExpandedInputs = CliArgs.expandInputs(o.inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq uses: no input files matched ${CliArgs.quotedSpecs(o.inputSpecs)}\n');
			return EXIT_RUNTIME;
		}

		final skipEntries: Array<SkipEntry> = [];
		final candidateNames: Map<String, Bool> = [];
		final allEntries: Null<Array<{ file: String, source: String, hits: Array<UsesHit> }>> = collectUsesEntries(
			nameStr, paths, plugin, shape, expanded.singleFile, skipEntries, candidateNames
		);
		if (allEntries == null) return EXIT_RUNTIME;

		if (allEntries.length == 0)
			CliIo.stderr('${CliWalk.emptyWalkerNudge('uses', nameStr, paths.length, paths.length - skipEntries.length, skipEntries, candidateNames)}\n');

		var totalHits: Int = 0;
		for (e in allEntries) totalHits += e.hits.length;
		final cappedLimit: Int = CliWalk.effectiveAutoLimit('uses', o.limit, totalHits);
		final shown: Array<{ file: String, source: String, hits: Array<UsesHit> }> = CliWalk.limitEntries(
			allEntries, cappedLimit, e -> e.hits.length, (e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k) }
		);
		for (entry in shown)
			CliIo.sysPrint(
				Text.renderUses(entry.file, entry.source, entry.hits, o.wantDoc, o.wantSource, o.flat, plugin.lexicalRegions(entry.source))
			);
		return ctx.emptyExit(allEntries.length == 0);
	}

	private static function printUsesUsage(): Void {
		CliIo.sysPrint('Usage: apq uses [options] <type-name> <file-or-dir-or-glob>...\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliUsage.printDocSourceFlatLimitLangHelp();
		CliIo.sysPrint('Finds type-position references — a field/var type annotation,\n');
		CliIo.sysPrint('an enum-constructor parameter type, a type parameter. Sister of\n');
		CliIo.sysPrint('`refs` (value bindings). `Array<T>` reports both `Array` and\n');
		CliIo.sysPrint('`T`. For "where is X declared" use `refs --decls` / `ast --select`.\n');
	}

	private static function parseUsesArgs(args: Array<String>): UsesOpts {
		var lang: String = 'haxe';
		var wantDoc: Bool = false;
		var wantSource: Bool = false;
		var flat: Bool = false;
		var limit: Int = -1;
		var name: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--doc':
					wantDoc = true;
				case '--source':
					wantSource = true;
				case '--flat':
					flat = true;
				case '--limit':
					try limit = CliArgs.parseLimit(args, ++i) catch (e: Exception) {
						CliIo.stderr('${e.message}\n');
						return usesParseExit(EXIT_USAGE);
					}
				case '-h', '--help':
					printUsesUsage();
					return usesParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq uses: unknown option "$a"\n');
						return usesParseExit(EXIT_USAGE);
					}
					if (name == null)
						name = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			wantDoc: wantDoc,
			wantSource: wantSource,
			flat: flat,
			limit: limit,
			name: name,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function collectUsesEntries(
		name: String, paths: Array<String>, plugin: GrammarPlugin, shape: TypeRefShape, singleFile: Bool, skipEntries: Array<SkipEntry>,
		candidateNames: Map<String, Bool>
	): Null<Array<{ file: String, source: String, hits: Array<UsesHit> }>> {
		final allEntries: Array<{ file: String, source: String, hits: Array<UsesHit> }> = [];
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = CliIo.readSourceForParse(path);
			final tree: Null<QueryNode> =
				CliWalk.parseWalked('uses', plugin.parseFileTypeRefs, path, source, singleFile, skipEntries, name);
			CliIo.streamProgress('uses', ++scanned, paths.length, singleFile);
			if (tree == null) {
				// Single-file mode treats a parse failure as fatal — null tells
				// the caller to return EXIT_RUNTIME. Multi-file mode records the
				// file in skipEntries and keeps walking.
				if (singleFile) return null;
				continue;
			}
			final hits: Array<UsesHit> = Uses.find(name, tree, shape);
			if (hits.length == 0) {
				RefsCommand.collectNames(tree, candidateNames);
				continue;
			}
			allEntries.push({ file: path, source: source, hits: hits });
		}
		return allEntries;
	}

}
