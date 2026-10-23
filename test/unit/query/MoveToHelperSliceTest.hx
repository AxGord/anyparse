package unit.query;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.MoveToHelper;
import anyparse.query.MoveToHelperArms;
import unit.cli.CliFixture;

using Lambda;
using StringTools;

/**
 * `MoveToHelper.move` — `move-to-helper`: members of a class move into a static helper that takes the class as its first
 * parameter. Pure and in-memory like `MoveMemberSliceTest`. Every Ok shape here was compile-proved on Haxe 4.3.7 by
 * writing the result and running it against the original (`--interp`, same printed value); each refusal names the
 * reason the helper could not keep the member's meaning.
 */
class MoveToHelperSliceTest extends Test {

	/** The headline source: instance state, a private constant, a private typedef, a staying static, an interpolation. */
	private static final SRC: String = 'package a;\n\nclass Src {\n\tprivate static inline final SCALE: Int = 10;\n'
		+ '\tpublic static final OPEN: Int = 3;\n\n\tprivate var count: Int = 1;\n\tprivate var hits: Int = 0;\n'
		+ '\tpublic var label: String = \'x\';\n\n\tpublic function new() {}\n\n\tpublic function go(): Int {\n'
		+ '\t\treturn total(2) + this.total(3);\n\t}\n\n\tprivate function total(k: Int): Int {\n\t\tcount++;\n\t\thits++;\n'
		+ '\t\tfinal e: Entry = { n: k };\n\t\treturn twice(e.n) * SCALE + count + OPEN + \'$$label\'.length + helperOf(this);\n'
		+ '\t}\n\n\tprivate function twice(v: Int): Int {\n\t\treturn v * 2 + count;\n\t}\n\n'
		+ '\tprivate static function helperOf(s: Src): Int {\n\t\treturn s.count;\n\t}\n}\n\nprivate typedef Entry = {\n'
		+ '\tvar n: Int;\n}\n';

	/** A caller in another file, reaching a moved member through a receiver typed as the source. */
	private static final USER: String = 'package a;\n\nclass User {\n\tpublic static function use(s: Src): Int {\n'
		+ '\t\treturn s.go() + @:privateAccess s.total(1);\n\t}\n}\n';

	/**
	 * The whole rewrite, every byte pinned. In the moved bodies: `count`/`hits` become `g.count`/`g.hits` (and stay
	 * fields of `Src` — a static helper holds no state), `this` becomes `g`, the call between moved members gains `g`, a
	 * staying static becomes `Src.helperOf`, the interpolated `$label` takes its braced form, the private constant `SCALE`
	 * and the private typedef `Entry` that only the moved code names move along. Callers: `total(2)` / `this.total(3)`
	 * become `SrcMath.total(this, …)`, the receiver caller `s.total(1)` becomes `SrcMath.total(s, 1)`. One
	 * `@:access(a.Src)` on the helper covers both bodies. Compile-proved: `User.use(new Src())` prints 240 before and after.
	 */
	@:pin('control')
	@:killer('M-HELPER-THIS-KEPT')
	@:killer('M-HELPER-MEMBER-UNQUALIFIED')
	@:killer('M-HELPER-NO-GRANT')
	@:killer('M-HELPER-FIELDS-TRAVEL')
	public function testAHelperIsCreatedAndEveryReferenceIsRewritten(): Void {
		final result: MoveResult = move(
			'total,twice', 'SrcMath', [{ file: 'a/Src.hx', source: SRC }, { file: 'a/User.hx', source: USER }], 'g'
		);
		capture(result, [
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nclass Src {\n\tpublic static final OPEN: Int = 3;\n\n\tprivate var count: Int = 1;\n\tprivate var hits: Int = 0;\n'
				+ '\tpublic var label: String = \'x\';\n\n\tpublic function new() {}\n\n\tpublic function go(): Int {\n'
				+ '\t\treturn SrcMath.total(this, 2) + SrcMath.total(this, 3);\n\t}\n\n\tprivate static function helperOf(s: Src): Int {\n'
				+ '\t\treturn s.count;\n\t}\n}\n'
			},
			{
				file: 'a/User.hx',
				source: 'package a;\n\nclass User {\n\tpublic static function use(s: Src): Int {\n\t\treturn s.go() + @:privateAccess SrcMath.total(s, 1);\n'
				+ '\t}\n}\n'
			},
			{
				file: 'a/SrcMath.hx',
				source: 'package a;\n\n/**\n * Static helpers taken out of `Src`: each reads the `Src` it is handed as its first parameter.\n'
				+ ' */\n@:access(a.Src)\nfinal class SrcMath {\n\n\tprivate static inline final SCALE: Int = 10;\n\n\tpublic static function total(g: '
				+ 'Src, k: Int): Int {\n\t\tg.count++;\n\t\tg.hits++;\n\t\tfinal e: Entry = { n: k };\n\t\treturn twice(g, e.n) * SCALE + g.count + Src.OPEN '
				+ '+ \'$${g.label}\'.length + Src.helperOf(g);\n\t}\n\n\tprivate static function twice(g: Src, v: Int): Int {\n'
				+ '\t\treturn v * 2 + g.count;\n\t}\n\n}\n\nprivate typedef Entry = {\n\tvar n: Int;\n}\n'
			}
		]);
	}

