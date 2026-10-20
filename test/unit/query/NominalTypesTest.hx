package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import haxe.Exception;
import unit.QueryTestHelpers;
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

	/**
	 * Stubs of standard-library declarations a fixture reads, where the index takes them for the std's own
	 * (`QueryTestHelpers.stdPath`): the dynamic type a reference may name bare, and a class a default names.
	 */
	private static final STD: Array<{ file: String, source: String }> = [
		{ file: QueryTestHelpers.stdPath('StdTypes.hx'), source: '@:coreType abstract Dynamic<T> from T to T {}\n' },
		{ file: QueryTestHelpers.stdPath('String.hx'), source: 'extern class String {}\n' }
	];

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

	/**
	 * A reference that leaves trailing type arguments out names its declaration applied to the defaults that declaration
	 * writes (4.3.7: with `class Box<T = Int>`, `Box` is `Box<Int>` — inside `Box` too, as an argument, through an extends
	 * link, and in a default that leaves its own arguments out): the binding, a member read through it, a member and a
	 * return written so.
	 */
	@:pin('control') @:killer('M-ANCESTOR-DEFAULT-FILL') @:killer('M-ANCESTOR-COMPLETE-OFF') @:killer('M-ANCESTOR-LINK-DEFAULTS')
	@:killer('M-MEMBER-READ-COMPLETE') @:killer('M-NOMINAL-BOUND-COMPLETE') @:killer('M-NOMINAL-RETURN-COMPLETE')
	@:killer('M-INDEX-PARAM-DEFAULTS')
	public function testAReferenceLeavingArgumentsOutNamesTheirDefaults(): Void {
		final text: String = 'package p;\n\nclass Item {}\n\nclass Box<T = Item> {\n\tpublic var v: Null<T>;\n\tpublic var self: Box;\n'
			+ '\tpublic function get(): Box return null;\n}\n\nclass Pair<A, B = String> {}\n\nclass Outer<T = Box> {}\n\n'
			+ 'class Sub extends Box {}\n\nclass C {\n\tvar b: Box;\n\tvar bs: Array<Box>;\n\tvar p: Pair<Int>;\n\tvar o: Outer;\n'
			+ '\tvar s: Sub;\n\tfunction probeB() return b;\n\tfunction probeV() return b.v;\n\tfunction probeSelf() return b.self;\n'
			+ '\tfunction probeSelfV() return b.self.v;\n\tfunction probeGet() return b.get();\n\tfunction probeList() return bs;\n'
			+ '\tfunction probePair() return p;\n\tfunction probeOuter() return o;\n\tfunction probeSub() return s.v;\n}\n';
		Assert.equals('Box<Item>', sourceAmong(text, STD, 'probeB'), 'the binding');
		Assert.equals('Null<Item>', sourceAmong(text, STD, 'probeV'), 'a member read through it');
		Assert.equals('Box<Item>', sourceAmong(text, STD, 'probeSelf'), 'a member written so, inside the type itself');
		Assert.equals('Null<Item>', sourceAmong(text, STD, 'probeSelfV'), 'read through such a member');
		Assert.equals('Box<Item>', sourceAmong(text, STD, 'probeGet'), 'a return written so');
		Assert.equals('Array<Box<Item>>', sourceAmong(text, STD, 'probeList'), 'as a type argument');
		Assert.equals('Pair<Int, String>', sourceAmong(text, STD, 'probePair'), 'a trailing argument left out');
		Assert.equals('Outer<Box<Item>>', sourceAmong(text, STD, 'probeOuter'), 'a default leaving its own arguments out');
		Assert.equals('Null<Item>', sourceAmong(text, STD, 'probeSub'), 'through an extends link');
	}

	/**
	 * A reference whose left-out arguments cannot be written in has no source answer rather than the reference as written:
	 * a parameter without a default (not a type the compiler accepts), a default reaching its own type again (the compiler
	 * overflows), a name a type parameter of the file may hold, and a default naming a type the reading file does not see.
	 * The dynamic type alone may be written bare, and a default the reading file sees the same is written in. A type two
	 * `#if` branches declare has a default only where both write the same one.
	 */
	@:pin('control') @:killer('M-ANCESTOR-DEFAULT-MISSING') @:killer('M-ANCESTOR-BARE-TYPE') @:killer('M-ANCESTOR-SCOPE-OFF')
	@:killer('M-ANCESTOR-DEFAULT-VISIBLE') @:killer('M-NOMINAL-BOUND-SCOPE')
	@:killer('M-INDEX-ALTERNATE-DEFAULTS')
	public function testAReferenceItCannotCompleteHasNoAnswer(): Void {
		final text: String = 'package p;\n\nclass Need<T> {}\n\nclass Rec<T = Rec> {}\n\nclass Item {}\n\nclass Box<T = Item> {}\n\n'
			+ 'class G<Box> {\n\tvar g: Box;\n}\n\nclass C {\n\tvar n: Need;\n\tvar r: Rec;\n\tvar b: Box;\n\tvar d: Dynamic;\n'
			+ '\tfunction probeNeed() return n;\n\tfunction probeRec() return r;\n\tfunction probeBox() return b;\n'
			+ '\tfunction probeDynamic() return d;\n}\n';
		Assert.isNull(sourceAmong(text, STD, 'probeNeed'), 'a parameter without a default');
		Assert.isNull(sourceAmong(text, STD, 'probeRec'), 'a default reaching its own type');
		Assert.isNull(sourceAmong(text, STD, 'probeBox'), 'a name a type parameter of the file holds');
		Assert.equals('Dynamic', sourceAmong(text, STD, 'probeDynamic'), 'the dynamic type written bare');
		final rec: Probe = probeIn(text, 'probeRec', STD);
		final recFile: Null<FileInfo> = rec.index.fileInfo('p/C.hx');
		Assert.isNull(recFile == null ? 'no file' : rec.index.typing.ancestors.completed('Rec', recFile, null, []), 'asked directly');
		final holder: Array<{ file: String, source: String }> = [
			{ file: 'a/Holder.hx', source: 'package a;\n\nimport b.Hidden;\n\nclass Holder<T = Hidden> {}\n' },
			{ file: 'b/Hidden.hx', source: 'package b;\n\nclass Hidden {}\n' }
		];
		final reader: String = 'package p;\n\nimport a.Holder;\n\nclass C {\n\tvar h: Holder;\n\tfunction probeHolder() return h;\n}\n';
		Assert.isNull(sourceAmong(reader, holder, 'probeHolder'), 'a default the reading file does not see');
		final seeing: String = 'package p;\n\nimport a.Holder;\nimport b.Hidden;\n\nclass C {\n\tvar h: Holder;\n'
			+ '\tfunction probeHolder() return h;\n}\n';
		Assert.equals('Holder<Hidden>', sourceAmong(seeing, holder, 'probeHolder'), 'one it sees the same');
		final branches: String = 'package p;\n\nclass Item {}\n\n#if a\nclass K<T = Item> {}\n#else\nclass K<T = String> {}\n#end\n\n'
			+ '#if a\nclass L<T = Item> {}\n#else\nclass L<T = Item> {}\n#end\n\nclass C {\n\tvar k: K;\n\tvar l: L;\n'
			+ '\tfunction probeK() return k;\n\tfunction probeL() return l;\n}\n';
		Assert.isNull(sourceAmong(branches, STD, 'probeK'), 'two branches writing two defaults');
		Assert.equals('L<Item>', sourceAmong(branches, STD, 'probeL'), 'two writing one');
	}

	/**
	 * A bare call `walk(1)` calls the member `walk` only where the name binds to that member: a local function of the
	 * name shadows it, and its return type is not the member's (the nominal walk names none for it).
	 */
	@:pin('control') @:killer('M-NOMINAL-UNQUALIFIED-MEMBER')
	public function testABareCallOfALocalFunctionIsNotTheMembers(): Void {
		final text: String = 'package p;\n\nclass Item {}\n\nclass C {\n\tfunction walk(n: Int): Item return null;\n'
			+ '\tfunction probeMember() return walk(1);\n\tfunction probeLocal() {\n\t\tfunction walk(n: Int): Int return n;\n'
			+ '\t\treturn walk(1);\n\t}\n}\n';
		Assert.equals('Item', nominalIn(text, 'probeMember'), 'the member');
		Assert.isNull(nominalIn(text, 'probeLocal'), 'a local function shadowing it');
	}

	/**
	 * A member read the import-aware walk cannot place (the receiver's type does not resolve from the reading file) falls
	 * back to the package-blind walk, which substitutes nothing: a member written with its type's parameter
	 * (`data: Array<T>`) then has no answer, rather than the parameter the receiver's argument binds.
	 */
	@:pin('control') @:killer('M-NOMINAL-BLIND-PARAMS')
	public function testABlindMemberReadWrittenWithAParameterHasNoAnswer(): Void {
		final others: Array<{ file: String, source: String }> = [
			{ file: 'a/Pri.hx', source: 'package a;\n\nclass Pri<T> {\n\tpublic var data: Array<T>;\n\tpublic var size: Int;\n}\n' }
		];
		final text: String = 'package p;\n\nclass C {\n\tvar p: Pri<String>;\n\tfunction probeData() return p.data;\n'
			+ '\tfunction probeSize() return p.size;\n}\n';
		Assert.isNull(sourceAmong(text, others, 'probeData'), 'a member written with the parameter');
		Assert.equals('Int', sourceAmong(text, others, 'probeSize'), 'one written without');
	}

	/**
	 * An expression inside a reification (`macro { n; }`) is a value of the syntax tree the program builds, so neither
	 * currency types it as the code its text spells; an interpolation (`$v{n}`) re-opens the code inside it, and the
	 * same read outside a reification is typed as ever.
	 */
	@:pin('control') @:killer('M-NOMINAL-REIFIED') @:killer('M-NOMINAL-REIFIED-NOMINAL') @:killer('M-REIFIED-REOPEN')
	public function testAnExpressionInsideAReificationIsNotTypedAsCode(): Void {
		final text: String = 'package p;\n\nclass C {\n\tvar n: Int;\n\tfunction f() {\n\t\tn;\n\t\t5;\n'
			+ '\t\treturn macro { n; 5; $$v{n}; };\n\t}\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final root: QueryNode = plugin.parseFile(text);
		final chain: ChainTypeContext = {
			declaredTypeSources: plugin.declaredTypeSources(text),
			source: text,
			typeSyntax: plugin.typeSyntax
		};
		final index: SymbolIndex = SymbolIndex.build([{ file: 'p/C.hx', source: text }], plugin);
		// the node of `kind` starting at the first character of `mark` the first `at` holds
		function typed(kind: String, at: String, mark: String): { source: Null<String>, nominal: Null<String> } {
			final from: Int = text.indexOf(at) + at.indexOf(mark);
			var found: Null<QueryNode> = null;
			function walk(node: QueryNode): Void {
				if (node.kind == kind && node.span?.from == from) found = node;
				for (c in node.children) walk(c);
			}
			walk(root);
			final node: QueryNode = found ?? throw new Exception('no $kind at $from');
			return {
				source: NominalTypes.expressionTypeSource(
					node, root, plugin.refShape(), plugin.declaredTypes(text), index, 'p/C.hx', chain
				),
				nominal: NominalTypes.expressionTypeNominal(
					node, root, plugin.refShape(), plugin.declaredTypes(text), index, 'p/C.hx', chain
				)
			};
		}
		Assert.same({ source: 'Int', nominal: 'Int' }, typed('IdentExpr', '\t\tn;', 'n'), 'a read as code');
		Assert.same({ source: 'Int', nominal: 'Int' }, typed('IntLit', '\t\t5;', '5'), 'a literal as code');
		Assert.same({ source: null, nominal: null }, typed('IdentExpr', '{ n;', 'n'), 'the read reified');
		Assert.same({ source: null, nominal: null }, typed('IntLit', 'n; 5', '5'), 'the literal reified');
		Assert.same({ source: 'Int', nominal: 'Int' }, typed('IdentExpr', '{n}', 'n'), 'the read an interpolation re-opens');
	}

	/**
	 * A call to an `@:overload` member returns what the signature it selects returns (`CallSelection`, 4.3.7 probes: the
	 * member's own signature first, then each annotation's in written order, the first compiling binds): `O.g(1)` — the own
	 * `(a:String)` refuses an `Int`, `(a:Int)` takes it — is a `Bool`; `O.h(1)` takes `(a:Float)`, written before `(a:Int)`,
	 * and is a `String`. An argument no arc types leaves every candidate open: `O.g(u)` is no answer, `O.z(u)` — each
	 * candidate returning `Void` — is a `Void`. A static read through a `typedef` alias, `null` binding an optional `?s`, a
	 * parameter typed where the file writes it, an instance member off a value: each decided alike. Both currencies.
	 */
	@:pin('control') @:killer('M-NOMINAL-SELECTED-STATIC') @:killer('M-NOMINAL-OVERLOAD-REFUSED') @:killer('M-SOURCE-OVERLOAD-REFUSED')
	@:killer('M-CALLS-FIRST-COMPILING') @:killer('M-CALLS-AGREED-RETURN') @:killer('M-SOURCE-SELECTED-STATIC')
	@:killer('M-NOMINAL-STATIC-ALIAS') @:killer('M-NOMINAL-ARGUMENT-NULL') @:killer('M-NOMINAL-ARGUMENT-BOUND')
	public function testAnOverloadedCallReturnsWhatTheSelectedSignatureReturns(): Void {
		final text: String = 'package p;\n\nextern class O {\n\t@:overload(function(a:Int):Bool {})\n'
			+ '\t@:overload(function(a:Float):String {})\n\tstatic function g(a:String):Int;\n\n'
			+ '\t@:overload(function(a:Float):String {})\n\t@:overload(function(a:Int):Bool {})\n'
			+ '\tstatic function h(a:String):Int;\n\n\t@:overload(function(a:Int):Void {})\n'
			+ '\tstatic function z(a:String):Void;\n\n\t@:overload(function(a:Float):Bool {})\n'
			+ '\tstatic function n(?s:String):Int;\n\n\t@:overload(function(a:Int):Bool {})\n\tfunction m(a:String):Int;\n'
			+ '}\n\ntypedef OA = O;\n\nclass C {\n\tvar o: O;\n\tfunction probeArity() return O.g(1);\n'
			+ '\tfunction probeOrder() return O.h(1);\n\tfunction probeOpen(u) return O.g(u);\n'
			+ '\tfunction probeAgreed(u) return O.z(u);\n\tfunction probeAlias() return OA.g(1);\n\tfunction probeNull() '
			+ 'return O.n(null);\n\tfunction probeBound(x:Int) return O.g(x);\n\tfunction probeValue() return o.m(1);\n}\n';
		Assert.equals('Bool', nominalIn(text, 'probeArity'), 'the own signature refuses the argument');
		Assert.equals('Bool', sourceIn(text, 'probeArity'), 'the own signature refuses the argument (source)');
		Assert.equals('String', nominalIn(text, 'probeOrder'), 'the first annotation compiling binds');
		Assert.equals('String', sourceIn(text, 'probeOrder'), 'the first annotation compiling binds (source)');
		Assert.isNull(nominalIn(text, 'probeOpen'), 'an untyped argument leaves three candidates');
		Assert.isNull(sourceIn(text, 'probeOpen'), 'an untyped argument leaves three candidates (source)');
		Assert.equals('Void', nominalIn(text, 'probeAgreed'), 'every candidate returns one type');
		Assert.equals('Bool', nominalIn(text, 'probeAlias'), 'a static read through a typedef alias');
		Assert.equals('Int', nominalIn(text, 'probeNull'), '`null` binds the optional `?s`');
		Assert.equals('Bool', nominalIn(text, 'probeBound'), 'a parameter typed where this file writes it');
		Assert.equals('Bool', nominalIn(text, 'probeValue'), 'an instance member off a value');
		Assert.equals('Bool', sourceIn(text, 'probeValue'), 'an instance member off a value (source)');
	}

	/**
	 * The superclass chain declares a member before an interface does (`raw_class_field`): `s.on()` on `class S extends E<S>
	 * implements IE`, with `E<T>.on(): T` and `IE.on(): IE`, is an `S` — `E`'s parameter bound through the chain — never
	 * the interface's `IE`, which the name walk used to take for a superclass return it could not name.
	 */
	@:pin('control') @:killer('M-NOMINAL-DECLARING-SUPER-POISON') @:killer('M-NOMINAL-SELECTED-VALUE') @:killer('M-SOURCE-SELECTED-VALUE')
	public function testTheSuperclassChainDeclaresAMemberBeforeAnInterface(): Void {
		final text: String = 'package p;\n\nclass E<T> {\n\tpublic function on(): T return null;\n}\n\ninterface IE {\n'
			+ '\tfunction on(): IE;\n}\n\nclass S extends E<S> implements IE {}\n\nclass C {\n\tvar s: S;\n'
			+ '\tfunction probeOn() return s.on();\n}\n';
		Assert.equals('S', nominalIn(text, 'probeOn'));
		Assert.equals('S', sourceIn(text, 'probeOn'), 'the source currency');
	}

	/**
	 * A bare call to an inherited member is typed through the declaration the enclosing type extends, where its file
	 * resolves it: `go()` in `Sub extends Img` (`p.Img`, whose `PBase.go(): Int`), beside a namesake `q.Img` whose base
	 * overloads `go` — the name walk, unioning both `Img`s, answers neither.
	 */
	@:pin('control') @:killer('M-NOMINAL-SELECTED-BARE') @:killer('M-SOURCE-SELECTED-BARE')
	public function testABareCallIsTypedThroughTheEnclosingDeclarationsChain(): Void {
		final text: String = 'package p;\n\nclass PBase {\n\tpublic function go(): Int return 0;\n}\n\nclass Img extends PBase {}\n\n'
			+ 'class Sub extends Img {\n\tfunction probeGo() return go();\n}\n';
		final other: String = 'package q;\n\nclass QBase {\n\t@:overload(function(a:Int):Void {})\n'
			+ '\tpublic function go(): String return null;\n}\n\nclass Img extends QBase {}\n';
		Assert.equals('Int', nominalAmong(text, [{ file: 'q/Img.hx', source: other }], 'probeGo'));
		Assert.equals('Int', sourceAmong(text, [{ file: 'q/Img.hx', source: other }], 'probeGo'), 'the source currency');
	}

	/**
	 * A namesake of the receiver's type no signature of which the call compiles against is not its type (the code
	 * compiles): `b.size(1)` on a `Buf` reads `p.Buf.size(a:Int): Int`, beside a `q.Buf` declaring only `size(): String`.
	 */
	@:pin('control') @:killer('M-NOMINAL-NAMESAKE-EXCLUDED')
	public function testANamesakeNoSignatureOfWhichCompilesIsNotTheReceiver(): Void {
		final text: String = 'package p;\n\nclass Buf {\n\t@:overload(function():Int {})\n\tpublic function size(a:Int): Int return 0;\n'
			+ '}\n\nclass C {\n\tvar b: Buf;\n\tfunction probeSize() return b.size(1);\n}\n';
		final other: String = 'package q;\n\nclass Buf {\n\tpublic function size(): String return null;\n}\n';
		Assert.equals('Int', nominalAmong(text, [{ file: 'q/Buf.hx', source: other }], 'probeSize'));
	}

	/**
	 * A method's own type parameter is bound by the arguments a call hands it (4.3.7: `id(1)` is an `Int`, and `id(n)` over
	 * `?n:Int` a `Null<Int>`, which the walk does not spell, so no answer), and its bound decides which signature compiles:
	 * `c('x')` — the own `<T:Int>(a:T)` refuses a `String`, the annotation `(a:String)` takes it — is a `Bool`. A function
	 * written with no return type has none, though its bound `<T:Int>` writes a type beside it.
	 */
	@:pin('control') @:killer('M-CALLS-PARAM-INFER') @:killer('M-CALLS-PARAM-BOUND') @:killer('M-INDEX-RETURN-SOURCE-SPAN')
	@:killer('M-CALLS-NULLABLE-UNBOUND')
	public function testAMethodsTypeParameterIsBoundByTheArguments(): Void {
		final text: String = 'package p;\n\nextern class O {\n\tstatic function id<T>(x:T):T;\n\n\t@:overload(function(a:String):Bool {})\n'
			+ '\tstatic function c<T:Int>(a:T):Int;\n}\n\nclass G {\n\tpublic function new() {}\n\n\tpublic function g<T:Int>(x:T) {}\n'
			+ '}\n\nclass C {\n\tvar o: G;\n\tfunction probeId() return O.id(1);\n\tfunction probeBound() return O.c(\'x\');\n'
			+ '\tfunction probeNoReturn() return o.g(1);\n\tfunction probeNullable(?n:Int) return O.id(n);\n}\n';
		Assert.equals('Int', nominalIn(text, 'probeId'), 'the argument binds `T`');
		Assert.equals('Int', sourceIn(text, 'probeId'), 'the argument binds `T` (source)');
		Assert.equals('Bool', nominalIn(text, 'probeBound'), 'the bound refuses the own signature');
		Assert.isNull(sourceIn(text, 'probeNoReturn'), 'no return written');
		Assert.isNull(sourceIn(text, 'probeNullable'), '`T` bound to `Null<Int>`, which the walk does not spell');
	}

	/**
	 * A generic abstract's clauses read with the arguments it is applied to (`apply_params`, 4.3.7 probes): an argument
	 * `true` misfits `E2<String, Float>` (`from String`, `from Float`), so `k(true)` and `m(true)` take the annotation
	 * `(x:Bool)` — through a `typedef` alias and as written —, and `g(1)` keeps its own signature (`Int` widens to `Float`).
	 */
	@:pin('control') @:killer('M-CASTS-APPLIED-ALIAS') @:killer('M-CASTS-APPLIED-WRITTEN') @:killer('M-CASTS-APPLIED-GRAPH-PARAM')
	public function testAGenericAbstractCastsThroughTheArgumentsItIsAppliedTo(): Void {
		final text: String = 'package p;\n\nabstract E2<A, B>(Dynamic) from A to A from B to B {}\n\ntypedef Path = E2<String, Float>;\n\n'
			+ 'extern class X {\n\t@:overload(function(x:Bool):Bool {})\n\tstatic function k(x:Path):String;\n\n'
			+ '\t@:overload(function(x:Bool):Bool {})\n\tstatic function m(x:E2<String, Float>):String;\n\n'
			+ '\t@:overload(function(x:Int):Bool {})\n\tstatic function g(x:Path):String;\n}\n\nclass C {\n\tfunction probeAlias() '
			+ 'return X.k(true);\n\tfunction probeWritten() return X.m(true);\n\tfunction probeWidened() return X.g(1);\n}\n';
		Assert.equals('Bool', nominalIn(text, 'probeAlias'), 'through a typedef alias');
		Assert.equals('Bool', nominalIn(text, 'probeWritten'), 'as written');
		Assert.equals('String', nominalIn(text, 'probeWidened'), 'the own signature takes a widened argument');
	}

	private static function nominal(fn: String): Null<String> {
		final at: Probe = probeIn(SOURCE, fn);
		return NominalTypes.expressionTypeNominal(at.node, at.root, at.plugin.refShape(), at.declared, at.index, 'p/C.hx', at.chain);
	}

	private static function nominalIn(text: String, fn: String): Null<String> {
		final at: Probe = probeIn(text, fn);
		return NominalTypes.expressionTypeNominal(at.node, at.root, at.plugin.refShape(), at.declared, at.index, 'p/C.hx', at.chain);
	}

	/** `nominalIn` with the files `others` indexed beside `text`. */
	private static function nominalAmong(text: String, others: Array<{ file: String, source: String }>, fn: String): Null<String> {
		final at: Probe = probeIn(text, fn, others);
		return NominalTypes.expressionTypeNominal(at.node, at.root, at.plugin.refShape(), at.declared, at.index, 'p/C.hx', at.chain);
	}

	private static function source(fn: String): Null<String> {
		return sourceIn(SOURCE, fn);
	}

	private static function sourceIn(text: String, fn: String): Null<String> {
		final at: Probe = probeIn(text, fn);
		return NominalTypes.expressionTypeSource(at.node, at.root, at.plugin.refShape(), at.declared, at.index, 'p/C.hx', at.chain);
	}

	/** `sourceIn` with the files `others` indexed beside `text`. */
	private static function sourceAmong(text: String, others: Array<{ file: String, source: String }>, fn: String): Null<String> {
		final at: Probe = probeIn(text, fn, others);
		return NominalTypes.expressionTypeSource(at.node, at.root, at.plugin.refShape(), at.declared, at.index, 'p/C.hx', at.chain);
	}

	/** The expression the function `fn` of `text` returns, with what the typer is handed for it, `others` indexed beside it. */
	private static function probeIn(text: String, fn: String, ?others: Array<{ file: String, source: String }>): Probe {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final root: QueryNode = plugin.parseFile(text);
		final found: Null<QueryNode> = returnedBy(root, fn);
		if (found == null) throw new Exception('the fixture has no `$fn`');
		final node: QueryNode = found;
		final chain: ChainTypeContext = {
			declaredTypeSources: plugin.declaredTypeSources(text),
			source: text,
			typeSyntax: plugin.typeSyntax
		};
		return {
			plugin: plugin,
			root: root,
			node: node,
			declared: plugin.declaredTypes(text),
			index: SymbolIndex.build([{ file: 'p/C.hx', source: text }].concat(others ?? []), plugin),
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
