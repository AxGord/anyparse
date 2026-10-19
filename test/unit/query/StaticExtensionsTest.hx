package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.SymbolIndex;
import unit.CheckFixture;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * Which static extension `recv.name` binds (`StaticExtensions.binding`, step T3 of the typer by specification), each
 * order first compiled on Haxe 4.3.7 with `--interp` and `-js` (FU14 probes, `docs/decisions.md`): the receiver's field,
 * then its type's `@:using` (the last argument first, the superclass's list before the interfaces', a typedef's own before
 * the aliased type's), then the file's `using`s the last first, then the ambient `import.hx`'s; inside one used module
 * the last declared type first, module-level functions last; a candidate whose first parameter rejects the receiver
 * passed over. Every answer is `Host.member`, or `-` where the service proves none.
 */
@:nullSafety(Strict)
class StaticExtensionsTest extends Test {

	@:pin('control') @:killer('M-BINDER-EXTENSION-LAST-USING') @:killer('M-BINDER-EXTENSION-FIRST-PARAM')
	public function testTheLastUsingBindsAndARejectingOnePassesOver(): Void {
		final index: SymbolIndex = indexOf([
			'p/A.hx' => 'package p;\n\nclass A {\n\tpublic static function f(s:Str):Int return 0;\n\n'
			+ '\tpublic static function r(s:Str):Int return 0;\n}\n',
			'p/B.hx' => 'package p;\n\nclass B {\n\tpublic static function f(s:Str):Int return 0;\n\n'
			+ '\tpublic static function r(o:Other):Int return 0;\n}\n',
			'p/Main.hx' => 'package p;\n\nusing p.A;\nusing p.B;\n\nclass Main {}\n'
		]);
		Assert.equals('B.f', binding(index, 'p/Main.hx', 'Str', 'f'), 'the last `using` first');
		Assert.equals('A.r', binding(index, 'p/Main.hx', 'Str', 'r'), 'a first parameter rejecting the receiver is passed over');
	}

	@:pin('control') @:killer('M-EXT-DECL-TWO-HOSTS') @:killer('M-EXT-MODULE-FIELDS-OPEN')
	public function testAModuleBringsItsLastDeclaredTypeFirstAndItsFunctionsLast(): Void {
		final index: SymbolIndex = indexOf([
			'p/M1.hx' => 'package p;\n\nclass X {\n\tpublic static function f(s:Str):Int return 0;\n}\n\n'
			+ 'class M1 {\n\tpublic static function f(s:Str):Int return 0;\n\n\tpublic static function h(s:Str):Int return 0;\n}\n',
			'p/M2.hx' => 'package p;\n\nfunction g(s:Str):Int return 0;\n\nclass M2 {\n\tpublic static function g(s:Str):Int return 0;\n'
			+ '}\n\nclass R {\n\tpublic static function g(o:Other):Int return 0;\n}\n',
			'p/M3.hx' => 'package p;\n\nfunction h(s:Str):Int return 0;\n\nclass M3 {}\n',
			'p/Main.hx' => 'package p;\n\nusing p.M1;\nusing p.M2;\nusing p.M3;\n\nclass Main {}\n'
		]);
		Assert.equals('M1.f', binding(index, 'p/Main.hx', 'Str', 'f'), 'the last declared type of the module first');
		Assert.equals('M2.g', binding(index, 'p/Main.hx', 'Str', 'g'), 'past a rejecting type, before the module-level function');
		Assert.equals('-', binding(index, 'p/Main.hx', 'Str', 'h'), 'a module-level function the index cannot type, ahead of `M1.h`');
	}

