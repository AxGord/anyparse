package unit.query;

import anyparse.query.CompilerFacts;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/** `CompilerFacts` over hand-written facts files: what a dump must hold to count, and positions in another file. */
@:nullSafety(Strict)
class CompilerFactsTest extends Test {

	private static final SOURCE: String = 'class A { function f() g(); }';

	@:pin('control') @:killer('M-FACTS-INCOMPLETE')
	public function testADumpWithoutItsClosingRecordContributesNothing(): Void {
		// a compile that died while writing leaves a prefix that parses line by line: it must not read as the whole build
		final node: String = '{"k":"node","id":"A.f","f":"A.hx","p":[10,27],"kind":"method","owner":"A","t":"()->Void",'
			+ '"calls":[{"t":"A.g","a":"FInstance","r":"A","rp":[23,24],"rt":"Void","p":[23,26]}]}';
		final complete: String = '{"k":"facts","v":1,"inline":true}\n$node\n{"k":"end","nodes":1,"types":0}\n';
		final cut: String = '{"k":"facts","v":1,"inline":true}\n$node\n';
		Assert.equals(1, table(complete).callsAt('A.hx', new Span(23, 26)).length);
		Assert.equals(0, table(cut).configurations.length);
		Assert.isNull(table(cut).node('A.f'));
	}

	@:pin('control') @:killer('M-FACTS-RECORD-KIND')
	public function testADumpHoldingARecordNoReaderKnowsContributesNothing(): Void {
		// the records a facts file holds are a closed list: one of a kind this reader does not know may say what a fact it
		// does read leaves out, so the whole file is of another version and the configuration is dropped, saying why
		final node: String = '{"k":"node","id":"A.f","f":"A.hx","p":[10,27],"kind":"method","owner":"A","t":"()->Void",'
			+ '"calls":[{"t":"A.g","a":"FInstance","r":"A","rp":[23,24],"rt":"Void","p":[23,26]}]}';
		function dump(extra: String): String {
			return '{"k":"facts","v":1,"inline":true}\n$node\n$extra{"k":"end","nodes":1,"types":0}\n';
		}
		Assert.equals(1, table(dump('')).configurations.length);
		final grown: CompilerFacts = table(dump('{"k":"future","id":"A.f"}\n'));
		Assert.equals(0, grown.configurations.length);
		Assert.isNull(grown.node('A.f'));
		Assert.same(
			[
				'one: its facts file holds a record of the kind `future`, which no reader here knows'
			],
			[
				for (d in grown.dropped) '${d.name}: ${d.reason}'
			]
		);
	}

	public function testAForeignPositionResolvesThroughItsDumpsFileTable(): Void {
		// code inlined from another file carries that file's index; two dumps may number their files differently
		final other: String = 'class B {}';
		final dump: String = '{"k":"facts","v":1,"inline":true}\n{"k":"file","i":0,"path":"B.hx"}\n'
			+ '{"k":"node","id":"A.f","f":"A.hx","p":[10,27],"kind":"method","owner":"A","t":"()->Void","vars":[{"n":"x","t":"Int","p":[0,6,7]}]}\n'
			+ '{"k":"end","nodes":1,"types":0}\n';
		final facts: CompilerFacts = CompilerFacts.build(
			[{ name: 'one', text: dump, file: path -> path }],
			file -> file == 'A.hx' ? SOURCE : file == 'B.hx' ? other : null, file -> file
		);
		final at: Null<FactPos> = facts.node('A.f')?.vars[0]?.at;
		Assert.equals('B.hx', at?.file);
		Assert.equals(6, at?.span.from);
	}

	@:pin('control') @:killer('M-FACTS-SPLICE-SITES-MET') @:killer('M-FACTS-SPLICE-UNATTRIBUTED') @:killer('M-FACTS-SPLICE-HARMLESS')
	@:killer('M-FACTS-SPLICE-INNERMOST') @:killer('M-FACTS-SPLICE-SECOND-SITE')
	public function testASplicedFactRunsAtTheSitesOfTheCallThatSplicedItIn(): Void {
		// `f` inlines `B.i` at `g();` and at `h();`, and `B.j`, whose declared range lies in `B.i`'s, at `k();`: code of `B.j`'s
		// body is `B.j`'s, run at `k();` alone. A fact no declared range holds may run anywhere in `f`, and one a method that
		// runs no project code spliced in is none of `f`'s
		final a: String = 'class A { function f() { g(); h(); k(); } }';
		final b: String = 'class B { inline function i() { x(); inline function j() { y(); } } }';
		final c: String = 'class C {}';
		function at(text: String, part: String): String {
			final from: Int = text.indexOf(part);
			return '$from,${from + part.length}';
		}
		final body: String = at(a, '{ g(); h(); k(); }');
		final iRoot: String = at(b, '{ x();');
		final iDeclared: String = at(b, 'inline function i() { x(); inline function j() { y(); } }');
		final jRoot: String = at(b, '{ y(); }');
		final jDeclared: String = at(b, 'inline function j() { y(); }');
		final g: String = at(a, 'g();');
		final h: String = at(a, 'h();');
		final k: String = at(a, 'k();');
		final x: String = at(b, 'x()');
		final y: String = at(b, 'y()');
		final inC: String = at(c, 'C');
		final dump: String = '{"k":"facts","v":1,"inline":true}\n{"k":"file","i":0,"path":"B.hx"}\n{"k":"file","i":1,"path":"C.hx"}\n'
			+ '{"k":"node","id":"A.f","f":"A.hx","p":[$body],"kind":"method","owner":"A","t":"()->Void","inc":["inline-site-unknown"],'
			+ '"calls":[{"t":"B.i","a":"inlined","rt":"Void","p":[0,$iRoot],"s":[$g],"d":[0,$iDeclared]},'
			+ '{"t":"B.i","a":"inlined","rt":"Void","p":[0,$iRoot],"s":[$h],"d":[0,$iDeclared]},'
			+ '{"t":"B.j","a":"inlined","rt":"Void","p":[0,$jRoot],"s":[$k],"d":[0,$jDeclared]}],'
			+ '"native":[{"w":"syntax","n":"x","p":[0,$x]},{"w":"syntax","n":"y","p":[0,$y]},'
			+ '{"w":"syntax","n":"c","p":[1,$inC]}]}\n{"k":"end","nodes":1,"types":0}\n';
		final facts: CompilerFacts = CompilerFacts.build(
			[{ name: 'one', text: dump, file: path -> path }],
			file -> file == 'A.hx' ? a : file == 'B.hx' ? b : file == 'C.hx' ? c : null, file -> file
		);
		function natives(part: String, ?harmless: (callee:String) -> Bool): Array<String> {
			final from: Int = a.lastIndexOf(part);
			final span: Span = new Span(from, from + part.length);
			final found: Null<Array<NativeFact>> = facts.within('A.hx', span, n -> n.natives, n -> n.at, true, harmless);
			return found == null ? ['null'] : [for (n in found) n.name];
		}
		Assert.same(['x', 'c'], natives('g();'));
		Assert.same(['x', 'c'], natives('h();'));
		Assert.same(['c'], natives(' } }'));
		Assert.same(['y', 'c'], natives('k();'));
		Assert.same(['c'], natives('g();', callee -> callee == 'B.i'));
		Assert.isNull(facts.within('A.hx', new Span(a.indexOf('g();'), a.indexOf('h();')), n -> n.natives, n -> n.at));
	}

	private static function table(text: String): CompilerFacts {
		return CompilerFacts.build([{ name: 'one', text: text, file: path -> path }], file -> file == 'A.hx' ? SOURCE : null, file -> file);
	}

}
