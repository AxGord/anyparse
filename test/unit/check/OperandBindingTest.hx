package unit.check;

import anyparse.check.Check;
import anyparse.check.DoubleNegation;
import anyparse.check.FoldStringLiterals;
import anyparse.check.InvertNegatedIfElse;
import anyparse.check.JoinStringAppend;
import anyparse.check.RedundantToString;
import anyparse.check.SimplifyNegatedCompound;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * `OperatorSelection` judges an operand by the declaration its type BINDS to where the type is
 * written, never by the simple name. Every fixture holds an indexed PLAIN class of the operand's
 * type name in the using file's own package — the declaration a by-name lookup finds — while the
 * compiler binds the name to something else: an overloading abstract outside the index
 * (`far.Tag`), a type parameter, a wrapped overloader. Each unsafe case was compile-and-run
 * verified on Haxe 4.3.7 `--interp`: `t + 'x' + 'y'` prints `r/x/y`, the folded `'${t}xy'` prints
 * `rxy`. `lib.Dir` overloads `+` only so that the gate asks at all.
 */
class OperandBindingTest extends Test {

	/** An overloader of `+` somewhere in the run, so `OperatorSelection.declared` answers yes. */
	private static final DIR: String = 'package lib;\n\nabstract Dir(String) from String to String {\n\n'
		+ '\t@:op(A + B) public inline function add(a: String): Dir return cast this + \'/\' + a;\n\n}\n';

	/** The plain class a simple-name lookup would take for the operand's type. */
	private static final PLAIN_TAG: String = 'package u;\n\nclass Tag {\n\n\tpublic function new() {}\n\n}\n';

	@:pin('control')
	@:killer('M-BINDING-UNINDEXED-IMPORT-FREE')
	public function testImportOfUnindexedTypeOutranksSamePackageClass(): Void {
		Assert.equals(REPORT_ONLY, fold(['u/Tag.hx' => PLAIN_TAG], 'import far.Tag;', 't: Tag', 't + \''));
	}

	@:pin('control')
	@:killer('M-OPERAND-SIMPLE-NAME')
	public function testImportOfUnindexedTypeIsNotItsIndexedNamesake(): Void {
		Assert.equals(
			REPORT_ONLY, fold(['other/Tag.hx' => PLAIN_TAG.replace('package u', 'package other')], 'import far.Tag;', 't: Tag', 't + \'')
		);
	}

	@:pin('control')
	@:killer('M-BINDING-ALIAS-BLIND')
	public function testAliasOfUnindexedTypeOutranksSamePackageClass(): Void {
		Assert.equals(REPORT_ONLY, fold(['u/T.hx' => PLAIN_TAG.replace('class Tag', 'class T')], 'import far.Tag as T;', 't: T', 't + \''));
	}

	@:pin('control')
	@:killer('M-BINDING-UNINDEXED-WILDCARD-FREE')
	public function testWildcardOverUnindexedPackageOutranksSamePackageClass(): Void {
		Assert.equals(REPORT_ONLY, fold(['u/Tag.hx' => PLAIN_TAG], 'import far.*;', 't: Tag', 't + \''));
	}

