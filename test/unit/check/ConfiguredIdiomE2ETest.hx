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
 * The two config-driven rules end to end through `apq lint --fix` against the real compiler.
 *
 * `prefer-api-idiom`: the program prints what it printed after its paired writes become the declared calls, and the
 * window whose second write reads the first is left as written. `typed-event-constant`: a constant whose listeners agree
 * is retyped, one whose listener is PROVABLY of another event class is reported at the listener and left alone, and one
 * whose listener only the compiler can judge (a function value returned by a call) is retyped speculatively, rejected
 * and reverted — after which a report run still names it, and the program still compiles and runs.
 */
@:nullSafety(Strict)
final class ConfiguredIdiomE2ETest extends Test {

	#if (sys || nodejs)
	private static final POINT: String = [
		'package geom;',
		'',
		'class Point {',
		'\tpublic var x:Float;',
		'\tpublic var y:Float;',
		'',
		'\tpublic function new(x:Float = 0, y:Float = 0) {',
		'\t\tthis.x = x;',
		'\t\tthis.y = y;',
		'\t}',
		'',
		'\tpublic function setTo(xa:Float, ya:Float):Void {',
		'\t\tx = xa;',
		'\t\ty = ya;',
		'\t}',
		'',
		'\tpublic function copyFrom(p:Point):Void {',
		'\t\tx = p.x;',
		'\t\ty = p.y;',
		'\t}',
		'}'
	].join('\n') + '\n';
	private static final POINT_MAIN: String = [
		'import geom.Point;',
		'',
		'class Main {',
		'\tstatic function main():Void {',
		'\t\tfinal p:Point = new Point();',
		'\t\tfinal q:Point = new Point(5, 6);',
		'\t\tp.x = 1;',
		'\t\tp.y = p.x + 2;',
		'\t\tSys.println(p.x + \',\' + p.y);',
		'\t\tp.y = 3;',
		'\t\tp.x = 4;',
		'\t\tSys.println(p.x + \',\' + p.y);',
		'\t\tp.y = q.y;',
		'\t\tp.x = q.x;',
		'\t\tSys.println(p.x + \',\' + p.y);',
		'\t}',
		'}'
	].join('\n') + '\n';
	private static final POINT_CONFIG: String = '{"compilerOracle":"check.hxml","resolutionRoots":["."],"rules":{"prefer-api-idiom":'
		+ '{"idioms":[{"type":"geom.Point","fields":["x","y"],"method":"setTo"},{'
		+ '"type":"geom.Point","fields":["x","y"],"copy":"copyFrom"}]}}}';
	private static final EVENT: String =
		'package ev;\n\nclass Event {\n\tpublic var type:String;\n\n\tpublic function new(type:String) {\n\t\tthis.type = type;\n\t}\n}\n';
	private static final EVENT_TYPE: String = 'package ev;\n\nabstract EventType<T>(String) from String to String {}\n';
	private static final DISPATCHER: String = 'package ev;\n\nclass Dispatcher {\n\tpublic function new() {}\n\n'
		+ '\tpublic function addEventListener<T>(type:EventType<T>, listener:T->Void):Void {}\n}\n';
	private static final POPUP_EVENT: String = 'package app;\n\nimport ev.Event;\n\nclass PopupEvent extends Event {\n'
		+ '\tpublic static inline final CLOSE:String = \'close\';\n\tpublic static inline final OPEN:String = \'open\';\n'
		+ '\tpublic static inline final HELD:String = \'held\';\n}\n';
	private static final MOUSE_EVENT: String = 'package app;\n\nimport ev.Event;\n\nclass MouseEv extends Event {}\n';
	private static final EVENT_MAIN: String = [
		'import app.MouseEv;',
		'import app.PopupEvent;',
		'import ev.Dispatcher;',
		'import ev.Event;',
		'',
		'class Main {',
		'\tstatic function main():Void {',
		'\t\tfinal d:Dispatcher = new Dispatcher();',
		'\t\td.addEventListener(PopupEvent.CLOSE, onEvent);',
		'\t\td.addEventListener(PopupEvent.OPEN, (e:MouseEv) -> {});',
		'\t\td.addEventListener(PopupEvent.HELD, made());',
		'\t\ttrace(PopupEvent.CLOSE == \'close\');',
		'\t}',
		'',
		'\tstatic function onEvent(e:Event):Void {}',
		'',
		'\tstatic function made():MouseEv->Void {',
		'\t\treturn e -> {};',
		'\t}',
		'}'
	].join('\n') + '\n';
	private static final EVENT_CONFIG: String = '{"compilerOracle":"check.hxml","resolutionRoots":["."],"rules":{"typed-event-constant":'
		+ '{"eventBase":"ev.Event","typeAbstract":"ev.EventType","listenerMethods":["addEventListener"]}}}';
	private static final HXML: String = '-cp .\n-main Main\n--interp\n';
	private static inline final BUFFER: Int = 1 << 20;
	#end

