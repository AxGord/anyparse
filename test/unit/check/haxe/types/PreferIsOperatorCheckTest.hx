package unit.check.haxe.types;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.RuleCategory;
import anyparse.check.Severity;
import anyparse.check.common.imports.UnusedImport;
import anyparse.check.haxe.types.PreferIsOperator;
import anyparse.query.CanonicalEdit;
import anyparse.query.StdResolver;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * The `prefer-is-operator` check: a two-argument `Std.isOfType(x, T)` whose receiver binds the std's `Std` and whose
 * second argument is a bare name binding no value is flagged `Info` and rewritten to `x is T`, parenthesised where the
 * parser would read the operator otherwise. A value argument, a shadowed or unread `Std`, a dotted argument, a comment the
 * rewrite would drop, a syntax position and a project older than the operator are left alone.
 */
class PreferIsOperatorCheckTest extends Test {

	private static inline final TYPES: String = 'class Base {\n\tpublic var visible:Bool = true;\n\n\tpublic function new() {}\n}\n\n'
		+ 'class Clip extends Base {}\n\n';

	/** The three shapes the rule exists for, and a value operand that would bind across the operator bare. */
	@:pin('control')
	@:killer('M-ISOP-PARENS-DROPPED')
	public function testCallsNamingATypeBecomeTheOperator(): Void {
		final src: String = TYPES
			+ 'class C {\n\tfunction hide(c:Array<Base>, i:Int):Void {\n\t\tc[i].visible = !Std.isOfType(c[i], Clip);\n\t}\n\n'
			+ '\tfunction nonEmpty(res:Dynamic):Bool {\n\t\treturn Std.isOfType(res, Array) && res.length > 0;\n\t}\n\n'
			+ '\tfunction f(obj:Dynamic, s:String):Void {\n\t\tif (Std.isOfType(obj, Base)) trace(Std.isOfType(s + 1, String));\n\t}\n}';
		final found: Array<Violation> = CheckFixture.violations(new PreferIsOperator(), src);
		Assert.equals(4, found.length);
		Assert.equals(Severity.Info, found[0].severity);
		Assert.equals('this Std.isOfType() call names a type: it can be the is operator', found[0].message);
		final fixed: String = fixedSource(src);
		Assert.stringContains('c[i].visible = !(c[i] is Clip);', fixed);
		Assert.stringContains('return res is Array && res.length > 0;', fixed);
		Assert.stringContains('if (obj is Base) trace((s + 1) is String);', fixed);
	}

	/** A parameter or a field holding a class is a value: the call reads it, the operator would read a type of its name. */
	@:pin('control')
	@:killer('M-ISOP-VALUE-ARGUMENT')
	public function testAValueArgumentIsLeftAlone(): Void {
		final src: String = '${TYPES}class C {\n\tstatic final KIND:Class<Base> = Clip;\n\n\tfunction count(items:Array<Base>, '
			+ 'type:Class<Base>):Int {\n\t\tvar n:Int = 0;\n\t\tfor (b in items) if (Std.isOfType(b, type) || Std.isOfType(b, '
			+ 'KIND)) n++;\n\t\treturn n;\n\t}\n\n\tfunction clip(b:Base):Bool {\n\t\treturn Std.isOfType(b, Clip);\n\t}\n}';
		final found: Array<Violation> = CheckFixture.violations(new PreferIsOperator(), src);
		Assert.equals(1, found.length, 'only the type argument');
		Assert.stringContains('return b is Clip;', fixedSource(src));
	}

	/** A `Std` the module declares is not the type the operator calls. */
	@:pin('control')
	@:killer('M-STDBIND-PROJECT-DECL-TRUSTED')
	public function testAProjectStdIsLeftAlone(): Void {
		final src: String = '${TYPES}private class Std {\n\tpublic static function isOfType(v:Dynamic, t:Dynamic):Bool {\n\t\treturn '
			+ 'false;\n\t}\n}\n\nclass C {\n\tfunction f(v:Dynamic):Bool {\n\t\treturn Std.isOfType(v, Base);\n\t}\n}';
		Assert.equals(0, CheckFixture.violations(new PreferIsOperator(), src).length);
	}

	/** A wildcard over a package the run does not read may bind `Std` to a module of it. */
	@:pin('control')
	@:killer('M-INTERP-UNKNOWN-TIER-TRUSTED')
	public function testAnUnreadStdImportIsLeftAlone(): Void {
		final src: String = 'import lib.*;\n\n${TYPES}class C {\n\tfunction f(v:Dynamic):Bool {\n\t\treturn Std.isOfType(v, Base);\n\t}\n}';
		Assert.equals(0, CheckFixture.violations(new PreferIsOperator(), src).length);
	}

	/** A local named `Std` is the call's receiver, a value. */
	@:pin('control')
	@:killer('M-ISOP-STD-VALUE')
	public function testALocalNamedStdIsLeftAlone(): Void {
		final src: String = '${TYPES}class Checker {\n\tpublic function new() {}\n\n'
			+ '\tpublic function isOfType(v:Dynamic, t:Dynamic):Bool {\n\t\treturn true;\n\t}\n}\n\nclass C {\n\tfunction '
			+ 'f(v:Dynamic):Bool {\n\t\tfinal Std:Checker = new Checker();\n\t\treturn Std.isOfType(v, Base);\n\t}\n}';
		Assert.equals(0, CheckFixture.violations(new PreferIsOperator(), src).length);
	}

