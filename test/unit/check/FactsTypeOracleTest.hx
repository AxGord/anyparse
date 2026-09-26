package unit.check;

import anyparse.check.Check.OracleType;
import anyparse.check.Check.Violation;
import anyparse.check.ExplicitType;
import anyparse.check.FactsTypeOracle;
import anyparse.check.FactsTypeSpelling;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CompilerFacts;
import anyparse.query.FactText;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `FactsTypeOracle` over hand-written facts files: it answers a type only when every configuration that typed the
 * declaration agrees, spells it as source or declines with a reason, and reads a file the run rewrote at the text the
 * compile read.
 */
@:nullSafety(Strict)
class FactsTypeOracleTest extends Test {

	private static final SRC: String = 'class A<T> {\n\tvar fld = g();\n\n\tfunction f(p) {\n\t\tvar v = g();\n\t}\n}\n';

	@:pin('control') @:killer('M-FACTS-ORACLE-AGREE') @:killer('M-FACTS-UNION')
	public function testConfigurationsThatDisagreeDecline(): Void {
		Assert.same(Typed('Int'), local(table([dump('Int'), dump('Int')])));
		final split: OracleType = local(table([dump('Null<pack.X>'), dump('pack.X')]));
		Assert.isTrue(declinedWith(split, 'the oracle configurations type it differently'), 'got $split');
	}

	@:pin('control') @:killer('M-FACTS-SPELL-UNKNOWN')
	public function testAnUnknownDeclines(): Void {
		Assert.same(Declined(FactsTypeOracle.DECLINE_UNKNOWN), local(table([dump('Array<?>')])));
		Assert.same(Declined(FactsTypeOracle.DECLINE_UNKNOWN), FactsTypeSpelling.spell('(?)->Void', { owner: null, method: null }));
	}

	@:pin('control') @:killer('M-FACTS-SPELL-SCOPE')
	public function testATypeParameterOutOfScopeDeclines(): Void {
		Assert.same(Typed('Array<A.T>'), local(table([dump('Array<$$A.T>')])));
		Assert.same(Typed('f.U'), local(table([dump('$$f.U')])));
		final foreign: OracleType = local(table([dump('$$pack.B.T')]));
		Assert.isTrue(declinedWith(foreign, 'its type names the type parameter `pack.B.T`'), 'got $foreign');
	}

	@:pin('control') @:killer('M-FACTS-SPELL-IMPL')
	public function testTypesNoSourceCanSpellDecline(): Void {
		final scope: TypeScope = { owner: 'A', method: null };
		Assert.same(Declined(FactsTypeOracle.DECLINE_UNSPELLABLE), FactsTypeSpelling.spell('Abstract<pack.M>', scope));
		Assert.same(Declined(FactsTypeOracle.DECLINE_UNSPELLABLE), FactsTypeSpelling.spell('Class<pack._M.M_Impl_>', scope));
		Assert.same(Typed('(Int, ?Null<String>) -> Bool'), FactsTypeSpelling.spell('(Int,?Null<String>)->Bool', scope));
		Assert.same(Typed('{a:Int, ?b:() -> Void}'), FactsTypeSpelling.spell('{a:Int,?b:()->Void}', scope));
	}

	@:pin('control') @:killer('M-FACTS-ABSENT')
	public function testCodeNoConfigurationCompiledDeclines(): Void {
		final facts: CompilerFacts = table([dump('Int')]);
		final oracle: FactsTypeOracle = new FactsTypeOracle(facts, file -> SRC);
		Assert.same(Declined(FactsTypeOracle.DECLINE_FILE_NOT_COMPILED), oracle.localType('B.hx', declOf(SRC), 'v', 0));
		// a local of the same name the facts do not list: a branch no build compiled
		Assert.same(Declined(FactsTypeOracle.DECLINE_CODE_NOT_COMPILED), oracle.localType('A.hx', declOf(SRC), 'w', 0));
	}

	@:pin('control') @:killer('M-FACTS-ORACLE-ORIGINAL')
	public function testARewrittenFileIsReadAtTheTextTheCompileRead(): Void {
		final facts: CompilerFacts = table([dump('Int')]);
		final now: String = SRC.replace('\tvar fld = g();\n', '\tvar fld:Int = g();\n\n\t// added\n');
		facts.invalidate('A.hx', SRC);
		final oracle: FactsTypeOracle = new FactsTypeOracle(facts, file -> now);
		Assert.same(Typed('Int'), oracle.localType('A.hx', declOf(now), 'v', 0));
	}

	@:pin('control') @:killer('M-FACTS-INVALIDATE-FOREIGN')
	public function testFactsOfTheRewrittenTextStayCurrent(): Void {
		// the facts compile ran after the run wrote the file: the rewrite did not outdate them
		final hash: Array<String> = FactText.contentHash(SRC).split(':');
		final read: String = dump('Int')
			.replace('\n{"k":"end"', '\n{"k":"src","path":"A.hx","len":${hash[0]},"md5":"${hash[1]}"}\n{"k":"end"');
		final facts: CompilerFacts = table([read]);
		facts.invalidate('A.hx', SRC.replace('class A', 'class  A'));
		Assert.same(Typed('Int'), new FactsTypeOracle(facts, file -> SRC).localType('A.hx', declOf(SRC), 'v', 0));
	}

	@:pin('control') @:killer('M-CODEPOINT-NATIVE')
	public function testASiteAfterNonAsciiTextIsFound(): Void {
		final source: String = '// \u{1F600} é\n' + SRC;
		// the compiler counts the emoji as one position, a Span as two
		final shift: Int = '// \u{1F600} é\n'.length - 1;
		final facts: CompilerFacts = CompilerFacts.build(
			[{ name: 'one', text: dump('Int', shift), file: path -> path }], file -> file == 'A.hx' ? source : null, file -> file
		);
		Assert.same(Typed('Int'), new FactsTypeOracle(facts, file -> source).localType('A.hx', declOf(source), 'v', 0));
	}