	/** Both sites become the declared calls, the order-dependent one stays, and the program prints what it printed. */
	public function testIdiomCallsPrintWhatTheWritesPrinted(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('apiidiom', [
			{ name: 'Main.hx', source: POINT_MAIN },
			{ name: 'geom/Point.hx', source: POINT },
			{ name: 'apqlint.json', source: POINT_CONFIG }
		]);
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-api-idiom', '$dir/Main.hx']));
		final after: String = File.getContent('$dir/Main.hx');
		Assert.isTrue(after.indexOf('\t\tp.x = 1;\n\t\tp.y = p.x + 2;\n') >= 0, after);
		Assert.isTrue(after.indexOf('\t\tp.setTo(4, 3);\n') >= 0, after);
		Assert.isTrue(after.indexOf('\t\tp.copyFrom(q);\n') >= 0, after);
		Assert.equals('1,3\n4,3\n5,6\n', before);
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * CLOSE is retyped; OPEN's lambda listener is provably of another event class, so it is reported and never written;
	 * HELD's listener is a function a call returns, which only the compiler judges — it rejects the retype, the verifier
	 * reverts that one edit and keeps CLOSE's, and a report run afterwards still carries both findings.
	 */
	@:pin('control') @:killer('M-EVENT-NO-MISMATCH')
	public function testTheOracleRevertsWhatTheRuleCannotProve(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('typedevent', [
			{ name: 'Main.hx', source: EVENT_MAIN },
			{ name: 'app/PopupEvent.hx', source: POPUP_EVENT },
			{ name: 'app/MouseEv.hx', source: MOUSE_EVENT },
			{ name: 'ev/Event.hx', source: EVENT },
			{ name: 'ev/EventType.hx', source: EVENT_TYPE },
			{ name: 'ev/Dispatcher.hx', source: DISPATCHER },
			{ name: 'apqlint.json', source: EVENT_CONFIG }
		]);
		if (dir == null) return;
		final fixLog: String = CliFixture.captureStderr(() -> Cli.run([
			'lint',
			'--fix',
			'--rule',
			'typed-event-constant',
			'$dir/app/PopupEvent.hx',
			'$dir/Main.hx'
		]));
		final after: String = File.getContent('$dir/app/PopupEvent.hx');
		Assert.isTrue(after.indexOf('CLOSE:ev.EventType<PopupEvent> = \'close\';') >= 0, after);
		Assert.isTrue(after.indexOf('OPEN:String = \'open\';') >= 0, 'the proven mismatch is never written: $after');
		Assert.isTrue(after.indexOf('HELD:String = \'held\';') >= 0, 'the compiler rejected HELD and it was reverted: $after');
		Assert.isTrue(fixLog.indexOf('1 edit(s) kept, 1 reverted') >= 0, fixLog);
		Assert.isTrue(fixLog.indexOf('typing PopupEvent.OPEN EventType<PopupEvent> would not compile here') >= 0, fixLog);
		final report: String = CliFixture.captureStdout(() -> Cli.run([
			'lint',
			'--all',
			'--no-oracle',
			'--rule',
			'typed-event-constant',
			'$dir/app/PopupEvent.hx',
			'$dir/Main.hx'
		]));
		Assert.isTrue(
			report.indexOf('listener (e:MouseEv) -> {} of PopupEvent.OPEN expects MouseEv, the event is PopupEvent') >= 0, report
		);
		Assert.isTrue(report.indexOf('event-type constant PopupEvent.HELD is typed String') >= 0, report);
		Assert.equals('Main.hx:12: true\n', run(dir), 'the build still compiles and runs');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The fixture tree with `check.hxml`, or null — with the scenario passed — when no compiler typechecks it. */
	private static function tree(name: String, files: Array<{ name: String, source: String }>): Null<String> {
		final dir: String = CliFixture.writeTree(name, files.concat([{ name: 'check.hxml', source: HXML }]));
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
