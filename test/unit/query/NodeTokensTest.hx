package unit.query;

import anyparse.grammar.json.JsonProjection;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.QueryNode;
import haxe.Exception;

/**
 * `NodeTokens` — the literals a parse matched for a node itself (`QueryNode.tokenSpans`), on a sample of forms: a
 * declaration's keyword and delimiters, a statement's keywords around its children, an operator, a call's parentheses.
 * Each pin names the mechanism that keeps the log exact: a branch the parser left, a memoised run replayed, a keyword
 * failing its word boundary, comment trivia, and the handle that carries the log beside its root.
 */
@:nullSafety(Strict)
class NodeTokensTest extends Test {

	private static final FORMS: String = 'class A {\n\tvar x: Int = 1;\n\tfunction f(a: Int, b: String): Void {\n'
		+ '\t\tif (a > 0) g(a, b) else return;\n\t\tfinal y = (a);\n\t\tfinal m = [1, 2];\n\t}\n}\n';

	@:pin('control')
	@:killer('M-TOKENS-OWN-COVERS-PARTS')
	public function testANodeOwnsItsKeywordsAndDelimitersNotItsChildrens(): Void {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(FORMS);
		Assert.equals('class { }', own(first(tree, 'ClassDecl'), FORMS));
		Assert.equals('var : = ;', own(first(tree, 'VarMember'), FORMS));
		Assert.equals('function ( , ) :', own(first(tree, 'FnMember'), FORMS));
		Assert.equals(':', own(first(tree, 'Required'), FORMS), 'a parameter owns its own type colon');
		Assert.equals('if ( ) else', own(first(tree, 'IfStmt'), FORMS));
		Assert.equals('>', own(first(tree, 'Gt'), FORMS));
		Assert.equals('( , )', own(first(tree, 'Call'), FORMS));
		Assert.equals('[ , ]', own(first(tree, 'ArrayExpr'), FORMS));
		Assert.equals('', own(first(tree, 'IdentExpr'), FORMS), 'a leaf the grammar reads by pattern matched no literal');
	}

	@:pin('control')
	@:killer('M-TOKEN-LOG-KEEPS-ABANDONED')
	public function testATokenOfABranchTheParserLeftIsDropped(): Void {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(FORMS);
		Assert.equals('( )', own(first(tree, 'ParenExpr'), FORMS));
		Assert.equals('return ;', own(first(tree, 'VoidReturnStmt'), FORMS));
	}

	@:pin('control')
	@:killer('M-MEMO-REPLAY-DROPS-TOKENS')
	public function testAMemoisedRunReplayedKeepsItsTokens(): Void {
		final source: String = 'class C {\n\tfunction f() {\n\t\tfinal x = (a ?? []).copy();\n\t}\n}\n';
		Assert.equals('[ ]', own(first(new HaxeQueryPlugin().parseFile(source), 'ArrayExpr'), source));
	}

	@:pin('control')
	@:killer('M-KW-BOUNDARY-KEEPS-TOKEN')
	public function testAKeywordFailingItsWordBoundaryLeavesNoToken(): Void {
		final source: String = 'class C {\n\tfunction f() {\n\t\tif (a) {}\n\t\telseBody = 1;\n\t}\n}\n';
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		Assert.equals('if ( )', own(first(tree, 'IfStmt'), source));
		Assert.equals('', own(named(tree, 'elseBody'), source), 'the `else` the parser tried on `elseBody` is not kept');
	}

	@:pin('control')
	@:killer('M-TRIVIA-LIT-RECORDS')
	public function testACommentDelimiterIsNoToken(): Void {
		final source: String = '/** Doc. */\nclass C {\n\t// note\n\tvar x = 1; /* c */\n}\n';
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		Assert.equals('class { }', own(first(tree, 'ClassDecl'), source));
		Assert.equals('var = ;', own(first(tree, 'VarMember'), source));
	}

	@:pin('control')
	@:killer('M-PARSED-ROOT-NO-TOKENS')
	public function testEachFileKeepsItsOwnTokensThroughTheCachingHost(): Void {
		final other: String = 'class B {\n\tfunction g() {\n\t\twhile (true) {}\n\t}\n}\n';
		final host: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		Assert.notNull(host.spanTypeInfo(FORMS), 'the root of FORMS is parsed and cached first');
		Assert.notNull(host.parseFile(other), 'then another file is parsed through the same host');
		final tree: QueryNode = host.parseFile(FORMS);
		Assert.equals('if ( ) else', own(first(tree, 'IfStmt'), FORMS), 'a root parsed before another file still holds its own log');
	}

