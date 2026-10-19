package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/**
 * The structural typer's arcs (`NominalTypes`), each read as the compiler types it (Haxe 4.3.7) and answering null where
 * the walk cannot say exactly: the deep walk's literal, construction and abstract-`this` arcs, its SOURCE mode
 * (`expressionTypeSource`, type arguments kept) with the method-call tail, and the written-type readers every
 * consumer of a container's element or a type's path shares (`elementTypeSourceOf`, `outerPathOf`).
 */
@:nullSafety(Strict)
class NominalTypesTest extends Test {

	/** The fixture module; each `probe*` function returns the expression a case asks about. */
	private static final SOURCE: String = 'package p;\n\nclass Item {}\n\nclass Box<T> {\n\tpublic function new() {}\n'
		+ '\tpublic function items(): Array<Item> return null;\n\tpublic function get(): T return null;\n'
		+ '\tpublic function pick<K>(): K return null;\n\tpublic function plain() return null;\n}\n\n'
		+ 'abstract Wrap(Array<Item>) {\n\tpublic function probeThis() return this;\n}\n\nclass C {\n'
		+ '\tvar m: Map<String, Array<Int>>;\n\tvar b: Box<Item>;\n\tfunction probeString() return \'x\';\n'
		+ '\tfunction probeInt() return 5;\n\tfunction probeNew() return new p.Box(1);\n'
		+ '\tfunction probeSelf() return this;\n\tfunction probeMap() return m;\n'
		+ '\tfunction probeItems() return b.items();\n\tfunction probeGet() return b.get();\n'
		+ '\tfunction probePick() return b.pick();\n\tfunction probePlain() return b.plain();\n}\n';

	@:pin('control')
	@:killer('M-NOMINAL-LITERAL')
	public function testALiteralIsItsType(): Void {
		Assert.equals('String', nominal('probeString'), 'a string literal');
		Assert.equals('Int', source('probeInt'), 'an int literal, as source too');
	}

	@:pin('control')
	@:killer('M-NOMINAL-CONSTRUCTED')
	public function testAConstructionIsTheTypeItWrites(): Void {
		Assert.equals('Box', nominal('probeNew'), 'by the simple name of the path written');
		Assert.isNull(source('probeNew'), 'with no source: the arguments it infers are spelled nowhere');
	}

	@:pin('control')
	@:killer('M-NOMINAL-ABSTRACT-THIS')
	public function testThisInsideAnAbstractIsItsUnderlyingValue(): Void {
		Assert.equals('Array<Item>', source('probeThis'), 'the underlying type as the header writes it');
		Assert.equals('Array', nominal('probeThis'), 'its nominal');
		Assert.equals('C', nominal('probeSelf'), 'a class instance is the class');
	}

	@:pin('control')
	@:killer('M-NOMINAL-SOURCE-CALL') @:killer('M-NOMINAL-RETURN-TYPEPARAM')
	public function testTheSourceModeKeepsTypeArguments(): Void {
		Assert.equals('Map<String, Array<Int>>', source('probeMap'), 'an annotated field, arguments kept');
		Assert.equals('Array<Item>', source('probeItems'), 'a method call, by the return its declaration writes');
		Assert.isNull(source('probeGet'), 'a return naming the type\'s parameter, which the call binds');
		Assert.isNull(source('probePick'), 'a return naming the method\'s own parameter');
		Assert.isNull(source('probePlain'), 'a return written nowhere');
	}

	@:pin('control')
	@:killer('M-NOMINAL-RETURN-AGREE')
	public function testDeclarationsWritingAReturnDifferentlyHaveNoSource(): Void {
		final split: String = 'package p;\n\nclass D {\n#if a\n\tpublic function make(): Array<Int> return null;\n#else\n\tpublic function '
			+ 'make(): Array<String> return null;\n#end\n}\n\nclass C {\n\tvar d: D;\n\tfunction probe() return d.make();\n}\n';
		Assert.isNull(sourceIn(split, 'probe'), 'one branch writes `Array<Int>`, the other `Array<String>`');
	}

