package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.DeclaredNullity;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import utest.Assert;
import utest.Test;

/**
 * `DeclaredNullity` — a declared type proves non-null only once it RESOLVES to a declaration that
 * excludes null. Asked through `TypeResolver.isProvablyNonNull` over the `… != null` operand of the
 * FIRST file, every fixture under `@:nullSafety(Strict)` so the type is the only thing that varies.
 */
class DeclaredNullityTest extends Test {

	@:pin('control')
	@:killer('M-NULLITY-ALIAS-TRUSTED')
	public function testTypedefOfNullIsUnproven(): Void {
		Assert.isFalse(proven([subject('MaybeR') + ' typedef MaybeR = Null<R>; class R {}']), 'the alias names `Null<R>`');
	}

	@:pin('control')
	@:killer('M-NULLITY-ALIAS-TRUSTED')
	public function testTypedefChainToNullIsUnproven(): Void {
		Assert.isFalse(proven([subject('A') + ' typedef A = B; typedef B = Null<R>; class R {}']), 'the second hop names `Null<R>`');
	}

	@:pin('control')
	@:killer('M-NULLITY-ALIAS-TRUSTED')
	public function testParameterisedTypedefOfNullIsUnproven(): Void {
		Assert.isFalse(proven([subject('Opt<R>') + ' typedef Opt<T> = Null<T>; class R {}']), '`Opt<R>` is `Null<R>`');
	}

	@:pin('control')
	@:killer('M-NULLITY-ALIAS-TRUSTED')
	public function testImportedTypedefOfNullIsUnproven(): Void {
		Assert.isFalse(proven([
			'package other; import pk.Types.MaybeR; ' + subject('MaybeR'),
			'package pk; typedef MaybeR = Null<R>; class R {}'
		], ['other/C.hx', 'pk/Types.hx']), 'the alias is declared in another package and resolves through the import');
	}

	@:pin('control')
	@:killer('M-NULLITY-UNDERLYING-TRUSTED')
	public function testAbstractOverNullIsUnproven(): Void {
		Assert.isFalse(proven([subject('NR') + ' abstract NR(Null<R>) {} class R {}']), 'the abstract carries a nullable value');
	}

	@:pin('control')
	@:killer('M-NULLITY-TYPE-PARAMS-IGNORED')
	public function testFunctionTypeParameterIsUnproven(): Void {
		Assert.isFalse(proven([
			'@:nullSafety(Strict) class C { static function m<R>(x:R):Void { if (x != null) {} } } class R {}'
		]), '`R` is the type parameter, which may be `Null<…>`, not the class of the same name');
	}

	@:pin('control')
	@:killer('M-NULLITY-TYPE-PARAMS-IGNORED')
	public function testClassTypeParameterIsUnproven(): Void {
		Assert.isFalse(proven([
			'@:nullSafety(Strict) class C<R> { function m(x:R):Void { if (x != null) {} } } class R {}'
		]), 'the enclosing class\'s parameter shadows the class of the same name');
	}

	@:pin('control')
	@:killer('M-NULLITY-UNRESOLVED-PROVEN')
	public function testUnresolvableNameIsUnproven(): Void {
		Assert.isFalse(proven([subject('Foo')]), 'no declaration of `Foo` is in scope, so nothing says it excludes null');
	}

	@:pin('control')
	@:killer('M-NULLITY-GUARD-IGNORED')
	public function testGuardedDeclarationIsUnproven(): Void {
		Assert.isFalse(
			proven([subject('R') + ' #if js class R {} #else typedef R = Null<Int>; #end']),
			'the index keeps one branch, and the other declares the name nullable'
		);
	}

	@:pin('control')
	@:killer('M-NULLITY-HOPS-CUT')
	public function testAliasOfClassIsProven(): Void {
		Assert.isTrue(proven([subject('RA') + ' typedef RA = R; class R {}']), 'the alias resolves to a class');
	}

	@:pin('control')
	@:killer('M-NULLITY-HOPS-CUT')
	public function testAbstractOverClassIsProven(): Void {
		Assert.isTrue(proven([subject('RAbs') + ' abstract RAbs(R) {} class R {}']), 'the abstract carries a class value');
	}

	@:pin('control')
	@:killer('M-NULLITY-HOPS-CUT')
	public function testEnumAbstractOverIntIsProven(): Void {
		Assert.isTrue(proven([subject('Color') + ' enum abstract Color(Int) { var Red = 0; }']), 'null safety makes the Int non-null');
	}

	@:pin('control')
	@:killer('M-NULLITY-ANON-REFUSED')
	public function testAnonymousStructureTypedefIsProven(): Void {
		Assert.isTrue(proven([subject('Anon') + ' typedef Anon = { name: String };']), 'a structure value is non-null under null safety');
	}

	@:pin('control')
	@:killer('M-NULLITY-SCOPE-LOST')
	public function testImportedClassIsProven(): Void {
		Assert.isTrue(
			proven(['package other; import pk.R; ' + subject('R'), 'package pk; class R {}'], ['other/C.hx', 'pk/R.hx']),
			'the class resolves through the import from the file that writes it'
		);
	}

