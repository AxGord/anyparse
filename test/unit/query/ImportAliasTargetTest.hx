package unit.query;

import anyparse.query.IndexScope;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex.FileInfo;

/**
 * An alias import's node carries the path it binds (`QueryNode.target`) beside the alias its name slot holds, read by
 * the parser — so a comment between its tokens is trivia, never the path — and the index records the keyword the
 * statement spells, so a rewrite of it keeps an `in` an `in`.
 */
@:nullSafety(Strict)
final class ImportAliasTargetTest extends Test {

	@:pin('control')
	@:killer('M-QUERY-TARGET-NONE')
	public function testAnAliasNodeCarriesItsPathAndAPlainImportNone(): Void {
		Assert.same(
			['ImportAliasDecl D a.b.C', 'ImportAliasInDecl F a.b.E', 'ImportDecl a.G null'],
			projected('import a.b.C as D;\nimport a.b.E in F;\nimport a.G;\nclass X {}')
		);
	}

	@:pin('control')
	@:killer('M-QUERY-TARGET-NONE')
	public function testACommentBetweenTheTokensIsNotThePath(): Void {
		Assert.same(
			['ImportAliasDecl D a.b.C', 'ImportAliasInDecl F a.b.E'],
			projected('import a.b.C /* z.W as */ as D;\nimport a.b.E // z.W in\n\tin F;\nclass X {}')
		);
	}

	@:pin('control')
	@:killer('M-INDEX-ALIAS-KEYWORD-FIXED')
	public function testTheIndexRecordsThePathAndTheKeywordEachAliasSpells(): Void {
		final info: Null<FileInfo> = IndexScope.declarationsOf(
			'p/X.hx', 'package p;\nimport a.b.C as D;\nimport a.b.E /* as */ in F;\nimport a.G;\nclass X {}', new HaxeQueryPlugin()
		);
		Assert.notNull(info);
		if (info == null) return;
		Assert.same(
			['D a.b.C as', 'F a.b.E in', 'null null null'], info.imports.map(imp -> '${imp.alias} ${imp.aliasTarget} ${imp.aliasKeyword}')
		);
	}

	/** `kind name target` of each import statement `source` declares at its top level. */
	private static function projected(source: String): Array<String> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(new HaxeQueryPlugin(), source);
		Assert.notNull(tree);
		return tree == null ? [] : [
			for (c in tree.children) if (c.kind != 'ClassDecl') '${c.kind} ${c.name} ${c.target}'
		];
	}

}
