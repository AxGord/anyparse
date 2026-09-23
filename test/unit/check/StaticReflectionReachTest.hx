package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.ReflectionScan;
import anyparse.check.StaticReflectionReach;
import anyparse.check.UnusedPrivate;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `unused-private`'s string gate for a PRIVATE STATIC: a string spelling the name keeps the static only
 * when a class value of its owner — or of a subtype, or an alias — can reach reflection
 * (`StaticReflectionReach`). Each keep-cell differs from the delete-control by one construct.
 */
@:nullSafety(Strict) class StaticReflectionReachTest extends Test {

	/** The owner: one unused private static, nothing else that could keep it. */
	private static inline final OWNER: String = 'class C {\n\tprivate static final SIZE: Float = 4;\n\n\tpublic function new() {}\n}\n';

	/** A data table spelling the name as a VALUE — the translation-table shape that used to keep it. */
	private static inline final TABLE: String =
		'class T {\n\tpublic static final ROWS: Array<Dynamic> = [{ Key: \'63\', Value: \'SIZE\' }];\n}\n';

	@:pin('control') @:killer('M-STATICREACH-NEVER')
	public function testAStaticNoClassValueReachesIsDeleted(): Void {
		Assert.equals(1, deletions(OWNER, []));
	}

	@:pin('control') @:killer('M-STATICREACH-INSTANCE')
	public function testAnInstanceFieldKeepsTheStringGate(): Void {
		Assert.equals(0, deletions('class C {\n\tprivate var SIZE: Float = 4;\n\n\tpublic function new() {}\n}\n', []));
	}

	@:pin('control') @:killer('M-STATICREACH-VALUE-BLIND')
	public function testTheClassNameAsAValueKeepsTheGate(): Void {
		Assert.equals(0, deletions(OWNER, [user('public static function k(): Dynamic {\n\t\treturn C;\n\t}')]));
	}

	@:pin('control') @:killer('M-STATICREACH-CONSUMER-NONE')
	public function testAWhitelistedConsumerOfTheClassNameDeletes(): Void {
		Assert.equals(1, deletions(OWNER, [
			user('public static function k(x: Dynamic): String {\n\t\treturn Type.getClassName(C) + Std.isOfType(x, C);\n\t}')
		]));
	}

	@:pin('control') @:killer('M-STATICREACH-CONSUMER-NONE')
	public function testAConsumedGetClassDeletes(): Void {
		Assert.equals(1, deletions(OWNER, [
			user('public static function k(x: Dynamic): String {\n\t\treturn Type.getClassName(Type.getClass(x));\n\t}'),
			{
				file: 'V.hx',
				source: 'using Type;\n\nclass V {\n\tpublic function k(): String {\n\t\treturn this.getClass().getClassName();\n\t}\n}\n'
			},
			user('public static function m(): Dynamic {\n\t\treturn Type.createInstance(Type.resolveClass(Std.string(1)), []);\n\t}', 'W')
		]));
	}

	@:pin('control') @:killer('M-STATICREACH-SOURCE-BLIND')
	public function testAnUnconsumedGetClassKeepsTheGate(): Void {
		Assert.equals(0, deletions(OWNER, [
			user('public static function k(x: Dynamic): Dynamic {\n\t\treturn Type.getClass(x);\n\t}')
		]));
		Assert.equals(0, deletions(OWNER, [
			user('public static function k(x: Dynamic): Dynamic {\n\t\treturn Type.typeof(x);\n\t}')
		]));
		Assert.equals(0, deletions(OWNER, [
			user('public static function k(s: String): Dynamic {\n\t\treturn Type.resolveClass(s);\n\t}')
		]));
	}

	@:pin('control') @:killer('M-STATICREACH-THIS-UNBOUNDED')
	public function testGetClassOfThisInAnUnrelatedClassDeletes(): Void {
		Assert.equals(1, deletions(OWNER, [user('public function k(): Dynamic {\n\t\treturn Type.getClass(this);\n\t}')]));
	}

	/** `this` in a SUPERCLASS of the owner can be an instance of the owner, so its class value is the owner's. */
	@:pin('control') @:killer('M-STATICREACH-THIS-BLIND')
	public function testGetClassOfThisOnTheOwnersChainKeepsTheGate(): Void {
		final files: Array<SourceFile> = [
			{ file: 'C.hx', source: OWNER.replace('class C', 'class C extends K') },
			{ file: 'K.hx', source: 'class K {\n\tpublic function k(): Dynamic {\n\t\treturn Type.getClass(this);\n\t}\n}\n' }
		];
		Assert.isTrue(reachable(files));
		Assert.isFalse(reachable([files[0], { file: 'K.hx', source: 'class K {}\n' }]), 'the control');
	}

	/** A SUBCLASS's class value exposes the inherited static on eval and ES6 js. */
	@:pin('control') @:killer('M-STATICREACH-SUBTYPE-BLIND')
	public function testASubclassAsAValueKeepsTheGate(): Void {
		final sub: SourceFile = {
			file: 'E.hx',
			source: 'class E extends C {\n\tpublic static function k(): Dynamic {\n\t\treturn E;\n\t}\n}\n'
		};
		Assert.isTrue(reachable([{ file: 'C.hx', source: OWNER }, sub]));
	}

	@:pin('control') @:killer('M-STATICREACH-ALIAS-BLIND')
	public function testAnAliasAsAValueKeepsTheGate(): Void {
		final files: Array<SourceFile> = [
			{ file: 'C.hx', source: OWNER },
			{ file: 'A.hx', source: 'typedef A = C;\n\nclass U {\n\tpublic static function k(): Dynamic {\n\t\treturn A;\n\t}\n}\n' }
		];
		Assert.isTrue(reachable(files));
		Assert.isTrue(reachable([
			{ file: 'C.hx', source: OWNER },
			{ file: 'U.hx', source: 'import C as B;\n\nclass U {\n\tpublic static function k(): Dynamic {\n\t\treturn B;\n\t}\n}\n' }
		]));
	}

	@:pin('control') @:killer('M-STATICREACH-TYPEPATH-BLIND')
	public function testALiteralNamingTheOwnerKeepsTheGate(): Void {
		Assert.isTrue(reachable([{ file: 'C.hx', source: OWNER }, user('public static final N: String = \'C\';')]));
		Assert.isFalse(reachable([{ file: 'C.hx', source: OWNER }, user('public static final N: String = \'D\';')]), 'the control');
	}

	@:pin('control') @:killer('M-STATICREACH-JS-HANDLE-BLIND')
	public function testAJsClassHandleKeepsTheGate(): Void {
		Assert.isTrue(reachable([
			{ file: 'C.hx', source: OWNER },
			user('public static function k(o: Dynamic): Dynamic {\n\t\treturn o.__class__;\n\t}')
		]));
		Assert.isTrue(reachable([
			{ file: 'C.hx', source: OWNER },
			user('public static function k(o: Dynamic): Dynamic {\n\t\treturn Reflect.field(o, \'constructor\');\n\t}')
		]));
	}

	/** `C.field('SIZE')` under `using Reflect` hands the CLASS to an extension; `C.k()` names a real member. */
	@:pin('control') @:killer('M-STATICREACH-RECEIVER-BLIND')
	public function testAnExtensionOnTheClassKeepsTheGate(): Void {
		final owner: String = OWNER.replace('public function new() {}', 'public static function k(): Int {\n\t\treturn 1;\n\t}');
		Assert.isTrue(reachable([
			{ file: 'C.hx', source: owner },
			user('public static function m(): Dynamic {\n\t\treturn C.field(\'x\');\n\t}')
		]));
		Assert.isFalse(reachable([
			{ file: 'C.hx', source: owner },
			user('public static function m(): Int {\n\t\treturn C.k();\n\t}')
		]), 'the control');
	}

	/** A macro can reify a string into an identifier, so its strings are never vouched for. */
	@:pin('control') @:killer('M-STATICREACH-MACRO-BLIND')
	public function testAStringInAMacroFileKeepsTheGate(): Void {
		Assert.isTrue(reachable([
			{ file: 'C.hx', source: OWNER },
			user('public static macro function m(): haxe.macro.Expr {\n\t\treturn macro $$i{\'SIZE\'};\n\t}')
		]));
	}

	/** Target code pasted as a string names the static directly, with no class value in between. */
	@:pin('control') @:killer('M-STATICREACH-CARRIER-BLIND')
	public function testAStringInANativeCarrierKeepsTheGate(): Void {
		Assert.isTrue(reachable([
			{ file: 'C.hx', source: OWNER },
			user('public static function m(): Dynamic {\n\t\treturn js.Syntax.code(\'C.SIZE\');\n\t}')
		]));
	}

	/** An unparsed `#if` region is bytes: a class source spelled there opens every class. */
	@:pin('control') @:killer('M-STATICREACH-OPAQUE-SOURCE-BLIND')
	public function testAClassSourceInAnOpaqueRegionKeepsTheGate(): Void {
		Assert.isTrue(reachable([{ file: 'C.hx', source: OWNER }, opaque('k(Type.getClass(x));')]));
		Assert.isFalse(reachable([{ file: 'C.hx', source: OWNER }, opaque('k(1);')]), 'the control');
	}

	/** …and the owner's name spelled there may be the class value handed to reflection. */
	@:pin('control') @:killer('M-STATICREACH-OPAQUE-CHAIN-BLIND')
	public function testTheOwnerInAnOpaqueRegionKeepsTheGate(): Void {
		Assert.isTrue(reachable([{ file: 'C.hx', source: OWNER }, opaque('k(C);')]));
	}

	/** A project `@:autoBuild` macro reifying the class it builds hands its class value to code no text here holds. */
	@:pin('control') @:killer('M-STATICREACH-REIFY-BLIND')
	public function testAClassReifyingBuildMacroKeepsTheGate(): Void {
		final reg: String = 'import haxe.macro.Context;\n\nclass Reg {\n\tpublic static macro function build(): Array<haxe.macro.Expr.Field> {\n'
			+ '\t\tfinal cls = Context.getLocalClass().get();\n\t\tfinal path: Array<String> = cls.pack.concat([cls.name]);\n'
			+ '\t\tfinal fields = Context.getBuildFields();\n\t\ttrace(macro Registry.add($$p{path}));\n\t\treturn fields;\n\t}\n}\n';
		final plain: String = 'import haxe.macro.Context;\n\nclass Reg {\n\tpublic static macro function build(): Array<haxe.macro.Expr.Field> {\n'
			+ '\t\treturn Context.getBuildFields();\n\t}\n}\n';
		final owner: SourceFile = { file: 'C.hx', source: OWNER.replace('class C', 'class C implements I') };
		final iface: SourceFile = { file: 'I.hx', source: '@:autoBuild(Reg.build())\ninterface I {}\n' };
		Assert.isTrue(reachable([owner, iface, { file: 'Reg.hx', source: reg }]));
		Assert.isFalse(reachable([owner, iface, { file: 'Reg.hx', source: plain }]), 'the control');
	}

	/** Inside a macro module `this` is reified into the CALLER, so `getClass(this)` there says nothing about the module's own class. */
	@:pin('control') @:killer('M-STATICREACH-MACRO-THIS')
	public function testGetClassOfThisInAMacroModuleKeepsTheGate(): Void {
		final tools: SourceFile = {
			file: 'Tools.hx',
			source: 'class Tools {\n\tpublic static macro function classOfThis(): haxe.macro.Expr {\n\t\treturn macro Type.getClass(this);\n\t}\n}\n'
		};
		Assert.isTrue(reachable([{ file: 'C.hx', source: OWNER }, tools]));
	}

	/** A library wrapper of `resolveClass` handed a computed name is a class source like `resolveClass` itself. */
	@:pin('control') @:killer('M-STATICREACH-DEFINITION-BLIND')
	public function testADefinitionLookupByAComputedNameKeepsTheGate(): Void {
		Assert.isTrue(reachable([
			{ file: 'C.hx', source: OWNER },
			user('public static function k(n: String): Dynamic {\n\t\treturn Lib2.getDefinitionByName(n);\n\t}')
		]));
	}

	/** `Reflect.field(Type, 'getClass')` calls the class source reflectively, with no call the walk can see. */
	@:pin('control') @:killer('M-STATICREACH-SOURCE-STRING-BLIND')
	public function testAStringNamingAClassSourceKeepsTheGate(): Void {
		Assert.isTrue(reachable([
			{ file: 'C.hx', source: OWNER },
			user('public static function k(): Dynamic {\n\t\treturn Reflect.field(Type, \'getClass\');\n\t}')
		]));
	}

	/** `x.isOfType(C)` is `Std.isOfType` only under a `using Std` — otherwise it is some method handed the class. */
	@:pin('control') @:killer('M-STATICREACH-USING-STD-ASSUMED')
	public function testAReceiverlessIsOfTypeNeedsUsingStd(): Void {
		final call: String = 'class U {\n\tpublic static function k(x: Dynamic): Bool {\n\t\treturn x.isOfType(C);\n\t}\n}\n';
		Assert.isTrue(reachable([{ file: 'C.hx', source: OWNER }, { file: 'U.hx', source: call }]));
		Assert.isFalse(reachable([{ file: 'C.hx', source: OWNER }, { file: 'U.hx', source: 'using Std;\n\n$call' }]), 'the control');
	}

	/**
	 * The same fold through the CLI, where the std joins the scope: a one-letter owner is always kept
	 * there (the std's strings spell `C`), so the owner carries a distinctive name.
	 */
	@:pin('control') @:killer('M-STATICREACH-NEVER')
	public function testTheCliDeletesADistinctiveStaticOnlyATableSpells(): Void {
		#if (sys || nodejs)
		final owner: String = 'package p;\n\nclass QzGridLine {\n\tprivate static final SIZE:Float = 4;\n\n\tpublic function new() {}\n}\n';
		final table: String =
			'package p;\n\nclass QzTable {\n\tpublic static final ROWS:Array<Dynamic> = [{Key: \'63\', Value: \'SIZE\'}];\n}\n';
		final dir: String = CliFixture.writeDir(
			'staticreach', [{ name: 'QzGridLine.hx', source: owner }, { name: 'QzTable.hx', source: table }]
		);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'unused-private', dir]), 'lint --fix exits ok');
		final out: String = File.getContent('$dir/QzGridLine.hx');
		Assert.isTrue(out.indexOf('SIZE') == -1, 'the static is deleted: $out');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** How many edits `unused-private` writes for `OWNER`-like `owner` with `TABLE` and `others` in scope. */
	private function deletions(owner: String, others: Array<SourceFile>): Int {
		final files: Array<SourceFile> = [{ file: 'C.hx', source: owner }, { file: 'T.hx', source: TABLE }].concat(others);
		final check: UnusedPrivate = new UnusedPrivate();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == 'C.hx');
		Assert.equals(1, own.length, 'the finding the gate decides must exist');
		final edits: Array<{ span: Span, text: String }> = check.fix(owner, own, plugin, SymbolIndex.build(files, plugin));
		return edits.length;
	}

	/** Whether a string spelling `SIZE` may reach `C.SIZE` over `files`. */
	private function reachable(files: Array<SourceFile>): Bool {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final reach: Null<StaticReflectionReach> = StaticReflectionReach.build(
			files, plugin, ReflectionScan.reflectionSurface(files, plugin)
		);
		if (reach != null) return reach.staticReachable('C', 'C.hx', 'SIZE', SymbolIndex.build(files, plugin));
		Assert.fail('the Haxe grammar answers the static-reach question');
		return true;
	}

	/** A class `B` whose method holds an `#if` region the grammar keeps raw, with `body` inside it. */
	private function opaque(body: String): SourceFile {
		return {
			file: 'B.hx',
			source: 'class B {\n\tfunction f(c: Bool, x: Dynamic): Void {\n\t\t#if js if (c) { $body } else #end h();\n\t}\n}\n'
		};
	}

	/** A class `name` holding `member`. */
	private function user(member: String, name: String = 'U'): SourceFile {
		return { file: '$name.hx', source: 'class $name {\n\t$member\n}\n' };
	}

}

/** One source of a cell's scope. */
private typedef SourceFile = {
	var file: String;
	var source: String;
};
