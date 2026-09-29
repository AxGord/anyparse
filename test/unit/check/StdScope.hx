package unit.check;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.StdResolver;
import haxe.Exception;
import haxe.io.Path;

/**
 * A plugin whose resolution scope holds `report` plus STUBS of the std containers, filed under the
 * machine's discovered std root — what a rule needs to PROVE a written `Array` / `List` / `Map` is
 * the std one (`SymbolIndex.resolvesToStdType`), since a plain test index holds no std at all.
 * The stubs declare only what the proof reads: the type, in its std module.
 */
@:nullSafety(Strict)
final class StdScope {

	/** The std modules stubbed, as `[path under the std root, source]`. */
	private static final STUBS: Array<Array<String>> = [
		['Array.hx', 'extern class Array<T> {\n\tvar length(default, null):Int;\n}'],
		['List.hx', 'typedef List<T> = haxe.ds.List<T>;'],
		[
			'haxe/ds/List.hx',
			'package haxe.ds;\n\nclass List<T> {\n\tpublic var length(default, null):Int;\n}'
		],
		['Map.hx', 'abstract Map<K, V>(Dynamic) {}'],
		['haxe/ds/StringMap.hx', 'package haxe.ds;\n\nclass StringMap<T> {}'],
		[
			'Lambda.hx',
			'class Lambda {\n\tpublic static function count<A>(it:Iterable<A>, ?pred:(item:A) -> Bool):Int {\n\t\treturn 0;\n\t}\n}'
		],
		['StringTools.hx', 'class StringTools {}']
	];

	/**
	 * `report` in a resolution scope beside the std stubs and any non-std `libraries` (a `resolutionLibs`
	 * half); throws when this machine has no discoverable std.
	 */
	public static function plugin(
		report: Array<{ file: String, source: String }>, ?libraries: Array<{ file: String, source: String }>, complete: Bool = true
	): CachingGrammarPlugin {
		final std: Null<String> = StdResolver.stdDir();
		if (std == null) throw new Exception('no installed Haxe std on this machine: the std-container proof cannot be exercised');
		final root: String = std;
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final library: Array<{ file: String, source: String }> = [
			for (stub in STUBS)
				{
					file: Path.join([root, stub[0]]),
					source: stub[1]
				}
		].concat(libraries ?? []);
		// `complete` declares the report the WHOLE project (`rootsMatched` / `rootsAllMatched`); false
		// is a run whose roots did not all match, so a project file may be missing from the index.
		scoped.setResolutionScope({
			declared: true,
			sources: () -> {
				report: report,
				projectRoots: [],
				library: new LibrarySources(library),
				rootsMatched: complete,
				rootsAllMatched: complete
			}
		});
		return scoped;
	}

}
