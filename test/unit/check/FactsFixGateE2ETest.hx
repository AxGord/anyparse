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
 * Three `--fix` gates that decline where the run cannot type something, answered by the compiler's facts over a real
 * compile: an operand of a concatenation a type in scope could overload (`fold-adjacent-string-literals`), the `extends`
 * chain of a private member's class (`unused-private`) and the receiver of a redundant `.toString()`
 * (`redundant-tostring`). Each fixture also holds the case the facts must NOT clear, and the rewritten program prints what
 * the original printed.
 */
class FactsFixGateE2ETest extends Test {

	#if (sys || nodejs)
	private static final FOLD_MAIN: String = 'abstract Dir(String) from String to String {\n'
		+ '\t@:op(A + B) static function add(a:Dir, b:String):Dir\n' + '\t\treturn (a : String) + \'/\' + b;\n' + '}\n' + '\n'
		+ 'class Main {\n' + '\tstatic function name():String {\n' + '\t\treturn \'n\';\n' + '\t}\n' + '\n'
		+ '\tstatic function main() {\n' + '\t\tfinal out:Array<String> = [];\n' + '\t\tfinal xs:Array<Int> = [1, 2];\n'
		+ '\t\tfor (i in xs) {\n' + '\t\t\tout.push(\'h\' + (i - 1) + \'_p1\');\n' + '\t\t\tout.push(i + 1 + \' \' + (i * 2));\n'
		+ '\t\t}\n' + '\t\tout.push((name() : Dir) + \'x\' + \'y\');\n' + '\t\tSys.println(out.join(\',\'));\n' + '\t}\n' + '}\n';
	private static final CHAIN_MAIN: String = 'class Impl extends Base {\n' + '\tprivate function hook():Void {\n'
		+ '\t\tSys.println(\'hook\');\n' + '\t}\n' + '\n' + '\tprivate function spare():Void {\n' + '\t\tSys.println(\'s\');\n' + '\t}\n'
		+ '\n' + '\tprivate function gone():Void {\n' + '\t\tSys.println(\'g\');\n' + '\t}\n' + '}\n' + '\n'
		+ 'class Leaf extends Built {\n' + '\tprivate function kept():Void {\n' + '\t\tSys.println(\'k\');\n' + '\t}\n' + '}\n' + '\n'
		+ 'class Main {\n' + '\tstatic function main() {\n' + '\t\tnew Impl().run();\n' + '\t\tnew Leaf();\n' + '\t}\n' + '}\n';
	private static final CHAIN_BASE: String = 'abstract class Base {\n' + '\tpublic function new() {}\n' + '\n'
		+ '\tpublic function run():Void {\n' + '\t\thook();\n' + '\t}\n' + '\n' + '\tprivate abstract function hook():Void;\n' + '\n'
		+ '\tprivate abstract function spare():Void;\n' + '}\n';
	private static final CHAIN_BUILT: String = '@:autoBuild(Noop.build())\n' + 'class Built {\n' + '\tpublic function new() {}\n' + '}\n';
	private static final CHAIN_NOOP: String = 'import haxe.macro.Expr;\n' + '\n' + 'class Noop {\n'
		+ '\tpublic static macro function build():Array<Field> {\n' + '\t\treturn null;\n' + '\t}\n' + '}\n';
	private static final TOSTRING_MAIN: String = 'import haxe.io.Path;\n' + '\n' + '@:nullSafety(Strict)\n' + 'class Main {\n'
		+ '\tstatic function main() {\n' + '\t\tfinal p:Path = new Path(\'a/b.txt\');\n' + '\t\tSys.println(\'$${p.toString()}\');\n'
		+ '\t\tSys.println(\'x\' + p.toString());\n' + '\t\tSys.println(\'d $${Date.now().toString()}\'.length);\n'
		+ '\t\tfinal d:Date = Date.now();\n' + '\t\tfinal n:Named = new Named();\n'
		+ '\t\tSys.println(\'\\t\\t\\t\\t\\t\\t\\t\\t\\t\\t\\t\\t\\t\\t\\t$${d.toString()}$${n.label}\'.length);\n' + '\t}\n' + '}\n'
		+ '\n' + 'class Named {\n' + '\tpublic final label:String = \'l\';\n' + '\n' + '\tpublic function new() {}\n' + '}\n';
	private static final FAR_MAIN: String = 'import far.Path2;\n' + '\n' + 'abstract Dir(String) from String to String {\n'
		+ '\t@:op(A + B) static function add(a:Dir, b:String):Dir\n' + '\t\treturn (a : String) + \'/\' + b;\n' + '}\n' + '\n'
		+ 'class Holder {\n' + '\tpublic final fp:Path2 = \'r\';\n' + '\n' + '\tpublic function new() {}\n' + '}\n' + '\n'
		+ 'class Main {\n' + '\tstatic function pick<T>(v:T):T {\n' + '\t\treturn v;\n' + '\t}\n' + '\n' + '\tstatic function main() {\n'
		+ '\t\tfinal out:Array<String> = [];\n' + '\t\tfinal c:Bool = out.length == 0;\n' + '\t\tfinal fp:Path2 = \'r\';\n'
		+ '\t\tfinal h:Holder = new Holder();\n' + '\t\tfinal hs:Array<Holder> = [h];\n' + '\t\tout.push((c ? fp : fp) + \'x\' + \'y\');\n'
		+ '\t\tout.push(hs[0].fp + \'x\' + \'y\');\n' + '\t\tout.push(pick(h).fp + \'x\' + \'y\');\n'
		+ '\t\tout.push(hs.copy()[0].fp + \'x\' + \'y\');\n' + '\t\tSys.println(out.join(\',\'));\n' + '\t}\n' + '}\n';
	private static final FAR_PATH: String = 'package far;\n' + '\n' + 'abstract Path2(String) from String to String {\n'
		+ '\t@:op(A + B) static function add(a:Path2, b:String):Path2\n' + '\t\treturn (a : String) + \'/\' + b;\n' + '}\n';
	private static final NEAR_PATH: String = 'package other;\n' + '\n' + 'class Path2 {\n' + '\tpublic function new() {}\n' + '}\n';
	private static final HXML: String = '-cp .\n-main Main\n--interp\n';
	private static inline final APQLINT: String = '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."]}';
	private static inline final BUFFER: Int = 1 << 20;
	#end

