package unit.check.common.nullsafety;

import anyparse.check.common.nullsafety.RedundantNarrowingCopy;
import anyparse.query.CanonicalEdit;
import anyparse.query.IndexScope;
import anyparse.util.Compare;
import unit.cli.CliFixture;

/**
 * The `redundant-narrowing-copy` check: a local that copies a field only so a null check narrows it is flagged, and the
 * fix reads the field where the copy was read — but only when nothing between the copy and its last use can change the
 * field: no call, no write, no loop or function literal around a use, and no other thread writing it.
 */
class RedundantNarrowingCopyTest extends Test {

	#if (sys || nodejs)
	private static final CONFIG: String = '{"rules":{"thread-safety":{"spawns":["Runner.create"],"closedWorld":true}}}';
	private static final RUNNER: String = 'class Runner { public static function create(fn:()->Void):Void {} }';
	private static inline final BOX: String = 'class Box { public var o:Null<Box>; public var height:Float = 0; public var y:Float = 0;'
		+ ' public var gg(get, never):Float; function get_gg():Float return 0;'
		+ ' public function new() {} public function m():Void {} public function n(v:Int):Void {} }';
	private static final WRAP: String = 'abstract Wrap(Box) from Box { public function show():String return \'wrap\'; }';
	private static final NUM: String = 'abstract Num(Int) from Int { @:op(A + B) public function add(b:Num):Num return this; }';
	private static final UNEQUAL: String =
		'abstract Unequal(Int) from Int { @:op(A != B) public function ne(b:Unequal):Bool return false; }';
	private static final GRID: String = 'abstract Grid(Array<Int>) { @:arrayAccess public function at(i:Int):Int return this[i]; }';
	private static inline final HOLDER: String = 'class Holder<T> { public function new() {}'
		+ ' public function put(v:T, n:String):Void { Reflect.setField(v, n, null); } }';
	private static inline final FIELDS: String = 'var nm:Num = 0; var grid:Grid; var arr:Array<Int> = []; var k:Int = 0; var plain:Box;'
		+ ' var g(get, never):Float; function get_g():Float { box = null; return 1; }'
		+ ' var onChange:Null<(C)->Void>; var box:Null<Box>; var h:Float = 0; static var sbox:Null<Box>;'
		+ ' var p:C; var shared:Null<Box>; var guarded(get, null):Null<Box>; function get_guarded():Null<Box> return box;'
		+ ' public function new() {} function other():Void {} function calc():Int return 1;'
		+ ' function take(a:Null<Box>, b:Int):Void {} function take2(a:Int, b:Null<Box>):Void {}';

	@:pin('control')
	@:killer('M-RNC-ANY-DATA-FIELD')
	public function testACopyOfAFieldUsedInTheWindowIsFlagged(): Void {
		final found: Array<String> = flagged(CONFIG, [
			'function a():Void { final listener:Null<(C)->Void> = onChange; if (listener != null) listener(this); }',
			'function b():Void { final l:Null<Box> = box; if (l != null) l.y = h - l.height; }',
			'function c():Void { final l:Null<Box> = box; if (l == null) return; l.m(); }',
			'function d():Void { final l:Null<Box> = sbox; if (l != null) l.m(); }',
			'function e():Void { final l:Null<Box> = p.shared; if (l != null) l.m(); }',
			'function f():Void { final l:Null<Box> = box; if (l != null) l.n(calc()); }',
			'function g(q:C):Void { final l:Null<Box> = q.box; if (l != null) l.m(); }',
			'function i():Void { var l:Null<Box> = box; if (l != null) l.m(); }'
		]);
		Assert.same([
			'l only copies box',
			'l only copies box',
			'l only copies box',
			'l only copies box',
			'l only copies p.shared',
			'l only copies q.box',
			'l only copies sbox',
			'listener only copies onChange'
		], found);
	}

	@:pin('control')
	@:killer('M-RNC-CALL-WINDOW')
	public function testAClassUnderTheLenientModeIsJudgedTheSame(): Void {
		Assert.same(
			['l only copies box'],
			flagged(CONFIG, ['function a():Void { final l:Null<Box> = box; if (l != null) l.m(); }'], '@:nullSafety ')
		);
		Assert.same(
			[], flagged(CONFIG, ['function a():Void { final l:Null<Box> = box; other(); if (l != null) l.m(); }'], '@:nullSafety ')
		);
	}

