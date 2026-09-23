package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.FieldInitAtDeclaration;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `field-init-at-declaration` check's CROSSING path: an init after an explicit `super(...)` is
 * hoisted ahead of the base constructor only when every early-init narrowing holds — a declared
 * project scope, an inert collection literal, a declared type whose `null` faults, a non-public
 * field, the sole write, and no occurrence of the field across the scope outside an uncaught
 * null-faulting position. Each fixture isolates one narrowing; the base-constructor regressions of
 * the ordinary path stay in `FieldInitAtDeclarationCheckTest`.
 */
class FieldInitAtDeclarationCrossingSuperTest extends Test {

	/**
	 * An inert collection init after `super()` moves when the project declares its roots and every read
	 * of the field faults on `null` outside any `try`.
	 */
	@:pin('control')
	@:killer('M-FIAD-CROSS-SUPER-UNPROVED')
	public function testInertInitAfterSuperMovedWhenEveryReadFaults(): Void {
		final src: String = crossingSuper('function g(i:Int):Int { _a.push(i); return _a[i] + _a.length; }');
		final vs: Array<Violation> = scopedViolations([{ file: 'C.hx', source: src }]);
		Assert.equals(1, vs.length);
		final fixed: String = scopedFixedSource(src);
		Assert.isTrue(fixed.indexOf('private var _a:Array<Int> = [];') >= 0);
		Assert.equals(-1, fixed.indexOf('_a = [];'));
	}

	/**
	 * With no declared `resolutionRoots` — a libs-only scope, or none —
	 * a reader in an unlinted file cannot be seen, so nothing crosses.
	 */
	@:pin('control')
	@:killer('M-FIAD-NO-ROOTS-ADMITTED')
	public function testCrossingWithoutResolutionRootsNotMoved(): Void {
		final src: String = crossingSuper('function g():Int return _a.length;');
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		Assert.equals(1, scopedViolations(files).length, 'declared roots admit it');
		Assert.equals(0, new FieldInitAtDeclaration().run(files, scopedPlugin(files, false)).length, 'a libs-only scope');
		Assert.equals(0, violations(src).length, 'no scope at all');
	}

	/** A `null` comparison would read the early value and answer differently once it is `[]`. */
	@:pin('control')
	@:killer('M-FIAD-EARLY-READ-IGNORED')
	public function testEarlyReadComparedToNullRefused(): Void {
		Assert.equals(0, crossingCount(crossingSuper('function g():Bool return _a == null;')));
	}

	@:pin('control')
	@:killer('M-FIAD-EARLY-READ-IGNORED')
	public function testEarlyThisReadComparedToNullRefused(): Void {
		Assert.equals(0, crossingCount(crossingSuper('function g():Bool return this._a == null;')));
	}

	@:pin('control')
	@:killer('M-FIAD-EARLY-READ-IGNORED')
	public function testEarlyReadDefaultedRefused(): Void {
		Assert.equals(0, crossingCount(crossingSuper('function g():Array<Int> return _a ?? [1];')));
	}

	@:pin('control')
	@:killer('M-FIAD-EARLY-READ-IGNORED')
	public function testEarlyReadSafeNavigatedRefused(): Void {
		Assert.equals(0, crossingCount(crossingSuper('function g():Null<Int> return _a?.length;')));
	}

	@:pin('control')
	@:killer('M-FIAD-EARLY-READ-IGNORED')
	public function testEarlyReadStoredRefused(): Void {
		Assert.equals(0, crossingCount(crossingSuper('var _b:Array<Int>; function g():Void { _b = _a; }')));
	}

	/** An argument receives the early `null` and may keep it: the value flows on instead of faulting. */
	@:pin('control')
	@:killer('M-FIAD-EARLY-READ-IGNORED', 'M-FIAD-EARLY-READ-CALL-ARG')
	public function testEarlyReadPassedAsArgumentRefused(): Void {
		Assert.equals(0, crossingCount(crossingSuper('function g():Void { trace(_a); }')));
	}

	/** A `try` around a faulting read turns the fault into working code the move then changes. */
	@:pin('control')
	@:killer('M-FIAD-TRY-IGNORED')
	public function testFaultingReadInsideTryRefused(): Void {
		final src: String = crossingSuper('function g():Void { try { _a.push(1); } catch (e:haxe.Exception) {} }');
		Assert.equals(0, crossingCount(src));
	}

	/**
	 * A lambda or local function written inside a `try` may run inside it —
	 * called there, or handed to a call there — so its fault is caught too.
	 */
	@:pin('control')
	@:killer('M-FIAD-TRY-BOUNDARY-CLEARED')
	public function testFaultingReadInLambdaOrLocalFunctionInsideTryRefused(): Void {
		for (body in [
			'try { final f:() -> Int = () -> _a.length; f(); } catch (e:haxe.Exception) {}',
			'try { function h():Int return _a.length; h(); } catch (e:haxe.Exception) {}',
			'try { [1].iter(i -> _a.push(i)); } catch (e:haxe.Exception) {}'
		]) Assert.equals(0, crossingCount(crossingSuper('function g():Void { $body }')), body);
	}

