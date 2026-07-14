package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.NewFile;
import anyparse.query.NewFile.NewFileResult;
import anyparse.query.NewFile.NewFileSpec;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

using StringTools;

/**
 * Probe for `apq new` — deterministic file creation. The bulk drives
 * `NewFile.create` directly with in-memory interface sources (pure, no
 * filesystem, runs on every target): interface methods are stubbed with
 * their sliced signatures, `@@` bodies fill them, unfilled methods become
 * NotImplementedException stubs, the interface's imports + sibling sub-types
 * are carried so the result type-checks, and a `@@` section naming an unknown
 * method or an unparseable body is an `Err` with nothing produced. A handful
 * of `#if (sys || nodejs)` cases cover the CLI glue — interface resolution
 * from disk, the create-only refusal, and `--write`.
 *
 * Pure-path assertions match the writer's DEFAULT options (no hxformat.json
 * is discoverable for an in-memory source) — colons carry no surrounding
 * space (`x:T`), unlike the project style.
 */
class NewFileSliceTest extends Test {

	private static inline final IFACE: String = 'package p;\nimport a.B;\ntypedef T = { var v: Int; }\ninterface I {\n\tpublic function f(x: T): B;\n\tpublic function g(): Void;\n}\n';
	#if (sys || nodejs)
	private static var counter: Int = 0;
	#end

	/** Every interface method is stubbed with its exact signature when no body is given. */
	public function testStubsAllMethods(): Void {
		final res: NewFileResult = create({
			className: 'Impl',
			pkg: 'p',
			fields: [],
			ifaceSimple: 'I',
			ifaceModule: 'p.I',
			ifaceSource: IFACE
		});
		final text: String = okText(res);
		Assert.isTrue(text.contains('final class Impl implements I'));
		Assert.isTrue(text.contains('public function f(x:T):B'));
		Assert.isTrue(text.contains('public function g():Void'));
		Assert.isTrue(text.contains('NotImplementedException'));
		Assert.equals(2, res.stubbed.length);
	}

	/** A `@@ <method>` section fills that body; the others stay stubbed and are reported. */
	public function testBodiesFillMethods(): Void {
		final res: NewFileResult = create({
			className: 'Impl',
			pkg: 'p',
			fields: [],
			ifaceSimple: 'I',
			ifaceModule: 'p.I',
			ifaceSource: IFACE,
			bodiesRaw: '@@ g\ntrace("hi");'
		});
		final text: String = okText(res);
		Assert.isTrue(text.contains('trace("hi")'));
		Assert.equals(1, res.stubbed.length);
		Assert.equals('f', res.stubbed[0]);
	}

	/** The interface file's imports AND its sibling sub-types are carried; same-package interface is not imported. */
	public function testCarriesImportsAndSubTypes(): Void {
		final text: String = okText(create({
			className: 'Impl',
			pkg: 'p',
			fields: [],
			ifaceSimple: 'I',
			ifaceModule: 'p.I',
			ifaceSource: IFACE
		}));
		Assert.isTrue(text.contains('import a.B;'));
		Assert.isTrue(text.contains('import p.I.T;'));
		Assert.isFalse(text.contains('import p.I;'));
	}

	/** An interface in another package IS imported by the new file. */
	public function testCrossPackageImportsInterface(): Void {
		final text: String = okText(create({
			className: 'Impl',
			pkg: 'x',
			fields: [],
			ifaceSimple: 'I',
			ifaceModule: 'p.I',
			ifaceSource: IFACE
		}));
		Assert.isTrue(text.contains('import p.I;'));
	}

	/** A `@@` section naming no interface method is an error. */
	public function testUnknownSectionIsError(): Void {
		final res: NewFileResult = create({
			className: 'Impl',
			pkg: 'p',
			fields: [],
			ifaceSimple: 'I',
			ifaceModule: 'p.I',
			ifaceSource: IFACE,
			bodiesRaw: '@@ nope\nreturn null;'
		});
		Assert.isTrue(isErr(res));
	}