	/**
	 * What only the moved code names travels with it: the private constant `SCALE` lands in the helper as a private
	 * static, the private typedef `Entry` in the helper's module after the helper, and neither stays behind — `Entry` is
	 * then the helper module's own type, so the import carry must not refuse it as unreachable.
	 */
	@:pin('control')
	@:killer('M-HELPER-CONSTANT-STAYS')
	@:killer('M-HELPER-TYPE-STAYS')
	@:killer('M-HELPER-TRAVELLING-IMPORTED')
	public function testWhatOnlyTheMovedCodeNamesTravelsWithIt(): Void {
		final result: MoveResult = move('total,twice', 'SrcMath', [{ file: 'a/Src.hx', source: SRC }], 'g');
		final helper: String = okSource(result, 'a/SrcMath.hx');
		final source: String = okSource(result, 'a/Src.hx');
		Assert.isTrue(helper.contains('private static inline final SCALE: Int = 10;'), helper);
		Assert.isTrue(helper.endsWith('private typedef Entry = {\n\tvar n: Int;\n}\n'), helper);
		Assert.isFalse(source.contains('SCALE'), source);
		Assert.isFalse(source.contains('Entry'), source);
	}

	/**
	 * Calls nested at ONE offset keep the outer call first: `add(add(1))`, `self().add(3)` and `this.self().self().add(4)`
	 * become `add(src, add(src, 1))`, `add(self(src), 3)` and `add(self(self(src)), 4)`. Each rewrite inserts its head at
	 * the receiver's start, and two insertions at one offset land in reverse push order, so the rewrites are pushed
	 * innermost first. The default parameter name is the source type's with a lower-case initial. Compile-proved: 46.
	 */
	@:pin('control')
	@:killer('M-HELPER-CALL-ORDER')
	public function testNestedCallsKeepTheOuterCallFirst(): Void {
		final src: String = 'package a;\n\nclass Src {\n\tvar n: Int = 2;\n\n\tpublic function new() {}\n\n\tpublic function self(): Src {\n'
			+ '\t\treturn this;\n\t}\n\n\tpublic function add(k: Int): Int {\n\t\treturn n + k;\n\t}\n\n\tpublic function chain(): Int {\n'
			+ '\t\treturn add(add(1)) + self().add(3) + this.self().self().add(4);\n\t}\n}\n';
		final helper: String = okSource(move('add,self,chain', 'Ops', [{ file: 'a/Src.hx', source: src }]), 'a/Ops.hx');
		Assert.isTrue(helper.contains('return add(src, add(src, 1)) + add(self(src), 3) + add(self(self(src)), 4);'), helper);
		Assert.isTrue(helper.contains('public static function self(src: Src): Src {\n\t\treturn src;'), helper);
	}

