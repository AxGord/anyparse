package anyparse.query;

import anyparse.query.SpanTypeInfoProvider.SpanTypeInfo;

/**
 * Optional capability a `GrammarPlugin` may ALSO implement alongside
 * `SpanTypeInfoProvider`: parse a source ONCE into the grammar's own root value, then
 * project that one root as many times as a run needs.
 *
 * Without it every source-taking entry point (`parseFile`, `parseFileTypeRefs`,
 * `spanTypeInfo`, `importMap`) starts by parsing `source` again — the projections differ,
 * the parse does not. `GrammarPlugin.projectBranchAware` was already written this way over
 * an already-parsed TREE; this is the same seam one level lower, over the root, which is
 * what the other projections need (the type-ref projection surfaces name-slot types the
 * default one skips, so they are absent from that tree).
 *
 * The root is grammar-specific and this interface is not, so it crosses as `Any`: an opaque
 * handle the engine only ever hands back to the plugin that made it. Every projection still
 * takes `source` alongside it, because a projection reads the original text as well as the
 * tree; pairing a root with a source from a different parse is the caller's error.
 *
 * On a null root — what a source that does not parse yields — each method behaves exactly
 * like its source-taking twin: `treeFromRoot` throws, `spanTypeInfoFromRoot` returns the
 * empty bundle, `importMapFromRoot` the empty map.
 */
@:nullSafety(Strict)
interface ParsedRootProvider {

	/** Parse `source` into the grammar's root value, or null when it does not parse. */
	public function parseRoot(source: String): Null<Any>;

	/** The `parseFile` / `parseFileTypeRefs` projection of an already-parsed root. Throws when `root` is null. */
	public function treeFromRoot(root: Null<Any>, source: String, withTypeRefs: Bool): QueryNode;

	/** The `spanTypeInfo` projection of an already-parsed root — the empty bundle when `root` is null. */
	public function spanTypeInfoFromRoot(root: Null<Any>, source: String): SpanTypeInfo;

	/** The `importMap` projection of an already-parsed root — the empty map when `root` is null. */
	public function importMapFromRoot(root: Null<Any>, source: String): Map<String, String>;

}