	/** An unparseable body fails the whole creation (writer round-trip rejects it). */
	public function testBadBodyIsError(): Void {
		final res: NewFileResult = create({
			className: 'Impl',
			pkg: 'p',
			fields: [],
			ifaceSimple: 'I',
			ifaceModule: 'p.I',
			ifaceSource: IFACE,
			bodiesRaw: '@@ g\nreturn (((;'
		});
		Assert.isTrue(isErr(res));
	}

	/** `--class` (no interface) emits a bare class carrying the verbatim fields. */
	public function testClassWithFields(): Void {
		final text: String = okText(create({ className: 'Box', pkg: 'p', fields: ['public final x: Int = 0;', 'public var y: String;'] }));
		Assert.isTrue(text.contains('final class Box {'));
		Assert.isFalse(text.contains('implements'));
		Assert.isTrue(text.contains('final x:Int = 0;'));
		Assert.isTrue(text.contains('var y:String;'));
	}

	/** A package-less target emits no `package` declaration. */
	public function testRootPackageHasNoPackageLine(): Void {
		final text: String = okText(create({ className: 'Root', pkg: '', fields: ['public final n: Int = 1;'] }));
		Assert.isFalse(text.contains('package'));
	}

	#if (sys || nodejs)
	/** Create-only: an existing path is refused (`EXIT_RUNTIME`) and left untouched. */
	public function testCreateOnlyRefusesExisting(): Void {
		final dir: String = tmpDir();
		final p: String = '$dir/Existing.hx';
		File.saveContent(p, 'package;\nclass Existing {}\n');
		Assert.equals(1, Cli.run(['new', p, '--class']));
		Assert.equals('package;\nclass Existing {}\n', File.getContent(p));
		CliFixture.removeDir(dir);
	}
	/** `--write` with a disk-resolved sibling interface produces the file. */
	public function testWriteResolvesSiblingInterface(): Void {
		final dir: String = tmpDir();
		File.saveContent('$dir/Iface.hx', 'package;\ninterface Iface {\n\tpublic function go(): Int;\n}\n');
		final p: String = '$dir/Impl.hx';
		Assert.equals(0, Cli.run(['new', p, '--implements', 'Iface', '--bodies', '@@ go\nreturn 1;', '--write']));
		Assert.isTrue(FileSystem.exists(p));
		final text: String = File.getContent(p);
		Assert.isTrue(text.contains('implements Iface'));
		Assert.isTrue(text.contains('public function go():Int'));
		Assert.isTrue(text.contains('return 1;'));
		CliFixture.removeDir(dir);
	}
	/** An interface that cannot be located on disk is an error. */
	public function testMissingInterfaceIsError(): Void {
		final dir: String = tmpDir();
		final p: String = '$dir/Impl.hx';
		Assert.equals(1, Cli.run(['new', p, '--implements', 'Nope']));
		Assert.isFalse(FileSystem.exists(p));
		CliFixture.removeDir(dir);
	}
	/** `--kind class` with no other shape flag creates an empty class (regression: it was rejected as "no intent" — only `--class` worked). */
	public function testCliKindClassEmpty(): Void {
		final dir: String = tmpDir();
		final p: String = '$dir/Empty.hx';
		Assert.equals(0, Cli.run(['new', p, '--kind', 'class', '--write']));
		Assert.isTrue(FileSystem.exists(p));
		Assert.isTrue(File.getContent(p).contains('class Empty'));
		CliFixture.removeDir(dir);
	}
	#end

	/** A created class is instantiable — a no-arg constructor is auto-emitted. */
	public function testEmitsConstructor(): Void {
		final text: String = okText(create({ className: 'Box', pkg: 'p', fields: [] }));
		Assert.isTrue(text.contains('public function new() {}'));
	}

