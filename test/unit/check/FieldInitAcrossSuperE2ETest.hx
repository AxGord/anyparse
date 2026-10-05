package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.CompilerOracle;
import anyparse.check.HaxeSpawn;
import anyparse.query.Cli;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * The `field-init-at-declaration` check's PROVEN crossing, end to end over a real compile whose facts are the truth: an
 * init after `super(...)` and an arbitrary constructor prefix moves when no code the hoist crosses can read the field and
 * its right-hand side changes nothing it did not build and reads nothing that code changes — and the program prints what it
 * printed. Every refusal fixture is a class whose move WOULD change the output: an override the base constructor calls, a
 * listener the prefix fires, a static the prefix writes, a static the construction writes, a method writing its own `this`,
 * a write in the prologue the move joins, a random generator, and a public field. Without the list of builds declared
 * complete nothing moves, as before.
 */
class FieldInitAcrossSuperE2ETest extends Test {

	#if (sys || nodejs)
	private static final ACCEPT_MAIN: String = [
		'class Main {',
		'\tstatic function main() {',
		'\t\tSys.println(new Child().report());',
		'\t}',
		'}',
		'',
		'class Counter {',
		'\tpublic static var n:Int = 0;',
		'}',
		'',
		'class Base {',
		'\tpublic function new() {',
		'\t\tCounter.n++;',
		'\t\thook();',
		'\t}',
		'',
		'\tprivate function hook():Void {}',
		'}',
		'',
		'class Part {',
		'\tpublic final label:String;',
		'',
		'\tpublic function new(l:String) {',
		'\t\tlabel = l + \'!\';',
		'\t}',
		'}',
		'',
		'class Child extends Base {',
		'\tprivate final _trail:Array<String> = [\'t\'];',
		'\tprivate final _part:Part;',
		'\tprivate final _tag:Part;',
		'\tprivate final _n:Int;',
		'',
		'\tpublic function new() {',
		'\t\tsuper();',
		'\t\t_n = Counter.n;',
		'\t\tfinal twice:Int = _n * 2;',
		'\t\tSys.println(\'ctor $$twice\');',
		'\t\t_part = new Part(\'x\');',
		'\t\t_tag = new Part(\'y\');',
		'\t}',
		'',
		'\toverride private function hook():Void {',
		'\t\tSys.println(\'hook $${_trail.length}\');',
		'\t}',
		'',
		'\tpublic function report():String {',
		'\t\treturn _part.label + _tag.label + _n;',
		'\t}',
		'}'
	].join('\n') + '\n';
	private static final REFUSE_MAIN: String = [
		'class Main {',
		'\tstatic function main() {',
		'\t\tSys.println(new ByOverride().report());',
		'\t\tSys.println(new ByListener().report());',
		'\t\tSys.println(new ByStaticRead().report());',
		'\t\tSys.println(new ByStaticWrite().report());',
		'\t\tSys.println(new ByMethodThis().report());',
		'\t\tSys.println(new ByPrologue().report());',
		'\t\tSys.println(new ByRandom().report());',
		'\t\tSys.println(new ByPublic().report());',
		'\t}',
		'}',
		'',
		'class Part {',
		'\tpublic final label:String;',
		'',
		'\tpublic function new(l:String) {',
		'\t\tlabel = l;',
		'\t}',
		'}',
		'',
		'class Base {',
		'\tpublic function new() {',
		'\t\thook();',
		'\t}',
		'',
		'\tprivate function hook():Void {}',
		'}',
		'',
		'class ByOverride extends Base {',
		'\tprivate final _part:Part;',
		'',
		'\tpublic function new() {',
		'\t\tsuper();',
		'\t\t_part = new Part(\'o\');',
		'\t}',
		'',
		'\toverride private function hook():Void {',
		'\t\tSys.println(_part == null ? \'early\' : \'late\');',
		'\t}',
		'',
		'\tpublic function report():String {',
		'\t\treturn _part.label;',
		'\t}',
		'}',
		'',
		'class Bus {',
		'\tprivate static final handlers:Array<() -> Void> = [];',
		'',
		'\tpublic static function listen(h:() -> Void):Void {',
		'\t\thandlers.push(h);',
		'\t}',
		'',
		'\tpublic static function fire():Void {',
		'\t\tfor (h in handlers) h();',
		'\t}',
		'}',
		'',
		'class ByListener extends Base {',
		'\tprivate final _part:Part;',
		'',
		'\tpublic function new() {',
		'\t\tsuper();',
		'\t\tBus.listen(fired);',
		'\t\tBus.fire();',
		'\t\t_part = new Part(\'l\');',
		'\t}',
		'',
		'\tprivate function fired():Void {',
		'\t\tSys.println(_part == null ? \'unset\' : \'set\');',
		'\t}',
		'',
		'\tpublic function report():String {',
		'\t\treturn _part.label;',
		'\t}',
		'}',
		'',
		'class Config {',
		'\tpublic static var suffix:String = \'-\';',
		'}',
		'',
		'class Suffixed {',
		'\tpublic final label:String;',
		'',
		'\tpublic function new(l:String) {',
		'\t\tlabel = l + Config.suffix;',
		'\t}',
		'}',
		'',
		'class ByStaticRead extends Base {',
		'\tprivate final _part:Suffixed;',
		'',
		'\tpublic function new() {',
		'\t\tsuper();',
		'\t\tConfig.suffix = \'+\';',
		'\t\t_part = new Suffixed(\'r\');',
		'\t}',
		'',
		'\tpublic function report():String {',
		'\t\treturn _part.label;',
		'\t}',
		'}',
		'',
		'class Log {',
		'\tpublic static var last:String = \'-\';',
		'}',
		'',
		'class Logged {',
		'\tpublic final id:Int = 7;',
		'',
		'\tpublic function new() {',
		'\t\tLog.last = \'logged\';',
		'\t}',
		'}',
		'',
		'class LogBase {',
		'\tpublic var first:String = \'\';',
		'',
		'\tpublic function new() {',
		'\t\tfirst = Log.last;',
		'\t}',
		'}',
		'',
		'class ByStaticWrite extends LogBase {',
		'\tprivate final _part:Logged;',
		'',
		'\tpublic function new() {',
		'\t\tsuper();',
		'\t\t_part = new Logged();',
		'\t}',
		'',
		'\tpublic function report():String {',
		'\t\treturn \'$$first,$${_part.id}\';',
		'\t}',
		'}',
		'',
		'class Stamp {',
		'\tpublic static var n:Int = 0;',
		'}',
		'',
		'class Stamped {',
		'\tpublic final seen:Int = Stamp.n;',
		'',
		'\tpublic function new() {}',
		'}',
		'',
		'class ByPrologue extends Base {',
		'\tprivate final _stamp:Int = Stamp.n++;',
		'\tprivate final _part:Stamped;',
		'',
		'\tpublic function new() {',
		'\t\tsuper();',
		'\t\t_part = new Stamped();',
		'\t}',
		'',
		'\tpublic function report():String {',
		'\t\treturn \'$$_stamp,$${_part.seen}\';',
		'\t}',
		'}',
		'',
		'class Rolled {',
		'\tpublic var roll:Float = 0;',
		'',
		'\tpublic function new() {',
		'\t\troll = Math.random();',
		'\t}',
		'}',
		'',
		'class RollBase {',
		'\tpublic final roll:Float = Math.random();',
		'',
		'\tpublic function new() {}',
		'}',
		'',
		'class ByRandom extends RollBase {',
		'\tprivate final _part:Rolled;',
		'',
		'\tpublic function new() {',
		'\t\tsuper();',
		'\t\t_part = new Rolled();',
		'\t}',
		'',
		'\tpublic function report():String {',
		'\t\treturn _part.roll < 2 ? \'rolled\' : \'?\';',
		'\t}',
		'}',
		'',
		'class ByPublic extends Base {',
		'\tpublic final part:Part;',
		'',
		'\tpublic function new() {',
		'\t\tsuper();',
		'\t\tpart = new Part(\'p\');',
		'\t}',
		'',
		'\tpublic function report():String {',
		'\t\treturn part.label;',
		'\t}',
		'}',
		'',
		'class Tally {',
		'\tpublic static final it:Tally = new Tally();',
		'',
		'\tpublic var n:Int = 0;',
		'',
		'\tpublic function new() {}',
		'',
		'\tpublic function bump():Int {',
		'\t\treturn ++n;',
		'\t}',
		'}',
		'',
		'class Bumped {',
		'\tpublic var at:Int = 0;',
		'',
		'\tpublic function new() {',
		'\t\tat = Tally.it.bump();',
		'\t}',
		'}',
		'',
		'class TallyBase {',
		'\tpublic var seen:Int = 0;',
		'',
		'\tpublic function new() {',
		'\t\tseen = Tally.it.n;',
		'\t}',
		'}',
		'',
		'class ByMethodThis extends TallyBase {',
		'\tprivate final _part:Bumped;',
		'',
		'\tpublic function new() {',
		'\t\tsuper();',
		'\t\t_part = new Bumped();',
		'\t}',
		'',
		'\tpublic function report():String {',
		'\t\treturn \'$$seen,$${_part.at}\';',
		'\t}',
		'}'
	].join('\n') + '\n';
	private static final HXML: String = '-cp .\n-main Main\n--interp\n';
	private static inline final COMPLETE: String =
		'{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."],"reachConfigurationsComplete":true}';
	private static inline final BUFFER: Int = 1 << 20;
	#end