	@:pin('control')
	@:killer('M-BINDING-ALIAS-BLIND')
	public function testImportAliasOutranksSamePackageClass(): Void {
		Assert.isFalse(proven([
			'package app; import other.Opt as MaybeR; ' + subject('MaybeR'),
			'package app; class MaybeR {}',
			'package other; typedef Opt = Null<app.R>;',
			'package app; class R {}'
		], ['app/C.hx', 'app/MaybeR.hx', 'other/Opt.hx', 'app/R.hx']), 'the compiler binds the alias, not the class of the same name in '
		+ 'the package');
	}

	@:pin('control')
	@:killer('M-BINDING-UNINDEXED-IMPORT-FREE')
	public function testImportOfUnindexedTypeIsUnproven(): Void {
		Assert.isFalse(proven([
			'package app; import other.MaybeR; ' + subject('MaybeR'),
			'package app; class MaybeR {}'
		], ['app/C.hx', 'app/MaybeR.hx']), 'the import binds a type the index does not hold, so the package class says nothing');
	}

	@:pin('control')
	@:killer('M-BINDING-UNINDEXED-IMPORT-FREE')
	public function testAliasOfUnindexedTypeIsUnproven(): Void {
		Assert.isFalse(proven([
			'package app; import other.Opt as MaybeR; ' + subject('MaybeR'),
			'package app; class MaybeR {}'
		], ['app/C.hx', 'app/MaybeR.hx']), 'the alias names a type the index does not hold');
	}

	@:pin('control')
	@:killer('M-BINDING-UNINDEXED-MODULE-FREE')
	public function testImportOfUnindexedModuleIsUnproven(): Void {
		Assert.isFalse(proven([
			'package app; import other.Mod; ' + subject('MaybeR'),
			'package app; class MaybeR {}'
		], ['app/C.hx', 'app/MaybeR.hx']), 'an unindexed module may declare the name as a sub-type, and its import outranks the package');
	}

	@:pin('control')
	@:killer('M-BINDING-UNINDEXED-WILDCARD-FREE')
	public function testWildcardOverUnindexedPackageIsUnproven(): Void {
		Assert.isFalse(proven([
			'package app; import other.*; ' + subject('MaybeR'),
			'package app; class MaybeR {}'
		], ['app/C.hx', 'app/MaybeR.hx']), 'a wildcard import outranks the package, and its package is not in the index');
	}

	@:pin('control')
	@:killer('M-BINDING-OWN-TIER-CUT')
	public function testModuleOwnTypeOutranksImport(): Void {
		Assert.isTrue(proven([
			'package app; import other.MaybeR; ' + subject('MaybeR') + ' private class MaybeR {}',
			'package other; typedef MaybeR = Null<Int>;'
		], ['app/C.hx', 'other/MaybeR.hx']), 'the module\'s own type is asked first, ahead of every import');
	}

	@:pin('control')
	@:killer('M-BINDING-WILDCARD-CUT')
	public function testWildcardOverIndexedPackageIsProven(): Void {
		Assert.isTrue(
			proven(['package app; import other.*; ' + subject('R'), 'package other; class R {}'], ['app/C.hx', 'other/R.hx']),
			'the wildcard brings in the main type of `other.R`'
		);
	}

	@:pin('control')
	@:killer('M-BINDING-PACKAGE-TIER-CUT')
	public function testParentPackageClassIsProven(): Void {
		Assert.isTrue(
			proven(['package app.sub; ' + subject('R'), 'package app; class R {}'], ['app/sub/C.hx', 'app/R.hx']),
			'a type of a parent package is in scope after the file\'s own package'
		);
	}

	/** The subject class: `x` is declared as `$type`, compared against null under Strict null safety. */
	private static function subject(type: String): String {
		return '@:nullSafety(Strict) class C { static function m(x:$type):Void { if (x != null) {} } }';
	}

	/**
	 * Whether the `… != null` operand of the first of `sources` is provably non-null, with every source
	 * in the index; `names` are the files' paths, `C.hx` and `T<i>.hx` by default.
	 */
	private static function proven(sources: Array<String>, ?names: Array<String>): Bool {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = [
			for (i in 0...sources.length) { file: names == null ? (i == 0 ? 'C.hx' : 'T$i.hx') : names[i], source: sources[i] }
		];
		final src: String = sources[0];
		final tree: QueryNode = plugin.parseFile(src);
		final shape: RefShape = plugin.refShape();
		final types: DeclaredNullity = DeclaredNullity.of(
			files[0].file, tree, src, shape, plugin, plugin.typeSyntax, SymbolIndex.build.bind(files, plugin)
		);
		final operand: Null<QueryNode> = nullCheckOperand(tree, shape);
		Assert.notNull(operand, 'fixture must contain a `… != null` comparison');
		return operand != null && TypeResolver.isProvablyNonNull(operand, tree, shape, types);
	}

	private static function nullCheckOperand(tree: QueryNode, shape: RefShape): Null<QueryNode> {
		final equalityKinds: Array<String> = shape.equalityKinds ?? [];
		final nullLit: Null<String> = shape.nullLiteralKind;
		var found: Null<QueryNode> = null;
		function walk(n: QueryNode): Void {
			if (found != null) return;
			if (nullLit != null && n.children.length == 2 && equalityKinds.contains(n.kind) && n.children[1].kind == nullLit) {
				found = n.children[0];
				return;
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		return found;
	}

}
