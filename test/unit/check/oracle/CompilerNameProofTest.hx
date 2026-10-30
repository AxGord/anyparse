package unit.check.oracle;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.oracle.CompilerDisplayOracle.TypeReplyPosition;
import anyparse.check.oracle.CompilerNameProof;
import anyparse.check.oracle.OracleCoverage.UsableCoverage;
import anyparse.check.oracle.OracleRunMemo;
import anyparse.check.oracle.OracleServerPool;

using StringTools;

/**
 * `OracleServerPool.positionIn` asks a configuration's warm server about a text that is not on disk, and
 * `CompilerNameProof` turns those answers into a verdict. The server is warmed by a full compile, so a text handed in is
 * read only once the cached module is dropped, and a path the run rewrote within the second the server last read it is
 * read afresh only because its CONTENT moved. No answer is never an agreement.
 */
final class CompilerNameProofTest extends Test {

	#if (sys || nodejs)
	private static final F_SOURCE: String =
		'package a;\n\nclass F {\n\tpublic static function make():String {\n\t\treturn \'a.F\';\n\t}\n}\n';
	private static final MAIN_SOURCE: String = 'package a.b;\n\nclass Main {\n\tstatic function main() {\n\t\ttrace(a.F.make());\n\t}\n}\n';

	/** The consumer as the rewrite would leave it: `F` alone, which only the handed-in text spells. */
	private static final SHORT_SOURCE: String = 'package a.b;\n\nclass Main {\n\tstatic function main() {\n\t\ttrace(F.make());\n\t}\n}\n';
	#end

