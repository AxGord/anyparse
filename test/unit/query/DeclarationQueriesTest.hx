package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeNameBinding;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

/**
 * The by-declaration type questions the call graph's former consumers ask the index instead (task B3): a typedef alias
 * followed hop by hop where each hop is ONE declaration (`TypeRefIndex.aliasedName`), the name-keyed sub- and supertype
 * closures (`SubtypeGraph`), the declaration hosting a member (`MemberLookup.declaringHost`), and whether a supertype may
 * declare a member a sealed method would hide behind (`MemberLookup.supertypesDeclareNone`).
 */
@:nullSafety(Strict)
class DeclarationQueriesTest extends Test {

	@:pin('control') @:killer('M-ALIAS-SINGLE-DECL')
	public function testAnAliasIsFollowedThroughOneDeclarationAHop(): Void {
		final index: SymbolIndex = indexOf([
			'p/Real.hx' => 'package p;\n\nclass Real {}\n',
			'p/Hop.hx' => 'package p;\n\ntypedef Hop = Real;\n',
			'p/Two.hx' => 'package p;\n\ntypedef Two = Hop;\n',
			'p/Shape.hx' => 'package p;\n\ntypedef Shape = { x: Int };\n',
			'p/Away.hx' => 'package p;\n\ntypedef Away = lib.Gone;\n',
			'a/Both.hx' => 'package a;\n\ntypedef Both = p.Real;\n',
			'b/Both.hx' => 'package b;\n\nclass Both {}\n'
		]);
		Assert.equals('Real', index.refs.aliasedName('Two'), 'two hops, each one declaration');
		Assert.equals('Shape', index.refs.aliasedName('Shape'), 'a typedef of a structure aliases no type');
		Assert.equals('Gone', index.refs.aliasedName('Away'), 'a hop out of the index: the target\'s written name');
		Assert.equals('Both', index.refs.aliasedName('Both'), 'a name declared twice is no hop to take');
	}

	public function testTheClosuresHoldTheTypeItself(): Void {
		final index: SymbolIndex = indexOf([
			'p/A.hx' => 'package p;\n\nclass A {}\n',
			'p/B.hx' => 'package p;\n\nclass B extends A {}\n',
			'p/C.hx' => 'package p;\n\nclass C extends B implements lib.I {}\n'
		]);
		Assert.same(['A', 'B', 'C'], sorted(index.subtypes.subtypeNamesClosure('A')), 'the type and every subtype');
		Assert.same(['C', 'B', 'I', 'A'], index.subtypes.supertypeNamesClosure('C'), 'the type, then each supertype name, breadth first');
	}

	/**
	 * What a subtype's chain passes to a supertype's parameters, read off the index (`SubtypeGraph.argumentsPassed`): a direct
	 * link's arguments as written, a longer chain's substituted through each type it climbs, nothing when the supertype is
	 * not on the chain or a link fills fewer parameters than it has.
	 */
	@:pin('control') @:killer('M-SUBTYPE-ARGS-SUBSTITUTED') @:killer('M-SUBTYPE-ARGS-ARITY') @:killer('M-GRAPH-INHERITED-ARGS')
	public function testASubtypeChainPassesItsArgumentsInItsOwnTerms(): Void {
		final index: SymbolIndex = indexOf([
			'p/Box.hx' => 'package p;\n\nclass Box<T> {}\n',
			'p/Direct.hx' => 'package p;\n\nclass Direct extends Box<String> {}\n',
			'p/Mid.hx' => 'package p;\n\nclass Mid<X> extends Box<Array<X>> {}\n',
			'p/Leaf.hx' => 'package p;\n\nclass Leaf extends Mid<Int> {}\n',
			'p/Short.hx' => 'package p;\n\nclass Short extends Mid {}\n',
			'p/Other.hx' => 'package p;\n\nclass Other {}\n'
		]);
		final syntax: TypeSyntaxReader = new HaxeQueryPlugin().typeSyntax;
		Assert.same(['String'], index.subtypes.argumentsPassed('Box', 'Direct', syntax), 'a direct link, as written');
		Assert.same(['Array<X>'], index.subtypes.argumentsPassed('Box', 'Mid', syntax), 'in the subtype\'s own terms');
		Assert.same(['Array<Int>'], index.subtypes.argumentsPassed('Box', 'Leaf', syntax), 'substituted through the type climbed');
		Assert.isNull(index.subtypes.argumentsPassed('Box', 'Short', syntax), 'a link filling fewer parameters than it has');
		Assert.isNull(index.subtypes.argumentsPassed('Box', 'Other', syntax), 'not on the chain');
	}

