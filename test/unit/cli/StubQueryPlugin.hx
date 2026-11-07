package unit.cli;

import anyparse.grammar.mermaid.MermaidQueryPlugin;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.TypeSyntax;
import anyparse.query.merge.StructuralMerge.MergeShape;
import anyparse.runtime.Span;

using StringTools;

/**
 * A grammar plugin the test tree alone declares, named `*QueryPlugin` so `GrammarDiscovery` registers it in the
 * suite's CLI with no CLI edit — what `GrammarRegistryTest` holds the discovery to. It answers to its own `--lang`,
 * extension and content test, and delegates everything else to the Mermaid plugin.
 */
@:nullSafety(Strict)
final class StubQueryPlugin implements GrammarPlugin {

	/** The `--lang` this plugin answers to. */
	public static inline final LANG: String = 'stub-grammar';

	/** The first line that makes a stdin document this plugin's. */
	public static inline final SHEBANG: String = '#!stub-grammar';

	/** The file extensions this plugin reads. */
	public static final EXTENSIONS: Array<String> = ['.stubgrammar'];

	/** Records, unlike the source grammar it delegates to, so a row that reads it is told apart from a default. */
	public static final MERGE: MergeShape = Records;

	private final _inner: MermaidQueryPlugin = new MermaidQueryPlugin();

	public function new() {}

	public function langName(): String {
		return LANG;
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
		return _inner.writeRoundTrip(source, optsJson);
	}

	public function layoutSplice(source: String, edits: Array<{ span: Span, text: String }>): Null<String> {
		return _inner.layoutSplice(source, edits);
	}

	public function layoutMetrics(?optsJson: String): Null<LayoutMetrics> {
		return _inner.layoutMetrics(optsJson);
	}

	public function memberGapPolicy(?optsJson: String): Null<MemberGapPolicy> {
		return _inner.memberGapPolicy(optsJson);
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

	/** Whether `text` starts with this plugin's `SHEBANG`. */
	public static function recognises(text: String): Bool {
		return text.startsWith(SHEBANG);
	}

}