	@:pin('control') @:killer('M-BINDER-EXTENSION-ATUSING') @:killer('M-EXT-TYPE-USING-FORWARD')
	public function testTheTypesOwnUsingBindsBeforeTheFilesAndPassesOverIntoThem(): Void {
		final index: SymbolIndex = indexOf([
			'p/C.hx' => 'package p;\n\n@:using(p.E1, p.E2) class C {}\n',
			'p/C3.hx' => 'package p;\n\n@:using(p.E1) class C3 {}\n',
			'p/E1.hx' => 'package p;\n\nclass E1 {\n\tpublic static function f(c:C):Int return 0;\n\n'
			+ '\tpublic static function h(o:Other):Int return 0;\n}\n',
			'p/E2.hx' => 'package p;\n\nclass E2 {\n\tpublic static function f(c:C):Int return 0;\n}\n',
			'p/F.hx' => 'package p;\n\nclass F {\n\tpublic static function f(c:C):Int return 0;\n\n'
			+ '\tpublic static function h(c:C3):Int return 0;\n}\n',
			'p/Main.hx' => 'package p;\n\nusing p.F;\n\nclass Main {}\n'
		]);
		Assert.equals('E2.f', binding(index, 'p/Main.hx', 'C', 'f'), 'the type\'s last `@:using` argument, before the file');
		Assert.equals('F.h', binding(index, 'p/Main.hx', 'C3', 'h'), 'a rejecting `@:using` candidate passes over into the file');
	}

	@:pin('control') @:killer('M-EXT-INTERFACES-FIRST')
	public function testAnInheritedUsingComesSuperclassFirst(): Void {
		final index: SymbolIndex = indexOf([
			'p/T.hx' => 'package p;\n\n@:using(p.T.EP) class P {}\n\n@:using(p.T.EI) interface I {}\n\n@:using(p.T.EG) class G {}\n\n'
			+ '@:using(p.T.EM) class Mid extends G {}\n\nclass D implements I extends P {}\n\n@:using(p.T.ED) class D2 extends P {}\n\n'
			+ 'class D3 extends Mid implements I {}\n\nclass EP {\n\tpublic static function f(p:P):Int return 0;\n\n'
			+ '\tpublic static function q(p:P):Int return 0;\n}\n\nclass EI {\n\tpublic static function f(i:I):Int return 0;\n\n'
			+ '\tpublic static function w(i:I):Int return 0;\n}\n\nclass ED {\n\tpublic static function q(d:D2):Int return 0;\n}\n\n'
			+ 'class EM {\n\tpublic static function y(m:Mid):Int return 0;\n}\n\nclass EG {\n'
			+ '\tpublic static function w(g:G):Int return 0;\n\n\tpublic static function y(g:G):Int return 0;\n}\n',
			'p/Main.hx' => 'package p;\n\nclass Main {}\n'
		]);
		Assert.equals('EP.f', binding(index, 'p/Main.hx', 'D', 'f'), 'the superclass before an interface written first');
		Assert.equals('ED.q', binding(index, 'p/Main.hx', 'D2', 'q'), 'the type\'s own before the inherited');
		Assert.equals('EG.w', binding(index, 'p/Main.hx', 'D3', 'w'), 'the whole superclass chain before an interface');
		Assert.equals('EM.y', binding(index, 'p/Main.hx', 'D3', 'y'), 'the nearer superclass first');
	}

	@:pin('control') @:killer('M-EXT-ALIAS-STOP')
	public function testATypedefBringsItsOwnThenTheAliasedTypes(): Void {
		final index: SymbolIndex = indexOf([
			'p/C.hx' => 'package p;\n\n@:using(p.EC) class C {}\n\n@:using(p.ET) typedef TD = C;\n\ntypedef TD2 = C;\n',
			'p/EC.hx' => 'package p;\n\nclass EC {\n\tpublic static function f(c:C):Int return 0;\n\n'
			+ '\tpublic static function g(c:C):Int return 0;\n}\n',
			'p/ET.hx' => 'package p;\n\nclass ET {\n\tpublic static function f(c:C):Int return 0;\n}\n',
			'p/Main.hx' => 'package p;\n\nclass Main {}\n'
		]);
		Assert.equals('ET.f', binding(index, 'p/Main.hx', 'TD', 'f'), 'the typedef\'s own first');
		Assert.equals('EC.f', binding(index, 'p/Main.hx', 'TD2', 'f'), 'a plain alias reaches the aliased type\'s');
		Assert.equals('EC.g', binding(index, 'p/Main.hx', 'TD', 'g'), 'then the aliased type\'s');
	}