	/** A subclass in ANOTHER file reads the field too — the scan covers the project scope, not the field's file. */
	@:pin('control')
	@:killer('M-FIAD-EARLY-READ-IGNORED', 'M-FIAD-EARLY-READ-SAME-FILE')
	public function testEarlyReadReturnedFromSubclassInOtherFileRefused(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: crossingSuper('') },
			{ file: 'D.hx', source: 'class D extends C { function h():Array<Int> return _a; }' }
		];
		Assert.equals(1, crossingCount(crossingSuper('')), 'the field\'s own file alone admits the move');
		Assert.equals(0, scopedViolations(files).length);
	}

	/** A same-named member another type declares is a different binding and does not block the move. */
	@:pin('control')
	@:killer('M-FIAD-DENOTES-ALL')
	public function testSameNamedFieldOfAnotherTypeDoesNotBlock(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: crossingSuper('function g():Int return _a.length;') },
			{ file: 'E.hx', source: 'class E { var _a:Array<Int>; function h():Bool return _a == null; }' }
		];
		Assert.equals(1, scopedViolations(files).length);
	}

	/** `this._a` in an unrelated type of the SAME file denotes that type's own member. */
	@:pin('control')
	@:killer('M-FIAD-DENOTES-ALL')
	public function testThisReadOfAnotherTypeInSameFileDoesNotBlock(): Void {
		final src: String = crossingSuper('') + ' class E { private var _a:Array<Int>; function g():Bool return this._a == null; }';
		Assert.equals(1, crossingCount(src));
	}

	/** A call's right-hand side runs ahead of the base constructor. */
	@:pin('control')
	@:killer('M-FIAD-INERT-ADMITS-ALL')
	public function testNewInitAfterSuperNotMoved(): Void {
		Assert.equals(0, crossingCount(crossingDynamic('new Foo()', '')));
	}

	@:pin('control')
	@:killer('M-FIAD-INERT-ADMITS-ALL')
	public function testStaticCallInitAfterSuperNotMoved(): Void {
		Assert.equals(0, crossingCount(crossingDynamic('Foo.make()', '')));
	}

	/** A collection is inert only when every element is: a foreign static read runs early too. */
	@:pin('control')
	@:killer('M-FIAD-INERT-ADMITS-ALL', 'M-FIAD-INERT-ELEMENT-ADMITS-ALL')
	public function testCollectionOfForeignReadAfterSuperNotMoved(): Void {
		Assert.equals(0, crossingCount(crossingDynamic('[Foo.x]', '')));
	}

	/** A `null` String answers `length` and `indexOf` on hxcpp instead of faulting, so an early read works. */
	@:pin('control')
	@:killer('M-FIAD-INERT-ADMITS-ALL', 'M-FIAD-CROSSING-ADMITS-SCALARS')
	public function testStringInitAfterSuperNotMoved(): Void {
		Assert.equals(0, crossingCount(crossingDynamic('\'abc\'', 'function g():Int return _a.length;')));
	}

	/** A scalar has no member access to fault on at all. */
	@:pin('control')
	@:killer('M-FIAD-INERT-ADMITS-ALL', 'M-FIAD-CROSSING-ADMITS-SCALARS')
	public function testScalarInitAfterSuperNotMoved(): Void {
		Assert.equals(0, crossingCount(crossingDynamic('5', '')));
	}

	/** An abstract's `@:from` would turn the literal into a call, and its methods may take a `null` receiver. */
	@:pin('control')
	@:killer('M-FIAD-ANY-DECLARED-TYPE')
	public function testNonCoreDeclaredTypeNotMoved(): Void {
		final src: String = 'class C extends B { private var _a:Tags; public function new() { super(); _a = []; } }';
		Assert.equals(0, crossingCount(src));
	}

	/**
	 * A core name the file SHADOWS names a user type — an abstract whose `@:from` can run code — so the
	 * type gate's "core array / map" reading does not hold. Imported, or reached by a wildcard.
	 */
	@:pin('control')
	@:killer('M-FIAD-SHADOW-IGNORED')
	public function testImportedUserMapShadowingTheCoreNameNotMoved(): Void {
		final userMap: { file: String, source: String } = {
			file: 'pkg/Map.hx',
			source: 'package pkg;\nabstract Map(Array<Int>) { @:from static function of(a:Array<Int>):Map return cast a; }'
		};
		final body: String = 'class C extends B { private var _m:Map; public function new() { super(); _m = [7]; } }';
		Assert.equals(1, scopedViolations([{ file: 'C.hx', source: body }, userMap]).length, 'unshadowed, the core Map crosses');
		Assert.equals(0, scopedViolations([{ file: 'C.hx', source: 'import pkg.Map;\n$body' }, userMap]).length, 'imported');
		Assert.equals(0, scopedViolations([{ file: 'C.hx', source: 'import pkg.*;\n$body' }, userMap]).length, 'a wildcard');
	}

	/** A same-package sibling module declaring the core name shadows it without any import. */
	@:pin('control')
	@:killer('M-FIAD-SHADOW-IGNORED')
	public function testSamePackageSiblingShadowingTheCoreNameNotMoved(): Void {
		final c: { file: String, source: String } = {
			file: 'p/C.hx',
			source: 'package p;\nclass C extends B { private var _a:Array<Int>; public function new() { super(); _a = []; } }'
		};
		Assert.equals(1, scopedViolations([c]).length, 'no sibling, the core Array crosses');
		final sibling: { file: String, source: String } = { file: 'p/Array.hx', source: 'package p;\nabstract Array<T>(Dynamic) {}' };
		Assert.equals(0, scopedViolations([c, sibling]).length);
	}

	/** Code outside the project may read a public field — or one of a `@:publicFields` type — early. */
	@:pin('control')
	@:killer('M-FIAD-PUBLIC-ADMITTED')
	public function testPublicFieldNotMoved(): Void {
		Assert.equals(0, crossingCount('class C extends B { public var _a:Array<Int>; public function new() { super(); _a = []; } }'));
		Assert.equals(0, crossingCount('@:publicFields class C extends B { var _a:Array<Int>; function new() { super(); _a = []; } }'));
	}

	/**
	 * A second writer could be what the base constructor reaches, and its write would outlive the deleted
	 * init. After a top-level `super()` the chain walk already refuses a non-sole init; an init BEFORE the
	 * call up heads an unbroken chain, so there only the crossing path's own sole-write conjunct refuses.
	 */
	@:pin('control')
	@:killer('M-FIAD-CROSS-SUPER-NO-SOLE')
	public function testSecondWriterAcrossSuperNotMoved(): Void {
		Assert.equals(0, crossingCount(crossingSuper('public function dispose():Void { _a = null; }')));
		final before: String = 'class C extends B { var _a:Array<Int>; public function new() { _a = []; super(); } '
			+ 'public function dispose():Void { _a = null; } }';
		Assert.equals(0, crossingCount(before));
	}

	/**
	 * The chain path never crosses `super(...)`: a crossing init the rule refused must not read as a
	 * co-mover in `fix`, or the accepted init after it is skipped for a prefix that never moves.
	 */
	@:pin('control')
	@:killer('M-FIAD-CROSS-SUPER-CHAIN')
	public function testRefusedCrossingInitDoesNotHoldBackTheFix(): Void {
		final src: String = 'class C extends B {\n\tvar _a:Array<Int>;\n\tvar _b:Array<Int>;\n\tpublic function new() {\n\t\t_a = [];\n'
			+ '\t\tsuper();\n\t\t_b = [];\n\t}\n\tfunction g():Bool return _a == null;\n}';
		final vs: Array<Violation> = scopedViolations([{ file: 'C.hx', source: src }]);
		Assert.equals(1, vs.length);
		Assert.isTrue(scopedFixedSource(src).indexOf('var _b:Array<Int> = [];') >= 0);
	}

	/** A subclass `C` whose constructor calls up and THEN assigns `_a = []`, followed by `members`. */
	private function crossingSuper(members: String): String {
		return 'class C extends B { private var _a:Array<Int>; public function new() { super(); _a = []; } $members }';
	}

	/** A subclass `C` with a `Dynamic` field `_a` its constructor assigns `rhs` AFTER calling up, followed by `members`. */
	private function crossingDynamic(rhs: String, members: String): String {
		return 'class C extends B { private var _a:Dynamic; public function new() { super(); _a = $rhs; } $members }';
	}

	/** The finding count of `src` as `C.hx` under a declared project scope. */
	private function crossingCount(src: String): Int {
		return scopedViolations([{ file: 'C.hx', source: src }]).length;
	}

	/** The rule's findings over `files` with those files as the report AND the declared `resolutionRoots`. */
	private function scopedViolations(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new FieldInitAtDeclaration().run(files, scopedPlugin(files));
	}

	/** `src` as `C.hx` after the rule's fix, under a declared project scope. */
	private function scopedFixedSource(src: String): String {
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final plugin: CachingGrammarPlugin = scopedPlugin(files);
		final check: FieldInitAtDeclaration = new FieldInitAtDeclaration();
		return CheckFixture.applyEdits(src, check.fix(src, check.run(files, plugin), plugin));
	}

	/**
	 * A plugin hosting a DECLARED scope whose report is the whole project — the shape a whole-project
	 * lint hands the rule: the roots half excludes the report, so it is empty — with `rootsMatched`
	 * saying whether the project's `resolutionRoots` matched any `.hx` at all.
	 */
	private function scopedPlugin(files: Array<{ file: String, source: String }>, rootsMatched: Bool = true): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {
				report: files,
				projectRoots: [],
				library: new LibrarySources([]),
				rootsMatched: rootsMatched
			}
		});
		return plugin;
	}

	private function violations(src: String): Array<Violation> {
		return new FieldInitAtDeclaration().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