	/**
	 * A module `Std` in the file's own package shadows the std's, and a run that lints only the reading file holds no
	 * declaration to see it by; the same file with the shadow gone is flagged, so the 0 is the shadow's.
	 */
	@:pin('control')
	@:killer('M-STDBIND-DISK-SHADOW-UNREAD')
	public function testAStdShadowOutsideTheLintSetIsLeftAlone(): Void {
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final root: String = '${tmp != null && tmp.length > 0 ? tmp : '/tmp'}/anyparse_isop_shadow_${Sys.time()}';
		FileSystem.createDirectory('$root/b');
		File.saveContent('$root/b/Std.hx', 'package b;\n\nclass Std {}');
		final files: Array<{ file: String, source: String }> = [
			{
				file: '$root/b/M.hx',
				source: 'package b;\n\nclass M {\n\tfunction f(v:Dynamic):Bool {\n\t\treturn Std.isOfType(v, M);\n\t}\n}'
			}
		];
		Assert.equals(0, CheckFixture.violationsIn(new PreferIsOperator(), files).length);
		FileSystem.deleteFile('$root/b/Std.hx');
		Assert.equals(1, CheckFixture.violationsIn(new PreferIsOperator(), files).length);
		for (dir in ['$root/b', root]) FileSystem.deleteDirectory(dir);
	}

	/** The rewrite replaces the whole call, so a comment between its arguments would be lost. */
	@:pin('control')
	@:killer('M-ISOP-COMMENT-DROPPED')
	public function testACommentInTheCallIsLeftAlone(): Void {
		final src: String = '${TYPES}class C {\n\tfunction f(v:Dynamic):Bool {\n\t\treturn Std.isOfType(v, /* the base */ Base);\n\t}\n}';
		Assert.equals(0, CheckFixture.violations(new PreferIsOperator(), src).length);
	}

	/** An annotation argument and a reification are read as syntax, where the call and the operator are different code. */
	@:pin('control')
	@:killer('M-ISOP-SYNTAX-POSITION-REWRITTEN')
	public function testSyntaxPositionsAreSkipped(): Void {
		final src: String = '${TYPES}class C {\n\t@:keep(Std.isOfType(v, Base))\n\tfunction f(v:Dynamic):Void {\n'
			+ '\t\tfinal e = macro Std.isOfType(v, Base);\n\t}\n}';
		Assert.equals(0, CheckFixture.violations(new PreferIsOperator(), src).length);
	}

