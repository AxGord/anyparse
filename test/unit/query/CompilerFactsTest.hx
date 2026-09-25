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

	private static function table(text: String): CompilerFacts {
		return CompilerFacts.build([{ name: 'one', text: text, file: path -> path }], file -> file == 'A.hx' ? SOURCE : null, file -> file);
	}

}
