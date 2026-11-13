package unit.check.haxe.members;

import anyparse.check.LintConfig;
import anyparse.check.haxe.facts.TypedFactsProbe;
import anyparse.check.haxe.members.UnusedEnumAbstractValue;
import anyparse.check.haxe.oracle.CompilerOracle;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.CompilerFacts;
import anyparse.util.Compare;
import haxe.io.Path;
import unit.cli.CliFixture;

using StringTools;

/**
 * `unused-enum-abstract-value` over a real compile's facts: a value is weighed by the type the compiler read it as, so a
 * bare name in a `case` or beside `==` keeps the value of the type the place expects and leaves a same-named value of
 * another type reported. A read in a conditional branch keeps the value whether a configuration compiled it or none
 * did; a type a value arrives into implicitly, a pinned one and one some code hands on as a value are not weighed. The
 * fix, off by default, removes a value only when it has its own initializer and no later value is numbered implicitly.
 */
class UnusedEnumAbstractValueCheckTest extends Test {

	private static inline final BUILD: String = '-cp .\n-main Main\n--interp\n';
	private static final CONFIG: String = '{"rules": {"unused-enum-abstract-value": {"enabled": true}}}';
	private static final FIX_CONFIG: String = '{"rules": {"unused-enum-abstract-value": {"enabled": true, "fix": true}}}';
	private static final TWINS: String = [
		'enum abstract Layout(String) to String {',
		'\tfinal NONE = \'none\';',
		'\tfinal GRID = \'grid\';',
		'\tfinal TABBED = \'a\\tb\';',
		'}',
		'',
		'enum abstract View(Int) {',
		'\tfinal LIST;',
		'\tfinal GRID;',
		'\tfinal TILE;',
		'}',
		'',
		'class Main {',
		'\tstatic function main() {',
		'\t\tvar view: View = LIST;',
		'\t\tif (view == GRID) trace(1);',
		'\t\tswitch view {',
		'\t\t\tcase TILE: trace(2);',
		'\t\t\tcase _:',
		'\t\t}',
		'\t\ttrace(Layout.NONE);',
		'\t\ttrace(Layout.TABBED);',
		'\t}',
		'}',
		''
	].join('\n');

	/**
	 * A same-named value of another type read bare by expected type leaves the unread twin reported, and no read value
	 * — a string value holding a control character included, which the facts carry escaped.
	 */
	@:pin('control')
	@:killer('M-EAV-FACTS-CAST')
	@:killer('M-EAV-DECLARATION-READ')
	@:killer('M-EAV-OTHER-TYPE-READ')
	@:killer('M-EAV-STRING-QUOTE')
	public function testATwinReadByAnotherTypeIsReported(): Void {
		final outcome: Null<Outcome> = lint(['Main.hx' => TWINS], [[]]);
		if (outcome != null) assertNames(['Layout.GRID'], outcome);
	}

	/**
	 * A bare `case` pattern reads its value: in a switch of several arms and in a single arm the compiler lowers to `==`. The
	 * same-named values of a type no pattern reads are reported only while the patterns are placed as the subject's values.
	 */
	@:pin('control')
	@:killer('M-EAV-FACTS-CASE')
	@:killer('M-EAV-FACTS-COMPARE')
	public function testABareCasePatternReadsByExpectedType(): Void {
		final source: String = [
			'enum abstract View(Int) {',
			'\tfinal LIST;',
			'\tfinal GRID;',
			'\tfinal TILE;',
			'\tfinal LOST;',
			'}',
			'',
			'enum abstract Other(Int) {',
			'\tfinal LIST;',
			'\tfinal GRID;',
			'\tfinal TILE;',
			'\tfinal KEEP;',
			'}',
			'',
			'class Main {',
			'\tstatic function main() {',
			'\t\tfinal view: View = cast Std.random(3);',
			'\t\tswitch view {',
			'\t\t\tcase LIST | TILE: trace(1);',
			'\t\t\tcase _: trace(2);',
			'\t\t}',
			'\t\tswitch view {',
			'\t\t\tcase GRID: trace(3);',
			'\t\t\tcase _:',
			'\t\t}',
			'\t\ttrace(Other.KEEP);',
			'\t}',
			'}',
			''
		].join('\n');
		final outcome: Null<Outcome> = lint(['Main.hx' => source], [[]]);
		if (outcome != null) assertNames(['Other.GRID', 'Other.LIST', 'Other.TILE', 'View.LOST'], outcome);
	}

