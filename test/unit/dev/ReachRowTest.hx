package unit.dev;

import anyparse.query.format.json.CodeGraphJson;
import dev.ArmRegistry.ArmRecord;
import dev.GateArms.ModuleTouch;
import dev.ReachRow;
import dev.SliceGate;
import devkit.Cmd.cmd;
import devkit.Summary;
import sys.FileSystem;
import sys.io.File;

using StringTools;
using Lambda;

/** `dev.ReachRow`: the slice gate's `reach` row, which holds each function a slice adds or changes to a test, an arm or a pinned caller. */
@:nullSafety(Strict)
final class ReachRowTest extends Test {

	private static final OUTLINE: String = [
		'10-80  ClassForm:Foo  final class Foo',
		'12-12    FinalMember:LIMIT  public static final LIMIT: Int = 3',
		'14-20    FnMember:new  public function new()',
		'22-30    FnMember:run  public function run(): Void',
		'32-40    FnMember:help  private function help(): Void',
		'82-90  ClassForm:Side  final class Side',
		'84-86    FnMember:go  function go(): Void',
		''
	].join('\n');

	@:pin('control')
	@:killer('M-REACH-OPEN-PASSES')
	public function testAFunctionNothingReachesIsRedAndTheVerdictNamesIt(): Void {
		final verdict: Outcome = ReachRow.verdict(['pk.Foo.run', 'pk.Foo.help'], []);
		switch verdict {
			case Failed(why):
				Assert.stringContains('pk.Foo.run', why);
				Assert.stringContains('pk.Foo.help', why);
				Assert.stringContains(ReachRow.DECLARATION, why);
			case _:
				Assert.fail('open functions must fail: $verdict');
		}
		Assert.isTrue(ReachRow.verdict([], []).match(Passed));
	}

	@:pin('control')
	@:killer('M-REACH-EXEMPT-BLIND')
	public function testADeclaredNameCoversTheFunctionsItNamesAndNoOther(): Void {
		Assert.isTrue(ReachRow.verdict(['pk.Foo.run'], ['Foo.run']).match(Passed));
		Assert.isTrue(ReachRow.verdict(['pk.Foo.run', 'pk.Foo.help'], ['pk.Foo']).match(Passed));
		Assert.isTrue(ReachRow.verdict(['pk.Foo.run', 'pk.Foo.help'], ['Foo.run']).match(Failed(_)));
		Assert.isTrue(ReachRow.verdict(['pk.Foo.run'], ['Fo']).match(Failed(_)));
		Assert.isTrue(ReachRow.verdict(['pk.Foo.run'], ['run']).match(Passed));
	}

	@:pin('control')
	@:killer('M-REACH-DIRECT-IGNORED')
	public function testAFunctionAPinReachesIsGreen(): Void {
		Assert.same([], ReachRow.open(['pk.Foo.run'], name -> name == 'pk.Foo.run', [], ReachRow.DEPTH));
	}

	@:pin('control')
	@:killer('M-REACH-EVERY-SEED-REACHED')
	public function testANewBranchNothingPinsIsRed(): Void {
		final callers: Map<String, Array<String>> = ['pk.Foo.help' => ['pk.Foo.run']];
		Assert.same(['pk.Foo.run', 'pk.Foo.help'], ReachRow.open(['pk.Foo.run', 'pk.Foo.help'], _ -> false, callers, ReachRow.DEPTH));
		Assert.same(['pk.Foo.help'], ReachRow.open(['pk.Foo.run', 'pk.Foo.help'], name -> name == 'pk.Foo.run', [], ReachRow.DEPTH));
	}

	@:pin('control')
	@:killer('M-REACH-NO-CLIMB')
	public function testAHelperIsReachedThroughAPinnedCaller(): Void {
		final callers: Map<String, Array<String>> = ['pk.Foo.help' => ['pk.Foo.mid'], 'pk.Foo.mid' => ['pk.Foo.run']];
		Assert.same([], ReachRow.open(['pk.Foo.help'], name -> name == 'pk.Foo.run', callers, ReachRow.DEPTH));
	}