	/**
	 * A SUBTYPE in scope calls the inherited member bare (`add(5)`): no binding of the source file sees it, and it becomes
	 * `Ops.add(this, 5)`, the receiver-qualified `self().add(6)` beside it `Ops.add(Ops.self(this), 6)`. Compile-proved: 46.
	 */
	@:pin('control')
	@:killer('M-HELPER-SUBTYPE-CALLERS-SKIPPED')
	public function testASubtypesBareCallIsRewritten(): Void {
		final src: String = 'package a;\n\nclass Src {\n\tvar n: Int = 2;\n\n\tpublic function new() {}\n\n\tpublic function self(): Src {\n'
			+ '\t\treturn this;\n\t}\n\n\tpublic function add(k: Int): Int {\n\t\treturn n + k;\n\t}\n}\n';
		final sub: String =
			'package a;\n\nclass Sub extends Src {\n\tpublic function more(): Int {\n\t\treturn add(5) + self().add(6);\n\t}\n}\n';
		final out: String = okSource(
			move('add,self', 'Ops', [{ file: 'a/Src.hx', source: src }, { file: 'a/Sub.hx', source: sub }]), 'a/Sub.hx'
		);
		Assert.isTrue(out.contains('return Ops.add(this, 5) + Ops.add(Ops.self(this), 6);'), out);
	}

	/**
	 * An EXISTING helper in another package receives the members: it gains `import a.Src;` for its parameter type, the
	 * source gains `import b.Ops;` for its rewritten caller, and the helper's own members stay where they were.
	 */
	public function testAnExistingHelperInAnotherPackageIsWiredBothWays(): Void {
		final src: String = 'package a;\n\nclass Src {\n\tpublic var n: Int = 2;\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function add(k: Int): Int {\n\t\treturn n + k;\n\t}\n\n\tpublic function go(): Int {\n\t\treturn add(1);\n\t}\n}\n';
		final ops: String = 'package b;\n\nclass Ops {\n\tpublic static function zero(): Int {\n\t\treturn 0;\n\t}\n}\n';
		final result: MoveResult = move('add', 'Ops', [{ file: 'a/Src.hx', source: src }, { file: 'b/Ops.hx', source: ops }]);
		final helper: String = okSource(result, 'b/Ops.hx');
		final source: String = okSource(result, 'a/Src.hx');
		Assert.isTrue(helper.contains('import a.Src;'), helper);
		Assert.isTrue(helper.contains('public static function zero(): Int'), helper);
		Assert.isTrue(helper.contains('public function add(src: Src, k: Int): Int {\n\t\treturn src.n + k;') == false, helper);
		Assert.isTrue(helper.contains('public static function add(src: Src, k: Int): Int {\n\t\treturn src.n + k;'), helper);
		Assert.isTrue(source.contains('import b.Ops;'), source);
		Assert.isTrue(source.contains('return Ops.add(this, 1);'), source);
	}

	/**
	 * A moved STATIC member moves as `move-member` moves one: `Src.twice(…)` callers across the scope become
	 * `Ops.twice(…)`, and the moved instance member's call of it stays bare in the helper.
	 */
	public function testAMovedStaticMovesAsMoveMemberMovesOne(): Void {
		final src: String = 'package a;\n\nclass Src {\n\tpublic var n: Int = 2;\n\n\tpublic function new() {}\n\n'
			+ '\tpublic static function twice(v: Int): Int {\n\t\treturn v * 2;\n\t}\n\n\tpublic function add(): Int {\n'
			+ '\t\treturn twice(n);\n\t}\n}\n';
		final user: String = 'package a;\n\nclass User {\n\tpublic static function run(): Int {\n\t\treturn Src.twice(3);\n\t}\n}\n';
		final result: MoveResult = move('twice,add', 'Ops', [{ file: 'a/Src.hx', source: src }, { file: 'a/User.hx', source: user }]);
		Assert.isTrue(okSource(result, 'a/User.hx').contains('return Ops.twice(3);'));
		Assert.isTrue(okSource(result, 'a/Ops.hx').contains('return twice(src.n);'));
	}