	@:pin('control')
	@:killer('M-BINDING-UNINDEXED-IMPORT-FREE')
	public function testAmbientImportOfUnindexedTypeOutranksSamePackageClass(): Void {
		#if (sys || nodejs)
		// The ambient chain is read from DISK beside the module, so this fixture is a real tree.
		final root: String = CliFixture.writeTree('apq_operand_ambient', [{ name: 'u/import.hx', source: 'import far.Tag;\n' }]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			Assert.equals(REPORT_ONLY, fold(['u/Tag.hx' => PLAIN_TAG], '', 't: Tag', 't + \'', root));
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-BINDING-UNINDEXED-MODULE-FREE')
	public function testSubTypeOfUnindexedModuleOutranksSamePackageClass(): Void {
		Assert.equals(REPORT_ONLY, fold(['u/Tag.hx' => PLAIN_TAG], 'import far.Mod;', 't: Tag', 't + \''));
	}

	/** Without any import the same-package class IS what the name binds to, and the fold is proven. */
	@:pin('control')
	@:killer('M-BINDING-PACKAGE-TIER-CUT')
	public function testSamePackageClassIsProven(): Void {
		Assert.equals(FIXABLE, fold(['u/Tag.hx' => PLAIN_TAG], '', 't: Tag', 't + \''));
	}

	/** `Null<Dir>` selects `Dir`'s own `+`: the wrapper is peeled, so the overload is SEEN, not merely unproven. */
	@:pin('control')
	@:killer('M-OPERAND-WRAPPER-KEPT')
	public function testNullableOverloaderIsOverloaded(): Void {
		Assert.equals(ABSENT, fold([], 'import lib.Dir;', 't: Null<Dir>', 't + \''));
	}

	/** A member's type is bound where the MEMBER is declared: `Holder.hx` imports `far.Tag`. */
	@:pin('control')
	@:killer('M-OPERAND-MEMBER-SCOPE-LOST')
	public function testMemberTypeBindsInItsDeclaringFile(): Void {
		final holder: String =
			'package h;\n\nimport far.Tag;\n\nclass Holder {\n\n\tpublic var t: Tag;\n\n\tpublic function new() {}\n\n}\n';
		Assert.equals(REPORT_ONLY, fold(['u/Tag.hx' => PLAIN_TAG, 'h/Holder.hx' => holder], 'import h.Holder;', 'h: Holder', 'h.t + \''));
	}

	/** The same chain to a `String` member is proven — the member path does type an operand. */
	@:pin('control')
	@:killer('M-OPERAND-MEMBER-CUT')
	public function testMemberOfBuiltinTypeIsProven(): Void {
		final holder: String = 'package h;\n\nclass Holder {\n\n\tpublic var s: String;\n\n\tpublic function new() {}\n\n}\n';
		Assert.equals(FIXABLE, fold(['h/Holder.hx' => holder], 'import h.Holder;', 'h: Holder', 'h.s + \''));
	}

	/** A method's own type parameter shadows the same-package class in its return type. */
	@:pin('control')
	@:killer('M-OPERAND-METHOD-PARAMS-IGNORED')
	public function testMethodTypeParameterIsNotTheSamePackageClass(): Void {
		final holder: String = 'package u;\n\nclass Holder {\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function pick<Tag>(v: Tag): Tag {\n\t\treturn v;\n\t}\n\n}\n';
		Assert.equals(REPORT_ONLY, fold(['u/Tag.hx' => PLAIN_TAG, 'u/Holder.hx' => holder], '', 'h: Holder', 'h.pick(null) + \''));
	}

	/** A static call through a type name: `Label.text()` returns a `String` its declaring file writes. */
	@:pin('control')
	@:killer('M-OPERAND-STATIC-RECEIVER-CUT')
	public function testStaticCallThroughTypeNameIsProven(): Void {
		final label: String = 'package u;\n\nclass Label {\n\n\tpublic static function text(): String {\n\t\treturn \'l\';\n\t}\n\n}\n';
		Assert.equals(FIXABLE, fold(['u/Label.hx' => label], '', 'h: Int', 'Label.text() + \''));
	}

	/** A call to a function this file declares: its written return type, bound here. */
	@:pin('control')
	@:killer('M-OPERAND-LOCAL-CALL-CUT')
	public function testCallToFunctionOfThisFileIsProven(): Void {
		Assert.equals(FIXABLE, fold([], '', 'h: Int', 'name() + \''));
	}

	/** The shared predicate covers every rule that asks it: the join of two `+=` on the imported `Tag`. */
	@:pin('control')
	@:killer('M-BINDING-UNINDEXED-IMPORT-FREE')
	public function testJoinAppendBindsTheTarget(): Void {
		final use: String = 'package u;\n\nimport far.Tag;\n\nclass Use {\n\n\tpublic static function f(): Tag {\n'
			+ '\t\tvar r: Tag = \'root\';\n\t\tr += \'a\';\n\t\tr += \'b\';\n\t\treturn r;\n\t}\n\n}\n';
		final route: String = 'package lib;\n\nabstract Route(String) from String to String {\n\n'
			+ '\t@:op(A += B) public inline function append(s: String): Route return cast this + \'/\' + s;\n\n}\n';
		Assert.isFalse(
			reports(new JoinStringAppend(), ['lib/Route.hx' => route, 'u/Tag.hx' => PLAIN_TAG, 'u/Use.hx' => use], 'r += \'a\'')
		);
	}

	@:pin('control')
	@:killer('M-BINDING-UNINDEXED-IMPORT-FREE')
	public function testNegationRulesBindTheOperands(): Void {
		final flagDecl: String = 'package lib;\n\nabstract Flag(Bool) from Bool to Bool {\n\n'
			+ '\t@:op(A == B) public inline function eq(b: Flag): Bool return this == cast b;\n\n'
			+ '\t@:op(!A) public inline function inv(): Bool return this;\n\n}\n';
		final plain: String = 'package u;\n\nclass Flag {\n\n\tpublic function new() {}\n\n}\n';
		final use: String = 'package u;\n\nimport far.Flag;\n\nclass Use {\n\n\tpublic static function a(f: Flag, g: Flag): Bool {\n'
			+ '\t\treturn !(f == g);\n\t}\n\n\tpublic static function b(f: Flag): Bool {\n\t\treturn !!f;\n\t}\n\n'
			+ '\tpublic static function d(f: Flag, x: Int): Int {\n\t\tif (!f) return x else return -x;\n\t}\n\n}\n';
		final files: Map<String, String> = ['lib/Flag.hx' => flagDecl, 'u/Flag.hx' => plain, 'u/Use.hx' => use];
		Assert.isFalse(reports(new SimplifyNegatedCompound(), files, '!(f == g)'), 'simplify-negated-compound');
		Assert.isFalse(reports(new DoubleNegation(), files, '!!f'), 'double-negation');
		Assert.isFalse(reports(new InvertNegatedIfElse(), files, 'if (!f)'), 'invert-negated-if-else');
	}

	/**
	 * `case t:` CAPTURES the switched `Dir` — a bare lowercase identifier in a pattern binds, it never
	 * compares — so the `t` after it is the `Dir`, not the outer `String`. `r/a/b` became `rab` when
	 * folded (4.3.7 `--interp`). Two layers decline it: the reference walk binds the read to the
	 * capture itself, and the branch scan would decline the outer binding anyway — so no single cut
	 * turns this red, and it is not pinned.
	 */
	public function testCaseCaptureShadowsTheOuterBinding(): Void {
		Assert.equals(REPORT_ONLY, foldOf(['u/Use.hx' => caseUse('case t:', '')], 't + \''));
	}

	/**
	 * The same capture when a `static inline` of its name also exists: the walk cannot decide between
	 * the capture and the constant, so its read keeps resolving to the outer `String` local — which
	 * captures here, since a local outranks the constant — and only the branch scan declines it.
	 */
	@:pin('control')
	@:killer('M-OPERAND-CASE-CAPTURE')
	public function testUndecidedCaptureShadowsTheOuterBinding(): Void {
		final use: String = caseUse('case t:', '', '\tstatic inline var t: String = \'k\';\n\n');
		Assert.equals(REPORT_ONLY, foldOf(['u/Use.hx' => use], 't + \''));
	}

	/** A declaration INSIDE the branch shadows the capture in turn, so the walk's answer stands. */
	@:pin('control')
	@:killer('M-OPERAND-CASE-CAPTURE-INSIDE')
	public function testDeclarationInsideTheBranchOutranksItsCapture(): Void {
		Assert.equals(FIXABLE, foldOf(['u/Use.hx' => caseUse('case t:', 'final t: String = \'q\'; ')], 't + \''));
	}

	/** An extern `@:overload` may select a signature returning the overloader: the written `String` proves nothing. */
	@:pin('control')
	@:killer('M-OPERAND-OVERLOAD-SIGNATURE')
	public function testOverloadedSignatureIsNotItsWrittenReturn(): Void {
		Assert.equals(REPORT_ONLY, fold(['u/Ext.hx' => EXT], '', 'h: Int', 'Ext.m(1) + \''));
	}

	@:pin('control')
	@:killer('M-INDEX-OVERLOAD-META')
	public function testOverloadMetaIsIndexed(): Void {
		Assert.equals(REPORT_ONLY, fold(['u/Ext.hx' => EXT], '', 'h: Int', 'Ext.m(1) + \''));
	}

	/** A macro's written return is what it BUILDS, not the type the call site receives. */
	@:pin('control')
	@:killer('M-OPERAND-MACRO-RETURN')
	public function testMacroMemberIsNotTypedByItsReturn(): Void {
		final gen: String = 'package u;\n\nclass Gen {\n\n\tpublic static macro function m(): String {\n\t\treturn null;\n\t}\n\n}\n';
		Assert.equals(REPORT_ONLY, fold(['u/Gen.hx' => gen], '', 'h: Int', 'Gen.m() + \''));
	}

	/** The same for an unqualified call to a macro the file itself declares. */
	@:pin('control')
	@:killer('M-OPERAND-LOCAL-MACRO')
	public function testLocalMacroIsNotTypedByItsReturn(): Void {
		final use: String = 'package u;\n\nclass Use {\n\n\tpublic static function f(): String {\n\t\treturn gen() + \'a\' + \'b\';\n\t}\n\n'
			+ '\tprivate static macro function gen(): String {\n\t\treturn null;\n\t}\n\n}\n';
		Assert.equals(REPORT_ONLY, foldOf(['u/Use.hx' => use], 'gen() + \''));
	}

	/**
	 * A member's nullable return, written as a PATH into an unindexed module (`far.MaybeR`, an alias of
	 * `Null<R>`), is not the same-package class of that last segment: `redundant-tostring` keeps the
	 * call that throws on null.
	 */
	@:pin('control')
	@:killer('M-NULLITY-RETURN-LAST-SEGMENT')
	public function testMemberReturnPathIsNotItsLastSegment(): Void {
		final holder: String = 'package u;\n\nclass Holder {\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function get(): far.MaybeR {\n\t\treturn null;\n\t}\n\n}\n';
		Assert.isFalse(dropsToString(['u/MaybeR.hx' => MAYBE, 'u/Holder.hx' => holder]));
	}

	/** And `@:overload` there: the other signature's `Null<MaybeR>` is a return the call may select. */
	@:pin('control')
	@:killer('M-NULLITY-RETURN-OVERLOAD')
	public function testMemberReturnWithOverloadIsUnproven(): Void {
		final holder: String = 'package u;\n\nextern class Holder {\n\n\tpublic function new();\n\n'
			+ '\t@:overload(function(x: Int): Null<MaybeR> {})\n\tpublic function get(): MaybeR;\n\n}\n';
		Assert.isFalse(dropsToString(['u/MaybeR.hx' => MAYBE, 'u/Holder.hx' => holder]));
	}

	/** Without the path or the overload the same member IS proven, so the pair above is discriminating. */
	@:pin('control')
	@:killer('M-NULLITY-RETURN-CUT')
	public function testMemberReturnOfIndexedClassIsProven(): Void {
		final holder: String = 'package u;\n\nclass Holder {\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function get(): MaybeR {\n\t\treturn new MaybeR();\n\t}\n\n}\n';
		Assert.isTrue(dropsToString(['u/MaybeR.hx' => MAYBE, 'u/Holder.hx' => holder]));
	}

	/** An extern whose `@:overload` returns the `+` overloader while the written signature returns `String`. */
	private static final EXT: String = 'package u;\n\nextern class Ext {\n\n'
		+ '\t@:overload(function(x: Int): lib.Dir {})\n\tpublic static function m(x: String): String;\n\n}\n';

	/** A class with a `toString`, named like the unindexed nullable alias `far.MaybeR`. */
	private static final MAYBE: String = 'package u;\n\nclass MaybeR {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function toString(): String {\n\t\treturn \'M\';\n\t}\n\n}\n';

	/** A `Use` whose outer `t: String` meets a switch over a `lib.Dir` with `pattern`, the branch body led by `lead`. */
	private static function caseUse(pattern: String, lead: String, members: String = ''): String {
		return 'package u;\n\nimport lib.Dir;\n\nclass Use {\n\n${members}\tpublic static function f(d: Dir): String {\n'
			+ '\t\tfinal t: String = \'q\';\n\t\tswitch d {\n\t\t\t$pattern\n\t\t\t\t${lead}return t + \'a\' + \'b\';\n\t\t}\n'
			+ '\t\treturn t;\n\t}\n\n}\n';
	}

	/** Whether `redundant-tostring` offers to drop `.toString()` off `h.get()` in a null-safe `Use`. */
	private static function dropsToString(files: Map<String, String>): Bool {
		final use: String = 'package u;\n\n@:nullSafety(Strict)\nclass Use {\n\n\tpublic static function f(h: Holder): String {\n'
			+ '\t\treturn \'$${h.get().toString()}x\';\n\t}\n\n}\n';
		final all: Map<String, String> = files.copy();
		all['u/Use.hx'] = use;
		return violationsAt(
			new RedundantToString(), all, 'h.get().toString()'
		).exists(v -> v.message.indexOf('not provably non-null') == -1);
	}

	/**
	 * `h.get()` on the imported `far.Holder` (unindexed) is typed by where `h`'s type BINDS, not by the
	 * simple name `Holder`: the same-package `u.Holder.get()` returns a class, `far.Holder.get()` an
	 * abstract overloading `+` (`s + h.get().toString()` printed `sTS`, dropped `s/OP/r`).
	 */
	@:pin('control')
	@:killer('M-TOSTRING-CALL-BY-NAME')
	public function testToStringCallReceiverBindsItsOwner(): Void {
		Assert.equals(REPORT_ONLY, toStringOf(TAGISH_TREE, 'import far.Holder;', 'h: Holder', 'h.get().toString()', '\'s\''));
	}

	/** The same call on the same-package `Holder` is proven, so the pair above is discriminating. */
	@:pin('control')
	@:killer('M-TOSTRING-CALL-CUT')
	public function testToStringCallReceiverOfIndexedOwnerIsProven(): Void {
		Assert.equals(FIXABLE, toStringOf(TAGISH_TREE, '', 'h: Holder', 'h.get().toString()'));
	}

	/** A local of an indexed class is proven through its binding. */
	@:pin('control')
	@:killer('M-TOSTRING-IDENT-CUT')
	public function testToStringIdentReceiverOfIndexedClassIsProven(): Void {
		Assert.equals(FIXABLE, toStringOf(TAGISH_TREE, '', 't: Tagish', 't.toString()'));
	}

	/** `String` imported from an unindexed module is not the built-in: the `+` is not proven concatenation. */
	@:pin('control')
	@:killer('M-TOSTRING-STRING-BINDING')
	public function testShadowedStringIsNotTheBuiltin(): Void {
		Assert.equals(ABSENT, toStringOf(TAGISH_TREE, 'import far.String;', 't: Tagish', 't.toString()'));
	}

	/** A same-package `Tagish` class with a `toString`, and a `Holder` whose `get()` returns one. */
	private static final TAGISH_TREE: Map<String, String> = [
		'u/Tagish.hx' => 'package u;\n\nclass Tagish {\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function toString(): String {\n\t\treturn \'C\';\n\t}\n\n}\n',
		'u/Holder.hx' => 'package u;\n\nclass Holder {\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function get(): Tagish {\n\t\treturn new Tagish();\n\t}\n\n}\n'
	];

	/**
	 * What `redundant-tostring` makes of `<left> + <call>` in a null-safe `u/Use.hx` with `imports` whose
	 * function takes `param` and `s: String`: fixed, reported without the fix, or not reported. An import
	 * of an unindexed module may declare a `String` of its own, so such a test leads with a literal.
	 */
	private static function toStringOf(
		extra: Map<String, String>, imports: String, param: String, call: String, left: String = 's'
	): String {
		final use: String = 'package u;\n\n$imports\n\n@:nullSafety(Strict)\nclass Use {\n\n'
			+ '\tpublic static function f($param, s: String): String {\n\t\treturn $left + $call;\n\t}\n\n}\n';
		final files: Map<String, String> = extra.copy();
		files['u/Use.hx'] = use;
		final found: Array<Violation> = violationsAt(new RedundantToString(), files, call);
		return if (found.length == 0)
			ABSENT
		else if (found.exists(v -> v.message.indexOf(', but ') != -1))
			REPORT_ONLY
		else
			FIXABLE;
	}

	private static inline final FIXABLE: String = 'fixable';
	private static inline final REPORT_ONLY: String = 'report-only';
	private static inline final ABSENT: String = 'absent';

	/**
	 * What `fold-adjacent-string-literals` makes of `<operand> + 'a' + 'b'` in `u/Use.hx`, a class
	 * with `imports` whose function takes `param` and also declares `name(): String`, beside `extra`
	 * and `lib.Dir`: fixed, reported without the fix, or not reported at all.
	 */
	private static function fold(extra: Map<String, String>, imports: String, param: String, needle: String, root: String = ''): String {
		final expr: String = needle.substr(0, needle.length - 1) + '\'a\' + \'b\'';
		final use: String = 'package u;\n\n$imports\n\nclass Use {\n\n\tpublic static function f($param): String {\n'
			+ '\t\treturn $expr;\n\t}\n\n\tprivate static function name(): String {\n\t\treturn \'n\';\n\t}\n\n}\n';
		final files: Map<String, String> = extra.copy();
		files['u/Use.hx'] = use;
		return foldOf(files, needle, root);
	}

	/** What `fold-adjacent-string-literals` makes of the construct at `needle` in `files`' `u/Use.hx`. */
	private static function foldOf(files: Map<String, String>, needle: String, root: String = ''): String {
		final found: Array<Violation> = violationsAt(new FoldStringLiterals(), files, needle, root);
		return if (found.length == 0)
			ABSENT
		else if (found.exists(v -> v.message.indexOf('overloads the concatenation operator') != -1))
			REPORT_ONLY
		else
			FIXABLE;
	}

	private static function reports(check: Check, files: Map<String, String>, needle: String): Bool {
		return violationsAt(check, files, needle).length > 0;
	}

	/**
	 * The findings of `check` over `files` plus `lib/Dir.hx` whose span covers `needle` in `u/Use.hx`,
	 * every path under `root` when one is given.
	 */
	private static function violationsAt(check: Check, files: Map<String, String>, needle: String, root: String = ''): Array<Violation> {
		final use: String = files['u/Use.hx'] ?? '';
		final at: Int = use.indexOf(needle);
		Assert.isTrue(at >= 0, 'the fixture holds $needle');
		final prefix: String = root == '' ? '' : '$root/';
		final run: Array<{ file: String, source: String }> = [{ file: '${prefix}lib/Dir.hx', source: DIR }];
		for (file => source in files) run.push({ file: '$prefix$file', source: source });
		#if (sys || nodejs)
		// A module's ambient chain is read beside it on disk, so a tree under `root` is written out whole.
		if (root != '') for (entry in run) {
			sys.FileSystem.createDirectory(haxe.io.Path.directory(entry.file));
			sys.io.File.saveContent(entry.file, entry.source);
		}
		#end
		return check.run(run, new HaxeQueryPlugin()).filter(v -> {
			final span: Null<Span> = v.span;
			return v.file == '${prefix}u/Use.hx' && span != null && span.from <= at && at < span.to;
		});
	}

}