	/** The operator is Haxe 4.2: a project declaring 4.1 is not told to write it, one declaring 4.2 is. */
	@:pin('control')
	@:killer('M-ISOP-VERSION-UNGATED')
	public function testAProjectOlderThanTheOperatorIsNotTold(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: '${TYPES}class C {\n\tfunction f(v:Dynamic):Bool {\n\t\treturn Std.isOfType(v, Base);\n\t}\n}' }
		];
		final older: LintConfig = LintConfig.parse('{"languageVersion": "4.1"}');
		final current: LintConfig = LintConfig.parse('{"languageVersion": "4.2"}');
		Assert.equals(0, CheckFixture.violationsIn(new PreferIsOperator(), files, null, _ -> older).length);
		Assert.equals(1, CheckFixture.violationsIn(new PreferIsOperator(), files, null, _ -> current).length);
	}

	/** A dotted argument and a qualified receiver are declined; a call nested in a flagged one waits for the next pass. */
	@:pin('guard')
	public function testDottedSpellingsAreDeclinedAndNestingFlagsOnce(): Void {
		final src: String = '${TYPES}class C {\n\tfunction f(v:Dynamic):Bool {\n'
			+ '\t\treturn Std.isOfType(v, pkg.Base) || std.Std.isOfType(v, Base) || Std.isOfType(Std.isOfType(v, Base), Bool);\n\t}\n}';
		final found: Array<Violation> = CheckFixture.violations(new PreferIsOperator(), src);
		Assert.equals(1, found.length);
		Assert.stringContains('Std.isOfType(v, Base) is Bool', fixedSource(src));
	}

	/** The import the call alone read stays read by the operator: `unused-import` has nothing to say after the fix. */
	@:pin('guard')
	public function testAnImportReadOnlyByTheCallStaysUsed(): Void {
		final clip: { file: String, source: String } = { file: 'pkg/Clip.hx', source: 'package pkg;\n\nclass Clip {}' };
		final main: String = 'import pkg.Clip;\n\nclass C {\n\tfunction f(v:Dynamic):Bool {\n\t\treturn Std.isOfType(v, Clip);\n\t}\n}';
		final run: FixRun = CheckFixture.fixRun(new PreferIsOperator(), [{ file: 'C.hx', source: main }, clip]);
		Assert.equals(1, run.violations.length);
		final fixed: String = CanonicalEdit.applyEdits(main, run.edits);
		Assert.stringContains('return v is Clip;', fixed);
		Assert.equals(0, CheckFixture.violationsIn(new UnusedImport(), [{ file: 'C.hx', source: fixed }, clip]).length);
	}

	public function testRegisteredUnderTypes(): Void {
		final check: Null<Check> = Linter.byId('prefer-is-operator');
		Assert.notNull(check);
		if (check != null) Assert.equals(RuleCategory.Types, check.category());
	}

	/** A value operand ending in a `switch` or block brace takes the pair Haxe needs before the operator. */
	@:pin('control')
	@:killer('M-PARENGUARD-BLOCK-LEFT-OPERAND-BARE')
	public function testABlockTerminatedValueOperandGetsThePair(): Void {
		final src: String = 'class C {\n\tfunction f(b:Int):Void {\n\t\ttrace(Std.isOfType({\n\t\t\tb;\n\t\t}, Int));\n'
			+ '\t\ttrace(Std.isOfType(function() {\n\t\t\treturn b;\n\t\t}, Int));\n\t}\n}';
		final fixed: String = fixedSource(src);
		Assert.stringContains('trace(({', fixed);
		Assert.stringContains('trace((function() {', fixed);
	}

	/**
	 * The std is indexed in a normal run, so `Std` binds the std's declaration; a module `Std` of the file's own package or a
	 * parent one outside the run still shadows it, and declines the site. With the shadow gone the site is flagged.
	 */
	@:pin('control')
	@:killer('M-STDBIND-BOUND-DISK-SHADOW-UNREAD')
	@:killer('M-STDBIND-DISK-SHADOW-UNREAD')
	public function testAStdShadowBesideAnIndexedStdIsLeftAlone(): Void {
		final stdDir: Null<String> = StdResolver.stdDir();
		if (stdDir == null) {
			Assert.pass();
			return;
		}
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final root: String = '${tmp != null && tmp.length > 0 ? tmp : '/tmp'}/anyparse_isop_std_${Sys.time()}';
		final std: { file: String, source: String } = {
			file: Path.join([stdDir, 'Std.hx']),
			source: 'extern class Std {\n\tpublic static function isOfType(v:Dynamic, t:Dynamic):Bool;\n}\n'
		};
		final use: String = 'class M {\n\tfunction f(v:Dynamic):Bool {\n\t\treturn Std.isOfType(v, M);\n\t}\n}';
		final own: Array<{ file: String, source: String }> = [{ file: '$root/a/b/M.hx', source: 'package a.b;\n\n$use' }, std];
		final parent: Array<{ file: String, source: String }> = [{ file: '$root/c/d/M.hx', source: 'package c.d;\n\n$use' }, std];
		for (dir in ['$root/a/b', '$root/c/d']) FileSystem.createDirectory(dir);
		File.saveContent('$root/a/b/Std.hx', 'package a.b;\n\nclass Std {}');
		File.saveContent('$root/c/Std.hx', 'package c;\n\nclass Std {}');
		Assert.equals(0, CheckFixture.violationsIn(new PreferIsOperator(), own).length);
		Assert.equals(0, CheckFixture.violationsIn(new PreferIsOperator(), parent).length);
		FileSystem.deleteFile('$root/a/b/Std.hx');
		FileSystem.deleteFile('$root/c/Std.hx');
		Assert.equals(1, CheckFixture.violationsIn(new PreferIsOperator(), own).length);
		Assert.equals(1, CheckFixture.violationsIn(new PreferIsOperator(), parent).length);
		for (dir in ['$root/a/b', '$root/a', '$root/c/d', '$root/c', root]) FileSystem.deleteDirectory(dir);
	}

	/**
	 * The call types its value against `Dynamic`, the operator against nothing, so a value unifying its arms under that
	 * expectation — a ternary, an `if`, a `switch`, a `try`, an array literal — may compile only as the call.
	 */
	@:pin('control')
	@:killer('M-ISOP-EXPECTATION-UNIFIED')
	public function testAValueUnifiedUnderTheExpectationIsLeftAlone(): Void {
		final src: String = 'class C {\n\tfunction f(c:Int):Void {\n\t\ttrace(Std.isOfType(c == 1 ? \'x\' : 2, String));\n'
			+ '\t\ttrace(Std.isOfType(if (c == 1) \'x\' else 2, String));\n\t\ttrace(Std.isOfType(switch c {\n\t\t\tcase 1: \'x\';\n'
			+ '\t\t\tcase _: 2;\n\t\t}, String));\n\t\ttrace(Std.isOfType(try \'x\' catch (e:Dynamic) 2, String));\n'
			+ '\t\ttrace(Std.isOfType([1, \'x\'], Array));\n\t\ttrace(Std.isOfType((c == 1 ? \'x\' : 2), String));\n\t}\n}';
		Assert.equals(0, CheckFixture.violations(new PreferIsOperator(), src).length);
	}

	/** `src` as `C.hx` after the check's fix. */
	private static function fixedSource(src: String): String {
		return CheckFixture.fixedSource(new PreferIsOperator(), src);
	}

}