	@:pin('control') @:killer('M-USING-HOSTS-ALIAS')
	public function testAnAliasInAUsedModuleBringsTheClassItNames(): Void {
		final index: SymbolIndex = indexOf([
			'p/Impl.hx' => 'package p;\n\nclass Impl {\n\tpublic static function f(s:Str):Int return 0;\n}\n',
			'p/Tm.hx' => 'package p;\n\ntypedef Anon = { x:Int };\n\nclass Tm {\n\tpublic static function f(s:Str):Int return 0;\n}\n\n'
			+ 'typedef Alias = Impl;\n',
			'p/Main.hx' => 'package p;\n\nusing p.Tm;\n\nclass Main {}\n'
		]);
		Assert.equals('Impl.f', binding(index, 'p/Main.hx', 'Str', 'f'), 'the alias, declared last, brings `Impl`');
	}

	@:pin('control') @:killer('M-EXT-NULL-PARAM-OPEN') @:killer('M-EXT-DYNAMIC-PARAM-OPEN') @:killer('M-UNIFY-GENERIC-GIVEN')
	public function testWhatAFirstParameterAccepts(): Void {
		final index: SymbolIndex = indexOf([
			'p/A.hx' => 'package p;\n\nclass A {\n\tpublic static function n(s:Null<Str>):Int return 0;\n\n'
			+ '\tpublic static function d(x:Dynamic):Int return 0;\n\n\tpublic static function t<T>(x:T):Int return 0;\n\n'
			+ '\tpublic static function sup(b:Base):Int return 0;\n}\n',
			'p/Base.hx' => 'package p;\n\nclass Base {}\n\nclass Sub extends Base {}\n\nclass Gen<T> extends Base {}\n',
			'p/Main.hx' => 'package p;\n\nusing p.A;\n\nclass Main {}\n'
		]);
		Assert.equals('A.n', binding(index, 'p/Main.hx', 'Str', 'n'), '`Null<Str>` accepts a `Str`');
		Assert.equals('A.d', binding(index, 'p/Main.hx', 'Str', 'd'), '`Dynamic` accepts every receiver');
		Assert.equals('-', binding(index, 'p/Main.hx', 'Str', 't'), 'a type parameter\'s constraint is not recorded');
		Assert.equals('A.sup', binding(index, 'p/Main.hx', 'Sub', 'sup'), 'a subclass');
		Assert.equals('A.sup', binding(index, 'p/Main.hx', 'Gen', 'sup'), 'a generic subclass, by its chain');
	}

	@:pin('control') @:killer('M-EXT-FIELD-FIRST') @:killer('M-EXT-PRIVATE-OPEN') @:killer('M-BINDER-EXTENSION-GUARDED-USING')
	public function testWhatTheWalkDoesNotProve(): Void {
		final index: SymbolIndex = indexOf([
			'p/A.hx' => 'package p;\n\nclass A {\n\tpublic static function f(c:Own):Int return 0;\n\n'
			+ '\tpublic static function g(s:Str):Int return 0;\n\n\tpublic static function k(s:Str):Int return 0;\n}\n',
			'p/B.hx' => 'package p;\n\nclass B {\n\tstatic function g(s:Str):Int return 0;\n}\n',
			'p/G.hx' => 'package p;\n\nclass G {\n\tpublic static function k(s:Str):Int return 0;\n}\n',
			'p/Own.hx' => 'package p;\n\nclass Own {\n\tpublic function f():Void {}\n}\n',
			'p/Main.hx' => 'package p;\n\nusing p.A;\nusing p.B;\n#if x\nusing p.G;\n#end\n\nclass Main {}\n'
		]);
		Assert.equals('-', binding(index, 'p/Main.hx', 'Own', 'f'), 'a field of the receiver binds before any extension');
		Assert.equals('-', binding(index, 'p/Main.hx', 'Str', 'g'), 'a private static: reached from its class only');
		Assert.equals('-', binding(index, 'p/Main.hx', 'Str', 'k'), 'a guarded `using` that may supply it');
	}