	@:pin('control')
	@:killer('M-REACH-DEPTH-UNBOUNDED')
	public function testAChainLongerThanTheDepthIsNotFollowed(): Void {
		final callers: Map<String, Array<String>> = ['a.A.f0' => ['a.A.f1'], 'a.A.f1' => ['a.A.f2'], 'a.A.f2' => ['a.A.f3']];
		final pinned: String -> Bool = name -> name == 'a.A.f3';
		Assert.same([], ReachRow.open(['a.A.f0'], pinned, callers, 3));
		Assert.same(['a.A.f0'], ReachRow.open(['a.A.f0'], pinned, callers, 2));
	}

	public function testACycleOfCallersEnds(): Void {
		final callers: Map<String, Array<String>> = ['a.A.f' => ['a.A.g'], 'a.A.g' => ['a.A.f']];
		Assert.same(['a.A.f'], ReachRow.open(['a.A.f'], _ -> false, callers, ReachRow.DEPTH));
	}

	@:pin('control')
	@:killer('M-REACH-CALLERS-REVERSED')
	public function testTheCallersOfAFunctionAreTheOnesAtTheSourceOfItsInEdges(): Void {
		final callers: Map<String, Array<String>> = ReachRow.callersOf(graph());
		Assert.same(['m.Caller.go'], callers['m.Callee.help']);
		Assert.isNull(callers['m.Caller.go']);
	}

	@:pin('control')
	@:killer('M-REACH-CONTAINS-IS-CALL')
	public function testAnEdgeThatHoldsIsNoCall(): Void {
		Assert.isNull(ReachRow.callersOf(graph())['m.Callee.inner']);
	}

	@:pin('control')
	@:killer('M-REACH-CONSTRUCTOR-READ')
	public function testTheOutlineGivesTheFunctionsOfEachTypeAsTheGraphNamesThem(): Void {
		Assert.same(['pk.Foo.run', 'pk.Foo.help', 'pk.Side.go'], ReachRow.functionsOf(OUTLINE, 'pk.Foo'));
		Assert.same(['Foo.run', 'Foo.help', 'Side.go'], ReachRow.functionsOf(OUTLINE, 'Foo'));
	}

	@:pin('control')
	@:killer('M-REACH-TOUCH-ALL')
	public function testOnlyTheFunctionsTheReportNamesAreSeeds(): Void {
		final functions: Array<String> = ReachRow.functionsOf(OUTLINE, 'pk.Foo');
		final touch: ModuleTouch = { module: 'pk.Foo', members: ['help', 'LIMIT'] };
		Assert.same(['pk.Foo.help'], ReachRow.seedsOf(touch, functions, false));
		Assert.same([], ReachRow.seedsOf({ module: 'pk.Foo', members: [] }, functions, true));
	}

	@:pin('control')
	@:killer('M-REACH-NEW-FILE-UNREAD')
	public function testANewModuleIsReadWholeAndOneTheReportCannotNameIsNot(): Void {
		final functions: Array<String> = ReachRow.functionsOf(OUTLINE, 'pk.Foo');
		final unnamed: ModuleTouch = { module: 'pk.Foo', members: null };
		Assert.same(functions, ReachRow.seedsOf(unnamed, functions, true));
		Assert.same([], ReachRow.seedsOf(unnamed, functions, false));
	}

	@:pin('control')
	@:killer('M-REACH-ARM-IGNORED')
	public function testAnArmNamesTheFunctionItCuts(): Void {
		final records: Array<ArmRecord> = [
			{ key: 'M-A', text: '{"name": "M-A", "type": "pk.Foo", "method": "run", "find": "a", "replace": "b"}' },
			{ key: 'M-B', text: '{"name": "M-B", "type": "pk.Foo.Side", "method": "go", "find": "a", "replace": "b"}' },
			{ key: 'M-C', text: '{"name": "M-C", "type": "pk.Foo", "find": "a", "replace": "b"}' }
		];
		Assert.same(['pk.Foo.run', 'pk.Side.go'], ReachRow.armed(records));
	}

	@:pin('control')
	@:killer('M-REACH-TEST-NAME-BLIND')
	public function testATestFileNamingTheTypeAndTheFunctionReachesIt(): Void {
		withRepo(repo -> {
			File.saveContent('$repo/test/FooTest.hx', 'class FooTest { function t() { new Foo().run(); } }\n');
			File.saveContent('$repo/test/arms.json', '{"type": "pk.Foo", "method": "help"}\n');
			Assert.isTrue(ReachRow.named(repo, 'pk.Foo.run'));
			Assert.isFalse(ReachRow.named(repo, 'pk.Foo.help'));
			Assert.isFalse(ReachRow.named(repo, 'pk.Bar.run'));
		});
	}

