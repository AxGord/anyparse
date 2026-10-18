package anyparse.grammar.json;

import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.CanonicalEdit;
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
 * The JSON grammar binding for the query engine — what lets hxq's EXISTING edit ops (`add-element`
 * `--after` / `--before` / `--append` / `--sorted`, `remove-element`, `replace-node`) and its readers
 * (`ast`, `source`) work on a `.json` file, with no second edit engine.
 *
 * The tree is `JsonProjection`'s (`Document` / `JObject` / `Member` / `JArray` / `JString` / `JNumber` / `JBool` / `JNull`), so a
 * selector walks the document by key — `Member:rules >> Member:registers > JArray` — and picks an array element by its value
 * (`JString:api.APIRequest2.success`) or by its ordinal (`--nth`). A `--match` pattern is a JSON value whose `"$x"` / `"$_"` strings are
 * metavariables.
 *
 * The writer is `JsonLayoutWriter`, FORMAT-PRESERVING: `writeRoundTrip` hands every parseable
 * document back byte for byte, so the canonical gate never refuses one, and `layoutSplice` lays an
 * edit's text in the way its siblings are laid out, leaving every other byte alone. The plain
 * pipeline (`writeRoundTripPlain`) is the grammar's Doc writer, `JValueWriter`.
 *
 * Everything a code grammar declares and a data grammar has no notion of — scopes, types, imports,
 * control flow, naming — answers empty or null, and the checks that read it no-op.
 */
@:nullSafety(Strict)
final class JsonQueryPlugin implements GrammarPlugin {

	/** The metavariable sigil a pattern string opens with. */
	private static inline final METAVAR_SIGIL: String = '$';

	private static final STRING_FOLD: JsonStringFold = new JsonStringFold();

	public function new() {}

	public function langName(): String {
		return 'json';
	}

	public function parseFile(source: String): QueryNode {
		return JsonProjection.parse(source);
	}

	/** A JSON value; a string whose whole value is `$name` is the metavariable `name` (`$_` the wildcard). */
	public function parsePattern(source: String): Pattern {
		final value: QueryNode = JsonProjection.parse(source).children[0];
		return new Pattern(metavars(value), Expr, source);
	}

	public function refShape(): RefShape {
		return {
			identKind: '',
			declHostKinds: [],
			moduleValueDeclKinds: [],
			scopeKinds: [],
			writeParentKinds: [],
			selfScopeDeclKinds: [],
			arrayLiteralKind: JsonProjection.ARRAY,
			objectLiteralKind: JsonProjection.OBJECT,
			stringLiteralKinds: [JsonProjection.STRING],
			commaContainerKinds: [JsonProjection.ARRAY, JsonProjection.OBJECT],
			delimitedContainerKinds: [JsonProjection.ARRAY, JsonProjection.OBJECT]
		};
	}

	public function projectedKinds(): Array<String> {
		return JsonQueryWalker.projectedKinds();
	}

	public function metaShape(): MetaShape {
		return { metaKinds: [], declHostKinds: [] };
	}

	public function selectKindEquivalence(): KindEquivalence {
		return new KindEquivalence([]);
	}

	/** JSON has no type positions: the type-reference projection is the plain one. */
	public function parseFileTypeRefs(source: String): QueryNode {
		return parseFile(source);
	}

	public function projectBranchAware(tree: QueryNode, source: String): QueryNode {
		return tree;
	}

	public function typeRefShape(): TypeRefShape {
		return { typeRefKinds: [] };
	}

	/** The document itself, byte for byte, when it parses — `JsonLayoutWriter` with no edit to lay out. */
	public function writeRoundTrip(source: String, ?optsJson: String): Null<String> {
		return JsonLayoutWriter.layout(source, []);
	}

	/** The splice of `edits`, what they introduced laid out like its siblings (`JsonLayoutWriter`). */
	public function layoutSplice(source: String, edits: Array<{ span: Span, text: String }>): Null<String> {
		return JsonLayoutWriter.layout(CanonicalEdit.applyEdits(source, edits), JsonLayoutWriter.marksOf(edits));
	}

	public function layoutMetrics(?optsJson: String): Null<LayoutMetrics> {
		return null;
	}

	public function memberGapPolicy(?optsJson: String): Null<MemberGapPolicy> {
		return null;
	}

	/** The grammar's Doc writer over the plain parse — the canonical JSON form, not the file's own. */
	public function writeRoundTripPlain(source: String, ?optsJson: String): Null<String> {
		return JValueWriter.write(JValueParser.parse(source));
	}

	public function reconParse(source: String): Bool {
		JValueSpanParser.parse(source);
		return true;
	}

	public function typeSyntax(typeSource: String): Null<TypeSyntax> {
		return null;
	}

	public function namingSupport(): Null<NamingSupport> {
		return null;
	}

	public function stringFoldSupport(): Null<StringFoldSupport> {
		return STRING_FOLD;
	}

	public function maxComplexity(path: String): Null<Int> {
		return null;
	}

	public function controlFlowSupport(): Null<ControlFlowSupport> {
		return null;
	}

	/**
	 * Every string literal of `source` — keys and values — read off its own parse, in source order;
	 * JSON has no comment. A source that does not parse answers none (every byte code), the
	 * conservative reading for the masking consumers; the ops parse first and refuse it anyway.
	 */
	public function lexicalRegions(source: String): Array<LexRegion> {
		final document: Null<QueryNode> = try JsonProjection.parse(source) catch (_: Exception) null;
		final regions: Array<LexRegion> = [];
		if (document != null) collectStrings(document, source, regions);
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

	/** `node` with every `"$name"` string turned into the metavariable `name`. */
	private static function metavars(node: QueryNode): QueryNode {
		final name: Null<String> = node.name;
		return node.kind == JsonProjection.STRING && name != null && name.startsWith(METAVAR_SIGIL) && name.length > 1
			? new QueryNode(Metavar.KIND, name.substr(1), [], node.span)
			: new QueryNode(node.kind, node.name, [for (child in node.children) metavars(child)], node.span);
	}

	/** Push the string-literal region of every `String` value and every `Member` key under `node`. */
	private static function collectStrings(node: QueryNode, source: String, out: Array<LexRegion>): Void {
		final span: Null<Span> = node.span;
		if (span != null && node.kind == JsonProjection.STRING) out.push({ from: span.from, to: span.to, kind: LexRegionKind.StringLit });
		if (span != null && node.kind == JsonProjection.MEMBER) {
			out.push({ from: span.from, to: JsonProjection.keyEndOf(node, source), kind: LexRegionKind.StringLit });
		}
		for (child in node.children) collectStrings(child, source, out);
	}

}