	@:pin('control')
	@:killer('M-RNC-CALL-WINDOW')
	public function testACallBeforeTheLastUseKeepsTheCopy(): Void {
		Assert.same([], flagged(CONFIG, ['function a():Void { final l:Null<Box> = box; other(); if (l != null) l.m(); }']));
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; if (l != null) { l.m(); l.m(); } }'
		]));
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; final z:Box = new Box(); if (l != null) l.m(); }'
		]));
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; if (l != null) take2(calc(), l); }'
		]));
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; if (l != null) l.m(); other(); if (l != null) l.m(); }'
		]));
	}

	@:pin('control')
	@:killer('M-RNC-WRITE-WINDOW')
	public function testAWriteBeforeTheLastUseKeepsTheCopy(): Void {
		Assert.same([], flagged(CONFIG, ['function a():Void { final l:Null<Box> = box; h = 1; if (l != null) l.m(); }']));
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; box = null; if (l != null) l.m(); }'
		]));
	}

	@:pin('control')
	@:killer('M-RNC-WRAPPED-USE')
	public function testALoopOrFunctionLiteralAroundAUseKeepsTheCopy(): Void {
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; for (i in 0...3) if (l != null) l.m(); }'
		]));
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; if (l != null) Runner.create(() -> l.m()); }'
		]));
	}

	@:pin('control')
	@:killer('M-RNC-NULL-COMPARED')
	public function testACopyNothingComparesWithNullIsLeftAlone(): Void {
		Assert.same([], flagged(CONFIG, ['function a():Void { final l:Null<Box> = box; l.m(); }']));
	}

	@:pin('control')
	@:killer('M-RNC-READ-ONLY')
	public function testACopyThatIsWrittenIsLeftAlone(): Void {
		Assert.same([], flagged(CONFIG, ['function a():Void { var l:Null<Box> = box; if (l != null) l = null; }']));
	}

	@:pin('control')
	@:killer('M-RNC-INTERPOLATED')
	public function testAnInterpolatedReadIsLeftAlone(): Void {
		Assert.same([], flagged(CONFIG, ['function a():Void { final l:Null<Box> = box; if (l != null) trace(\'$$l\'); }']));
	}

	@:pin('control')
	@:killer('M-RNC-LOCAL-COPY')
	public function testACopyOfALocalIsLeftAlone(): Void {
		Assert.same([], flagged(CONFIG, ['function a(q:Null<Box>):Void { final l:Null<Box> = q; if (l != null) l.m(); }']));
	}

	@:pin('control')
	@:killer('M-RNC-GETTER')
	public function testAPropertyWithAGetterIsLeftAlone(): Void {
		Assert.same([], flagged(CONFIG, ['function a():Void { final l:Null<Box> = guarded; if (l != null) l.m(); }']));
	}

	@:pin('control')
	@:killer('M-RNC-REDECLARED')
	public function testANameOfTheFieldPathDeclaredAgainInTheWindowIsLeftAlone(): Void {
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; final box:Null<Box> = null; if (l != null) l.m(); }'
		]));
	}

	@:pin('control')
	@:killer('M-RNC-CHAIN-GUARDED')
	public function testAChainNotReadWhereTheCopyWasIsLeftAlone(): Void {
		Assert.same([], flagged(CONFIG, [
			'function a(c:Bool):Void { final l:Null<Box> = p.shared; if (c) { if (l != null) l.m(); } }'
		]));
		Assert.same([], flagged(CONFIG, [
			'function a(c:Bool):Void { final l:Null<Box> = p.shared; if (c && l != null) l.m(); }'
		]));
	}

	@:pin('control')
	@:killer('M-RNC-COMMENT')
	public function testACommentInsideTheDeclarationIsKept(): Void {
		Assert.same([], flagged(CONFIG, [
			'function a():Void {\n final l:Null<Box> = /* keep */ box;\n if (l != null) l.m(); }'
		]));
	}

	@:pin('control')
	@:killer('M-RNC-FACTS-ALWAYS')
	public function testAProjectThatClosesNothingHasNoFacts(): Void {
		final body: Array<String> = ['function a():Void { final l:Null<Box> = box; if (l != null) l.m(); }'];
		Assert.same([], flagged('{}', body));
		Assert.same([], flagged('{"rules":{"thread-safety":{"spawns":["Runner.create"]}}}', body));
	}

	@:pin('control')
	@:killer('M-RNC-SPAWNED-WRITE')
	public function testAFieldAThreadWritesIsLeftAlone(): Void {
		final read: String = 'function a():Void { final l:Null<Box> = shared; if (l != null) l.m(); }';
		Assert.same(['l only copies shared'], flagged(CONFIG, [read]));
		final boot: String = 'static function main():Void { final c:C = new C(); c.w(); }';
		Assert.same([], flagged(CONFIG, [read, boot, 'function w():Void { Runner.create(() -> { shared = null; }); }']));
		Assert.same([], flagged(CONFIG, [
			read,
			boot,
			'function w():Void { Runner.create(set); } function set():Void { shared = null; }'
		]));
	}

	@:pin('control')
	@:killer('M-RNC-SPAWNED-READER')
	public function testAFieldReadOnAThreadAndWrittenAnywhereIsLeftAlone(): Void {
		final read: String = 'function a():Void { final l:Null<Box> = shared; if (l != null) l.m(); }';
		final start: String = 'function s():Void { Runner.create(a); } static function main():Void { final c:C = new C(); c.s(); }';
		Assert.same(['l only copies shared'], flagged(CONFIG, [read, start]));
		Assert.same([], flagged(CONFIG, [read, start, 'function w():Void { shared = null; }']));
	}

	@:pin('control')
	@:killer('M-RNC-REFLECTIVE')
	public function testAFieldWrittenByNameIsLeftAlone(): Void {
		final read: String = 'function a():Void { final l:Null<Box> = shared; if (l != null) l.m(); }';
		Assert.same([], flagged(CONFIG, [read, 'function w(name:String):Void { Reflect.setField(this, name, null); }']));
	}

	@:pin('control')
	@:killer('M-RNC-FIX-TEXT')
	public function testTheFixReadsTheFieldWhereTheCopyWasRead(): Void {
		final out: String = fixed(CONFIG, 'function a():Void { final l:Null<Box> = p.shared; if (l != null) l.y = h - l.height; }');
		Assert.isTrue(out.indexOf('if (p.shared != null) p.shared.y = h - p.shared.height;') >= 0, out);
	}

	@:pin('control')
	@:killer('M-RNC-FIX-DROP')
	public function testTheFixDropsTheCopyLine(): Void {
		final out: String = fixed(
			CONFIG, 'function a():Void { final listener:Null<(C)->Void> = onChange; if (listener != null) listener(this); }'
		);
		Assert.isTrue(out.indexOf('final listener') < 0, out);
		Assert.isTrue(out.indexOf('if (onChange != null) onChange(this);') >= 0, out);
	}

	@:pin('control')
	@:killer('M-RNC-GETTER-WINDOW')
	public function testAGetterReadBeforeTheLastUseKeepsTheCopy(): Void {
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; if (l != null) l.y = g - l.height; }'
		]));
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; if (l != null) l.y = this.g - l.height; }'
		]));
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; if (l != null) l.y = l.gg + l.height; }'
		]));
		Assert.same(['l only copies box'], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; if (l != null) l.y = l.height + l.gg; }'
		]));
	}

	@:pin('control')
	@:killer('M-RNC-COPY-TYPE')
	public function testACopyWrittenWithAnotherTypeIsLeftAlone(): Void {
		Assert.same([], flagged(CONFIG, [
			'function a():String { final l:Null<Wrap> = box; if (l != null) return l.show(); return \'\'; }'
		]));
		Assert.same(['l only copies box'], flagged(CONFIG, ['function a():String { final l = box; if (l != null) l.m(); return \'\'; }']));
	}

	@:pin('control')
	@:killer('M-RNC-OPERATOR-WINDOW')
	public function testAnOperatorATypeOverloadsKeepsTheCopy(): Void {
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; final n = nm + nm; if (l != null) l.m(); }'
		]));
		Assert.same(['l only copies box'], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; final n = k + 1; if (l != null) l.m(); }'
		]));
	}

	@:pin('control')
	@:killer('M-RNC-INDEX-WINDOW')
	public function testAnIndexAccessATypeOverloadsKeepsTheCopy(): Void {
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; final e = grid[k]; if (l != null) l.m(); }'
		]));
	}

	@:pin('control')
	@:killer('M-RNC-CAST-WINDOW')
	public function testAValueConvertedToAWrittenTypeKeepsTheCopy(): Void {
		Assert.same([], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; final w:Wrap = plain; if (l != null) l.m(); }'
		]));
		Assert.same(['l only copies box'], flagged(CONFIG, [
			'function a():Void { final l:Null<Box> = box; final w:Box = plain; if (l != null) l.m(); }'
		]));
	}

	@:pin('control')
	@:killer('M-RNC-ARGUMENT-WINDOW')
	public function testAnArgumentBeforeTheLastUseKeepsTheCopy(): Void {
		Assert.same([], flagged(CONFIG, ['function a():Void { final l:Null<Box> = box; if (l != null) take2(k, l); }']));
		Assert.same(['l only copies box'], flagged(CONFIG, ['function a():Void { final l:Null<Box> = box; if (l != null) take(l, k); }']));
	}

	@:pin('control')
	@:killer('M-RNC-REFLECTIVE-CLASSES')
	public function testAReflectiveWriteTheConfigBoundsAwayFromTheFieldLeavesItSteady(): Void {
		final read: String = 'function a():Void { final l:Null<Box> = shared; if (l != null) l.m(); }';
		final reflective: String =
			'{"reflectiveClasses":["nope.**"],"rules":{"thread-safety":{"spawns":["Runner.create"],"closedWorld":true}}}';
		Assert.same(['l only copies shared'], flagged(reflective, [read], '', [HOLDER]));
	}

	@:pin('control')
	@:killer('M-RNC-UNBOUNDED-REFLECTIVE')
	public function testAReflectiveWriteOfAnyTypeKeepsTheField(): Void {
		final read: String = 'function a():Void { final l:Null<Box> = shared; if (l != null) l.m(); }';
		Assert.same([], flagged(CONFIG, [read], '', [HOLDER]));
	}

	@:pin('control')
	@:killer('M-RNC-NULL-OPERAND')
	public function testANullComparisonIsJudgedByTheOtherOperand(): Void {
		Assert.same(['l only copies box'], flagged(CONFIG, ['function a():Void { final l:Null<Box> = box; if (l != null) l.m(); }']));
	}

	@:pin('control')
	@:killer('M-RNC-STRUCTURAL-OPERAND')
	public function testAFunctionValueComparedWithNullCarriesNoOverload(): Void {
		Assert.same(['listener only copies onChange'], flagged(CONFIG, [
			'function a():Void { final listener:Null<(C)->Void> = onChange; if (listener != null) listener(this); }'
		]));
	}

	/** The copies the check flags in a class of `members`, each as its message up to the null check. */
	private static function flagged(config: String, members: Array<String>, meta: String = '', ?extra: Array<String>): Array<String> {
		final out: Array<String> = [];
		inProject(config, sourcesOf(members, meta, extra ?? []), (files, plugin) -> {
			for (v in Linter.run(files, plugin, [new RedundantNarrowingCopy()]))
				out.push(v.message.substr(0, v.message.indexOf(' so a null check')));
		});
		out.sort(Compare.compareString);
		return out;
	}

	/** The class holding `member`, after the check's fix has been applied to it. */
	private static function fixed(config: String, member: String): String {
		var result: String = '';
		inProject(config, sourcesOf([member], '', []), (files, plugin) -> {
			final check: RedundantNarrowingCopy = new RedundantNarrowingCopy();
			final found: Array<Violation> = Linter.run(files, plugin, [check]);
			final source: String = files[files.length - 1].source;
			result = CanonicalEdit.applyEdits(source, check.fix(source, found, plugin, IndexScope.report(files, plugin)));
		});
		return result;
	}

	/** The project's modules: the helper types, the `extra` ones, and the class `C` of `members` last. */
	private static function sourcesOf(members: Array<String>, meta: String, extra: Array<String>): Array<String> {
		return [RUNNER, BOX, WRAP, NUM, UNEQUAL, GRID].concat(extra).concat(['${meta}class C { $FIELDS ${lines(members)} }']);
	}

	/** Each statement of the members on a line of its own: the copy's line is dropped whole, so it must stand alone. */
	private static function lines(members: Array<String>): String {
		return members.join('\n').split('; ').join(';\n').split('{ ').join('{\n');
	}
	/** `body` over `sources` as the files of a project whose `apq.json` is `config`. */
	private static function inProject(
		config: String, sources: Array<String>, body: (files:Array<{ file: String, source: String }>, plugin:HaxeQueryPlugin) -> Void
	): Void {
		final dir: String = CliFixture.writeDir('narrowingcopy', [{ name: 'apq.json', source: config }]);
		final files: Array<{ file: String, source: String }> = QueryTestHelpers.rootModules(sources)
			.map(entry -> { file: '$dir/${entry.file}', source: entry.source });
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> body(files, new HaxeQueryPlugin()));
	}
	#else
	public function testNonSysTarget(): Void {
		Assert.pass('non-sys target');
	}
	#end

}
