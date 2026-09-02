package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ExtractInterface;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `ExtractInterface.extract` — generate an interface from a class's
 * public instance methods and make the class implement it. Each test
 * drives the PURE op with an in-memory source, asserts the generated
 * interface + the `implements` header edit, and re-parses both. Refusal
 * cases assert `Err`.
 */
class ExtractInterfaceSliceTest extends Test {

	/**
	 * Only public instance methods are extracted: a private method, a
	 * static method and the constructor are all excluded; the class gains
	 * `implements`.
	 */
	public function testBasicExtract(): Void {
		final src: String = 'package pkg;\n\nclass Service {\n\tvar count:Int = 0;\n\tpublic function new() {}\n'
			+ '\tpublic function fetch(id:Int):String return \'x\';\n\tpublic function reset():Void {}\n'
			+ '\tfunction helper():Int return count;\n\tpublic static function make():Service return null;\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Service.hx', 'Service', 'IService', 'pkg/IService.hx', null, src);
		Assert.equals(2, changes.length);
		final iface: String = changeFor(changes, 'pkg/IService.hx').newSource;
		Assert.isTrue(iface.contains('interface IService'), 'declares the interface');
		Assert.isTrue(iface.contains('function fetch(id:Int):String;'), 'carries fetch signature');
		Assert.isTrue(iface.contains('function reset():Void;'), 'carries reset signature');
		Assert.isFalse(iface.contains('helper'), 'excludes the private method');
		Assert.isFalse(iface.contains('make'), 'excludes the static method');
		Assert.isFalse(iface.contains('function new'), 'excludes the constructor');
		final newSrc: String = changeFor(changes, 'pkg/Service.hx').newSource;
		Assert.isTrue(newSrc.contains('class Service implements IService {'), 'class implements the interface');
	}

	/** Only the imports the signatures reference are carried into the interface. */
	public function testImportCarry(): Void {
		final src: String = 'package pkg;\n\nimport haxe.ds.Option;\nimport haxe.ds.StringMap;\n\nclass S {\n\tpublic function new() {}\n'
			+ '\tpublic function f():Option<Int> return null;\n\tpublic function g(x:Int):Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', null, src);
		final iface: String = changeFor(changes, 'pkg/IS.hx').newSource;
		Assert.isTrue(iface.contains('import haxe.ds.Option;'), 'carries the referenced import');
		Assert.isFalse(iface.contains('StringMap'), 'drops the unreferenced import');
	}

	/** `--members` selects a subset; the others are not in the interface. */
	public function testMembersSubset(): Void {
		final src: String =
			'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n\tpublic function b():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', ['a'], src);
		final iface: String = changeFor(changes, 'pkg/IS.hx').newSource;
		Assert.isTrue(iface.contains('function a():Void;'), 'includes the selected method');
		Assert.isFalse(iface.contains('function b'), 'excludes the unselected method');
	}

	/** An existing `extends` clause is preserved; `implements` is appended. */
	public function testExtendsPreserved(): Void {
		final src: String =
			'package pkg;\n\nclass S extends Base {\n\tpublic function new() { super(); }\n\tpublic function a():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', null, src);
		final newSrc: String = changeFor(changes, 'pkg/S.hx').newSource;
		Assert.isTrue(newSrc.contains('class S extends Base implements IS {'), 'extends preserved, implements added');
	}

	/**
	 * A `{` inside a header comment is NOT the class body brace — the op must
	 * anchor past the comment instead of splicing `implements` into it.
	 */
	public function testCommentBraceInHeader(): Void {
		final src: String =
			'package pkg;\n\nclass Holder /* body { starts */ {\n\tpublic function new() {}\n\n\tpublic function ping():Void {}\n}\n';
		final changes: Array<MoveChange> = okChanges('pkg/Holder.hx', 'Holder', 'IHolder', 'pkg/IHolder.hx', null, src);
		final newSrc: String = changeFor(changes, 'pkg/Holder.hx').newSource;
		Assert.isTrue(newSrc.contains('class Holder implements IHolder /* body { starts */ {'), 'implements lands outside the comment');
		Assert.isFalse(newSrc.contains('body implements'), 'nothing spliced inside the comment');
	}

	/** A `{` inside a header LINE comment is not the body brace either. */
	public function testLineCommentBraceInHeader(): Void {
		final src: String =
			'package pkg;\n\nclass Holder // note {\n{\n\tpublic function new() {}\n\n\tpublic function ping():Void {}\n}\n';
		final changes: Array<MoveChange> = okChanges('pkg/Holder.hx', 'Holder', 'IHolder', 'pkg/IHolder.hx', null, src);
		final newSrc: String = changeFor(changes, 'pkg/Holder.hx').newSource;
		Assert.isTrue(newSrc.contains('class Holder implements IHolder // note {'), 'implements lands before the line comment');
	}

	/** A structural type-parameter constraint brace is not the body brace. */
	public function testTypeParamConstraintBrace(): Void {
		final src: String =
			'package pkg;\n\nclass Holder<T:{ x:Int }> {\n\tpublic function new() {}\n\n\tpublic function ping():Void {}\n}\n';
		final changes: Array<MoveChange> = okChanges('pkg/Holder.hx', 'Holder', 'IHolder', 'pkg/IHolder.hx', null, src);
		final newSrc: String = changeFor(changes, 'pkg/Holder.hx').newSource;
		Assert.isTrue(newSrc.contains('class Holder<T:{ x:Int }> implements IHolder {'), 'implements lands after the type params');
	}

	/** An existing `implements` clause is preserved; the new one is appended after it. */
	public function testExistingImplementsPreserved(): Void {
		final src: String = 'package pkg;\n\nclass S implements IThing {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', null, src);
		final newSrc: String = changeFor(changes, 'pkg/S.hx').newSource;
		Assert.isTrue(newSrc.contains('class S implements IThing implements IS {'), 'both implements clauses present');
	}

	/** A `final class` gets the `implements` clause too. */
	public function testFinalClass(): Void {
		final src: String = 'package pkg;\n\nfinal class S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', null, src);
		final newSrc: String = changeFor(changes, 'pkg/S.hx').newSource;
		Assert.isTrue(newSrc.contains('final class S implements IS {'), 'final class implements the interface');
	}

	/** A class with no public instance method is refused. */
	public function testNoPublicMethodsRefused(): Void {
		final src: String =
			'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tfunction hidden():Void {}\n\tpublic static function s():Void {}\n}';
		assertErr(ExtractInterface.extract('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', null, src, plugin()));
	}

	/** A `--members` entry that is not an extractable method is refused. */
	public function testUnknownMemberRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractInterface.extract('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', ['nope'], src, plugin()));
	}

	/** The interface name must differ from the source type. */
	public function testNameEqualsTypeRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractInterface.extract('pkg/S.hx', 'S', 'S', 'pkg/S2.hx', null, src, plugin()));
	}

	/** An invalid interface name is refused. */
	public function testInvalidNameRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractInterface.extract('pkg/S.hx', 'S', '1bad', 'pkg/X.hx', null, src, plugin()));
	}

	/**
	 * A class that ALREADY implements the interface is refused — nothing written.
	 *
	 * RED at base: the header splice appended a clause without reading the ones already
	 * there, so a re-run produced `class S implements IS implements IS`, at rc 0 and past
	 * the parse gate because the header still parses. Killed by arm M1.
	 */
	public function testAlreadyImplementsRefused(): Void {
		final src: String = 'package pkg;\n\nclass S implements IS {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		switch ExtractInterface.extract('pkg/S.hx', 'S', 'IS', 'pkg/IS2.hx', null, src, plugin()) {
			case Ok(changes, _):
				Assert.fail('expected Err (refusal), got Ok with ${changes.length} change(s)');
			case Err(message):
				Assert.stringContains('already implements "IS"', message);
		}
	}

	/**
	 * The refusal is EXACT-NAME, so a class already implementing a DIFFERENT interface
	 * still extracts and the two clauses stand side by side.
	 *
	 * Green at base by construction; killed by arm M2, which widens the refusal to any
	 * `implements` clause.
	 */
	public function testSecondInterfaceStillExtracts(): Void {
		final src: String = 'package pkg;\n\nclass S implements IA {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'IB', 'pkg/IB.hx', null, src);
		final newSrc: String = changeFor(changes, 'pkg/S.hx').newSource;
		Assert.isTrue(newSrc.contains('class S implements IA implements IB {'), 'both clauses stand, in source order');
	}

	/**
	 * A QUALIFIED clause of the same simple name does not block the extraction: only a
	 * type resolution could tell `other.IS` and a local `IS` apart, and the pair is legal
	 * Haxe. Green at base by construction; killed by arm M2 the same way.
	 */
	public function testQualifiedSameNameDoesNotBlock(): Void {
		final src: String = 'package pkg;\n\nclass S implements other.IS {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', null, src);
		final newSrc: String = changeFor(changes, 'pkg/S.hx').newSource;
		Assert.isTrue(newSrc.contains('implements other.IS implements IS'), 'the qualified clause is a different type');
	}

	/**
	 * A clause behind `#if` counts: it is a child of the `Conditional`, not of the form
	 * node, so the flat scan missed it and the header gained a second clause that is a
	 * duplicate on every target the condition selects. Killed by arm M16.
	 */
	public function testGuardedImplementsRefused(): Void {
		final src: String =
			'package pkg;\n\nclass S\n#if sys\nimplements IS\n#end\n{\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		switch ExtractInterface.extract('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', null, src, plugin()) {
			case Ok(changes, _):
				Assert.fail('expected Err (refusal), got Ok with ${changes.length} change(s)');
			case Err(message):
				Assert.stringContains('already implements "IS"', message);
		}
	}

	/** A source type that is not a class in the file is refused. */
	public function testNoSuchClassRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractInterface.extract('pkg/S.hx', 'Other', 'IS', 'pkg/IS.hx', null, src, plugin()));
	}

	/**
	 * The created interface is canonical UNDER THE PROJECT'S CONFIG, not under the
	 * writer's compiled defaults.
	 *
	 * `buildInterface` used to call `plugin.writeRoundTrip(source, null)`, so a
	 * project whose `hxformat.json` sets anything the writer has an opinion about
	 * got a file styled by the DEFAULTS while its own `fmt --list` judged it by the
	 * config — drifted from birth, and the next writer-emit op on it refused with
	 * `file is not in canonical form`. Four-space indentation is the cheapest
	 * discriminator: the default is a tab.
	 */
	public function testCreatedInterfaceIsCanonicalUnderProjectConfig(): Void {
		final config: String = '{"indentation": {"character": "    ", "tabWidth": 4}}';
		final src: String =
			'package pkg;\n\nclass Service {\n    public function new() {}\n\n    public function fetch(id:Int):String return \'x\';\n}\n';
		switch ExtractInterface.extract('pkg/Service.hx', 'Service', 'IService', 'pkg/IService.hx', null, src, plugin(), config) {
			case Ok(changes, _):
				final iface: String = changeFor(changes, 'pkg/IService.hx').newSource;
				Assert.isTrue(iface.contains('\n    function fetch'), 'indented by the config, not by the default tab:\n<$iface>');
				Assert.equals(
					iface, plugin().writeRoundTrip(iface, config),
					'the created file must pass the ONE-pass canonical gate the next op puts on it'
				);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * The EDITED source must come back canonical, not just the CREATED one — the
	 * asymmetry the sibling commit left standing.
	 *
	 * RED at the base commit. ` implements IBase` looks like the safest edit an op can
	 * make, and it is still a WRITER decision: on a header already near the limit the
	 * splice pushes the line past it, where the writer breaks the trailing clause onto
	 * a continuation line. A verbatim splice cannot know that, so the source was
	 * canonical one second before the op ran and drifted the moment it returned. The
	 * created interface, in the same call, was already fixed-point canonical.
	 *
	 * Both halves are asserted together: the fixed point AND the wrap the raw splice
	 * never produced, so neither can be satisfied by an op that did nothing.
	 */
	public function testTheEditedSourceComesBackCanonical(): Void {
		final src: String = 'package pkg;\n\nclass Long implements AlphaBetaGammaDeltaEpsilonZetaEtaThetaIotaKappaLambdaMuNuXi'
			+ ' implements OmicronPiRhoSigmaTauUpsilonPhiChiPsiOmegaAlphaBetaGamma {\n\tpublic function new() {}\n\n'
			+ '\tpublic function alpha():Int {\n\t\treturn 1;\n\t}\n\n\tpublic function beta():Int {\n\t\treturn 2;\n\t}\n}\n';
		Assert.equals(
			src, plugin().writeRoundTrip(src, null), 'the fixture must be canonical BEFORE the op, else there is no drift to see'
		);
		final changes: Array<MoveChange> = okChanges('pkg/Long.hx', 'Long', 'IBase', 'pkg/IBase.hx', ['alpha'], src);
		final newSrc: String = changeFor(changes, 'pkg/Long.hx').newSource;
		Assert.equals(newSrc, plugin().writeRoundTrip(newSrc, null), 'the edited file must be the writer fixed point:\n<$newSrc>');
		Assert.isTrue(newSrc.contains('\n\t\timplements IBase {'), 'the over-long header wrapped, which is what the raw splice never did');
	}

	/**
	 * CONTROL — green at the base commit BY CONSTRUCTION, and it must stay green.
	 *
	 * A span-splice op is FORMAT-PRESERVING, and canonicalising the edited file must
	 * not turn it into a reformatter: a source nobody ever ran `fmt` over keeps its own
	 * layout, and only the spliced clause is new. `editKeepingCanonical` decides that
	 * by re-asking the input gate, so the whole existing suite of non-canonical
	 * fixtures in this class is the same control at scale — this one states it.
	 */
	public function testANonCanonicalSourceIsNotReformatted(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a( ):Void {}\n}';
		Assert.notEquals(src, plugin().writeRoundTrip(src, null), 'the fixture must be NON-canonical, else this control proves nothing');
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', null, src);
		final newSrc: String = changeFor(changes, 'pkg/S.hx').newSource;
		Assert.isTrue(newSrc.contains('public function a( ):Void {}'), 'the odd spacing the user wrote is untouched:\n<$newSrc>');
		Assert.isTrue(newSrc.contains('class S implements IS {'), 'and the clause still landed');
	}

	private function okChanges(
		srcFile: String, srcType: String, ifaceName: String, ifaceFile: String, memberNames: Null<Array<String>>, srcSource: String
	): Array<MoveChange> {
		switch ExtractInterface.extract(srcFile, srcType, ifaceName, ifaceFile, memberNames, srcSource, plugin()) {
			case Ok(changes, advisory):
				Assert.notNull(advisory);
				for (c in changes) {
					var parsed: Bool = true;
					try
						plugin().parseFile(c.newSource)
					catch (_: haxe.Exception)
						parsed = false;
					Assert.isTrue(parsed, 'rewritten ${c.file} should re-parse');
				}
				return changes;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return [];
		}
	}

	private function assertErr(result: MoveResult): Void {
		switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
			case Err(_):
				Assert.pass();
		}
	}

	private function changeFor(changes: Array<MoveChange>, file: String): MoveChange {
		for (c in changes) if (c.file == file) return c;
		Assert.fail('no change for file $file');
		return { file: file, newSource: '' };
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

}