	@:pin('control')
	@:killer('M-REACH-TEST-NAME-ANY-FILE')
	public function testTheTypeAndTheFunctionMustLieInOneFile(): Void {
		withRepo(repo -> {
			File.saveContent('$repo/test/OneTest.hx', 'class OneTest { var x: Foo; }\n');
			File.saveContent('$repo/test/TwoTest.hx', 'class TwoTest { function t() { help(); } }\n');
			Assert.isFalse(ReachRow.named(repo, 'pk.Foo.help'));
		});
	}

	@:pin('control')
	@:killer('M-REACH-TEST-FILE-READ')
	public function testOnlyASourceFileOfTheLibraryOrTheToolsReachesTheRow(): Void {
		Assert.isTrue(ReachRow.reached(['src/a/B.hx']));
		Assert.isTrue(ReachRow.reached(['docs/x.md', 'tools/src/dev/C.hx']));
		Assert.isFalse(ReachRow.reached(['test/unit/a/BTest.hx', 'docs/x.md', 'src/a/notes.md']));
	}

	@:pin('control')
	@:killer('M-REACH-DECLARATION-IN-LOGS')
	public function testTheDeclarationLiesBesideTheGateLogsDirectory(): Void {
		Assert.equals('/w-logs/${ReachRow.DECLARATION}', ReachRow.declaration('/w-logs/slice-gate/'));
	}

	@:pin('guard')
	public function testTheGateRunsTheRowInABranch(): Void {
		Assert.isTrue(SliceGate.GATE_BRANCHES.exists(rows -> rows.contains('reach')));
	}

	@:pin('control')
	@:killer('M-REACH-FILE-BLIND')
	public function testTheFileOfAModuleIsTheTouchedSourceFileThatHoldsIt(): Void {
		final touched: Array<String> = ['docs/x.md', 'tools/src/dev/Foo.hx', 'src/pk/Bar.hx'];
		Assert.equals('tools/src/dev/Foo.hx', ReachRow.fileOf('dev.Foo', touched));
		Assert.equals('src/pk/Bar.hx', ReachRow.fileOf('pk.Bar', touched));
		Assert.isNull(ReachRow.fileOf('pk.Baz', touched));
		Assert.isNull(ReachRow.fileOf('pk.Foo', touched));
	}

	@:pin('control')
	@:killer('M-REACH-ENTRY-POINT-REACHES')
	public function testAChainThatEndsOnlyAtAnEntryPointMainIsRed(): Void {
		withRepo(repo -> {
			File.saveContent('$repo/test/FooTest.hx', 'class FooTest { function t() { Foo.main(); } }\n');
			Assert.isFalse(ReachRow.named(repo, 'pk.Foo.main'));
			final callers: Map<String, Array<String>> = ['pk.Foo.wire' => ['pk.Foo.main']];
			Assert.same(['pk.Foo.wire'], ReachRow.open(['pk.Foo.wire'], name -> ReachRow.named(repo, name), callers, ReachRow.DEPTH));
		});
	}

	private static function graph(): CodeGraphJson {
		return {
			nodes: [
				{
					id: 'm_go',
					level: 'member',
					name: 'm.Caller.go',
					label: 'go',
					external: false,
					focus: false
				},
				{
					id: 'm_help',
					level: 'member',
					name: 'm.Callee.help',
					label: 'help',
					external: false,
					focus: false
				},
				{
					id: 'm_inner',
					level: 'member',
					name: 'm.Callee.inner',
					label: 'inner',
					external: false,
					focus: false
				},
				{
					id: 't_Callee',
					level: 'type',
					name: 'm.Callee',
					label: 'Callee',
					external: false,
					focus: false
				}
			],
			edges: [
				{
					from: 'm_go',
					to: 'm_help',
					kind: 'call',
					weight: 1
				},
				{
					from: 'm_help',
					to: 'm_inner',
					kind: 'contains',
					weight: 1
				},
				{
					from: 't_Callee',
					to: 'm_help',
					kind: 'call',
					weight: 1
				}
			]
		};
	}

	/** A git repository with an empty `test` directory. */
	private static function withRepo(body: (repo: String) -> Void): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory('$repo/test');
			cmd('git -C $repo init -q -b main').run().check();
			body(repo);
		});
	}

}
