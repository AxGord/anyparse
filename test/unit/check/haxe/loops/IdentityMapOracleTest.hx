package unit.check.haxe.loops;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.FixVerifier;
import anyparse.check.haxe.loops.IdentityMap;
import anyparse.check.haxe.oracle.CompilerOracle;
import unit.cli.CliFixture;

/**
 * `identity-map` under the compiler oracle: its rewrite stands where the compiler accepts it. A map that only widens an
 * enum abstract's element type to `Null<E>` is the array ascribed; the same ascription over an abstract that converts
 * through `@:to`, or a subclass widened to its base, does not unify, so it is reverted to a finding.
 *
 * Each scenario spawns the real compiler and skips (`Assert.pass`) when the host has no `haxe`.
 */
@:nullSafety(Strict)
final class IdentityMapOracleTest extends Test {

	private static final HXML: String = '-cp .\n-main Good\n';
	private static final ENUM_ABSTRACT: String = '@:nullSafety(Strict)\nenum abstract E(String) to String {\n\tvar A = "a";\n'
		+ '\tvar B = "b";\n\tpublic static final ALL:Array<E> = [A, B];\n}\n';

	/** An abstract whose `@:to` function builds the `String`, and a subclass: neither `Array` converts to the base's. */
	private static final CONVERSIONS: String = 'abstract W(String) {\n\tpublic function new(i:String) {\n\t\tthis = i;\n\t}\n\n'
		+ '\t@:to\n\tpublic function toStr():String {\n\t\treturn \'w\' + this;\n\t}\n}\n\nclass P {}\n\n'
		+ 'class Q extends P {\n\tpublic function new() {}\n}\n';

	/** The line's own fixture: the identity to `Null<E>` followed by `concat` is the ascribed array followed by `concat`. */
	@:pin('control')
	@:killer('M-IM-NO-FIX')
	public function testWideningToNullEnumAbstractIsRewritten(): Void {
		final done: Null<Outcome> = rewritten('final rows:Array<Null<E>> = E.ALL.map(x -> (x : Null<E>)).concat([null]);');
		if (done == null) return;
		Assert.equals(1, done.applied);
		Assert.stringContains('final rows:Array<Null<E>> = (E.ALL : Array<Null<E>>).concat([null]);', done.text);
	}

	public function testWideningComprehensionIsRewrittenWithACopy(): Void {
		final done: Null<Outcome> = rewritten('final rows:Array<Null<E>> = [for (x in E.ALL) (x : Null<E>)];');
		if (done == null) return;
		Assert.stringContains('final rows:Array<Null<E>> = (E.ALL : Array<Null<E>>).copy();', done.text);
	}

	public function testBareMapIsRewrittenToCopy(): Void {
		final done: Null<Outcome> = rewritten('final rows:Array<E> = E.ALL.map(x -> x);');
		if (done == null) return;
		Assert.stringContains('final rows:Array<E> = E.ALL.copy();', done.text);
	}

	/** An abstract converting through `@:to`, and a subclass widened to its base, do not unify as arrays: the oracle reverts both. */
	@:pin('guard')
	public function testConversionAndUpcastAreKeptAsWritten(): Void {
		for (statement in [
			'final ws:Array<W> = [new W(\'1\')];\n\t\tfinal rows:Array<String> = ws.map(w -> (w : String));',
			'final qs:Array<Q> = [new Q()];\n\t\tfinal rows:Array<P> = qs.map(q -> (q : P));'
		]) {
			final done: Null<Outcome> = rewritten(statement, CONVERSIONS);
			if (done == null) return;
			Assert.equals(1, done.reverted, 'the oracle took the edit back');
			Assert.equals(0, done.applied);
			Assert.stringContains(statement, done.text);
		}
	}

	/**
	 * Runs `identity-map` over a `Good` class holding `statement` through `FixVerifier` and returns the file as left on disk,
	 * or null when no compiler is available.
	 */
	private function rewritten(statement: String, prelude: String = ''): Null<Outcome> {
		#if (sys || nodejs)
		final main: String =
			'${prelude == '' ? ENUM_ABSTRACT : prelude}\n@:nullSafety(Strict)\nclass Good {\n\tstatic function main() {\n\t\t$statement\n\t\ttrace(rows);\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('identity-map', [{ name: 'Good.hx', source: main }, { name: 'check.hxml', source: HXML }]);
		final path: String = '$dir/Good.hx';
		final available: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		if (!available) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return null;
		}
		final verified: FixVerifyResult = FixVerifier.verify(
			[{ file: path, source: main }], [new IdentityMap()],
			new HaxeQueryPlugin(), [{ hxml: 'check.hxml', dir: dir, defines: [] }], (p, c) -> File.saveContent(p, c)
		);
		final onDisk: String = File.getContent(path);
		CliFixture.removeDir(dir);
		return { text: onDisk, applied: verified.applied.length, reverted: verified.reverted.length };
		#else
		Assert.pass('non-sys target');
		return null;
		#end
	}

}

/** What `FixVerifier` left of a fixture: the file as it stands and how many edits the compiler let through or took back. */
private typedef Outcome = { final text: String; final applied: Int; final reverted: Int; };
