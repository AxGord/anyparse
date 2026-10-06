package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.HaxeSpawn;
import anyparse.check.Linter;
import anyparse.check.ScratchField;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `scratch-field` check: a private field every read and write of which sits in one method, each
 * read after a write of the same call, is a local of that method. The fix deletes the field and
 * declares the local at the first write. Refusals come in two kinds: no finding at all (the field is
 * reachable from elsewhere), and a finding whose fix is declined (the proof the fix needs fails).
 */
class ScratchFieldCheckTest extends Test {

	/** A plain scratch value: the field goes, its first write declares the local, every use is renamed. */
	@:pin('control') @:killer('M-SCRATCH-SILENT')
	public function testAScratchFieldBecomesALocal(): Void {
		final src: String = scratch(
			'private var _point:P;',
			'function move(v:Float):Float {\n\t\t_point = new P(v * 2);\n'
			+ '\t\tfinal a:Float = if (_point.x < 0) 0 else _point.x;\n\t\treturn a + this._point.x;\n\t}'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('scratch-field', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(
			'field `_point` is used only inside `move`, written before every read there — it can be a local of that method', vs[0].message
		);
		final out: String = fixed(src);
		Assert.isTrue(out.indexOf('_point') < 0, out);
		Assert.isTrue(out.indexOf('final point:P = new P(v * 2);') >= 0, out);
		Assert.isTrue(out.indexOf('return a + point.x;') >= 0, out);
	}

	/** More than one write declares a `var`. */
	@:pin('control') @:killer('M-SCRATCH-SILENT')
	public function testSeveralWritesDeclareAVar(): Void {
		final out: String = fixed(
			scratch('private var _tmp:Int = 0;', 'function sum(n:Int):Int {\n\t\t_tmp = n;\n\t\t_tmp += 1;\n' + '\t\treturn _tmp * 2;\n\t}')
		);
		Assert.isTrue(out.indexOf('var tmp:Int = n;') >= 0, out);
		Assert.isTrue(out.indexOf('tmp += 1;') >= 0, out);
	}

	/** A read in a loop body after the write of its own iteration is dominated; the local is declared per iteration. */
	@:pin('control') @:killer('M-SCRATCH-SILENT')
	public function testAReadAfterTheWriteOfItsIterationIsDominated(): Void {
		final out: String = fixed(scratch(
			'private var _step:Int;',
			'function loop(n:Int):Int {\n\t\tvar t:Int = 0;\n'
			+ '\t\tfor (i in 0...n) {\n\t\t\t_step = i * 2;\n\t\t\tt += _step;\n\t\t}\n\t\treturn t;\n\t}'
		));
		Assert.isTrue(out.indexOf('final step:Int = i * 2;') >= 0, out);
	}

	/** A construction whose constructor only assigns its own fields is an initializer nothing observes being dropped. */
	@:pin('control') @:killer('M-SCRATCH-SILENT')
	public function testATrivialConstructionInitializerIsDropped(): Void {
		final out: String = fixed(
			scratch('private var _q:P = new P(0);', 'function f(v:Float):Float {\n\t\t_q = new P(v);\n\t\treturn _q.x;\n\t}')
		);
		Assert.isTrue(out.indexOf('new P(0)') < 0, out);
		Assert.isTrue(out.indexOf('final q:P = new P(v);') >= 0, out);
	}

	/** A value type may have its methods called: no lifetime hangs on the field. */
	@:pin('control') @:killer('M-SCRATCH-VALUE-TYPES-OFF')
	public function testAValueTypeMayBeCalledOn(): Void {
		final out: String = fixed(
			scratch('private var _s:String;', 'function f():String {\n\t\t_s = \'a\';\n\t\treturn _s.toUpperCase();\n\t}')
		);
		Assert.isTrue(out.indexOf('final s:String = \'a\';') >= 0, out);
	}

	/** The stripped name is taken when the method does not mention it; otherwise the field's own name is kept. */
	@:pin('control') @:killer('M-SCRATCH-NAME-UNCHECKED')
	public function testATakenNameKeepsTheFieldName(): Void {
		final out: String = fixed(scratch('private var _w:Int;', 'function f(w:Int):Int {\n\t\t_w = w + 1;\n\t\treturn _w;\n\t}'));
		Assert.isTrue(out.indexOf('final _w:Int = w + 1;') >= 0, out);
	}

	/** A read the walk reaches before any write of the call sees the previous call's value: reported, fix declined. */
	@:pin('control') @:killer('M-SCRATCH-DOMINANCE-OFF')
	public function testAReadBeforeAnyWriteIsNotDominated(): Void {
		final src: String = scratch('private var _acc:Int = 0;', 'function count():Int {\n\t\t_acc++;\n\t\treturn _acc;\n\t}');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('field `_acc` is used only inside `count`, but a read there can see what an earlier call left in it', vs[0].message);
		Assert.notNull(vs[0].declineReason);
		Assert.equals(src, fixed(src));
	}

	/** A write in one arm of an `if` with no `else` does not dominate a read after it. */
	@:pin('control') @:killer('M-SCRATCH-BRANCH-OPTIMISTIC')
	public function testAOneArmedWriteDoesNotDominate(): Void {
		assertDeclinedAs(
			scratch('private var _b:Int = 0;', 'function f(c:Bool):Int {\n\t\tif (c) _b = 1;\n\t\treturn _b;\n\t}'),
			'a read is not preceded'
		);
	}

	/** A write in a loop body does not dominate a read after the loop: the body may run zero times. */
	@:pin('control') @:killer('M-SCRATCH-CONDITIONAL-KEEPS')
	public function testALoopBodyWriteDoesNotDominateAfterTheLoop(): Void {
		assertDeclinedAs(
			scratch('private var _x:Int = 0;', 'function f(n:Int):Int {\n\t\tfor (i in 0...n) _x = i;\n\t\treturn _x;\n\t}'),
			'a read is not preceded'
		);
	}

	/** A write in a `try` body does not dominate a read after it: the body may throw first. */
	@:pin('control') @:killer('M-SCRATCH-TRY-ALWAYS')
	public function testATryBodyWriteDoesNotDominate(): Void {
		assertDeclinedAs(
			scratch(
				'private var _t:Int = 0;',
				'function f():Int {\n\t\ttry {\n\t\t\t_t = g();\n\t\t} catch (e:haxe.Exception) {}\n'
				+ '\t\treturn _t;\n\t}\n\n\tfunction g():Int {\n\t\treturn 1;\n\t}'
			),
			'a read is not preceded'
		);
	}

	/** Both arms assign, so the reads are dominated — but no single statement can hold the declaration. */
	@:pin('control') @:killer('M-SCRATCH-SLOT-ANYWHERE')
	public function testWritesInBothArmsHaveNoDeclarationSlot(): Void {
		assertDeclinedAs(
			scratch(
				'private var _b:Int = 0;',
				'function f(c:Bool):Int {\n\t\tif (c) {\n\t\t\t_b = 1;\n\t\t} else {\n\t\t\t_b = 2;\n' + '\t\t}\n\t\treturn _b;\n\t}'
			),
			'no one place to declare'
		);
	}

	/** Without a declared type the local could infer another one from its first write. */
	@:pin('control') @:killer('M-SCRATCH-UNTYPED')
	public function testAnUntypedFieldDeclines(): Void {
		assertDeclinedAs(scratch('private var _u = 0;', 'function f():Int {\n\t\t_u = 4;\n\t\treturn _u;\n\t}'), 'declares no type');
	}

	/** A method called on an object the field held may start work that outlives the call. */
	@:pin('control') @:killer('M-SCRATCH-LIFETIME-OFF')
	public function testAMethodCalledOnTheValueDeclines(): Void {
		assertDeclinedAs(
			scratch('private var _l:P;', 'function f():Float {\n\t\t_l = new P(1);\n\t\t_l.go();\n\t\treturn _l.x;\n\t}'),
			'outlives the call'
		);
	}

	/** A method that names itself may recurse between a write and a read. */
	@:pin('control') @:killer('M-SCRATCH-RECURSION-OFF')
	public function testARecursiveMethodDeclines(): Void {
		assertDeclinedAs(
			scratch(
				'private var _r:Int = 0;', 'function rec(n:Int):Int {\n\t\t_r = n;\n\t\tif (n > 0) rec(n - 1);\n' + '\t\treturn _r;\n\t}'
			),
			'recursive call'
		);
	}

	/** A constructor spelling `new` builds another object, whose field is not the one being made a local. */
	@:pin('control') @:killer('M-SCRATCH-CTOR-RECURSES')
	public function testAConstructorConstructingIsNoRecursion(): Void {
		final src: String =
			'class C {\n\tprivate var _bg:P;\n\n\tpublic function new() {\n\t\t_bg = new P(1);\n\t\ttrace(_bg.x);\n\t}\n}\n\n$SUPPORT';
		Assert.isTrue(fixed(src).indexOf('final bg:P = new P(1);') >= 0);
	}

	/** An initializer that calls something may be observed by its absence. */
	@:pin('control') @:killer('M-SCRATCH-INIT-OFF')
	public function testAnImpureInitializerDeclines(): Void {
		assertDeclinedAs(
			scratch(
				'private var _i:Int = compute();',
				'function f():Int {\n\t\t_i = 4;\n\t\treturn _i;\n\t}\n\n' + '\tstatic function compute():Int {\n\t\treturn 3;\n\t}'
			),
			'initializer'
		);
	}

	/** A construction whose constructor does more than assign its own fields is not dropped. */
	@:pin('control') @:killer('M-SCRATCH-TRIVIAL-CTOR-ANY')
	public function testANonTrivialConstructionDeclines(): Void {
		assertDeclinedAs(
			scratch('private var _n:N = new N();', 'function f():Int {\n\t\t_n = new N();\n\t\treturn _n.v;\n\t}'), 'initializer'
		);
	}

	/** A build macro may read the field list the fix changes: declined without an oracle, typechecked with one. */
	@:pin('control') @:killer('M-SCRATCH-MACRO-IGNORED')
	public function testABuildMacroDeclinesUnlessAnOracleVerifies(): Void {
		final src: String = '@:build(M.b())\n' + scratch('private var _m:Int;', 'function f():Int {\n\t\t_m = 1;\n\t\treturn _m;\n\t}');
		assertDeclinedAs(src, 'build macro');
		final check: ScratchField = new ScratchField();
		check.setOracleRelaxed(true);
		Assert.isTrue(fixedWith(check, src).indexOf('final m:Int = 1;') >= 0);
	}

	/** Used in two methods: the field carries a value between them. */
	@:pin('control') @:killer('M-SCRATCH-ONE-METHOD')
	public function testAFieldOfTwoMethodsIsNotReported(): Void {
		Assert.equals(
			0,
			violations(scratch(
				'private var _o:Int = 0;',
				'function a():Void {\n\t\t_o = 1;\n\t}\n\n' + '\tfunction b():Int {\n\t\t_o = 2;\n\t\treturn _o;\n\t}'
			)).length
		);
	}

	/** A closure may run after the call returns. */
	@:pin('control') @:killer('M-SCRATCH-CLOSURE')
	public function testAClosureOccurrenceIsNotReported(): Void {
		Assert.equals(
			0,
			violations(scratch(
				'private var _c:Int = 0;', 'function f():() -> Int {\n\t\t_c = 1;\n\t\tfinal r:Int = _c;\n\t\treturn () -> _c + r;\n\t}'
			)).length
		);
	}

	/** A string spelling the name may be a `Reflect.field` target. */
	@:pin('control') @:killer('M-SCRATCH-REFLECTION-OFF')
	public function testANameInAStringIsNotReported(): Void {
		Assert.equals(
			0,
			violations(
				scratch('private var _s:Int = 0;', 'function f():Int {\n\t\t_s = 2;\n' + '\t\treturn _s + Reflect.field(this, "_s");\n\t}')
			).length
		);
	}

	/** A public field, a static one or one carrying metadata is not a plain private scratch value. */
	@:pin('control') @:killer('M-SCRATCH-MODIFIERS')
	public function testAModifiedFieldIsNotReported(): Void {
		final body: String = 'function f():Int {\n\t\t_k = 1;\n\t\treturn _k;\n\t}';
		Assert.equals(0, violations(scratch('public var _k:Int = 0;', body)).length);
		Assert.equals(0, violations(scratch('@:keep private var _k:Int = 0;', body)).length);
	}

	/** A subtype mentioning the field may read it. */
	@:pin('control') @:killer('M-SCRATCH-CONFINED-OFF')
	public function testASubtypeMentioningTheFieldIsNotReported(): Void {
		final src: String = scratch('private var _z:Int = 0;', 'function f():Int {\n\t\t_z = 1;\n\t\treturn _z;\n\t}');
		final sub: String = 'class D extends C {\n\tfunction g():Int {\n\t\treturn _z;\n\t}\n}';
		Assert.equals(
			0, new ScratchField().run([{ file: 'C.hx', source: src }, { file: 'D.hx', source: sub }], new HaxeQueryPlugin()).length
		);
	}

	/** Another object's member of that name is the field of another instance. */
	@:pin('control') @:killer('M-SCRATCH-FOREIGN-OFF')
	public function testAnotherReceiversMemberIsNotReported(): Void {
		Assert.equals(
			0, violations(scratch('private var _y:Int = 0;', 'function f(o:C):Int {\n\t\t_y = 1;\n\t\treturn _y + o._y;\n\t}')).length
		);
	}

	/** A field the method only writes is a dead store, not a scratch value. */
	@:pin('control') @:killer('M-SCRATCH-WRITE-ONLY')
	public function testAWriteOnlyFieldIsNotReported(): Void {
		Assert.equals(0, violations(scratch('private var _d:Int = 0;', 'function f():Void {\n\t\t_d = 1;\n\t}')).length);
	}

	/** A type carrying `@:rtti` keeps every field reachable by name. */
	@:pin('control') @:killer('M-SCRATCH-RTTI-OFF')
	public function testAnRttiTypeIsNotReported(): Void {
		Assert.equals(
			0, violations('@:rtti\n' + scratch('private var _e:Int;', 'function f():Int {\n\t\t_e = 1;\n\t\treturn _e;\n\t}')).length
		);
	}

	/** The fixed program prints what the original printed. */
	public function testTheFixedProgramRunsTheSame(): Void {
		#if (sys || nodejs)
		final main: String = 'class Main {\n\tprivate var _point:P;\n\tprivate var _tmp:Int = 0;\n\n\tpublic function new() {}\n\n'
			+ '\tfunction move(v:Float):Float {\n\t\t_point = new P(v * 2);\n\t\treturn if (_point.x < 0) 0 else _point.x + this._point.x;\n\t}\n\n'
			+ '\tfunction sum(n:Int):Int {\n\t\t_tmp = n;\n\t\tfor (i in 0...n) _tmp += i;\n\t\treturn _tmp;\n\t}\n\n'
			+ '\tstatic function main():Void {\n\t\tfinal m:Main = new Main();\n\t\tSys.println(m.move(3) + " " + m.sum(4) + " " + m.move(-1));\n'
			+ '\t}\n}\n\n' + SUPPORT;
		final dir: String = CliFixture.writeTree('scratchfield', [{ name: 'Main.hx', source: main }]);
		final before: HaxeRun = HaxeSpawn.run(['-cp', '.', '-main', 'Main', '--interp'], dir, 1 << 20);
		if (before.status != 0) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped: ${before.err}${before.failure}');
			return;
		}
		final out: String = fixed(main);
		File.saveContent('$dir/Main.hx', out);
		final after: HaxeRun = HaxeSpawn.run(['-cp', '.', '-main', 'Main', '--interp'], dir, 1 << 20);
		CliFixture.removeDir(dir);
		Assert.isTrue(out.indexOf('_point') < 0 && out.indexOf('_tmp') < 0, out);
		Assert.equals('12 10 0', before.out.trim(), before.err);
		Assert.equals(before.out, after.out, after.err);
		#else
		Assert.pass('no process spawning on this target');
		#end
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('scratch-field'));
	}