	@:pin('control')
	@:killer('M-DISPLAY-STDIN-DROPPED')
	public function testTheTextHandedInIsTheOneAsked(): Void {
		#if (sys || nodejs)
		Assert.isTrue(pooled((pool, config, root) -> {
			final main: String = '$root/a/b/Main.hx';
			final was: Null<TypeReplyPosition> = pool.positionIn(config, main, MAIN_SOURCE, MAIN_SOURCE.indexOf('F.make'));
			was != null && CompilerNameProof.samePosition(was, pool.positionIn(config, main, SHORT_SOURCE, SHORT_SOURCE.indexOf('F.make')));
		}));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-DISPLAY-STDIN-NOT-INVALIDATED')
	public function testTheModuleTheWarmCompileCachedIsDroppedFirst(): Void {
		#if (sys || nodejs)
		Assert.isTrue(pooled(
			(pool, config, root) -> lineOf(pool.positionIn(config, '$root/a/b/Main.hx', SHORT_SOURCE, SHORT_SOURCE.indexOf('F.make'))) == 3
		));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `a/F.hx` gains two lines on disk with its modification time unchanged — a write inside the second the server read it. */
	@:pin('control')
	@:killer('M-POOL-POSITION-STALE-WRITES')
	public function testAPathWrittenInTheSameSecondIsReadAtItsNewText(): Void {
		#if (sys || nodejs)
		Assert.isTrue(pooled((pool, config, root) -> {
			final main: String = '$root/a/b/Main.hx';
			final at: Int = MAIN_SOURCE.indexOf('F.make');
			final first: Null<Int> = lineOf(pool.positionIn(config, main, MAIN_SOURCE, at));
			final f: String = '$root/a/F.hx';
			final stamp: Date = sys.FileSystem.stat(f).mtime;
			sys.io.File.saveContent(f, '// moved\n// down\n$F_SOURCE');
			js.node.Fs.utimesSync(f, stamp, stamp);
			first == 3 && lineOf(pool.positionIn(config, main, MAIN_SOURCE, at)) == 5;
		}));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A display request over a text that does not compile leaves the next warm compile reading the valid bytes on disk. A
	 * guard: the compiler keeps no module it typed from display-stdin, so `positionIn` marking the file moved is a second
	 * line of defence this fixture cannot tell apart from the first.
	 */
	@:pin('guard')
	public function testTheNextCompileReadsTheDiskNotTheTextHandedIn(): Void {
		#if (sys || nodejs)
		final broken: String = MAIN_SOURCE.replace('\t\ttrace(', '\t\tvar x:Int = \'s\';\n\t\ttrace(');
		Assert.isTrue(pooled((pool, config, root) -> {
			final asked: Null<TypeReplyPosition> = pool.positionIn(config, '$root/a/b/Main.hx', broken, broken.indexOf('F.make'));
			asked != null && pool.compile([config])[0]?.status == 0;
		}));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-NAME-PROOF-NO-ANSWER-AGREES')
	public function testANameTheCompilerDoesNotPlaceIsNoAgreement(): Void {
		#if (sys || nodejs)
		Assert.isFalse(pooled((pool, config, root) -> {
			final proof: CompilerNameProof = new CompilerNameProof();
			proof.answerFor(() -> judgedBy([], [config]), new HaxeQueryPlugin());
			proof.sameDeclaration('$root/a/b/Main.hx', MAIN_SOURCE, 0, MAIN_SOURCE, 0);
		}));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-NAME-PROOF-NO-ASK-AGREES')
	public function testNoConfigurationCompilingTheSiteIsNoAgreement(): Void {
		final proof: CompilerNameProof = new CompilerNameProof();
		Assert.isFalse(proof.sameDeclaration('a/b/Main.hx', 'x', 0, 'x', 0), 'no judges installed');
		proof.answerFor(() -> judgedBy([], []), new HaxeQueryPlugin());
		Assert.isFalse(proof.sameDeclaration('a/b/Main.hx', 'x', 0, 'x', 0), 'judges, none compiling the site');
	}

	@:pin('guard')
	public function testSamePositionNeedsBothAnswersAtOnePlace(): Void {
		final here: TypeReplyPosition = {
			file: 'a/F.hx',
			line: 3,
			first: 7,
			last: 8,
			byLine: false
		};
		final there: TypeReplyPosition = {
			file: 'a/F.hx',
			line: 4,
			first: 7,
			last: 8,
			byLine: false
		};
		Assert.same([true, false, false], [
			CompilerNameProof.samePosition(here, Reflect.copy(here)),
			CompilerNameProof.samePosition(here, there),
			CompilerNameProof.samePosition(here, null)
		]);
	}

	/** A coverage answer naming `known` configurations with no compiled set and `unknown` ones whose set is unknown. */
	private static function judgedBy(known: Array<OracleConfig>, unknown: Array<OracleConfig>): UsableCoverage {
		return {
			configs: known,
			coverages: [],
			unknown: unknown,
			excluded: [],
			stop: null
		};
	}

	#if (sys || nodejs)
	/**
	 * `ask`'s answer from the run pool of a configuration over a tree whose `a.b.Main` calls `a.F.make()`, both modules among
	 * the paths the run may write; the pool is stopped and the tree removed after.
	 */
	private function pooled(ask: (OracleServerPool, OracleConfig, String) -> Bool): Bool {
		final root: String = CliFixture.writeTree('apq_name_proof', [
			{ name: 'a/F.hx', source: F_SOURCE },
			{ name: 'a/b/Main.hx', source: MAIN_SOURCE },
			{ name: 'build.hxml', source: '-cp .\n-main a.b.Main\n--no-output\n' }
		]);
		final memo: OracleRunMemo = new OracleRunMemo(false, () -> ['$root/a/F.hx', '$root/a/b/Main.hx']);
		final config: OracleConfig = OracleRunMemo.attach([{ hxml: 'build.hxml', dir: root, defines: [] }], memo)[0];
		memo.servers.start([config]);
		Assert.isTrue(memo.servers.running(), 'a warm server comes up');
		final out: Bool = ask(memo.servers, config, root);
		memo.servers.stop();
		CliFixture.removeDir(root);
		return out;
	}

	/** The line a reply names, or null for no reply. */
	private static function lineOf(pos: Null<TypeReplyPosition>): Null<Int> {
		return pos?.line;
	}
	#end

}
