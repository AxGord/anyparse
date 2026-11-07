package unit.ds;

import anyparse.proc.ProcessRun;

/**
 * `anyparse.ds.Bits` where the suite does not run: the contract on the interpreter, whose bit scan is the portable one
 * rather than js's `clz32`, and the compile-time refusal of every domain that is not fixed.
 */
class BitsTargetsTest extends Test {

	private static final DOMAINS: String = 'enum Hue { Red; Green; Blue; }\nenum abstract Narrow(Int) { final Low = 0; final Next = 1; '
		+ fill('N', 2, 31)
		+ ' final Top = 31; }\nenum abstract Wide(Int) { final Low = 0; '
		+ fill('W', 1, 31)
		+ ' final Last = 31; final First = 32; '
		+ fill('W', 33, 63)
		+ ' final Top = 63; }\nenum abstract Sparse(Int) { final Zero = 0; final Far = 200000000; }\n'
		+ 'enum Arg { Plain; Carrying(value: Int); }\nenum abstract Named(String) { final A = "a"; }\n'
		+ 'enum abstract Shifted(Int) { final A = 1 << 2; }\nprivate enum Hidden { One; Two; }\n';

	public function testContractOnTheInterpreter(): Void {
		final run: Null<ProcessRun> = TargetCompile.compile(
			program(
				'\tstatic function main() {\n\t\tvar hues = new Bits<Hue>(); hues.add(Blue); hues.add(Red);\n'
				+ '\t\tvar narrow: Bits<Narrow> = Narrow.Top; narrow.add(Narrow.Low);\n'
				+ '\t\tvar wide: Bits<Wide> = [Wide.Top, Wide.First, Wide.Last, Wide.Low];\n'
				+ '\t\tfinal kept = wide; wide.remove(Wide.First);\n\t\tfinal sparse: Bits<Sparse> = Sparse.Far;\n\t\tSys.println([for ('
				+ 'v in hues) v] + " " + [for (v in ~hues) v] + " " + [for (v in narrow) v] + " " + [for (v in ~narrow) v].length);\n'
				+ '\t\tSys.println([for (v in wide) v] + " " + [for (v in kept) v] + " " + [for (v in ~wide) v].length + " " + ('
				+ 'wide | Wide.First == kept));\n\t\tSys.println([for (v in sparse) v] + " " + [for (v in ~sparse) v]);\n\t}\n'
			),
			['--interp']
		);
		if (run == null) return;
		Assert.equals(0, run.status, run.err);
		Assert.equals('[Red,Blue] [Green] [0,31] 30\n[0,31,63] [0,31,32,63] 61 true\n[200000000] [0]\n', run.out.split('\r').join(''));
	}

	/** A constructor with arguments has no single value for its bit to stand for. */
	@:pin('control')
	@:killer('M-DS-BITS-ARGUMENTS')
	public function testAConstructorWithArgumentsIsRefused(): Void {
		assertRefused('Arg', 'the constructor Carrying takes arguments');
	}

	public function testEveryOtherUnfixedDomainIsRefused(): Void {
		assertRefused('Int', 'the domain is not fixed');
		assertRefused('haxe.ds.Option<Int>', 'an enum with type parameters is not a fixed domain');
		assertRefused('Named', 'an enum abstract over anything but Int');
		assertRefused('Shifted', 'A is not a non-negative Int literal');
		assertRefused('Main.Hidden', 'a private type cannot be named outside its module');
	}

	/** A type parameter is no domain at all: what it stands for is decided by each caller. */
	public function testATypeParameterIsRefused(): Void {
		assertSourceRefused(
			program('\tstatic function main() f(1);\n\tstatic function f<T>(value: T) new Bits<T>();\n'), 'the domain is not fixed'
		);
	}

	/** A set is a value, so `add` on a `final` one is a reassignment the compiler refuses. */
	public function testAFinalSetCannotChange(): Void {
		assertSourceRefused(
			program('\tstatic function main() {\n\t\tfinal hues = new Bits<Hue>();\n\t\thues.add(Red);\n\t}\n'),
			'Cannot modify abstract value of final local'
		);
	}

	/** The declarations `final <prefix><value> = <value>;` for every value from `from` up to, not including, `to`. */
	private static function fill(prefix: String, from: Int, to: Int): String {
		return [for (value in from ... to) 'final $prefix$value = $value;'].join(' ');
	}

	/** A module declaring the test domains and a `Main` whose body is `body`. */
	private static function program(body: String): String {
		return 'import anyparse.ds.Bits;\n${DOMAINS}class Main {\n$body}\n';
	}

	private static function assertRefused(element: String, reason: String): Void {
		assertSourceRefused(program('\tstatic function main() new Bits<$element>();\n'), reason);
	}

	/** `source` fails to compile, and the compiler's message says `reason`. */
	private static function assertSourceRefused(source: String, reason: String): Void {
		final run: Null<ProcessRun> = TargetCompile.compile(source, ['--interp']);
		if (run == null) return;
		Assert.notEquals(0, run.status, reason);
		Assert.stringContains(reason, run.err, reason);
	}

}
