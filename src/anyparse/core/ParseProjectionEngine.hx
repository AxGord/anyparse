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
		final root: String = haxe.io.Path.directory(
			haxe.io.Path.directory(haxe.macro.Context.resolvePath('anyparse/core/ParseProjectionEngine.hx'))
		);
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
		final parts: Array<String> = [];
		for (directory in directories) collect('$root/$directory', parts);
		for (module in modules) parts.push(sys.io.File.getContent('$root/$module'));
		return macro $v{haxe.crypto.Md5.encode(parts.join('\n'))};
	}

	#if macro
	private static function collect(directory: String, into: Array<String>): Void {
		final names: Array<String> = sys.FileSystem.readDirectory(directory);
		names.sort(Reflect.compare);
		for (name in names) {
			final path: String = '$directory/$name';
			if (sys.FileSystem.isDirectory(path))
				collect(path, into);
			else if (name.endsWith('.hx'))
				into.push('$path\n${sys.io.File.getContent(path)}');
		}
	}
	#end

}