	/**
	 * The declaration questions the call graph asks by simple name, answered by the index (`CallGraphImports`): whether any
	 * type declares a member of a kind (`MemberLookup.declaresMemberAs`, an enum constructor a bare call builds), each
	 * declaration of a member with its file (`MemberLookup.memberDeclarationsOf`), and the paths a declaration is named by
	 * (`TypeNameBinding.namingPaths`).
	 */
	@:pin('control') @:killer('M-MEMBER-KIND-IGNORED') @:killer('M-TS-PATH-DECLARED-PACKAGE')
	public function testTheGraphsDeclarationQuestionsAreTheIndexs(): Void {
		final index: SymbolIndex = indexOf([
			'p/Colour.hx' => 'package p;\n\nenum Colour {\n\tRed;\n\tGreen;\n}\n\nclass Paint {\n\tpublic var tone:Int = 0;\n}\n',
			'q/Box.hx' => 'package q;\n\nclass Box {\n\tpublic var item:String;\n}\n',
			'r/Box.hx' => 'package r;\n\nclass Box {\n\tpublic var item:Int;\n}\n'
		]);
		final ctorKinds: Array<String> = new HaxeQueryPlugin().refShape().execution?.enumConstructorKinds ?? [];
		Assert.isTrue(index.members.declaresMemberAs('Red', ctorKinds), 'an enum constructor');
		Assert.isFalse(index.members.declaresMemberAs('tone', ctorKinds), 'a field is no constructor');
		Assert.isFalse(index.members.declaresMemberAs('Blue', ctorKinds), 'nothing declares it');
		Assert.same(['q/Box.hx:String', 'r/Box.hx:Int'], [
			for (d in index.members.memberDeclarationsOf('Box', 'item')) '${d.file.file}:${d.member.typeSource}'
		], 'each declaration, with its file');
		final paths: Array<String> = [
			for (r in index.refs.resolvedDeclsNamed('Colour')) for (p in TypeNameBinding.namingPaths(r)) p
		];
		Assert.same(['p.Colour', 'p.Colour.Colour'], paths, 'a main type: its module, and its module and its name');
		final sub: Array<String> = [
			for (r in index.refs.resolvedDeclsNamed('Paint')) for (p in TypeNameBinding.namingPaths(r)) p
		];
		Assert.same(['p.Colour.Paint', 'p.Paint'], sub, 'a sub-type: its module and its name, its package and its name');
	}

	@:pin('control') @:killer('M-HOST-UNIQUE')
	public function testAMemberIsHostedWhereItsDeclarationIs(): Void {
		final index: SymbolIndex = indexOf([
			'p/Base.hx' => 'package p;\n\nclass Base {\n\tpublic var lock:Int = 0;\n}\n',
			'p/Kid.hx' => 'package p;\n\nclass Kid extends Base {}\n',
			'a/Twin.hx' => 'package a;\n\nclass Twin {\n\tpublic var lock:Int = 0;\n}\n',
			'b/Twin.hx' => 'package b;\n\nclass Twin {\n\tpublic var lock:Int = 0;\n}\n'
		]);
		Assert.equals('p/Base.hx', index.members.declaringHost('Kid', 'lock')?.host.file.file, 'an inherited member, on its declaration');
		Assert.isNull(index.members.declaringHost('Twin', 'lock'), 'a name declared twice hosts nothing provable');
	}

	@:pin('control') @:killer('M-SEAL-AMBIGUOUS') @:killer('M-SEAL-UNRESOLVED-IFACE') @:killer('M-SEAL-DECLARING-SUPER')
	public function testASupertypeThatMayDeclareTheMemberIsNamed(): Void {
		final index: SymbolIndex = indexOf([
			'p/Plain.hx' => 'package p;\n\nclass Plain extends lib.Unseen {\n\tfunction run():Void {}\n}\n',
			'p/Iface.hx' => 'package p;\n\nclass Iface implements lib.Unknown {\n\tfunction run():Void {}\n}\n',
			'p/Base.hx' => 'package p;\n\nclass Base {\n\tfunction run():Void {}\n}\n',
			'p/Kid.hx' => 'package p;\n\nclass Kid extends Base {\n\toverride function run():Void {}\n}\n',
			'p/Shared.hx' => 'package p;\n\nclass Shared {\n\tfunction run():Void {}\n}\n',
			'cp1/p/Shared.hx' => 'package p;\n\nclass Shared {}\n',
			'p/Over.hx' => 'package p;\n\nclass Over extends Shared {\n\tfunction run():Void {}\n}\n'
		]);
		Assert.isTrue(index.members.supertypesDeclareNone('Plain', 'run'), 'an unread superclass: reached only by an override');
		Assert.isFalse(index.members.supertypesDeclareNone('Iface', 'run'), 'an unread interface may declare it');
		Assert.isFalse(index.members.supertypesDeclareNone('Kid', 'run'), 'a superclass declaring it');
		Assert.isFalse(index.members.supertypesDeclareNone('Over', 'run'), 'a link naming two declarations of one module');
	}

	private static function indexOf(files: Map<String, String>): SymbolIndex {
		final entries: Array<{ file: String, source: String }> = [for (file => source in files) { file: file, source: source }];
		entries.sort((a, b) -> Reflect.compare(a.file, b.file));
		return CheckFixture.index(entries, new HaxeQueryPlugin());
	}

	private static function sorted(names: Array<String>): Array<String> {
		final out: Array<String> = names.copy();
		out.sort(Reflect.compare);
		return out;
	}

}