	/**
	 * An operand only the facts type (`(i - 1)`, `i * 2`) lets the merge through, while a check-type `(name() : Dir)` —
	 * whose value flows in as a `String` but IS a `Dir`, the type that overloads `+` — stays: the facts answer the type of
	 * the expression itself, never the source type of a conversion at its range.
	 */
	@:pin('control') @:killer('M-FOLD-FACTS-OPERAND') @:killer('M-FACTS-VALUE-TYPE-FLOWS')
	public function testAnOperandTheFactsTypeLetsTheMergeThrough(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('foldfacts', [{ name: 'Main.hx', source: FOLD_MAIN }], HXML);
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'fold-adjacent-string-literals', dir]));
		final after: String = File.getContent('$dir/Main.hx');
		Assert.isTrue(after.indexOf('out.push(\'h$${(i - 1)}_p1\');') >= 0, after);
		Assert.isTrue(after.indexOf('out.push(\'$${i + 1} $${(i * 2)}\');') >= 0, after);
		Assert.isTrue(after.indexOf('out.push((name() : Dir) + \'x\' + \'y\');') >= 0, after);
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * An operand the facts type as `far.Path2` — an abstract overloading `+` that the resolution scope does not declare —
	 * stays, though the scope's own `Path2` is a plain class: the overload table judges a simple name, so the facts name
	 * only a type no operator can be declared on.
	 */
	@:pin('control') @:killer('M-FOLD-FACTS-PLAIN-KINDS')
	public function testAnAbstractTheFactsTypeIsNeverJudgedByAnotherDeclarationOfItsName(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('foldfar', [
			{ name: 'src/Main.hx', source: FAR_MAIN },
			{ name: 'src/other/Path2.hx', source: NEAR_PATH },
			{ name: 'lib/far/Path2.hx', source: FAR_PATH }
		], '-cp src\n-cp lib\n-main Main\n--interp\n', '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["src"]}');
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'fold-adjacent-string-literals', '$dir/src']));
		Assert.equals(FAR_MAIN, File.getContent('$dir/src/Main.hx'));
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A private member of a class whose supertypes live outside the resolution scope goes once the facts show no supertype
	 * declares it; one an abstract supertype declares stays, and so does one of a class under a supertype's `@:autoBuild`.
	 */
	@:pin('control') @:killer('M-UNUSED-PRIVATE-CHAIN-FACTS') @:killer('M-UNUSED-PRIVATE-CHAIN-DECLARED')
	@:killer('M-UNUSED-PRIVATE-CHAIN-AUTOBUILD')
	public function testAPrivateMemberNoSupertypeDeclaresIsDeleted(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('chainfacts', [
			{ name: 'src/Main.hx', source: CHAIN_MAIN },
			{ name: 'lib/Base.hx', source: CHAIN_BASE },
			{ name: 'lib/Built.hx', source: CHAIN_BUILT },
			{ name: 'lib/Noop.hx', source: CHAIN_NOOP }
		], '-cp src\n-cp lib\n-main Main\n--interp\n', '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["src"]}');
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'unused-private', '$dir/src']));
		final after: String = File.getContent('$dir/src/Main.hx');
		Assert.isTrue(after.indexOf('function gone') < 0, after);
		for (kept in ['function hook', 'function spare', 'function kept']) Assert.isTrue(after.indexOf(kept) >= 0, '$kept\n$after');
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A receiver of a class the resolution scope does not declare (`haxe.io.Path`) loses its `.toString()` once the facts
	 * show every configuration compiled it as a non-extern class; an extern one (`Date` on `--interp`) keeps it — also
	 * where, after fifteen escapes, the compiler places the read of `n` exactly at `d`'s range.
	 */
	@:pin('control') @:killer('M-TOSTRING-FACTS-CLASS') @:killer('M-TOSTRING-FACTS-EXTERN') @:killer('M-FACTS-ESCAPE-SHIFT')
	public function testAReceiverTheFactsTypeAsANonExternClassLosesItsToString(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('tostringfacts', [{ name: 'Main.hx', source: TOSTRING_MAIN }], HXML);
		if (dir == null) return;
		final before: String = run(dir);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'redundant-tostring', dir]));
		final after: String = File.getContent('$dir/Main.hx');
		Assert.isTrue(after.indexOf('Sys.println(\'$$p\');') >= 0, after);
		Assert.isTrue(after.indexOf('Sys.println(\'x\' + p);') >= 0, after);
		Assert.isTrue(after.indexOf('Date.now().toString()') >= 0, after);
		Assert.isTrue(after.indexOf('$${d.toString()}') >= 0, after);
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The fixture tree, or null — the test passed as skipped — when no `haxe` typechecks it. */
	private static function tree(
		name: String, files: Array<{ name: String, source: String }>, hxml: String, apqlint: String = APQLINT
	): Null<String> {
		final dir: String = CliFixture.writeTree(
			name, files.concat([{ name: 'check.hxml', source: hxml }, { name: 'apqlint.json', source: apqlint }])
		);
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
