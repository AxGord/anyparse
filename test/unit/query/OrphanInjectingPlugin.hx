package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.TypeSyntax;

using StringTools;

/**
 * The Haxe plugin with a DEFECTIVE writer: `writeRoundTrip` replaces `from` with `to` in what the real
 * writer emits, and every other method delegates. It stands in for the writer bug the `fmt` orphan
 * gate exists for — a re-emission that strands an `else` — which the real writer cannot be made to
 * commit, so the gate's wiring in `apq fmt` has no other way to be driven.
 */
@:nullSafety(Strict)
final class OrphanInjectingPlugin implements GrammarPlugin {

	private final _inner: HaxeQueryPlugin = new HaxeQueryPlugin();
	private final _from: String;
	private final _to: String;

	public function new(from: String, to: String) {
		_from = from;
		_to = to;
	}

	public function langName(): String {
		return _inner.langName();
	}

	public function parseFile(source: String): QueryNode {
		return _inner.parseFile(source);
	}

	public function parsePattern(source: String): Pattern {
		return _inner.parsePattern(source);
	}

	public function refShape(): RefShape {
		return _inner.refShape();
	}

	public function projectedKinds(): Array<String> {
		return _inner.projectedKinds();
	}

	public function metaShape(): MetaShape {
		return _inner.metaShape();
	}

	public function selectKindEquivalence(): KindEquivalence {
		return _inner.selectKindEquivalence();
	}

	public function parseFileTypeRefs(source: String): QueryNode {
		return _inner.parseFileTypeRefs(source);
	}

	public function projectBranchAware(tree: QueryNode, source: String): QueryNode {
		return _inner.projectBranchAware(tree, source);
	}

	public function typeRefShape(): TypeRefShape {
		return _inner.typeRefShape();
	}

	public function writeRoundTrip(source: String, ?optsJson: String): Null<String> {
		final written: Null<String> = _inner.writeRoundTrip(source, optsJson);
		return written == null ? null : written.replace(_from, _to);
	}

	public function layoutMetrics(?optsJson: String): Null<LayoutMetrics> {
		return _inner.layoutMetrics(optsJson);
	}

	public function writeRoundTripPlain(source: String, ?optsJson: String): Null<String> {
		return _inner.writeRoundTripPlain(source, optsJson);
	}

	public function reconParse(source: String): Bool {
		return _inner.reconParse(source);
	}

	public function typeSyntax(typeSource: String): Null<TypeSyntax> {
		return _inner.typeSyntax(typeSource);
	}

	public function namingSupport(): Null<NamingSupport> {
		return _inner.namingSupport();
	}

	public function stringFoldSupport(): Null<StringFoldSupport> {
		return _inner.stringFoldSupport();
	}

	public function maxComplexity(path: String): Null<Int> {
		return _inner.maxComplexity(path);
	}

	public function controlFlowSupport(): Null<ControlFlowSupport> {
		return _inner.controlFlowSupport();
	}

	public function lexicalRegions(source: String): Array<LexRegion> {
		return _inner.lexicalRegions(source);
	}

	public function booleanLogicSupport(): Null<BooleanLogicSupport> {
		return _inner.booleanLogicSupport();
	}

	public function knownExtensionMethods(modulePath: String): Null<Array<String>> {
		return _inner.knownExtensionMethods(modulePath);
	}

	public function checkOverrides(path: String): Null<CheckOverrides> {
		return _inner.checkOverrides(path);
	}

	public function ambientImportSources(path: String, pkg: String): AmbientImports {
		return _inner.ambientImportSources(path, pkg);
	}

	public function ambientImportGovernance(path: String): Null<AmbientImportGovernance> {
		return _inner.ambientImportGovernance(path);
	}

	public function ambientImportSites(path: String, pkg: String): Array<String> {
		return _inner.ambientImportSites(path, pkg);
	}

}