	@:pin('control')
	@:killer('M-ELEMENT-PEEL') @:killer('M-OUTER-PATH-PEEL')
	public function testTheWrittenTypeReadersPeelTheirWrappers(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final params: Map<String, Int> = ['Array' => 0, 'Map' => 1];
		Assert.equals('Item', NominalTypes.elementTypeSourceOf('Null<Array<Item>>', params, ['Null'], plugin.typeSyntax), 'peeled');
		Assert.equals(
			'Array<Int>', NominalTypes.elementTypeSourceOf('Map<String, Array<Int>>', params, [], plugin.typeSyntax), 'the value'
		);
		Assert.isNull(NominalTypes.elementTypeSourceOf('List<Item>', params, [], plugin.typeSyntax), 'a container not listed');
		Assert.isNull(NominalTypes.elementTypeSourceOf('Array', params, [], plugin.typeSyntax), 'written without its argument');
		Assert.equals('haxe.ds.Map', NominalTypes.outerPathOf('Null<haxe.ds.Map<K, V>>', ['Null'], plugin.typeSyntax), 'the path, peeled');
		Assert.isNull(NominalTypes.outerPathOf('Int -> Void', [], plugin.typeSyntax), 'a function type has none');
	}

	@:pin('control')
	@:killer('M-CONSTRUCTION-CTOR-GAP')
	public function testAConstructionReadsTheTypeArgumentsItWrites(): Void {
		final text: String = 'package p;\n\nclass C {\n\tfunction probeBare() return new Box(x);\n'
			+ '\tfunction probeArgs() return new pkg.Box<Int,Array<String>>(1, (y));\n'
			+ '\tfunction probeParens() return new Box<(Int), "s">(f);\n\tfunction probeNone() return new Box<Int>();\n}\n';
		final bare: Null<WrittenConstruction> = construction(text, 'probeBare');
		Assert.equals('Box', bare?.text, 'no type argument written');
		Assert.equals(0, bare?.args.length, 'the constructor\'s argument is none of the type\'s');
		final args: Null<WrittenConstruction> = construction(text, 'probeArgs');
		Assert.equals('pkg.Box<Int,Array<String>>', args?.text, 'the path and the arguments as written');
		Assert.equals('Array<String>', args?.args[1], 'each argument verbatim');
		Assert.equals(2, construction(text, 'probeParens')?.args.length, 'a parenthesised and a constant type argument');
		Assert.equals('Box<Int>', construction(text, 'probeNone')?.text, 'with no constructor argument');
	}

	@:pin('control')
	@:killer('M-NOMINAL-LOCAL-INIT')
	public function testALocalWrittenWithNoTypeHoldsItsInitializersType(): Void {
		final text: String = 'package p;\n\nclass Item {}\n\nclass C {\n\tvar items: Array<Item>;\n\tfunction probeLiteral() {\n'
			+ '\t\tvar s = \'x\';\n\t\treturn s;\n\t}\n\tfunction probeField() {\n\t\tvar all = items;\n\t\treturn all;\n\t}\n'
			+ '\tfunction probeTyped() {\n\t\tvar n: Float = 1;\n\t\treturn n;\n\t}\n\tfunction probeChain() {\n'
			+ '\t\tvar a = items;\n\t\tvar b = a;\n\t\treturn b;\n\t}\n}\n';
		Assert.equals('String', sourceIn(text, 'probeLiteral'), 'a literal initializer');
		Assert.equals('Array<Item>', sourceIn(text, 'probeField'), 'a field initializer, arguments kept');
		Assert.equals('Float', sourceIn(text, 'probeTyped'), 'the annotation wins over the initializer');
		Assert.equals('Array<Item>', sourceIn(text, 'probeChain'), 'through a local initialised by another');
		final at: Probe = probeIn(text, 'probeField');
		final use: Null<QueryNode> = NominalTypes.localInitializer(at.node, at.root, at.plugin.refShape(), at.chain.declaredTypeSources);
		Assert.equals('IdentExpr', use?.kind, 'the initializer node itself');
	}

	/**
	 * A read of an optional parameter carries the language's optional-value type (4.3.7): `?x: Int` reads as `Null<Int>`
	 * with or without a default, `?w: Null<Int>` as itself, a lambda's `?a: String` as `Null<String>`, and a parameter with a
	 * default but no `?` as written.
	 */
	@:pin('control') @:killer('M-NOMINAL-OPTIONAL-PARAM')
	public function testAnOptionalParameterReadsAsNullable(): Void {
		final text: String = 'package p;\n\nclass C {\n\tfunction probeOpt(?x: Int) return x;\n'
			+ '\tfunction probeDefault(y: Int = 3) return y;\n\tfunction probeBoth(?z: Int = 4) return z;\n'
			+ '\tfunction probeWrapped(?w: Null<Int>) return w;\n\tfunction probeCallback(?cb: Int -> Void) return cb;\n}\n';
		Assert.equals('Null<Int>', sourceIn(text, 'probeOpt'), '?x: Int');
		Assert.equals('Null', nominalIn(text, 'probeOpt'), 'its nominal');
		Assert.equals('Int', sourceIn(text, 'probeDefault'), 'a default with no `?`');
		Assert.equals('Null<Int>', sourceIn(text, 'probeBoth'), 'a default with `?`');
		Assert.equals('Null<Int>', sourceIn(text, 'probeWrapped'), 'not wrapped twice');
		Assert.equals('Null<Int -> Void>', sourceIn(text, 'probeCallback'), 'a function type');
	}

