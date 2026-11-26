package anyparse.core;

using StringTools;

/**
 * The engine code a stored parse projection depends on (`ParseDiskCache`) — the grammars, the parser runtime and macros
 * that build a tree, the formats it reads, and the few query types it is shaped as — hashed when the engine compiles, so
 * a projection another engine wrote misses. A class of its own: a macro types its class in the macro context, where the
 * cache's own dependencies cannot be built.
 */
final class ParseProjectionEngine {

	/** md5 over every source a stored projection depends on, read at compile time in a fixed order. */
	public static macro function digest(): haxe.macro.Expr {
		final directories: Array<String> = ['core', 'runtime', 'macro', 'format', 'grammar'];
		final modules: Array<String> = [
			'query/QueryNode.hx',
			'query/CachingGrammarPlugin.hx',
			'query/SpanTypeInfoProvider.hx',
			'query/ParsedRootProvider.hx',
			'query/ParseGate.hx',
			'query/SourceText.hx',
			'query/CondDirectives.hx',
			'query/CondBranchProjection.hx',
			'query/ParseDiskCache.hx'
		];
		final paths: Array<String> = [];
		for (directory in directories) listSources(engineRoot(), directory, paths);
		return macro $v{hashOf(paths.concat(modules))};
	}

	/**
	 * md5 over every source a record derived from stored parses depends on (`ProjectOutlines`, `CallGraphStore`): what
	 * `digest` covers, the shared `util` and `ds` packages, and the whole query layer that reads a record off a parse, its
	 * command layer aside — a record is derived by code `digest` leaves out, so an edit of that code is a miss too.
	 */
	public static macro function outlineDigest(): haxe.macro.Expr {
		return macro $v{hashOf(outlinePaths())};
	}

	/** The sources `outlineDigest` hashes, relative to the engine's package root, in the order it hashes them. */
	public static macro function outlineSources(): haxe.macro.Expr {
		return macro $v{outlinePaths()};
	}

	#if macro
	/** md5 over each source of `paths`, relative to the engine's package root, as its path and its text, in order. */
	private static function hashOf(paths: Array<String>): String {
		return haxe.crypto.Md5.encode(paths.map(path -> '$path\n${sys.io.File.getContent('${engineRoot()}/$path')}').join('\n'));
	}

	private static function engineRoot(): String {
		return haxe.io.Path.directory(haxe.io.Path.directory(haxe.macro.Context.resolvePath('anyparse/core/ParseProjectionEngine.hx')));
	}

	private static function outlinePaths(): Array<String> {
		final paths: Array<String> = [];
		for (directory in ['core', 'ds', 'runtime', 'macro', 'format', 'grammar', 'query', 'util'])
			listSources(engineRoot(), directory, paths);
		return paths;
	}

	/** Every `.hx` under `relative`, in name order, the command layer `query/cli` aside: no outline is read off it. */
	private static function listSources(root: String, relative: String, into: Array<String>): Void {
		if (relative == 'query/cli') return;
		final names: Array<String> = sys.FileSystem.readDirectory('$root/$relative');
		names.sort(anyparse.util.Compare.compareString);
		for (name in names) {
			final path: String = '$relative/$name';
			if (sys.FileSystem.isDirectory('$root/$path'))
				listSources(root, path, into);
			else if (name.endsWith('.hx'))
				into.push(path);
		}
	}
	#end

}
