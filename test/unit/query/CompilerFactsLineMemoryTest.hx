package unit.query;

import anyparse.query.CompilerFacts;

using StringTools;

/**
 * `CompilerFacts` keeps a node line in the memory its text needs: a dump holding one character outside Latin-1 is
 * read as a two-byte string, and a line cut from it must not keep that width.
 */
@:nullSafety(Strict)
class CompilerFactsLineMemoryTest extends Test {

	/** How many node lines the dump holds. */
	private static inline final LINES: Int = 10000;

	/** The padding that sizes each node line. */
	private static inline final PAD: Int = 2000;

	/** The live heap the table may hold per character of its node lines. */
	private static inline final MAX_BYTES_PER_CHAR: Float = 1.5;

	@:pin('control')
	@:killer('M-FACT-LINE-NARROWED')
	public function testANodeLineCutFromATwoByteDumpIsKeptAtOneBytePerCharacter(): Void {
		#if nodejs
		final gc: () -> Void = js.Syntax.code("(require('v8').setFlagsFromString('--expose-gc'), require('vm').runInNewContext('gc'))");
		gc();
		gc();
		final before: Float = heapUsed();
		final chars: Array<Int> = [0];
		final facts: CompilerFacts = table(chars);
		gc();
		gc();
		final grown: Float = heapUsed() - before;
		Assert.equals(1, facts.configurations.length);
		Assert.isTrue(
			grown < chars[0] * MAX_BYTES_PER_CHAR, 'the table holds ${Math.round(grown)} bytes for ${chars[0]} characters of node lines'
		);
		#else
		Assert.pass();
		#end
	}

	@:pin('control')
	@:killer('M-FACT-LINE-LATIN1-KEPT')
	public function testANodeLineHoldingLatin1CharactersAboveAsciiReadsBackUnchanged(): Void {
		// the narrowed copy is a byte per character: a character in 0x80-0xff must come back as itself, never re-decoded
		final source: String = 'class A { function f() g(); }';
		final latin: String = '{"k":"node","id":"A.f","f":"A.hx","p":[10,27],"kind":"method","owner":"A","t":"(café:Ä)->Void"}';
		final wide: String = '{"k":"node","id":"A.g","f":"A.hx","p":[10,27],"kind":"method","owner":"A","t":"()->Void —"}';
		final text: String = '{"k":"facts","v":1,"inline":true}\n$latin\n$wide\n{"k":"end","nodes":2,"types":0}\n';
		final facts: CompilerFacts = CompilerFacts.build(
			[{ name: 'one', text: text, file: path -> path }], file -> file == 'A.hx' ? source : null, file -> file
		);
		Assert.equals('(café:Ä)->Void', facts.node('A.f')?.signature);
		Assert.equals('()->Void —', facts.node('A.g')?.signature);
	}

	/** A table over one dump of `LINES` node lines, one of them holding a character outside Latin-1; `chars[0]` counts their characters. */
	private static function table(chars: Array<Int>): CompilerFacts {
		final pad: String = ''.lpad('x', PAD);
		final text: StringBuf = new StringBuf();
		text.add('{"k":"facts","v":1,"inline":true}\n');
		for (i in 0...LINES) {
			final mark: String = i == 0 ? '—' : 'x';
			final line: String = '{"k":"node","id":"A.f$i","f":"A.hx","p":[${i * 10},${i * 10 + 5}],"kind":"method","owner":"A",'
				+ '"t":"()->Void","pad":"$mark$pad"}';
			chars[0] += line.length;
			text.add(line);
			text.add('\n');
		}
		text.add('{"k":"end","nodes":$LINES,"types":0}\n');
		return CompilerFacts.build([{ name: 'one', text: text.toString(), file: path -> path }], file -> null, file -> file);
	}

	#if nodejs
	/** The live heap of this process, in bytes. */
	private static function heapUsed(): Float {
		return js.Syntax.code('process.memoryUsage().heapUsed');
	}
	#end

}