	/** The arm-retarget hint: an arm on a moved member is retargeted, and one whose `find` the rewrite changed is flagged. */
	@:pin('control')
	@:killer('M-HELPER-ARM-RETARGET-NONE')
	@:killer('M-HELPER-ARM-STALE-NONE')
	public function testTheArmHintRetargetsAndFlagsAStaleFind(): Void {
		final changes: Array<MoveChange> = switch move('total,twice', 'SrcMath', [{ file: 'a/Src.hx', source: SRC }], 'g') {
			case Ok(c, _): c;
			case Err(message):
				Assert.fail(message);
				return;
		};
		final arms: String = '{"arms": [{"name": "M-A", "type": "a.Src", "method": "twice", "find": "v * 2", "replace": "v"},'
			+ ' {"name": "M-B", "type": "a.Src", "method": "twice", "find": "return v * 2 + count;", "replace": "return 0;"},'
			+ ' {"name": "M-C", "type": "a.Src", "method": "go", "find": "total(2)", "replace": "0"}]}';
		final hints: Array<String> = MoveToHelperArms.hints(arms, changes, 'Src', 'SrcMath', new HaxeQueryPlugin());
		Assert.same([
			'arm M-A: retarget "a.Src#twice" -> "a.SrcMath#twice"',
			'arm M-B: retarget "a.Src#twice" -> "a.SrcMath#twice"',
			'arm M-B: its find no longer occurs in "a.SrcMath#twice" — re-aim it',
			'arm M-C: its find no longer occurs in "a.Src#go" — re-aim it'
		], hints);
	}

	// ---- refusals ----