	@:pin('control') @:killer('M-FACTS-FIELD-TYPES')
	public function testAFieldTheConfigurationsTypeApartDeclines(): Void {
		final field: Span = new Span(SRC.indexOf('var fld'), SRC.indexOf('g();') + 4);
		final same: FactsTypeOracle = new FactsTypeOracle(table([dump('Int'), dump('Int')]), file -> SRC);
		Assert.same(Typed('Int'), same.fieldType('A.hx', field, 'fld', 0));
		final apart: FactsTypeOracle = new FactsTypeOracle(table([dump('Int'), dump('Int', 0, 'Float')]), file -> SRC);
		Assert.isTrue(declinedWith(apart.fieldType('A.hx', field, 'fld', 0), 'the oracle configurations type it differently'));
	}

	@:pin('control') @:killer('M-FACTS-SIGNATURE-VARIANTS')
	public function testASignatureTheConfigurationsTypeApartDeclines(): Void {
		final fn: Span = new Span(SRC.indexOf('function f'), SRC.indexOf('\t}\n}') + 2);
		final same: FactsTypeOracle = new FactsTypeOracle(table([dump('Int'), dump('Int')]), file -> SRC);
		Assert.same(Typed('Int'), same.returnType('A.hx', fn, 'f', 0));
		Assert.same(Typed('Null<Int>'), same.paramType('A.hx', fn, 'f', 0, 'p', 0));
		final apart: FactsTypeOracle = new FactsTypeOracle(table([dump('Int'), dump('Int', 0, 'Int', 'Float', 'Float')]), file -> SRC);
		Assert.isTrue(declinedWith(apart.returnType('A.hx', fn, 'f', 0), 'the oracle configurations type it differently'));
		Assert.isTrue(declinedWith(apart.paramType('A.hx', fn, 'f', 0, 'p', 0), 'the oracle configurations type it differently'));
		Assert.same(Declined(FactsTypeOracle.DECLINE_PARAM_MISMATCH), same.paramType('A.hx', fn, 'f', 0, 'q', 0));
	}

	@:pin('control') @:killer('M-EXPLICIT-TYPE-STRUCTURAL-DECLINE')
	public function testExplicitTypeSaysWhyItsStructuralFixDeclined(): Void {
		final source: String = 'class C {\n\tvar y = g();\n\n\tfunction f(x) {\n\t\treturn x;\n\t}\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ExplicitType = new ExplicitType();
		final violations: Array<Violation> = check.run([{ file: 'C.hx', source: source }], plugin);
		Assert.equals(3, violations.length);
		Assert.equals(0, check.fix(source, violations, plugin).length);
		for (v in violations)
			Assert.isTrue((v.declineReason ?? '').indexOf('oracle-assisted pass') >= 0, '${v.message}: ${v.declineReason}');
	}

	/** The type the oracle over `facts` gives the local `v` of `SRC`. */
	private static function local(facts: CompilerFacts): OracleType {
		return new FactsTypeOracle(facts, file -> SRC).localType('A.hx', declOf(SRC), 'v', 0);
	}

	/** The span of the `var v` declaration in `source`. */
	private static function declOf(source: String): Span {
		return new Span(source.indexOf('var v'), source.indexOf('g();\n\t}') + 4);
	}

	private static function declinedWith(answer: OracleType, prefix: String): Bool {
		return switch answer {
			case Declined(reason): reason.startsWith(prefix);
			case Typed(_): false;
		};
	}

	/**
	 * One configuration's facts of `SRC` (at compiler offsets `shift` fewer than the text's, for text before it the
	 * compiler counts shorter): `v` typed `varType`, `fld` typed `fieldType`, and `f` returning `result` from a parameter
	 * `p` typed `Null<param>`.
	 */
	private static function dump(
		varType: String, shift: Int = 0, fieldType: String = 'Int', result: String = 'Int', param: String = 'Int'
	): String {
		function at(offset: Int): Int return offset + shift;
		final fnFrom: Int = at(SRC.indexOf('(p)'));
		final fnTo: Int = at(SRC.indexOf('\t}\n}') + 2);
		final varFrom: Int = at(SRC.indexOf('var v'));
		final varTo: Int = at(SRC.indexOf('g();\n\t}') + 3);
		final fldFrom: Int = at(SRC.indexOf('var fld'));
		final fldTo: Int = at(SRC.indexOf('g();') + 3);
		return '{"k":"facts","v":1,"inline":true}\n'
			+ '{"k":"type","id":"A","f":"A.hx","p":[${at(0)},${at(SRC.length)}],"kind":"class","pack":"","params":["T"],'
			+ '"fields":[{"n":"fld","k":"var(default,default)","t":"$fieldType","p":[$fldFrom,$fldTo]}]}\n'
			+ '{"k":"node","id":"A.f","f":"A.hx","p":[$fnFrom,$fnTo],"kind":"method","owner":"A","t":"(?Null<$param>)->$result",'
			+ '"params":[{"n":"p","t":"Null<$param>"}],"vars":[{"n":"v","t":"$varType","p":[$varFrom,$varTo]}]}\n'
			+ '{"k":"end","nodes":1,"types":1}\n';
	}

	private static function table(dumps: Array<String>): CompilerFacts {
		return CompilerFacts.build(
			[for (i in 0...dumps.length) { name: 'c$i', text: dumps[i], file: path -> path }],
			file -> file == 'A.hx' ? SRC : null, file -> file
		);
	}

}