	/** A read only in a `#if` branch keeps its value, whether another configuration compiles the branch or none does. */
	@:pin('control')
	@:killer('M-EAV-CONDITIONAL')
	public function testAReadOnlyInAConditionalBranchKeepsTheValue(): Void {
		final source: String = [
			'enum abstract Mode(Int) {',
			'\tfinal A = 1;',
			'\tfinal B = 2;',
			'\tfinal C = 3;',
			'\tfinal D = 4;',
			'}',
			'',
			'class Main {',
			'\tstatic function main() {',
			'\t\ttrace(Mode.A);',
			'\t\t#if never',
			'\t\ttrace(Mode.B);',
			'\t\t#end',
			'\t\t#if extra',
			'\t\ttrace(Mode.C);',
			'\t\t#end',
			'\t}',
			'}',
			''
		].join('\n');
		final outcome: Null<Outcome> = lint(['Main.hx' => source], [[], ['extra']]);
		if (outcome != null) assertNames(['Mode.D'], outcome);
	}

	/**
	 * A qualified value as a `case` of a switch over the underlying type or
	 * over `Dynamic` is compiled with no value recorded, and still matches.
	 */
	@:pin('control')
	@:killer('M-EAV-UNRECORDED-READ')
	public function testACasePatternOverTheUnderlyingTypeKeepsTheValue(): Void {
		final source: String = [
			'enum abstract Cmd(String) to String {',
			'\tfinal RUN = \'run\';',
			'\tfinal DEAD_CMD = \'dead\';',
			'}',
			'',
			'enum abstract Flag(Int) {',
			'\tfinal X = 1;',
			'\tfinal Y = 2;',
			'}',
			'',
			'class Main {',
			'\tstatic function handle(cmd: String, d: Dynamic): Void {',
			'\t\tswitch cmd {',
			'\t\t\tcase Cmd.RUN: trace(\'run\');',
			'\t\t\tcase _:',
			'\t\t}',
			'\t\tswitch d {',
			'\t\t\tcase Flag.X: trace(\'x\');',
			'\t\t\tcase _:',
			'\t\t}',
			'\t}',
			'',
			'\tstatic function main() {',
			'\t\thandle(\'run\', 1);',
			'\t}',
			'}',
			''
		].join('\n');
		final outcome: Null<Outcome> = lint(['Main.hx' => source], [[]]);
		if (outcome != null) assertNames(['Cmd.DEAD_CMD', 'Flag.Y'], outcome);
	}