	/**
	 * Two inits after `super()`, a local declaration and a call move onto their declarations together, and the program prints
	 * what it printed; the init reading the static the base constructor bumps stays, in the pass that moves the others and in
	 * the next one, where its file no longer has the facts the compile recorded.
	 */
	@:pin('control') @:killer('M-FIAD-PROVEN-NEVER') @:killer('M-FRESH-ONLY-ENTRY-FACETED')
	public function testAProvenInitCrossesSuperAndThePrefix(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('fiadproven', ACCEPT_MAIN, COMPLETE);
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'field-init-at-declaration', '$dir/Main.hx']));
		final after: String = File.getContent('$dir/Main.hx');
		Assert.isTrue(after.indexOf('private final _part:Part = new Part(\'x\');') >= 0, after);
		Assert.isTrue(after.indexOf('private final _tag:Part = new Part(\'y\');') >= 0, after);
		Assert.isTrue(after.indexOf('_n = Counter.n;') >= 0, after);
		Assert.equals(-1, after.indexOf('_part = new Part'));
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Every class whose move would change the output keeps its constructor init, and the program is untouched. */
	@:pin('control') @:killer('M-FIAD-PROVEN-ALWAYS') @:killer('M-FIAD-PROVEN-NO-READER') @:killer('M-FIAD-PROVEN-NO-COMMUTE')
	@:killer('M-FIAD-PROVEN-EXPOSED') @:killer('M-FRESH-ONLY-WRITES-ADMITTED')
	@:killer('M-FRESH-ONLY-STATEFUL-LIBRARY')
	public function testAnObservableCrossingKeepsTheInit(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('fiadrefused', REFUSE_MAIN, COMPLETE);
		if (dir == null) return;
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'field-init-at-declaration', '$dir/Main.hx']));
		Assert.equals(REFUSE_MAIN, File.getContent('$dir/Main.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Without the list of builds declared complete the facts are not the truth, and the proven crossing stays off. */
	@:pin('control') @:killer('M-FIAD-PROVEN-ALWAYS')
	public function testWithoutTheTruthTheInitStays(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('fiadnotruth', ACCEPT_MAIN, '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."]}');
		if (dir == null) return;
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'field-init-at-declaration', '$dir/Main.hx']));
		Assert.equals(ACCEPT_MAIN, File.getContent('$dir/Main.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function tree(name: String, main: String, apqlint: String): Null<String> {
		final dir: String = CliFixture.writeTree(name, [
			{ name: 'Main.hx', source: main },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: apqlint }
		]);
		if (CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) return dir;
		CliFixture.removeDir(dir);
		Assert.pass('haxe unavailable — skipped');
		return null;
	}

	private static function run(dir: String): String {
		return HaxeSpawn.run(['check.hxml'], dir, BUFFER).out;
	}
	#end

}
