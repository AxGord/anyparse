package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
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