	@:pin('control')
	@:killer('M-JSON-NO-TOKENS')
	public function testAJsonMemberOwnsTheColonItsValueFollows(): Void {
		final source: String = '{"a": 1, "b" :\n\t[true]}';
		final document: QueryNode = JsonProjection.parse(source);
		final members: Array<QueryNode> = all(document, JsonProjection.MEMBER);
		Assert.equals(2, members.length);
		Assert.equals(4, JsonProjection.colonOf(members[0], source), 'a colon touching its key');
		Assert.equals(13, JsonProjection.colonOf(members[1], source), 'a colon past a space, its value on the next line');
		Assert.equals(4, JsonProjection.keyEndOf(members[0], source));
		Assert.equals(12, JsonProjection.keyEndOf(members[1], source), 'the key ends before the space ahead of its colon');
		Assert.equals('[ ]', own(first(document, JsonProjection.ARRAY), source));
	}

	@:pin('control')
	@:killer('M-SEP-BYTE-NOT-RECORDED')
	public function testAStarLoopOwnsTheSeparatorsItMatchedByByte(): Void {

		final source: String = 'enum E {\n\tA(x: Int, y: Int);\n}\ntypedef T = {a: Int, b: Int};\ntypedef U = {a: Int; b: Int};\n'
			+ 'class C {\n\tfunction f() {\n\t\tfinal o = {a: 1, b: 2};\n\t\tfinal g = (a, b) -> a;\n\t\tnew C(1, 2);\n\t}\n}\n';
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		Assert.equals('( , ) ;', own(first(tree, 'ParamCtor'), source), 'constructor parameters');
		final anons: Array<QueryNode> = all(tree, 'Anon');
		Assert.equals('{ , }', own(anons[0], source), 'comma-separated members');
		Assert.equals('{ ; }', own(anons[1], source), 'the alternative separator the member list matched');
		Assert.equals('{ , }', own(first(tree, 'ObjectLit'), source), 'object literal fields');
		Assert.equals('( , ) ->', own(first(tree, 'ThinParenLambdaExpr'), source), 'lambda parameters');
		Assert.equals('new ( , )', own(first(tree, 'NewExpr'), source), 'constructor call arguments');
	}

	@:pin('control')
	@:killer('M-SEP-BYTE-NOT-RECORDED')
	public function testATrailingSeparatorBeforeTheCloseBelongsToItsContainer(): Void {
		final source: String =
			'class C {\n\tfunction f(a: Int, b: Int,) {\n\t\tg(1, 2,);\n\t\tfinal xs = [1, 2,];\n\t\tfinal o = {a: 1, b: 2,};\n\t}\n}\n';
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		Assert.equals('function ( , , )', own(first(tree, 'FnMember'), source), 'parameters');
		Assert.equals('( , , )', own(first(tree, 'Call'), source), 'call arguments');
		Assert.equals('[ , , ]', own(first(tree, 'ArrayExpr'), source), 'array elements');
		Assert.equals('{ , , }', own(first(tree, 'ObjectLit'), source), 'object literal fields');
	}

	@:pin('control')
	@:killer('M-SEP-BYTE-NOT-RECORDED')
	public function testAJsonContainerOwnsItsCommas(): Void {
		final source: String = '{"a": [1, 2], "b": 3}';
		final document: QueryNode = JsonProjection.parse(source);
		Assert.equals('{ , }', own(first(document, JsonProjection.OBJECT), source));
		Assert.equals('[ , ]', own(first(document, JsonProjection.ARRAY), source));
	}

	@:pin('guard')
	public function testTheDeclarationsReadKeepsNoTokens(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.treeFromRoot(plugin.parseDeclarationsRoot(FORMS), FORMS, false);
		Assert.isNull(tree.tokenLog, 'a parse that records no tokens hands none to its tree');
		Assert.equals('', own(first(tree, 'ClassDecl'), FORMS));
	}

	/** `node`'s own tokens as text, space-separated. */
	private static function own(node: QueryNode, source: String): String {
		return node.tokenSpans().map(span -> source.substring(span.from, span.to)).join(' ');
	}

	/** The first node of `kind` in document order; throws when there is none. */
	private static function first(tree: QueryNode, kind: String): QueryNode {
		final found: Array<QueryNode> = all(tree, kind);
		if (found.length == 0) throw new Exception('no $kind node');
		return found[0];
	}

	/** The first node named `name` in document order; throws when there is none. */
	private static function named(tree: QueryNode, name: String): QueryNode {
		final found: Array<QueryNode> = [];
		collect(tree, node -> node.name == name, found);
		if (found.length == 0) throw new Exception('no node named $name');
		return found[0];
	}

	private static function all(tree: QueryNode, kind: String): Array<QueryNode> {
		final found: Array<QueryNode> = [];
		collect(tree, node -> node.kind == kind, found);
		return found;
	}

	private static function collect(node: QueryNode, accept: QueryNode -> Bool, into: Array<QueryNode>): Void {
		if (accept(node)) into.push(node);
		for (child in node.children) collect(child, accept, into);
	}

}
