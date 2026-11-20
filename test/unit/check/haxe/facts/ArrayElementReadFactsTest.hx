package unit.check.haxe.facts;

/**
 * The facts of a build for an array member read through a local: a target lowers the read of an element to its own
 * spelling (`Array.__get`, `cpp.NativeArray.unsafeGet`), and the walk reports it as an index read, never as a call of the
 * array or as the array handed on.
 */
@:nullSafety(Strict)
class ArrayElementReadFactsTest extends Test {

	private static inline final CPP_BUILD: String = '-cp .\n-main Main\n-D analyzer-optimize\n-cpp out\n';
	private static inline final JVM_BUILD: String = '-cp .\n-main Main\n-D analyzer-optimize\n--jvm out.jar\n';

	/** A method reading `items` through the local `xs`, by a loop, an index and the inlined `map`, and a method handing `xs` on. */
	private static inline final SOURCE: String = 'class Main {\n\tpublic var items:Array<Main> = [];\n\tpublic function new() {}\n'
		+ '\tfunction step():Int {\n\t\tfinal xs:Array<Main> = items;\n\t\tvar n:Int = 0;\n\t\tfor (x in xs) n += x.items.length;\n'
		+ '\t\tfinal first:Main = xs[0];\n\t\tfinal ys:Array<Main> = xs.map(m -> m);\n\t\treturn n + ys.length + (first == null ? 0 : 1);\n\t}\n'
		+ '\tfunction hand():Void {\n\t\tfinal xs:Array<Main> = items;\n\t\tkeep(xs);\n\t}\n'
		+ '\tstatic function keep(a:Array<Main>):Void {}\n\tstatic function main() new Main().step();\n}\n';

	@:pin('control')
	@:killer('M-FACTS-ARRAY-ELEMENT-FUNCTION')
	public function testAnElementReadThroughAStaticFunctionOfTheTargetIsAnIndexRead(): Void {
		// hxcpp reads the element of a loop over a local through `cpp.NativeArray.unsafeGet`, which takes the array first
		final uses: Array<String> = usesOf(CPP_BUILD, 'step');
		Assert.equals(0, uses.filter(u -> u.contains('unsafeGet')).length, 'the array is handed to the read: $uses');
		Assert.isTrue(uses.contains('index'), 'no index read: $uses');
	}

	@:pin('control')
	@:killer('M-FACTS-ARRAY-ELEMENT-METHOD')
	public function testAnElementReadThroughAMethodOfTheArrayIsAnIndexRead(): Void {
		// the jvm target reads the element of a loop over a local through `Array.__get`
		final uses: Array<String> = usesOf(JVM_BUILD, 'step');
		Assert.isFalse(uses.contains('call:__get'), 'the array is called: $uses');
		Assert.isTrue(uses.contains('index'), 'no index read: $uses');
	}

	@:pin('control')
	@:killer('M-FACTS-ARRAY-ELEMENT-FUNCTION-ANY')
	public function testAnArrayHandedToAnyOtherFunctionStaysHanded(): Void {
		for (build in [CPP_BUILD, JVM_BUILD]) {
			final uses: Array<String> = usesOf(build, 'hand');
			Assert.isTrue(uses.contains('value(Main.keep)'), 'the argument is not handed: $uses');
		}
	}

	/** The uses of the member `items` the facts of `build` record in the method `method`, each with the method or argument it names. */
	private static function usesOf(build: String, method: String): Array<String> {
		final dir: String = CliFixture.writeTree(
			'array_element', [{ name: 'Main.hx', source: SOURCE }, { name: 'build.hxml', source: build }]
		);
		final oracles: Array<OracleConfig> = [{ hxml: 'build.hxml', dir: dir, defines: [] }];
		final node: Null<FactNode> = TypedFactsProbe.probeAll(oracles)?.node('Main.$method');
		final uses: Array<String> = [
			for (f in node?.fields ?? [])
				if (f.field == 'items' && !f.write)
					f.use + (f.method == null ? '' : ':${f.method}') + (f.argument == null ? '' : '(${f.argument.target})')
		];
		CliFixture.removeDir(dir);
		return uses;
	}

}
