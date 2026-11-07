package unit.check.oracle;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.oracle.CompilerDisplayOracle.TypeReplyPosition;
import anyparse.check.oracle.CompilerNameProof;
import anyparse.check.oracle.OracleRunMemo;
import anyparse.check.oracle.OracleServerPool;
import anyparse.query.EditJournal;
import anyparse.query.OracleProvider.UsableCoverage;
import anyparse.runtime.Span;

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
	/** A consumer declaring its own `F` below the name that reads it. */
	private static final OWN_SOURCE: String = 'package a.b;\n\nclass Main {\n\tstatic function main() {\n\t\ttrace(F.make());\n\t}\n}\n\n'
		+ 'class F {\n\tpublic static function make():String {\n\t\treturn \'own\';\n\t}\n}\n';

	/** What a rewrite puts above `OWN_SOURCE`, here before the package line so every offset moves by its length. */
	private static final OWN_ABOVE: String = '// moved\n// down\n';
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
	 * A display request handing in a text of `a.F` with no `make` leaves the next warm compile of `a.b.Main`, which calls
	 * `make`, reading the valid bytes on disk. A guard: the compiler keeps no module it typed from display-stdin, so
	 * `positionIn` marking the file moved is a second line of defence this fixture cannot tell apart from the first.
	 */
	@:pin('guard')
	public function testTheNextCompileReadsTheDiskNotTheTextHandedIn(): Void {
		#if (sys || nodejs)
		final broken: String = F_SOURCE.replace('make', 'gone');
		Assert.isTrue(pooled((pool, config, root) -> {
			final asked: Null<TypeReplyPosition> = pool.positionIn(config, '$root/a/F.hx', broken, broken.indexOf('gone'));
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
			proof.sameDeclarations('$root/a/b/Main.hx', MAIN_SOURCE, MAIN_SOURCE, [{ before: 0, after: 0 }], [])[0];
		}));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-NAME-PROOF-NO-ASK-AGREES')
	public function testNoConfigurationCompilingTheSiteIsNoAgreement(): Void {
		final proof: CompilerNameProof = new CompilerNameProof();
		Assert.same([false], proof.sameDeclarations('a/b/Main.hx', 'x', 'x', [{ before: 0, after: 0 }], []), 'no judges installed');
		proof.answerFor(() -> judgedBy([], []), new HaxeQueryPlugin());
		Assert.same(
			[false], proof.sameDeclarations('a/b/Main.hx', 'x', 'x', [{ before: 0, after: 0 }], []), 'judges, none compiling the site'
		);
	}

	/** An import above the rewritten site: the local `F` it names moves down with the text and is still that `F`. */
	@:pin('control')
	@:killer('M-NAME-PROOF-RAW-POSITIONS')
	public function testADeclarationInTheEditedFileMovesWithTheRewrite(): Void {
		#if (sys || nodejs)
		final inserted: Int = OWN_ABOVE.length;
		final at: Int = OWN_SOURCE.indexOf('F.make');
		final above: String = OWN_ABOVE + OWN_SOURCE;
		final verdicts: Array<Bool> = [];
		Assert.isTrue(pooledOver(OWN_SOURCE, (pool, config, root) -> {
			final proof: CompilerNameProof = new CompilerNameProof();
			proof.answerFor(() -> judgedBy([], [config]), new HaxeQueryPlugin());
			for (verdict in proof.sameDeclarations('$root/a/b/Main.hx', OWN_SOURCE, above, [
				{ before: at, after: at + inserted },
				{ before: at, after: above.indexOf('trace') }
			], [{ span: new Span(0, 0), text: OWN_ABOVE }])) verdicts.push(verdict);
			true;
		}));
		Assert.same([true, false], verdicts);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `F` of `class F {}`, at one place in both texts, and the rewrite replaced it: nothing says it is the same declaration. */
	@:pin('control')
	@:killer('M-NAME-PROOF-RAW-POSITIONS')
	public function testAnAnswerWhoseSpanMeetsAnEditDeclines(): Void {
		final was: TypeReplyPosition = {
			file: 'a/b/Main.hx',
			line: 1,
			first: 7,
			last: 8,
			byLine: false
		};
		final journal: EditJournal = new EditJournal();
		journal.record('class F {}\n', [{ span: new Span(6, 7), text: 'G' }], 'class G {}\n');
		Assert.isFalse(CompilerNameProof.namesOnePlace(was, Reflect.copy(was), 'a/b/Main.hx', 'class F {}\n', 'class G {}\n', journal));
	}

	/** A declaration in another file does not move with the rewrite, so only the raw place counts. */
	@:pin('control')
	@:killer('M-NAME-PROOF-EVERY-ANSWER-CARRIED')
	public function testAnAnswerInAnotherFileComparesRaw(): Void {
		final there: TypeReplyPosition = {
			file: 'elsewhere/F.hx',
			line: 3,
			first: 7,
			last: 8,
			byLine: false
		};
		final moved: TypeReplyPosition = {
			file: 'elsewhere/F.hx',
			line: 4,
			first: 7,
			last: 8,
			byLine: false
		};
		final before: String = 'x\n\n\n';
		final after: String = 'y\nx\n\n\n';
		final journal: EditJournal = new EditJournal();
		journal.record(before, [{ span: new Span(0, 0), text: 'y\n' }], after);
		Assert.same([true, false], [
			CompilerNameProof.namesOnePlace(there, Reflect.copy(there), 'a/b/Main.hx', before, after, journal),
			CompilerNameProof.namesOnePlace(there, moved, 'a/b/Main.hx', before, after, journal)
		]);
	}

	/** A reply by whole lines names no span to carry back, so only the raw place counts. */
	@:pin('control')
	@:killer('M-NAME-PROOF-EVERY-ANSWER-CARRIED')
	public function testAReplyByLinesComparesRaw(): Void {
		final lines: TypeReplyPosition = {
			file: 'a/b/Main.hx',
			line: 3,
			first: 3,
			last: 5,
			byLine: true
		};
		final before: String = 'x\n\n\n';
		final after: String = 'y\nx\n\n\n';
		final journal: EditJournal = new EditJournal();
		journal.record(before, [{ span: new Span(0, 0), text: 'y\n' }], after);
		Assert.isTrue(CompilerNameProof.namesOnePlace(lines, Reflect.copy(lines), 'a/b/Main.hx', before, after, journal));
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

	/** Two sites asked in one round: the short name still binds `a.F`, the second site's rewritten text names `trace` instead. */
	@:pin('control')
	@:killer('M-NAME-PROOF-FIRST-PAIR-FOR-EVERY-SITE')
	public function testEachSiteOfOneRoundGetsItsOwnVerdict(): Void {
		#if (sys || nodejs)
		final at: Int = MAIN_SOURCE.indexOf('F.make');
		final verdicts: Array<Bool> = [];
		Assert.isTrue(pooled((pool, config, root) -> {
			final proof: CompilerNameProof = new CompilerNameProof();
			proof.answerFor(() -> judgedBy([], [config]), new HaxeQueryPlugin());
			for (verdict in proof.sameDeclarations('$root/a/b/Main.hx', MAIN_SOURCE, SHORT_SOURCE, [
				{ before: at, after: SHORT_SOURCE.indexOf('F.make') },
				{ before: at, after: SHORT_SOURCE.indexOf('trace') }
			], [])) verdicts.push(verdict);
			true;
		}));
		Assert.same([true, false], verdicts);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * One round asks the same file at two texts in turn: one declaring its own `F`, one calling `a.F`. Each answer is read
	 * from its own text, so one drop of the cached module serves every ask.
	 */
	@:pin('control')
	@:killer('M-POOL-POSITIONS-FIRST-ASK-TEXT')
	public function testEachAskOfOneRoundIsReadAtItsOwnText(): Void {
		#if (sys || nodejs)
		final local: String = '$SHORT_SOURCE\nclass F {\n\tpublic static function make():String {\n\t\treturn \'b\';\n\t}\n}\n';
		final named: Array<String> = [];
		Assert.isTrue(pooled((pool, config, root) -> {
			final answers: Null<Array<Null<TypeReplyPosition>>> = pool.positionsIn([config], '$root/a/b/Main.hx', [
				[
					{ content: local, at: local.indexOf('F.make') },
					{ content: MAIN_SOURCE, at: MAIN_SOURCE.indexOf('F.make') },
					{ content: local, at: local.indexOf('F.make') }
				]
			])[0];
			for (answer in answers ?? []) named.push(answer == null ? 'none' : answer.file.endsWith('a/F.hx') ? 'a.F' : 'own');
			true;
		}));
		Assert.same(['own', 'a.F', 'own'], named);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Two configurations of one tree are asked in one round, and each answers its own asks. */
	@:pin('guard')
	public function testEveryConfigurationIsAskedInOneRound(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_name_proof_two', [
			{ name: 'a/F.hx', source: F_SOURCE },
			{ name: 'a/b/Main.hx', source: MAIN_SOURCE },
			{ name: 'build.hxml', source: '-cp .\n-main a.b.Main\n--no-output\n' },
			{ name: 'other.hxml', source: '-cp .\n-main a.b.Main\n--no-output\n-D other\n' }
		]);
		final memo: OracleRunMemo = new OracleRunMemo(false, () -> ['$root/a/F.hx', '$root/a/b/Main.hx']);
		final configs: Array<OracleConfig> = OracleRunMemo.attach([
			{ hxml: 'build.hxml', dir: root, defines: [] },
			{ hxml: 'other.hxml', dir: root, defines: [] }
		], memo);
		memo.servers.start(configs);
		final ask: PositionAsk = { content: SHORT_SOURCE, at: SHORT_SOURCE.indexOf('F.make') };
		final lines: Array<Null<Int>> = [
			for (answers in memo.servers.positionsIn(
				configs, '$root/a/b/Main.hx', [[ask], [ask, ask]]
			)) for (answer in answers ?? [null]) lineOf(answer)
		];
		memo.servers.stop();
		CliFixture.removeDir(root);
		Assert.same([3, 3, 3], lines);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-POOL-ASKS-NOT-INTERLEAVED')
	public function testEveryConfigurationsFirstAskComesBeforeAnySecond(): Void {
		final ask: PositionAsk = { content: '', at: 0 };
		Assert.same(
			[{ oracle: 0, ask: 0 }, { oracle: 2, ask: 0 }, { oracle: 0, ask: 1 }],
			OracleServerPool.interleaved([0, 2], [[ask, ask], [ask], [ask]])
		);
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
		return pooledOver(MAIN_SOURCE, ask);
	}

	/** `pooled`, over a tree whose `a.b.Main` is `main`. */
	private function pooledOver(main: String, ask: (OracleServerPool, OracleConfig, String) -> Bool): Bool {
		final root: String = CliFixture.writeTree('apq_name_proof', [
			{ name: 'a/F.hx', source: F_SOURCE },
			{ name: 'a/b/Main.hx', source: main },
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
