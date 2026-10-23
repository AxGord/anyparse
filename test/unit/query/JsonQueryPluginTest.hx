package unit.query;

import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.query.Engine;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.Selector;
import anyparse.runtime.Span;

using Lambda;

/**
 * `JsonQueryPlugin` — the JSON grammar's query projection and the selector vocabulary it gives the
 * edit ops: a document walked by key (`Member:<key>`), an array element picked by its decoded value
 * (`JString:<value>`), every span tight from the first byte to the last.
 */
@:nullSafety(Strict)
class JsonQueryPluginTest extends Test {

	private static final DOCUMENT: String =
		' {\n\t"rules": {\n\t\t"thread-safety": {\n\t\t\t"registers": ["addEventListener", "a\\"b"],\n\t\t\t"n": 3\n\t\t}\n\t}\n}\n';

	private final _plugin: JsonQueryPlugin = new JsonQueryPlugin();

	/** A member is named by its decoded key and spans the key's opening quote through its value. */
	@:killer('M-QUERY-NAME-IGNORED')
	@:pin('control')
	public function testAMemberIsNamedByItsKey(): Void {
		final member: QueryNode = only('Member:thread-safety');
		Assert.equals('Member', member.kind);
		final span: Null<Span> = member.span;
		Assert.notNull(span);
		if (span != null) Assert.equals('"thread-safety": {', DOCUMENT.substring(span.from, span.from + 18));
		Assert.equals('JObject', member.children[0].kind);
	}

	/** The selector the edit ops take walks the document by key, and names an element by its decoded value. */
	public function testASelectorWalksByKeyAndPicksAnElementByValue(): Void {
		final element: QueryNode = only('Member:rules >> Member:registers > JArray > JString:a"b');
		final span: Null<Span> = element.span;
		Assert.notNull(span);
		if (span != null) Assert.equals('"a\\"b"', DOCUMENT.substring(span.from, span.to));
	}

	/** The root value's span starts at its first byte, not at the document's leading whitespace. */
	@:killer('M-JSON-ROOT-UNTIGHTENED')
	@:pin('control')
	public function testTheRootSpanIsTight(): Void {
		final root: QueryNode = _plugin.parseFile(DOCUMENT).children[0];
		Assert.equals(1, root.span?.from);
		Assert.equals(DOCUMENT.length - 1, root.span?.to);
	}

	/** Every kind the shape declares is one the walker projects. */
	public function testEveryDeclaredKindIsProjected(): Void {
		final shape: RefShape = _plugin.refShape();
		final projected: Array<String> = _plugin.projectedKinds();
		final declared: Array<String> =
			[shape.arrayLiteralKind ?? '', shape.objectLiteralKind ?? ''].concat(shape.commaContainerKinds ?? [])
				.concat(shape.delimitedContainerKinds ?? [])
				.concat(shape.stringLiteralKinds ?? []);
		for (kind in declared) Assert.isTrue(projected.contains(kind), '$kind is projected');
		Assert.isTrue(projected.contains('Member'), 'the entry kind is projected');
	}

	/** The lexical regions are the string literals, keys included, in source order. */
	@:killer('M-JSON-REGIONS-NONE')
	@:pin('control')
	public function testTheLexicalRegionsAreTheStrings(): Void {
		final source: String = '{"k": ["v", 1]}';
		final regions: Array<LexRegion> = _plugin.lexicalRegions(source);
		Assert.equals('"k"|"v"', [for (r in regions) source.substring(r.from, r.to)].join('|'));
	}

	/** A pattern string written `"$name"` is a metavariable. */
	@:killer('M-JSON-PATTERN-NO-METAVAR')
	@:pin('control')
	public function testAPatternStringCanBeAMetavariable(): Void {
		final pattern: Pattern = _plugin.parsePattern('{"name": "$$n"}');
		final member: QueryNode = pattern.root.children[0];
		Assert.equals('name', member.name);
		Assert.equals('Metavar', member.children[0].kind);
		Assert.equals('n', member.children[0].name);
	}

	/** The one node `selector` matches in `DOCUMENT`. */
	private function only(selector: String): QueryNode {
		final matches: Array<QueryNode> = Engine.select(_plugin.parseFile(DOCUMENT), Selector.parse(selector));
		Assert.equals(1, matches.length, '$selector matches one node');
		return matches[0];
	}

}