	/** The classes every fixture uses: a value class with a trivial constructor, one without, and a method to call. */
	private static final SUPPORT: String = 'class P {\n\tpublic var x:Float;\n\n\tpublic function new(x:Float) {\n\t\tthis.x = x;\n\t}\n\n'
		+ '\tpublic function go():Void {}\n}\n\nclass N {\n\tpublic var v:Int = 0;\n\n\tpublic function new() {\n\t\ttrace(v);\n\t}\n}';

	private function violations(src: String): Array<Violation> {
		return new ScratchField().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** `src` after the fix of a check that runs without an oracle. */
	private function fixed(src: String): String {
		return fixedWith(new ScratchField(), src);
	}

	/** `src` after `check`'s fix of its own findings. */
	private function fixedWith(check: ScratchField, src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, plugin);
		return CanonicalEdit.applyEdits(src, edits);
	}

	/** Exactly one finding, its fix declined for a reason that says `why`, and the source left alone. */
	private function assertDeclinedAs(src: String, why: String): Void {
		final check: ScratchField = new ScratchField();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, plugin);
		Assert.equals(0, edits.length);
		final reason: String = vs[0].declineReason ?? '';
		Assert.isTrue(reason.indexOf(why) >= 0, reason);
	}

	/** A class `C` declaring `field` and `method`, followed by the support classes. */
	private static function scratch(field: String, method: String): String {
		return 'class C {\n\t$field\n\n\tpublic function new() {}\n\n\t$method\n}\n\n$SUPPORT';
	}

}