	/**
	 * No value is weighed of a type with a `from` cast, of a `@:keep` type, of an `@:expose` value, of a type a macro
	 * call is handed, or of a type argument of a host a build macro writes — while an unread value of a plain type, and one
	 * of a type argument of a plain generic, are reported.
	 */
	@:pin('control')
	@:killer('M-EAV-IMPLICIT-ARRIVAL')
	@:killer('M-EAV-NAMED-AS-VALUE')
	@:killer('M-EAV-PINNED')
	@:killer('M-EAV-MACRO-HOST')
	public function testAnImplicitArrivalAPinOrAnEnumerationExemptsTheValues(): Void {
		final source: String = [
			'enum abstract Code(Int) from Int {',
			'\tfinal X = 1;',
			'}',
			'',
			'@:keep',
			'enum abstract Kept(Int) {',
			'\tfinal K = 1;',
			'}',
			'',
			'enum abstract Shown(Int) {',
			'\t@:expose',
			'\tfinal S = 1;',
			'}',
			'',
			'enum abstract Listed(Int) {',
			'\tfinal L = 1;',
			'}',
			'',
			'enum abstract Plain(Int) {',
			'\tfinal U = 1;',
			'}',
			'',
			'enum abstract Sized(Int) {',
			'\tfinal S1 = 1;',
			'}',
			'',
			'enum abstract Carried(Int) {',
			'\tfinal C1 = 1;',
			'}',
			'',
			'@:build(Enumerate.build())',
			'class Box<T> {',
			'\tpublic function new() {}',
			'}',
			'',
			'class Holder<T> {',
			'\tpublic function new() {}',
			'}',
			'',
			'class Main {',
			'\tstatic function main() {',
			'\t\tfinal code: Code = 5;',
			'\t\ttrace(code);',
			'\t\ttrace(Enumerate.all(Listed));',
			'\t\ttrace(new Box<Sized>());',
			'\t\ttrace(new Holder<Carried>());',
			'\t}',
			'}',
			''
		].join('\n');
		final macroSource: String = [
			'import haxe.macro.Context;',
			'import haxe.macro.Expr;',
			'',
			'class Enumerate {',
			'\tpublic static macro function all(e: Expr): Expr {',
			'\t\treturn macro [];',
			'\t}',
			'',
			'\tpublic static macro function build(): Array<Field> {',
			'\t\treturn Context.getBuildFields();',
			'\t}',
			'}',
			''
		].join('\n');
		final outcome: Null<Outcome> = lint(['Main.hx' => source, 'Enumerate.hx' => macroSource], [[]]);
		if (outcome != null) assertNames(['Carried.C1', 'Plain.U'], outcome);
	}

	/**
	 * The fix removes an explicitly valued value with its group label when it is alone in the group, keeps the label of a
	 * group another value follows in, and refuses an implicitly numbered value and one a later implicit number follows;
	 * without the rule's `fix` key it removes nothing.
	 */
	@:pin('control')
	@:killer('M-EAV-LATER-IMPLICIT')
	@:killer('M-EAV-LABEL-ALONE')
	@:killer('M-EAV-FIX-OFF')
	public function testTheFixRemovesOnlyAValueNoNumberingDependsOn(): Void {
		final source: String = [
			'enum abstract Mode(Int) {',
			'\tfinal A = 1;',
			'\tfinal B = 2;',
			'\t// pair',
			'\tfinal C = 3;',
			'',
			'\t// group',
			'\tfinal D = 4;',
			'\tfinal E = 5;',
			'}',
			'',
			'enum abstract Auto(Int) {',
			'\tfinal P;',
			'\tfinal Q;',
			'\tfinal R;',
			'}',
			'',
			'enum abstract Num(Int) {',
			'\tfinal M = 1;',
			'\tfinal N;',
			'}',
			'',
			'class Main {',
			'\tstatic function main() {',
			'\t\ttrace(Mode.A);',
			'\t\ttrace(Mode.B);',
			'\t\ttrace(Mode.E);',
			'\t\ttrace(Auto.P);',
			'\t\ttrace(Auto.R);',
			'\t\ttrace(Num.N);',
			'\t}',
			'}',
			''
		].join('\n');
		final fixed: Null<Outcome> = lint(['Main.hx' => source], [[]], true);
		if (fixed == null) return;
		assertNames(['Auto.Q', 'Mode.C', 'Mode.D', 'Num.M'], fixed);
		final expected: String = source.replace('\tfinal B = 2;\n\t// pair\n\tfinal C = 3;\n', '\tfinal B = 2;\n')
			.replace('\t// group\n\tfinal D = 4;\n', '\t// group\n');
		Assert.equals(expected, fixed.fixed['Main.hx']);
		final declined: Array<String> = [for (v in fixed.found) if (v.declineReason != null) v.message.split('`')[1]];
		declined.sort(Compare.compareString);
		Assert.same(['Auto.Q', 'Num.M'], declined);
		final off: Null<Outcome> = lint(['Main.hx' => source], [[]]);
		if (off != null) Assert.equals(source, off.fixed['Main.hx']);
	}

