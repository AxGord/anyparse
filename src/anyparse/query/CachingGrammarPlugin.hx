package anyparse.query;

import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.StringFold.StringFoldSupport;

/**
 * A run-scoped `GrammarPlugin` decorator that memoizes `parseFile` /
 * `parseFileTypeRefs` by source content.
 *
 * The analysis checks each parse every file independently — `Linter.run` calls
 * every check's `run`, and each `run` calls `plugin.parseFile`, so without this
 * the same file is parsed once per check (N checks over M files is N×M parses).
 * During `--fix` the `SymbolIndex` build and every fix pass re-parse on top of
 * that. The checks only READ the trees (they collect violations and spans, never
 * mutate the AST), so a single parse can be shared across all of them safely;
 * keying on source content means an unchanged file is reused across fix passes
 * while a rewritten one re-parses on its new content.
 *
 * The cache holds mutable state, so it must stay run-scoped — create a fresh
 * wrapper per lint run / fix run and never share it across threads. Every other
 * method delegates straight through; a parse that throws is not cached (a
 * skip-parse file re-parses per check, a negligible minority).
 */
@:nullSafety(Strict)
final class CachingGrammarPlugin implements GrammarPlugin {

	private final _inner: GrammarPlugin;
	private final _parseCache: Map<String, QueryNode> = [];
	private final _typeRefCache: Map<String, QueryNode> = [];

	public function new(inner: GrammarPlugin) {
		_inner = inner;
	}

	public function parseFile(source: String): QueryNode {
		final cached: Null<QueryNode> = _parseCache[source];
		if (cached != null) return cached;
		final tree: QueryNode = _inner.parseFile(source);
		_parseCache[source] = tree;
		return tree;
	}

	public function parseFileTypeRefs(source: String): QueryNode {
		final cached: Null<QueryNode> = _typeRefCache[source];
		if (cached != null) return cached;
		final tree: QueryNode = _inner.parseFileTypeRefs(source);
		_typeRefCache[source] = tree;
		return tree;
	}

	public function langName(): String return _inner.langName();

	public function parsePattern(source: String): Pattern return _inner.parsePattern(source);

	public function refShape(): RefShape return _inner.refShape();

	public function metaShape(): MetaShape return _inner.metaShape();

	public function selectKindEquivalence(): KindEquivalence return _inner.selectKindEquivalence();

	public function typeRefShape(): TypeRefShape return _inner.typeRefShape();

	public function writeRoundTrip(source: String, ?optsJson: String): Null<String> return _inner.writeRoundTrip(source, optsJson);

	public function writeRoundTripPlain(source: String, ?optsJson: String): Null<String>
		return _inner.writeRoundTripPlain(source, optsJson);

	public function reconParse(source: String): Bool return _inner.reconParse(source);

	public function namingSupport(): Null<NamingSupport> return _inner.namingSupport();

	public function stringFoldSupport(): Null<StringFoldSupport> return _inner.stringFoldSupport();

	public function maxComplexity(path: String): Null<Int> return _inner.maxComplexity(path);

	public function controlFlowSupport(): Null<ControlFlowSupport> return _inner.controlFlowSupport();

}
