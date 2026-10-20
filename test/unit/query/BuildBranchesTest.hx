package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AbstractCasts;
import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.ReachLiveness.ReachConfiguration;
import anyparse.query.SymbolIndex;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

/**
 * Which `#if` branches of a declaration the typer reads (`BuildBranches`, `docs/typing-service.md` step T6): with the run's
 * declared builds known, a branch every build provably leaves out is dropped; with none known, or one build that may take
 * it, every branch is read. A header whose `enum` keyword is split by `#if` from the `@:enum` meta declares one enum
 * abstract whichever branch the compiler takes (Haxe 4.3.7).
 */
@:nullSafety(Strict)
class BuildBranchesTest extends Test {

	/**
	 * `S` writes its `enum` keyword under `#if`, `@:enum` under `#else`; `T` is shaped like a library's text-alignment
	 * abstract: two such abstracts under `#if !flash` (the second under `#else` of `#if !js2`), a `typedef` to a target
	 * type under `#else`. No native build compiles either branch of `U`; `V` converts from `String` only under `flash`.
	 */
	private static final FIXTURE: String = 'package p;\n\n#if (haxe_ver >= 4.0) enum #else @:enum #end abstract S(Int) {\n'
		+ '\tvar A = 1;\n}\n\n#if !flash\n#if !js2\n/** doc */\n#if (haxe_ver >= 4.0) enum #else @:enum #end abstract T(Null<Int>) {\n'
		+ '\tpublic var LEFT = 3;\n\n\t@:from private static function fromString(value:String):T return LEFT;\n\n'
		+ '\t@:to private function toString():String return \'left\';\n}\n#else\n@:x(\'y\') #if (haxe_ver >= 4.0) enum #else @:enum #end '
		+ 'abstract T(String) from String to String {\n\tpublic var LEFT = \'left\';\n}\n#end\n#else\n'
		+ 'typedef T = flash.text.Other;\n#end\n\n#if js2\nenum abstract U(Int) {\n\tvar A = 1;\n}\n#elseif flash\n'
		+ 'typedef U = flash.text.Other;\n#end\n\n#if !flash\nabstract V(Int) {}\n#else\nabstract V(Int) {\n'
		+ '\t@:from static function ofString(s:String):V return null;\n}\n#end\n';

	/** A build the way a native target's compile reports it: `flash` and `js2` never defined. */
	private static final NATIVE: ReachConfiguration = {
		name: 'native',
		defined: ['cpp', 'sys', 'haxe_ver'],
		everDefined: ['cpp', 'sys', 'haxe_ver'],
		values: ['haxe_ver' => '4.307'],
		compiled: [],
		types: []
	};

	/** The split header is ONE enum abstract, with no build known: its value is of it, and it has a cast graph. */
	public function testASplitEnumHeaderDeclaresOneEnumAbstract(): Void {
		final index: SymbolIndex = indexUnder(null);
		final s: ResolvedType = declared(index, 'S');
		Assert.isTrue(index.typing.casts.holdsUntypedValue(s, 'A'));
		Assert.notNull(index.typing.casts.graph(s));
	}

	/**
	 * Under a build that leaves `flash` and `js2` undefined only the first abstract of `T` is compiled: `T.LEFT` is of `T`,
	 * and `T` casts to no `Float`.
	 */
	@:pin('control') @:killer('M-BUILDS-FILTER-OFF') @:killer('M-BUILDS-HOST-OFF') @:killer('M-CASTS-CLAUSES-LIVE') @:killer('M-CASTS-BRANCHES-LIVE')
	public function testABranchNoDeclaredBuildCompilesIsDropped(): Void {
		final index: SymbolIndex = indexUnder([NATIVE]);
		final t: ResolvedType = declared(index, 'T');
		Assert.isTrue(index.typing.casts.holdsUntypedValue(t, 'LEFT'));
		Assert.equals(Misfits, index.typing.unification.casts(Declared(t), Core('Float')));
		Assert.equals(1, index.typing.casts.branchMembers(t)?.length);
	}

	/** With no build known every branch is read: the `typedef` branch declares no value, and the casts stay open. */
	@:pin('control') @:killer('M-BUILDS-NONE-KNOWN') @:killer('M-CASTS-CLAUSES-NULL') @:killer('M-INDEX-BRANCHES-ALTERNATE')
	public function testEveryBranchIsReadWhenTheRunKnowsNoBuilds(): Void {
		final index: SymbolIndex = indexUnder(null);
		final t: ResolvedType = declared(index, 'T');
		Assert.isFalse(index.typing.casts.holdsUntypedValue(t, 'LEFT'));
		Assert.equals(MayFit, index.typing.unification.casts(Declared(t), Core('Float')));
	}