	/**
	 * The command: `--dry-run` prints the helper it would create and writes nothing, `--write` creates it beside the source.
	 */
	@:pin('control')
	@:killer('M-HELPER-DRY-RUN-WRITES')
	public function testTheDryRunWritesNothingAndTheWriteCreatesTheHelper(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('movetohelper', [{ name: 'a/Src.hx', source: SRC }]);
		CliFixture.always(() -> CliFixture.removeDir(dir), () -> {
			final args: Array<String> = [
				'move-to-helper',
				'$dir/a/Src.hx',
				'total,twice',
				'--to',
				'SrcMath',
				'--scope',
				dir,
				'--param',
				'g'
			];
			final printed: String = CliFixture.captureStdout(() -> Assert.equals(0, Cli.run(args.concat(['--dry-run']))));
			Assert.isTrue(printed.contains('=== $dir/a/SrcMath.hx (created) ==='), printed);
			Assert.isFalse(FileSystem.exists('$dir/a/SrcMath.hx'), 'a dry run writes nothing');
			Assert.equals(0, Cli.run(args.concat(['--write'])));
			Assert.isTrue(File.getContent('$dir/a/SrcMath.hx').contains('public static function total(g'), 'the helper is created');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-HELPER-ACCESSOR-ALLOWED')
	public function testAPropertyAccessorIsRefused(): Void {
		final src: String = 'package a;\n\nclass Src {\n\tpublic var p(get, set): Int;\n\t@:isVar var q(default, default): Int = 0;\n\n'
			+ '\tpublic function new() {}\n\n\tfunction get_p(): Int {\n\t\treturn q;\n\t}\n\n\tfunction set_p(v: Int): Int {\n'
			+ '\t\treturn q = v;\n\t}\n}\n';
		refused(move('set_p', 'Ops', [{ file: 'a/Src.hx', source: src }]), 'accessor of the property "p"');
	}

	@:pin('control')
	@:killer('M-HELPER-FIELD-ALLOWED')
	public function testAnInstanceFieldIsRefused(): Void {
		final src: String = 'package a;\n\nclass Src {\n\tvar n: Int = 1;\n\n\tpublic function new() {}\n}\n';
		refused(move('n', 'Ops', [{ file: 'a/Src.hx', source: src }]), 'it is an instance field');
	}

	@:pin('control')
	@:killer('M-HELPER-MODIFIER-ALLOWED')
	public function testADynamicMemberIsRefused(): Void {
		final src: String =
			'package a;\n\nclass Src {\n\tpublic function new() {}\n\n\tdynamic function f(): Int {\n\t\treturn 1;\n\t}\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }]), 'it is declared `dynamic`');
	}

	@:pin('control')
	@:killer('M-HELPER-MODIFIER-ALLOWED')
	public function testAMacroMemberIsRefused(): Void {
		final src: String =
			'package a;\n\nclass Src {\n\tpublic function new() {}\n\n\tmacro function f() {\n\t\treturn macro 1;\n\t}\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }]), 'it is declared `macro`');
	}

	@:pin('control')
	@:killer('M-MOVE-OVERRIDE-MEMBER')
	public function testAnOverrideIsRefused(): Void {
		final base: String = 'package a;\n\nclass Base {\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n}\n';
		final src: String = 'package a;\n\nclass Src extends Base {\n\tpublic function new() {}\n\n\toverride public function f(): Int {\n'
			+ '\t\treturn 2;\n\t}\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }, { file: 'a/Base.hx', source: base }]), 'it overrides');
	}

	@:pin('control')
	@:killer('M-MOVE-OVERRIDDEN-MEMBER')
	public function testAMemberASubtypeOverridesIsRefused(): Void {
		final src: String =
			'package a;\n\nclass Src {\n\tpublic function new() {}\n\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n}\n';
		final sub: String = 'package a;\n\nclass Sub extends Src {\n\toverride public function f(): Int {\n\t\treturn 2;\n\t}\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }, { file: 'a/Sub.hx', source: sub }]), 'a subtype of "Src" declares it');
	}

	@:pin('control')
	@:killer('M-MOVE-IMPLEMENTATION')
	public function testAnInterfaceImplementationIsRefused(): Void {
		final iface: String = 'package a;\n\ninterface I {\n\tfunction f(): Int;\n}\n';
		final src: String =
			'package a;\n\nclass Src implements I {\n\tpublic function new() {}\n\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n}\n';
		refused(
			move('f', 'Ops', [{ file: 'a/Src.hx', source: src }, { file: 'a/I.hx', source: iface }]),
			'"I", a supertype of "Src", declares it'
		);
	}

	@:pin('control')
	@:killer('M-HELPER-VALUE-USE-ALLOWED')
	public function testAMemberPassedAsAFunctionValueIsRefused(): Void {
		final src: String = 'package a;\n\nclass Src {\n\tpublic function new() {}\n\n\tpublic function f(x: Int): Int {\n\t\treturn x;\n\t}\n\n'
			+ '\tpublic function g(): Array<Int> {\n\t\treturn [1].map(f);\n\t}\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }]), '"f" is used as a function value at a/Src.hx:11:18');
	}

	@:pin('control')
	@:killer('M-HELPER-RECEIVER-VALUE-ALLOWED')
	public function testABoundMemberIsRefused(): Void {
		final src: String = 'package a;\n\nclass Src {\n\tpublic function new() {}\n\n\tpublic function f(x: Int): Int {\n\t\treturn x;\n\t}\n\n'
			+ '\tpublic function g(): () -> Int {\n\t\treturn this.f.bind(1);\n\t}\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }]), '"f" is used as a function value');
	}

	@:pin('control')
	@:killer('M-HELPER-SUPER-ALLOWED')
	public function testASuperAccessIsRefused(): Void {
		final base: String =
			'package a;\n\nclass Base {\n\tpublic function new() {}\n\n\tpublic function b(): Int {\n\t\treturn 1;\n\t}\n}\n';
		final src: String = 'package a;\n\nclass Src extends Base {\n\tpublic function f(): Int {\n\t\treturn super.b();\n\t}\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }, { file: 'a/Base.hx', source: base }]), 'reaches `super`');
	}

	@:pin('control')
	@:killer('M-HELPER-UNRESOLVED-ALLOWED')
	public function testAnUnresolvedReferenceIsRefused(): Void {
		final src: String = 'package a;\n\nclass Src extends lib.Far {\n\tpublic function new() {}\n\n\tpublic function f(): Int {\n'
			+ '\t\treturn farValue + 1;\n\t}\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }]), 'cannot resolve "farValue" at a/Src.hx:7:10');
	}

	@:pin('control')
	@:killer('M-HELPER-MODULE-VALUE-ALLOWED')
	public function testAModuleLevelValueIsRefused(): Void {
		final src: String = 'package a;\n\nclass Src {\n\tpublic function new() {}\n\n\tpublic function f(): Int {\n\t\treturn helper();\n\t}\n}\n\n'
			+ 'function helper(): Int {\n\treturn 1;\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }]), 'a module-level declaration of a/Src.hx');
	}

	@:pin('control')
	@:killer('M-HELPER-SHARED-TYPE-ALLOWED')
	public function testAPrivateTypeTheStayingCodeNamesIsRefused(): Void {
		final src: String = 'package a;\n\nclass Src {\n\tpublic function new() {}\n\n\tpublic function f(e: Entry): Int {\n\t\treturn e.n;\n\t}\n\n'
			+ '\tpublic function g(): Entry {\n\t\treturn { n: 1 };\n\t}\n}\n\nprivate typedef Entry = {\n\tvar n: Int;\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }]), 'the private type "Entry" is named both');
	}

	@:pin('control')
	@:killer('M-HELPER-PARAM-CLASH-UNCHECKED')
	public function testAParameterNameTheMovedCodeSpellsIsRefused(): Void {
		final src: String = 'package a;\n\nclass Src {\n\tvar n: Int = 1;\n\n\tpublic function new() {}\n\n\tpublic function f(g: Int): Int {\n'
			+ '\t\treturn g + n;\n\t}\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }], 'g'), 'the moved code already spells "g" at a/Src.hx:8:20');
	}

	@:pin('control')
	@:killer('M-HELPER-GENERIC-ALLOWED')
	public function testAGenericSourceIsRefused(): Void {
		final src: String = 'package a;\n\nclass Src<T> {\n\tvar v: Null<T> = null;\n\n\tpublic function new() {}\n\n\tpublic function f(): Null<T> {\n'
			+ '\t\treturn v;\n\t}\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }]), '"Src" is generic');
	}

	@:pin('control')
	@:killer('M-HELPER-NON-CLASS-ALLOWED')
	public function testANonClassSourceIsRefused(): Void {
		final src: String = 'package a;\n\nabstract Src(Int) {\n\tpublic function f(): Int {\n\t\treturn this + 1;\n\t}\n}\n';
		refused(move('f', 'Ops', [{ file: 'a/Src.hx', source: src }]), '"Src" is not a class');
	}

	private static function move(
		names: String, helper: String, files: Array<{ file: String, source: String }>, ?param: String
	): MoveResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return MoveToHelper.move('a/Src.hx', 'Src', names.split(','), helper, null, param, files, plugin, plugin.typeRefShape());
	}

	private static function okSource(result: MoveResult, file: String): String {
		return switch result {
			case Ok(changes, _): changes.find(c -> c.file == file)?.newSource ?? 'NO CHANGE FOR $file';
			case Err(message): 'Err: $message';
		};
	}

	private static function refused(result: MoveResult, reason: String): Void {
		switch result {
			case Ok(changes, _):
				Assert.fail('expected a refusal naming "$reason", got Ok over ${[for (c in changes) c.file].join(', ')}');
			case Err(message):
				Assert.isTrue(message.contains(reason), message);
		}
	}

	private function capture(result: MoveResult, expected: Array<{ file: String, source: String }>): Void {
		switch result {
			case Ok(changes, _):
				Assert.equals(expected.length, changes.length, 'changed-file count, got ${[for (c in changes) c.file].join(', ')}');
				for (e in expected) {
					final change: Null<MoveChange> = changes.find(c -> c.file == e.file);
					if (change == null)
						Assert.fail('no change for ${e.file}');
					else
						Assert.equals(e.source, change.newSource, 'byte capture for ${e.file}');
				}
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

}