	/**
	 * A read of an optional STRUCTURE field carries the optional-value type, in each of its three spellings (`?a: T`,
	 * `var ?b: T`, `@:optional var c: T`), while a required field and an interface's `@:optional` field read as written
	 * (4.3.7: `i.e` of an `@:optional var e: Int` is `Int`).
	 */
	@:pin('control') @:killer('M-MEMBER-OPTIONAL-READ') @:killer('M-INDEX-OPTIONAL-FIELD')
	public function testAnOptionalStructureFieldReadsAsNullable(): Void {
		final text: String = 'package p;\n\ntypedef S = {\n\t?a: Int,\n\tvar ?b: String;\n\t@:optional var c: Float;\n\tvar d: Int;\n}\n\n'
			+ 'interface I {\n\t@:optional var e: Int;\n}\n\nclass C {\n\tvar s: S;\n\tvar i: I;\n'
			+ '\tfunction probeA() return s.a;\n\tfunction probeB() return s.b;\n\tfunction probeC() return s.c;\n'
			+ '\tfunction probeD() return s.d;\n\tfunction probeE() return i.e;\n}\n';
		Assert.equals('Null<Int>', sourceIn(text, 'probeA'), '?a: Int');
		Assert.equals('Null<String>', sourceIn(text, 'probeB'), 'var ?b: String');
		Assert.equals('Null<Float>', sourceIn(text, 'probeC'), '@:optional var c: Float');
		Assert.equals('Int', sourceIn(text, 'probeD'), 'a required field');
		Assert.equals('Int', sourceIn(text, 'probeE'), 'an interface field');
	}

	/**
	 * A member declared with a supertype's type parameter reads as what the extends chain passes up (4.3.7): `Base<T>.item`
	 * through `Mid<U> extends Base<Array<U>>` and `Leaf extends Mid<String>` is `Array<String>` — read bare, off `this`, off
	 * a `Leaf` and off a `Mid<Int>`; inside a generic type its own parameter is the answer.
	 */
	@:pin('control') @:killer('M-ANCESTOR-ARGS-OFF') @:killer('M-MEMBER-READ-HOST-ARGS') @:killer('M-NOMINAL-SELF-PARAMS')
	public function testAnInheritedMemberReadsThroughItsChainsArguments(): Void {
		final text: String = 'package p;\n\nclass Base<T> {\n\tpublic var item: T;\n}\n\nclass Mid<U> extends Base<Array<U>> {}\n\n'
			+ 'class Leaf extends Mid<String> {\n\tfunction probeBare() return item;\n\tfunction probeThis() return this.item;\n}\n\nclass '
			+ 'Own<V> {\n\tvar v: V;\n\tfunction probeOwn() return v;\n\tfunction probeOwnThis() return this.v;\n\tfunction probeOwnSelf() return this;\n}\n\nclass C {\n\tvar '
			+ 'leaf: Leaf;\n\tvar mid: Mid<Int>;\n\tfunction probePath() return leaf.item;\n\tfunction probeArgs() return mid.item;\n}\n';
		Assert.equals('Array', nominalIn(text, 'probeBare'), 'a bare read in the subclass');
		Assert.equals('Array<String>', sourceIn(text, 'probeThis'), 'off this');
		Assert.equals('Array<String>', sourceIn(text, 'probePath'), 'off a Leaf');
		Assert.equals('Array<Int>', sourceIn(text, 'probeArgs'), 'off a Mid<Int>');
		Assert.equals('V', nominalIn(text, 'probeOwn'), 'the type\'s own parameter, bare');
		Assert.equals('V', sourceIn(text, 'probeOwnThis'), 'and off this');
		Assert.equals('Own<V>', sourceIn(text, 'probeOwnSelf'), 'a generic type\'s `this`: the type applied to its own parameters');
	}