	/**
	 * A branch one declared build may take stays: a build defining `flash`, or one that sets it at some point of the compile
	 * (an initialization or build macro) though not for every file.
	 */
	public function testABranchABuildMayTakeStays(): Void {
		final flash: ReachConfiguration = {
			name: 'flash',
			defined: ['flash'],
			everDefined: ['flash'],
			values: [],
			compiled: [],
			types: []
		};
		final late: ReachConfiguration = {
			name: 'late',
			defined: ['cpp'],
			everDefined: ['cpp', 'flash'],
			values: [],
			compiled: [],
			types: []
		};
		Assert.isFalse(leftIsValue(indexUnder([NATIVE, flash])), 'a build defining it');
		Assert.isFalse(leftIsValue(indexUnder([late])), 'a build that sets it later');
	}

	/**
	 * A conversion member only a branch no build compiles declares converts nothing: `V` takes no `String` under the native
	 * build; with no build known the member may be the one compiled.
	 */
	@:pin('control') @:killer('M-CASTS-MEMBERS-LIVE')
	public function testADroppedBranchsMembersConvertNothing(): Void {
		final v: TypeEnd = Declared(declared(indexUnder([NATIVE]), 'V'));
		Assert.equals(Misfits, indexUnder([NATIVE]).typing.unification.casts(Core('String'), v));
		final open: SymbolIndex = indexUnder(null);
		Assert.equals(MayFit, open.typing.unification.casts(Core('String'), Declared(declared(open, 'V'))));
	}

	/**
	 * A declaration no build compiles at all is read whole: `U` declares its value in one of two branches neither of which a
	 * native build takes, so `U.A` is still no value of `U`.
	 */
	@:pin('control') @:killer('M-BUILDS-NONE-LIVE')
	public function testADeclarationNoBuildCompilesIsReadWhole(): Void {
		final index: SymbolIndex = indexUnder([NATIVE]);
		Assert.isFalse(index.typing.casts.holdsUntypedValue(declared(index, 'U'), 'A'));
	}

	/**
	 * The builds are asked for once per index, and only by a question about a declaration with more than one branch: `S`
	 * has one, `T` three.
	 */
	@:pin('control') @:killer('M-BUILDS-ONE-BRANCH') @:killer('M-BUILDS-ASKED-ONCE')
	public function testTheBuildsAreAskedOnceAndOnlyForSeveralBranches(): Void {
		var reads: Int = 0;
		final index: SymbolIndex = indexUnder([NATIVE], () -> reads++);
		final casts: AbstractCasts = index.typing.casts;
		Assert.isTrue(casts.holdsUntypedValue(declared(index, 'S'), 'A'));
		Assert.equals(0, reads, 'one branch');
		Assert.isTrue(casts.holdsUntypedValue(declared(index, 'T'), 'LEFT'));
		Assert.isTrue(casts.holdsUntypedValue(declared(index, 'T'), 'LEFT'));
		Assert.equals(1, reads, 'several branches');
	}

	/** Whether `T.LEFT` is a value of `T` in `index`. */
	private static function leftIsValue(index: SymbolIndex): Bool {
		return index.typing.casts.holdsUntypedValue(declared(index, 'T'), 'LEFT');
	}

	private static function declared(index: SymbolIndex, type: String): ResolvedType {
		final found: Null<ResolvedType> = index.refs.findDeclaredType('p/M.hx', type);
		if (found == null) throw 'no declaration $type';
		return found;
	}

	/**
	 * The index of the fixture, built by a run that knows `configurations` as its builds — none when null — calling `read`
	 * each time it is asked for them.
	 */
	private static function indexUnder(configurations: Null<Array<ReachConfiguration>>, ?read: () -> Void): SymbolIndex {
		final files: Array<{ file: String, source: String }> = [{ file: 'p/M.hx', source: FIXTURE }];
		if (configurations == null) return CheckFixture.index(files, new HaxeQueryPlugin());
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final onRead: () -> Void = read ?? () -> {};
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {report: files, projectRoots: [], library: new LibrarySources([]) },
			builds: () -> {
				onRead();
				{ configurations: configurations, library: [] };
			}
		});
		return plugin.indexOver(files);
	}

}