	/** A `@@ doc` section becomes the class doc-comment. */
	public function testDocSection(): Void {
		final text: String = okText(create({
			className: 'Box',
			pkg: 'p',
			fields: [],
			bodiesRaw: '@@ doc\nA documented box.'
		}));
		Assert.isTrue(text.contains('/**'));
		Assert.isTrue(text.contains('A documented box.'));
	}

	/** A user-supplied constructor is not shadowed by the auto-emitted one. */
	public function testUserConstructorNotDuplicated(): Void {
		final text: String = okText(create({ className: 'Box', pkg: 'p', fields: ['public function new() { trace(1); }'] }));
		Assert.isTrue(text.contains('trace(1)'));
		Assert.isFalse(text.contains('new() {}'));
	}

	/** `--kind interface` emits an interface with super-interfaces, no constructor, no `final`. */
	public function testInterfaceKind(): Void {
		final text: String = okText(create({
			className: 'I',
			pkg: 'p',
			kind: 'interface',
			extendsList: ['Base'],
			fields: ['public function f(): Void;']
		}));
		Assert.isTrue(text.contains('interface I extends Base'));
		Assert.isTrue(text.contains('function f'));
		Assert.isFalse(text.contains('function new'));
		Assert.isFalse(text.contains('final class'));
	}

	/** `--kind enum` emits an enum carrying the given constructors. */
	public function testEnumKind(): Void {
		final text: String = okText(create({
			className: 'Color',
			pkg: 'p',
			kind: 'enum',
			fields: ['Red;', 'Rgb(r: Int, g: Int, b: Int);']
		}));
		Assert.isTrue(text.contains('enum Color {'));
		Assert.isTrue(text.contains('Red;'));
		Assert.isTrue(text.contains('Rgb('));
		Assert.isFalse(text.contains('function new'));
	}

	/** `--kind typedef` emits an anon-struct typedef from the fields. */
	public function testTypedefKind(): Void {
		final text: String = okText(create({
			className: 'Point',
			pkg: 'p',
			kind: 'typedef',
			fields: ['var x: Int;', 'var y: Int;']
		}));
		Assert.isTrue(text.contains('typedef Point = {'));
		Assert.isTrue(text.contains('var x'));
	}

	/** A class with `--extends` inherits its super's constructor (no auto `new()`), and a qualified base is imported. */
	public function testClassExtendsNoAutoConstructor(): Void {
		final text: String = okText(create({
			className: 'T',
			pkg: 'p',
			kind: 'class',
			extendsList: ['a.b.Base'],
			fields: []
		}));
		Assert.isTrue(text.contains('class T extends Base'));
		Assert.isTrue(text.contains('import a.b.Base;'));
		Assert.isFalse(text.contains('function new'));
	}

	/** `--open` (isFinal false) emits a non-final class. */
	public function testOpenClass(): Void {
		final text: String = okText(create({
			className: 'Box',
			pkg: 'p',
			isFinal: false,
			fields: ['public final n: Int = 0;']
		}));
		Assert.isTrue(text.contains('class Box {'));
		Assert.isFalse(text.contains('final class'));
	}

	/** `--implements` on a non-class kind is rejected. */
	public function testImplementsRequiresClass(): Void {
		final res: NewFileResult = create({
			className: 'I',
			pkg: 'p',
			kind: 'interface',
			fields: [],
			ifaceSimple: 'X',
			ifaceModule: 'p.X',
			ifaceSource: 'package p;\ninterface X {}'
		});
		Assert.isTrue(isErr(res));
	}

	/** `--kind typedef --extends` emits a struct typedef extension (`{ > Base, … }`), one `>` per base. */
	public function testTypedefExtends(): Void {
		final text: String = okText(create({
			className: 'E',
			pkg: 'p',
			kind: 'typedef',
			extendsList: ['Base', 'Other'],
			fields: ['var x: Int;']
		}));
		Assert.isTrue(text.contains('typedef E = {'));
		Assert.isTrue(text.contains('> Base,'));
		Assert.isTrue(text.contains('> Other,'));
		Assert.isTrue(text.contains('var x'));
	}

