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
		+ 'abstract Wrap(Array<Item>) {\n\tpublic function probeThis() return this;\n}\n\n'
		+ 'class C {\n\tvar m: Map<String, Array<Int>>;\n\tvar b: Box<Item>;\n'
		+ '\tfunction probeString() return \'x\';\n\tfunction probeInt() return 5;\n'
		+ '\tfunction probeNew() return new p.Box(1);\n\tfunction probeSelf() return this;\n'
		+ '\tfunction probeMap() return m;\n\tfunction probeItems() return b.items();\n'
		+ '\tfunction probeGet() return b.get();\n\tfunction probePick() return b.pick();\n'
		+ '\tfunction probePlain() return b.plain();\n}\n';

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
		final split: String = 'package p;\n\nclass D {\n#if a\n\tpublic function make(): Array<Int> return null;\n#else\n'
			+ '\tpublic function make(): Array<String> return null;\n#end\n}\n\nclass C {\n\tvar d: D;\n'
			+ '\tfunction probe() return d.make();\n}\n';
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

	private static function nominal(fn: String): Null<String> {
		final at: Probe = probeIn(SOURCE, fn);
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
			final body: Null<QueryNode> = Lambda.find(node.children, c -> c.kind == 'ExprBody');
			final ret: Null<QueryNode> = body == null ? null : body.children[0];
			return ret == null ? null : ret.children[0];
		}
		for (c in node.children) {
			final hit: Null<QueryNode> = returnedBy(c, fn);
			if (hit != null) return hit;
		}
		return null;
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