	/** Without the facts only a value whose name occurs nowhere outside its declaration is reported. */
	@:pin('control')
	@:killer('M-EAV-NO-FACTS')
	public function testWithoutFactsOnlyANameOccurringNowhereIsReported(): Void {
		final source: String = TWINS.replace('\tfinal GRID = \'grid\';\n', '\tfinal GRID = \'grid\';\n\tfinal ORPHAN = \'orphan\';\n');
		final outcome: Null<Outcome> = lint(['Main.hx' => source], [[]], false, false);
		if (outcome == null) return;
		assertNames(['Layout.ORPHAN'], outcome);
		Assert.isTrue(outcome.found[0]?.message.indexOf('occurs nowhere') >= 0, outcome.found[0]?.message);
	}

	/** The `Type.VALUE` each finding names, sorted. */
	private static function names(outcome: Outcome): Array<String> {
		final out: Array<String> = outcome.found.map(v -> v.message.split('`')[1]);
		out.sort(Compare.compareString);
		return out;
	}

	/**
	 * The rule's findings over `files` compiled by `configurations` (with the compiler's facts unless `facts` is false),
	 * and each file as the fix leaves it; null when no compiler is there to type the fixture.
	 */
	private static function lint(
		files: Map<String, String>, configurations: Array<Array<String>>, fix: Bool = false, facts: Bool = true
	): Null<Outcome> {
		#if (sys || nodejs)
		final written: Array<{ name: String, source: String }> = [for (name => text in files) { name: name, source: text }];
		written.push({ name: 'build.hxml', source: BUILD });
		final dir: String = CliFixture.writeTree('eav_facts', written);
		var table: Null<CompilerFacts> = null;
		if (facts) {
			if (!CompilerOracle.typecheck('build.hxml', dir).match(Confirmed)) {
				CliFixture.removeDir(dir);
				Assert.pass('haxe unavailable — skipped');
				return null;
			}
			final oracles: Array<OracleConfig> = [for (d in configurations) {
				hxml: 'build.hxml',
				dir: dir,
				defines: d
			}]; // noqa: prefer-map
			table = TypedFactsProbe.probeAll(oracles);
			if (table == null || table.configurations.length != configurations.length) {
				CliFixture.removeDir(dir);
				Assert.fail('the fixture compiled but left no facts: ${[for (d in table?.dropped ?? []) d.reason]}');
				return null;
			}
		}
		final sources: Array<{ file: String, source: String }> = [for (name => text in files) {
			file: Path.join([dir, name]),
			source: text
		}];
		final held: Null<CompilerFacts> = table;
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {
				report: sources,
				projectRoots: [],
				library: new LibrarySources([]),
				rootsMatched: true,
				rootsAllMatched: true
			},
			facts: () -> held
		});
		final check: UnusedEnumAbstractValue = new UnusedEnumAbstractValue();
		final json: String = fix ? FIX_CONFIG : CONFIG;
		final found: Array<Violation> = CheckFixture.violationsIn(check, sources, plugin, _ -> LintConfig.parse(json));
		final fixed: Map<String, String> = [];
		for (entry in sources) {
			final own: Array<Violation> = found.filter(v -> v.file == entry.file);
			fixed[Path.withoutDirectory(entry.file)] = CanonicalEdit.applyEdits(entry.source, check.fix(entry.source, own, plugin));
		}
		CliFixture.removeDir(dir);
		return { found: found, fixed: fixed };
		#else
		Assert.pass('non-sys target');
		return null;
		#end
	}

	/** Assert the findings of `outcome` name exactly `expected`, sorted. */
	private static function assertNames(expected: Array<String>, outcome: Outcome, ?pos: haxe.PosInfos): Void {
		final got: Array<String> = names(outcome);
		Assert.same(expected, got, 'found ${got.join(', ')}', pos);
	}

}

/** What one lint of a fixture found, and each of its files as the fix leaves it. */
private typedef Outcome = { final found: Array<Violation>; final fixed: Map<String, String>; }