	/** `--kind abstract` emits `abstract N(U) from .. to ..` with members and no auto-constructor. */
	public function testAbstractKind(): Void {
		final text: String = okText(create({
			className: 'Money',
			pkg: 'p',
			kind: 'abstract',
			underlying: 'Int',
			fromList: ['Int'],
			toList: ['Int'],
			fields: ['public function double(): Int return 0;']
		}));
		Assert.isTrue(text.contains('abstract Money(Int) from Int to Int'));
		Assert.isTrue(text.contains('function double'));
		Assert.isFalse(text.contains('function new'));
	}

	/** `--kind abstract` without `--underlying` is an error. */
	public function testAbstractRequiresUnderlying(): Void {
		final res: NewFileResult = create({
			className: 'X',
			pkg: 'p',
			kind: 'abstract',
			fields: []
		});
		Assert.isTrue(isErr(res));
	}

	/** A qualified abstract underlying is imported. */
	public function testAbstractQualifiedUnderlyingImports(): Void {
		final text: String = okText(create({
			className: 'W',
			pkg: 'p',
			kind: 'abstract',
			underlying: 'a.b.U',
			fields: []
		}));
		Assert.isTrue(text.contains('abstract W(U)'));
		Assert.isTrue(text.contains('import a.b.U;'));
	}

	/** `@@ members` appends a free-form member block to any kind. */
	public function testFreeFormMembers(): Void {
		final text: String = okText(create({
			className: 'C',
			pkg: 'p',
			kind: 'class',
			fields: [],
			bodiesRaw: '@@ members\npublic function helper(): Int return 1;'
		}));
		Assert.isTrue(text.contains('function helper'));
	}

	/** `@@ members` adds helpers ALONGSIDE --implements stubs (no "names no method" error). */
	public function testMembersAlongsideImplements(): Void {
		final text: String = okText(create({
			className: 'Impl',
			pkg: 'p',
			fields: [],
			ifaceSimple: 'I',
			ifaceModule: 'p.I',
			ifaceSource: IFACE,
			bodiesRaw: '@@ members\nfunction helper(): Int return 0;'
		}));
		Assert.isTrue(text.contains('function helper'));
		Assert.isTrue(text.contains('function f'));
	}

	/** `createRaw` canonicalises an arbitrary parseable whole file. */
	public function testCreateRawOk(): Void {
		switch NewFile.createRaw('package p;\nenum E { A; B; }\nclass C { public function new() {} }', new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.contains('enum E'));
				Assert.isTrue(text.contains('class C'));
			case Err(message):
				Assert.fail('expected Ok, got: $message');
		}
	}

	/** `createRaw` rejects an unparseable whole file. */
	public function testCreateRawUnparseable(): Void {
		switch NewFile.createRaw('package p;\nclass C {', new HaxeQueryPlugin()) {
			case Ok(_):
				Assert.fail('expected Err');
			case Err(_):
				Assert.pass();
		}
	}

	private inline function create(spec: NewFileSpec): NewFileResult {
		return NewFile.create(spec, new HaxeQueryPlugin());
	}

	private function okText(res: NewFileResult): String {
		return switch res.result {
			case Ok(text): text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				'';
		};
	}

	private function isErr(res: NewFileResult): Bool {
		return switch res.result {
			case Ok(_): false;
			case Err(_): true;
		};
	}

	#if (sys || nodejs)
	private static function tmpDir(): String {
		counter++;
		final env: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = env != null && env.length > 0 ? env.endsWith('/') ? env.substr(0, env.length - 1) : env : '/tmp';
		final dir: String = '$base/tmp_apq_new_${Sys.time()}_$counter';
		FileSystem.createDirectory(dir);
		return dir;
	}
	#end

}