	/**
	 * Two things the index cannot order: which file of a module it holds twice the compiler loads (the class path's first),
	 * and which branch of a type under `#if` a build compiles. Each is decided only when every alternative passes.
	 */
	@:pin('control') @:killer('M-EXT-AMBIGUOUS-MODULE', 'M-EXT-GUARDED-LINKS')
	public function testAlternativesTheIndexCannotOrderMustAllPass(): Void {
		final index: SymbolIndex = indexOf([
			'p/A.hx' => 'package p;\n\nclass A {\n\tpublic static function f(s:Str):Int return 0;\n\n'
			+ '\tpublic static function g(s:Str):Int return 0;\n\n\tpublic static function h(g:G):Int return 0;\n}\n',
			'one/p/Dup.hx' => 'package p;\n\nclass Dup {\n\tpublic static function f(s:Str):Int return 0;\n}\n',
			'two/p/Dup.hx' => 'package p;\n\nclass Dup {}\n',
			'p/G.hx' => 'package p;\n\n#if x\nclass G extends P {}\n#else\nclass G {}\n#end\n',
			'p/P.hx' => 'package p;\n\n@:using(p.EP) class P {}\n',
			'p/EP.hx' => 'package p;\n\nclass EP {\n\tpublic static function h(x:Dynamic):Int return 0;\n}\n',
			'p/Main.hx' => 'package p;\n\nusing p.A;\nusing p.Dup;\n\nclass Main {}\n'
		]);
		Assert.equals('-', binding(index, 'p/Main.hx', 'Str', 'f'), 'one file of the module declares it');
		Assert.equals('A.g', binding(index, 'p/Main.hx', 'Str', 'g'), 'no file of the module declares it');
		Assert.equals('-', binding(index, 'p/Main.hx', 'G', 'h'), 'a supertype of one branch brings it');
	}

	@:pin('control') @:killer('M-EXT-AMBIENT-FIRST')
	public function testTheFilesOwnUsingsComeBeforeTheAmbientOnes(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_static_extensions', [
			{ name: 'src/p/Str.hx', source: 'package p;\n\nclass Str {}\n' },
			{
				name: 'src/p/IA.hx',
				source: 'package p;\n\nclass IA {\n\tpublic static function g(s:Str):Int return 0;\n\n'
				+ '\tpublic static function h(s:Str):Int return 0;\n}\n'
			},
			{ name: 'src/p/IC.hx', source: 'package p;\n\nclass IC {\n\tpublic static function g(s:Str):Int return 0;\n}\n' },
			{ name: 'src/p/import.hx', source: 'using p.IA;\n' },
			{ name: 'src/p/Main.hx', source: 'package p;\n\nusing p.IC;\n\nclass Main {}\n' }
		]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final names: Array<String> = ['src/p/Str.hx', 'src/p/IA.hx', 'src/p/IC.hx', 'src/p/import.hx', 'src/p/Main.hx'];
			final index: SymbolIndex = CheckFixture.index([
				for (n in names) { file: '$root/$n', source: sys.io.File.getContent('$root/$n') }
			], new HaxeQueryPlugin());
			Assert.equals('IC.g', binding(index, '$root/src/p/Main.hx', 'Str', 'g'), 'the file\'s own `using` first');
			Assert.equals('IA.h', binding(index, '$root/src/p/Main.hx', 'Str', 'h'), 'then the ambient one');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** What `recv.name` binds in `file` on a receiver of the one type named `receiver` the fixture declares: `Host.member`, or `-`. */
	private static function binding(index: SymbolIndex, file: String, receiver: String, name: String): String {
		final fi: Null<FileInfo> = index.fileInfo(file);
		final decls: Array<ResolvedType> = index.refs.resolvedDeclsNamed(receiver);
		if (fi == null || decls.length != 1) return 'no fixture $file / $receiver';
		final found: Null<HostedMembers> = index.typing.extensions.binding(fi, decls[0], name);
		return found == null ? '-' : '${found.host.type.name}.${found.members[0].name}';
	}

	/** An index over `files` (path -> source) and the two receiver types `Str` and `Other`. */
	private static function indexOf(files: Map<String, String>): SymbolIndex {
		final all: Array<{ file: String, source: String }> = [
			{ file: 'p/Str.hx', source: 'package p;\n\nclass Str {}\n' },
			{ file: 'p/Other.hx', source: 'package p;\n\nclass Other {}\n' }
		];
		for (file => source in files) all.push({ file: file, source: source });
		return CheckFixture.index(all, new HaxeQueryPlugin());
	}

}