	/**
	 * A call whose declaration returns a type parameter — of the method or of its type — has no nominal: the parameter names
	 * what each call binds, and the compiler's answer is that binding, never the parameter (`b.get()` of a `Box<Item>` is an
	 * `Item`, `b.pick()` whatever `K` is inferred to). A written type the grammar does not read as one type is no answer either.
	 */
	@:pin('control') @:killer('M-NOMINAL-RETURN-PARAM-NAME') @:killer('M-NOMINAL-UNREADABLE-WRITTEN')
	public function testATypeParameterReturnOrAnUnreadableTypeHasNoAnswer(): Void {
		Assert.isNull(nominal('probeGet'), 'the type\'s parameter');
		Assert.isNull(nominal('probePick'), 'the method\'s own parameter');
		Assert.equals('Array', nominal('probeItems'), 'a concrete return still answers');
		final text: String = 'package p;\n\nclass C {\n\tfunction probeLocal() {\n\t\tvar n: #if lime Int #else String #end = null;\n'
			+ '\t\treturn n;\n\t}\n}\n';
		Assert.isNull(sourceIn(text, 'probeLocal'), 'a local written under `#if`');
	}

	private static function nominal(fn: String): Null<String> {
		final at: Probe = probeIn(SOURCE, fn);
		return NominalTypes.expressionTypeNominal(at.node, at.root, at.plugin.refShape(), at.declared, at.index, 'p/C.hx', at.chain);
	}

	private static function nominalIn(text: String, fn: String): Null<String> {
		final at: Probe = probeIn(text, fn);
		return NominalTypes.expressionTypeNominal(at.node, at.root, at.plugin.refShape(), at.declared, at.index, 'p/C.hx', at.chain);
	}

	private static function source(fn: String): Null<String> {
		return sourceIn(SOURCE, fn);
	}

	private static function sourceIn(text: String, fn: String): Null<String> {
		final at: Probe = probeIn(text, fn);
		return NominalTypes.expressionTypeSource(at.node, at.root, at.plugin.refShape(), at.declared, at.index, 'p/C.hx', at.chain);
	}

	/** The expression the function `fn` of `text` returns, with what the typer is handed for it. */
	private static function probeIn(text: String, fn: String): Probe {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final root: QueryNode = plugin.parseFile(text);
		final found: Null<QueryNode> = returnedBy(root, fn);
		if (found == null) throw new Exception('the fixture has no `$fn`');
		final node: QueryNode = found;
		final chain: ChainTypeContext = {
			declaredTypeSources: plugin.declaredTypeSources(text),
			source: text,
			usings: [],
			typeSyntax: plugin.typeSyntax
		};
		return {
			plugin: plugin,
			root: root,
			node: node,
			declared: plugin.declaredTypes(text),
			index: SymbolIndex.build([{ file: 'p/C.hx', source: text }], plugin),
			chain: chain
		};
	}

	/** The value the expression body of the function `fn` under `node` returns. */
	private static function returnedBy(node: QueryNode, fn: String): Null<QueryNode> {
		if (node.kind == 'FnMember' && node.name == fn) {
			// an expression body returns its expression; a block, what its `return` does
			final body: Null<QueryNode> = Lambda.find(node.children, c -> c.kind == 'ExprBody' || c.kind == 'BlockBody');
			final ret: Null<QueryNode> = if (body == null)
				null
			else if (body.kind == 'ExprBody')
				body.children[0]
			else
				Lambda.find(body.children, c -> c.kind == 'ReturnStmt');
			return ret == null ? null : ret.children[0];
		}
		for (c in node.children) {
			final hit: Null<QueryNode> = returnedBy(c, fn);
			if (hit != null) return hit;
		}
		return null;
	}

	/** What `NominalTypes.writtenConstruction` reads off the construction the function `fn` of `text` returns. */
	private static function construction(text: String, fn: String): Null<WrittenConstruction> {
		final at: Probe = probeIn(text, fn);
		return NominalTypes.writtenConstruction(at.node, at.plugin.refShape(), text);
	}

}

/** What `NominalTypesTest.probeIn` hands the typer. */
private typedef Probe = {
	final plugin: HaxeQueryPlugin;
	final root: QueryNode;
	final node: QueryNode;
	final declared: Map<Int, String>;
	final index: SymbolIndex;
	final chain: ChainTypeContext;
}
