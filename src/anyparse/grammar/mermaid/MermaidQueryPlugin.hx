package anyparse.grammar.mermaid;

import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.LexicalRegions.LexRegionKind;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.TypeSyntax;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * The Mermaid flowchart grammar binding for the query engine: what lets `ast`, `source` and the
 * edit ops read a `.mmd` file through `MermaidProjection`'s tree, and `fmt` re-emit it in the
 * canonical form of `MermaidWriter`.
 *
 * The writer RE-EMITS the whole document (one statement per line, labels re-encoded), so
 * `writeRoundTrip` is the canonical form, not the file's own bytes, and `layoutSplice` answers
 * null for `CanonicalEdit` to finish an edit by the writer's fixed point. A `%%` comment is a
 * statement of the grammar, so the writer never loses one.
 *
 * A `--match` pattern is one statement; a node whose id is `$name` is the metavariable `name`.
 * Everything a code grammar declares and a diagram has no notion of — scopes, types, imports,
 * control flow, naming — answers empty or null, and the checks that read it no-op.
 */
@:nullSafety(Strict)
final class MermaidQueryPlugin implements GrammarPlugin {

	/** The `--lang` this plugin answers to. */
	public static inline final LANG: String = 'mermaid';

	/** The file extensions (lower case, with the dot) a file of this grammar carries; the CLI routes such a file here. */
	public static final EXTENSIONS: Array<String> = ['.mmd', '.mermaid'];

	/** The metavariable sigil a pattern node id opens with. */
	private static inline final METAVAR_SIGIL: String = '$';

	/** The kind of a node id, the one a pattern metavariable takes the place of. */
	private static inline final ID_KIND: String = 'Id';

	/** The header a pattern statement is parsed under. */
	private static inline final PATTERN_HEADER: String = 'flowchart\n';

	public function new() {}

	public function langName(): String {
		return LANG;
	}

	public function parseFile(source: String): QueryNode {
		return MermaidProjection.parse(source);
	}

	/** One statement, parsed under a bare `flowchart` header; a node id `$name` is the metavariable `name`. */
	public function parsePattern(source: String): Pattern {
		final statements: Array<QueryNode> = MermaidProjection.parse(PATTERN_HEADER + source).children;
		if (statements.length < 2) throw new Exception('mermaid: a pattern is one statement, and "$source" holds none');
		return new Pattern(metavars(statements[1]), Stmt, source);
	}

	public function refShape(): RefShape {
		return new RefShape('', [], [], [], [], []);
	}

	public function projectedKinds(): Array<String> {
		return MermaidQueryWalker.projectedKinds();
	}

	public function metaShape(): MetaShape {
		return { metaKinds: [], declHostKinds: [] };
	}

	public function selectKindEquivalence(): KindEquivalence {
		return new KindEquivalence([]);
	}

	/** A flowchart has no type positions: the type-reference projection is the plain one. */
	public function parseFileTypeRefs(source: String): QueryNode {
		return parseFile(source);
	}

	public function projectBranchAware(tree: QueryNode, source: String): QueryNode {
		return tree;
	}

	public function typeRefShape(): TypeRefShape {
		return { typeRefKinds: [] };
	}

	/** The canonical form of `source` (`MermaidWriter` over the Fast parse). */
	public function writeRoundTrip(source: String, ?optsJson: String): Null<String> {
		return MermaidWriter.write(MermaidParser.parse(source));
	}

	/** Null: the writer re-emits the whole document, so `CanonicalEdit` finishes the splice itself. */
	public function layoutSplice(source: String, edits: Array<{ span: Span, text: String }>): Null<String> {
		return null;
	}

	public function layoutMetrics(?optsJson: String): Null<LayoutMetrics> {
		return null;
	}

	public function memberGapPolicy(?optsJson: String): Null<MemberGapPolicy> {
		return null;
	}

	/** The same canonical form: the grammar has one pipeline. */
	public function writeRoundTripPlain(source: String, ?optsJson: String): Null<String> {
		return writeRoundTrip(source, optsJson);
	}

	public function reconParse(source: String): Bool {
		MermaidSpanParser.parse(source);
		return true;
	}

	public function typeSyntax(typeSource: String): Null<TypeSyntax> {
		return null;
	}

	public function namingSupport(): Null<NamingSupport> {
		return null;
	}

	public function stringFoldSupport(): Null<StringFoldSupport> {
		return null;
	}

	public function maxComplexity(path: String): Null<Int> {
		return null;
	}

	public function controlFlowSupport(): Null<ControlFlowSupport> {
		return null;
	}

	/**
	 * Every `%%` comment statement of `source`, read off its own parse, in source order. A source
	 * that does not parse answers none (every byte code), the conservative reading for the masking
	 * consumers; the ops parse first and refuse it anyway.
	 */
	public function lexicalRegions(source: String): Array<LexRegion> {
		final document: Null<QueryNode> = try MermaidProjection.parse(source) catch (_: Exception) null;
		final regions: Array<LexRegion> = [];
		if (document != null) collectComments(document, regions);
		return regions;
	}

	public function booleanLogicSupport(): Null<BooleanLogicSupport> {
		return null;
	}

	public function knownExtensionMethods(modulePath: String): Null<Array<String>> {
		return null;
	}

	public function checkOverrides(path: String): Null<CheckOverrides> {
		return null;
	}

	public function ambientImportSources(path: String, pkg: String): AmbientImports {
		return { sources: [], bounded: true };
	}

	public function ambientImportGovernance(path: String): Null<AmbientImportGovernance> {
		return null;
	}

	public function ambientImportSites(path: String, pkg: String): Array<String> {
		return [];
	}

	/** `node` with every node id `$name` turned into the metavariable `name`. */
	private static function metavars(node: QueryNode): QueryNode {
		final name: Null<String> = node.name;
		return node.kind == ID_KIND && name != null && name.startsWith(METAVAR_SIGIL) && name.length > 1
			? new QueryNode(Metavar.KIND, name.substr(1), [], node.span)
			: new QueryNode(node.kind, node.name, [for (child in node.children) metavars(child)], node.span);
	}

	/** Push the line-comment region of every `Comment` statement under `node`. */
	private static function collectComments(node: QueryNode, out: Array<LexRegion>): Void {
		final span: Null<Span> = node.span;
		if (span != null && node.kind == MermaidProjection.COMMENT)
			out.push({ from: span.from, to: span.to, kind: LexRegionKind.LineComment });
		for (child in node.children) collectComments(child, out);
	}

}
