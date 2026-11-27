package unit.query;

import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;

/**
 * `RefactorSupport` over a type whose header alone is split across a `#if`: the by-name lookup finds it rooted on the wrapper
 * that holds the members, a plain type is never reported as split, and the body-brace offset — one per branch there — is
 * refused so a check inserting after it skips the type.
 */
class SplitHeaderLookupTest extends Test {

	private static final SPLIT: String =
		'#if js\nclass T {\n#else\nclass T extends B {\n#end\n\tpublic function f():Void {}\n}\n\nclass B {}\n';

	/** The lookup answers with the wrapper as the member-holding node, and the refusal names the split header. */
	@:pin('control')
	@:killer('M-ADD-MEMBER-SPLIT-HEADER-BODY-ROOT')
	public function testLookupIsRootedOnTheWrapper(): Void {
		final decl: TypeDeclMatch = resolve(SPLIT, 'T');
		Assert.equals('CondSharedBodyDecl', decl.nameNode.kind);
		Assert.isTrue(decl.nameNode == decl.declNode);
		Assert.notNull(RefactorSupport.splitHeaderRefusal(decl));
	}

	/** A plain type has one head and is never refused as split. */
	public function testPlainTypeIsNotSplit(): Void {
		Assert.isNull(RefactorSupport.splitHeaderRefusal(resolve(SPLIT, 'B')));
	}

	/** No single offset opens the body of a split-header type. */
	@:pin('control')
	@:killer('M-SPLIT-HEADER-BODY-BRACE-NULL')
	public function testBodyBraceOfSplitHeaderIsRefused(): Void {
		Assert.isNull(RefactorSupport.typeBodyBraceOffset(SPLIT, resolve(SPLIT, 'T'), 'T', []));
		Assert.notNull(RefactorSupport.typeBodyBraceOffset(SPLIT, resolve(SPLIT, 'B'), 'B', []));
	}

	private static function resolve(source: String, name: String): TypeDeclMatch {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		final decl: Null<TypeDeclMatch> = RefactorSupport.uniqueTypeDeclNamed(tree, name);
		if (decl == null) throw 'no unique type $name';
		return decl;
	}

}
