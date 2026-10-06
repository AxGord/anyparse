package unit.check;

import anyparse.check.Check;
import anyparse.check.HaxeSpawn;
import anyparse.check.ImportBlockOrder;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.ImportOrder;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeRefPrinter;
import anyparse.runtime.Span;
import sys.io.File;
import unit.QueryTestHelpers;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `import-order` check: a contiguous block of plain imports carrying NO recognisable order
 * is reported, and the autofix permutes its whole lines back into order. Covers the block
 * boundaries (blank line, `using` / wildcard / alias, block comment), the `order` option, the
 * refusals that keep a load-bearing order intact, and the comment pinning.
 *
 * Plus the `using` WEDGE and its `usingAfterImports` opt-out: import runs a `using` group is
 * wedged between are ONE block, merged and sorted with the group moved below them — and the four
 * refusals that keep a merge from rebinding a name or misattributing a comment. And the WILDCARD members
 * `WildcardImportGate` admits into a block: each measured precedence pair, each refusal of what the index cannot
 * enumerate, the insert seat reading the same runs, and one end-to-end compile and run of a reordered block.
 */
class ImportBlockOrderCheckTest extends Test {

	/** The reported incident's shape: an ordered block with one import appended past its end. */
	private static inline final APPENDED: String = 'package app;\n\nimport app.base.Host;\nimport pkg.mid.events.Alpha;\n'
		+ 'import pkg.mid.SetBeta;\nimport util.Valid;\nimport app.deep.Mod.Widget;\n\nclass C {}\n';

	/**
	 * The WEDGE incident, verbatim from `TM/src/tests/unit/FileSystemSyncTest.hx`: a `#if`-guarded
	 * `#error` header, a wildcard import, a sorted run, a `using`, then a SECOND sorted run.
	 */
	private static inline final WEDGE: String = 'package tests.unit;\n\n#if !UNIT_TESTS\n#error "unit only"\n#end\n'
		+ 'import tink.unit.Assert.*;\nimport fs.DrillsFolderWatcher;\nimport fs.FSUtil;\nimport haxe.io.Path;\n\n'
		+ 'using tink.CoreApi;\n\nimport fs.FolderWatcher;\nimport haxe.Exception;\n\nclass C {}\n';

	/** The `usingAfterImports` opt-out — the pre-wedge reading, where a `using` is an immovable run boundary. */
	private static inline final KEEP_USING: String = '{"rules":{"import-order":{"usingAfterImports":false}}}';

	/**
	 * The library the WILDCARD fixtures resolve against. A wildcard joins a run only on evidence, so
	 * every module a fixture's wildcard or explicit run member names is here — `mystery.*` is
	 * deliberately absent, which is what makes the unknown-module refusals testable. `p.C` holds a
	 * static `f`, a static `Foo` named like the TYPE `q.Foo`, and an INSTANCE `g`; `q.D` the statics
	 * `f`, `g` and `Red`; `p.Col` the enum constructor `Red`; `v.Fns` a MODULE-LEVEL field `f`; and
	 * `s.Sub` / `s.Built` / `s.Alias` the three types whose static set the gate refuses to read.
	 */
	private static final WILD_LIBS: Array<{ file: String, source: String }> = [
		{ file: 'a/Alpha.hx', source: 'package a;\n\nclass Alpha {}\n' },
		{ file: 'b/Bee.hx', source: 'package b;\n\nclass Bee {}\n' },
		{ file: 'z/Zeta.hx', source: 'package z;\n\nclass Zeta {}\n' },
		{ file: 'fs/FSUtil.hx', source: 'package fs;\n\nclass FSUtil {}\n' },
		{ file: 'haxe/io/Path.hx', source: 'package haxe.io;\n\nclass Path {}\n' },
		{
			file: 'tink/unit/Assert.hx',
			source: 'package tink.unit;\n\nclass Assert {\n\tpublic static function assert(b: Bool): Bool {\n\t\treturn b;\n\t}\n}\n'
		},
		{ file: 'tink/testrunner/Assertion.hx', source: 'package tink.testrunner;\n\nclass Assertion {}\n' },
		{ file: 'p/T.hx', source: 'package p;\n\nclass T {}\n' },
		{ file: 'q/T.hx', source: 'package q;\n\nclass T {}\n' },
		{ file: 'q/U.hx', source: 'package q;\n\nclass U {}\n' },
		{ file: 'q/Foo.hx', source: 'package q;\n\nclass Foo {}\n' },
		{
			file: 'p/C.hx',
			source: 'package p;\n\nclass C {\n\tpublic static var f: Int = 1;\n\tpublic static var Foo: Int = 2;\n'
				+ '\tpublic var g: Int = 3;\n}\n'
		},
		{ file: 'p/Col.hx', source: 'package p;\n\nenum Col {\n\tRed;\n}\n' },
		{
			file: 'q/D.hx',
			source: 'package q;\n\nclass D {\n\tpublic static var f: Int = 1;\n\tpublic static var g: Int = 2;\n'
				+ '\tpublic static var Red: Int = 3;\n}\n'
		},
		{ file: 'r/E.hx', source: 'package r;\n\nclass E {\n\tpublic static var f: Int = 1;\n}\n' },
		{ file: 'r/G.hx', source: 'package r;\n\nclass G {\n\tpublic static var g: Int = 1;\n}\n' },
		{ file: 'v/Fns.hx', source: 'package v;\n\nfunction f(): Void {}\n\nclass Fns {}\n' },
		{ file: 'v/Plain.hx', source: 'package v;\n\nclass Plain {}\n' },
		{ file: 's/Base.hx', source: 'package s;\n\nclass Base {}\n' },
		{ file: 's/Sub.hx', source: 'package s;\n\nclass Sub extends Base {\n\tpublic static var h: Int = 1;\n}\n' },
		{ file: 's/Built.hx', source: 'package s;\n\n@:build(s.Macro.build())\nclass Built {\n\tpublic static var h: Int = 1;\n}\n' },
		{ file: 's/Alias.hx', source: 'package s;\n\ntypedef Alias = Built;\n' }
	];

	/**
	 * The library the BINDING fixtures resolve against — every module a fixture names is here except
	 * `mystery.*`, so each line binds what its source declares. `v.Fns` / `v.Fns2` each declare a
	 * MODULE-LEVEL `modfn`, `v.Reds` a module-level `Red` and `w.Other` a module-level `other`; `p.Col` /
	 * `p.Col2` share the constructor `Red`, which `p.M`'s SECONDARY enum and `p.Pm`'s PRIVATE one declare
	 * too; `p.Ab3` holds the value `Blue` and a STATIC field `Red`; `p.TAlias` / `p.TNull` alias `p.Col2` (the
	 * second through `Null<T>`, stubbed at the root as the std declares it); `p.Built` carries a build macro.
	 */
	private static final BIND_LIBS: Array<{ file: String, source: String }> = [
		{ file: 'a/Alpha.hx', source: 'package a;\n\nclass Alpha {}\n' },
		{ file: 'z/Zeta.hx', source: 'package z;\n\nclass Zeta {}\n' },
		{ file: 'v/Fns.hx', source: 'package v;\n\nfunction modfn(): Void {}\n\nclass Fns {}\n' },
		{ file: 'v/Fns2.hx', source: 'package v;\n\nfunction modfn(): Void {}\n\nclass Fns2 {}\n' },
		{ file: 'v/Reds.hx', source: 'package v;\n\nfunction Red(): Void {}\n\nclass Reds {}\n' },
		{ file: 'w/Other.hx', source: 'package w;\n\nfunction other(): Void {}\n\nclass Other {}\n' },
		{ file: 'p/Col.hx', source: 'package p;\n\nenum Col {\n\tRed;\n\tGreen;\n}\n' },
		{ file: 'p/Col2.hx', source: 'package p;\n\nenum Col2 {\n\tRed;\n\tBlue;\n}\n' },
		{ file: 'p/M.hx', source: 'package p;\n\nclass M {}\n\nenum MSub {\n\tRed;\n\tPink;\n}\n' },
		{ file: 'p/Pm.hx', source: 'package p;\n\nclass Pm {}\n\nprivate enum PE {\n\tRed;\n}\n' },
		{
			file: 'p/Ab3.hx',
			source: 'package p;\n\nenum abstract Ab3(String) {\n\tvar Blue = \'b\';\n\n\tpublic static final Red: String = \'r\';\n}\n'
		},
		{ file: 'p/TAlias.hx', source: 'package p;\n\ntypedef TAlias = Col2;\n' },
		{ file: 'p/TNull.hx', source: 'package p;\n\ntypedef TNull = Null<Col2>;\n' },
		{ file: 'Null.hx', source: '@:coreType abstract Null<T> {}\n' },
		{ file: 'p/Built.hx', source: 'package p;\n\n@:build(p.Macro.build())\nenum Built {\n\tTeal;\n}\n' }
	];

	public function testAppendedImportFlagged(): Void {
		final vs: Array<Violation> = violations(APPENDED);
		Assert.equals(1, vs.length);
		Assert.equals('import-order', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("'app.deep.Mod.Widget'"), 'names the out-of-place import: ${vs[0].message}');
	}

	public function testAppendedImportIsMovedIntoPlace(): Void {
		Assert.equals(
			'package app;\n\nimport app.base.Host;\nimport app.deep.Mod.Widget;\nimport pkg.mid.events.Alpha;\n'
			+ 'import pkg.mid.SetBeta;\nimport util.Valid;\n\nclass C {}\n',
			fixed(APPENDED)
		);
	}

	public function testFixOutputSurvivesTheWriter(): Void {
		switch CanonicalEdit.canonicalize(APPENDED, edits(APPENDED), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('import app.base.Host;\nimport app.deep.Mod.Widget;\nimport pkg.mid.events.Alpha;') >= 0, text);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	public function testAsciiOrderedBlockNotFlagged(): Void {
		Assert.equals(0, violations('package app;\n\nimport a.Alpha;\nimport m.Middle;\nimport z.Zeta;\n\nclass C {}\n').length);
	}

	public function testCaseFoldedBlockNotFlagged(): Void {
		// `pkg.mid.events.Alpha` before `pkg.mid.SetBeta` is the order an IDE writes and a human
		// reads. Only codepoint order disagrees, so the default `any` must accept it.
		Assert.equals(0, violations('package app;\n\nimport pkg.mid.events.Alpha;\nimport pkg.mid.SetBeta;\n\nclass C {}\n').length);
	}

	public function testSingleImportNeverFlagged(): Void {
		Assert.equals(0, violations('package app;\n\nimport z.Zeta;\n\nclass C {}\n').length);
	}

	// --- the `order` option ---

	public function testAsciiOptionFlagsACaseFoldedBlock(): Void {
		final src: String = 'package app;\n\nimport pkg.mid.events.Alpha;\nimport pkg.mid.SetBeta;\n\nclass C {}\n';
		final config: String = '{"rules":{"import-order":{"order":"ascii"}}}';
		Assert.equals(1, violations(src, config).length);
		Assert.equals('package app;\n\nimport pkg.mid.SetBeta;\nimport pkg.mid.events.Alpha;\n\nclass C {}\n', fixed(src, config));
	}

	public function testCaseInsensitiveOptionFlagsAnAsciiBlock(): Void {
		final src: String = 'package app;\n\nimport a.Zeta;\nimport a.alpha.Beta;\n\nclass C {}\n';
		final config: String = '{"rules":{"import-order":{"order":"case-insensitive"}}}';
		Assert.equals(1, violations(src, config).length);
		Assert.equals('package app;\n\nimport a.alpha.Beta;\nimport a.Zeta;\n\nclass C {}\n', fixed(src, config));
	}

	// --- block boundaries ---

	public function testBlankLineGroupsAreOrderedIndependently(): Void {
		// Each group is ordered on its own; the concatenation is not, and must not be reported —
		// a project's visual grouping is not disorder.
		Assert.equals(
			0, violations('package app;\n\nimport z.Alpha;\nimport z.Zeta;\n\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n').length
		);
	}

	public function testGroupsAreFixedWithoutBeingMerged(): Void {
		final src: String = 'package app;\n\nimport z.Zeta;\nimport z.Alpha;\n\nimport a.Beta;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(2, violations(src).length);
		Assert.equals('package app;\n\nimport z.Alpha;\nimport z.Zeta;\n\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n', fixed(src));
	}

	public function testUsingSplitsTheBlockAndStaysPutUnderTheOptOut(): Void {
		// `"usingAfterImports": false` restores the pre-wedge reading: a `using` is a run boundary
		// that never moves, and the two import runs around it are ordered separately.
		final src: String =
			'package app;\n\nimport z.Zeta;\nimport z.Alpha;\nusing ext.One;\nimport a.Beta;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(2, violations(src, KEEP_USING).length);
		Assert.equals(
			'package app;\n\nimport z.Alpha;\nimport z.Zeta;\nusing ext.One;\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n',
			fixed(src, KEEP_USING)
		);
	}

	@:pin('control') @:killer('M-WILDGATE-UNKNOWN-TYPE-JOINS')
	public function testWildcardSplitsTheBlock(): Void {
		Assert.equals(0, violations('package app;\n\nimport z.Zeta;\nimport other.*;\nimport a.Alpha;\n\nclass C {}\n').length);
	}

	public function testAliasSplitsTheBlock(): Void {
		Assert.equals(0, violations('package app;\n\nimport z.Zeta;\nimport other.Thing as T;\nimport a.Alpha;\n\nclass C {}\n').length);
	}

	// --- wildcard MEMBERS: a wildcard joins the block when its position decides nothing ---

	/**
	 * The incident, `TM/src/tests/unit/FolderWatcherTest.hx`'s header: a field wildcard written ABOVE
	 * the block it sorts into. `tink.unit.Assert` declares one static, which no other line binds, so
	 * the wildcard is a line like any other and the block is reported and sorted with it.
	 */
	@:pin('control') @:killer('M-WILDGATE-NEVER-JOINS', 'M-RUN-GATE-NO-INDEX', 'M-FIX-GATE-NO-INDEX')
	public function testAFieldWildcardWithFreeNamesJoinsTheBlock(): Void {
		final src: String = 'package tests.unit;\n\n#if !UNIT_TESTS\n#error "unit only"\n#end\nimport tink.unit.Assert.*;\n'
			+ 'import fs.FSUtil;\nimport haxe.io.Path;\nimport tink.testrunner.Assertion;\n\nusing tink.CoreApi;\n\nclass C {}\n';
		final vs: Array<Violation> = violations(src, null, WILD_LIBS);
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.isTrue(vs[0].message.contains("'fs.FSUtil'"), vs[0].message);
		final expected: String = 'package tests.unit;\n\n#if !UNIT_TESTS\n#error "unit only"\n#end\nimport fs.FSUtil;\n'
			+ 'import haxe.io.Path;\nimport tink.testrunner.Assertion;\nimport tink.unit.Assert.*;\n\n'
			+ 'using tink.CoreApi;\n\nclass C {}\n';
		Assert.equals(expected, fixed(src, null, WILD_LIBS));
		Assert.equals(0, violations(expected, null, WILD_LIBS).length, 'the fix converges in one pass');
	}

	@:pin('control') @:killer('M-WILDGATE-NEVER-JOINS')
	public function testAPackageWildcardJoinsTheBlock(): Void {
		final src: String = module('import z.Zeta;\nimport q.*;\nimport a.Alpha;\n');
		Assert.equals(1, violations(src, null, WILD_LIBS).length);
		Assert.equals(module('import a.Alpha;\nimport q.*;\nimport z.Zeta;\n'), fixed(src, null, WILD_LIBS));
	}

	/** `*` is below every letter and the dot, so a wildcard sorts after its own type and ahead of that type's fields. */
	public function testAWildcardSortsByItsFullText(): Void {
		final src: String = module('import p.C.*;\nimport p.C;\n');
		Assert.equals(1, violations(src, null, WILD_LIBS).length);
		Assert.equals(module('import p.C;\nimport p.C.*;\n'), fixed(src, null, WILD_LIBS));
	}

	/** An explicit import outranks a package wildcard in EITHER statement order, so a shared type name is no block. */
	public function testAnExplicitImportOfTheSameTypeNeverBlocksAPackageWildcard(): Void {
		final src: String = module('import z.Zeta;\nimport p.*;\nimport q.T;\n');
		Assert.equals(1, violations(src, null, WILD_LIBS).length);
		Assert.equals(module('import p.*;\nimport q.T;\nimport z.Zeta;\n'), fixed(src, null, WILD_LIBS));
	}

	/** A package wildcard binds no value, so even an explicit member the index cannot see never blocks it. */
	@:pin('control') @:killer('M-WILDGATE-PACKAGE-ASKS-EXPLICIT')
	public function testAnUnindexedExplicitImportNeverBlocksAPackageWildcard(): Void {
		Assert.equals(1, violations(module('import z.Zeta;\nimport q.*;\nimport mystery.Box;\n'), null, WILD_LIBS).length);
	}

	/** In expression position a VALUE outranks a TYPE of the same name in either order: `p.C`'s static `Foo` meets `q.Foo` nowhere. */
	public function testAStaticNamedLikeAnImportedTypeNeverBlocks(): Void {
		Assert.equals(1, violations(module('import z.Zeta;\nimport p.C.*;\nimport q.Foo;\n'), null, WILD_LIBS).length);
	}

	/** Only a STATIC is imported by a field wildcard: `p.C`'s instance `g` does not meet `q.D`'s static `g`. */
	@:pin('control') @:killer('M-WILDGATE-INSTANCE-BOUND')
	public function testAnInstanceMemberIsNoNameTheWildcardBinds(): Void {
		Assert.equals(1, violations(module('import z.Zeta;\nimport p.C.*;\nimport q.D.g;\n'), null, WILD_LIBS).length);
	}

	/** Two package wildcards binding one module name: the LAST wins, so their order is load-bearing and both stay boundaries. */
	@:pin('control') @:killer('M-WILDGATE-PACKAGE-NAMES-IGNORED')
	public function testTwoPackageWildcardsSharingAModuleNameStayBoundaries(): Void {
		Assert.equals(0, violations(module('import z.Zeta;\nimport q.*;\nimport p.*;\n'), null, WILD_LIBS).length);
	}

	/** A field wildcard and an explicit FIELD import of one name: the LAST wins. */
	@:pin('control') @:killer('M-BIND-FIELD-RANK-IGNORED', 'M-WILDGATE-FIELD-IMPORT-NO-NAME')
	public function testAFieldWildcardSharingAStaticWithAFieldImportStaysABoundary(): Void {
		Assert.equals(0, violations(module('import z.Zeta;\nimport p.C.*;\nimport q.D.f;\n'), null, WILD_LIBS).length);
	}

	/** Two field wildcards of one static name: the LAST wins — and `r.G`, sharing none with `p.C`, joins. */
	@:pin('control') @:killer('M-BIND-FIELD-RANK-IGNORED')
	public function testTwoFieldWildcardsSharingAStaticStayBoundaries(): Void {
		Assert.equals(0, violations(module('import z.Zeta;\nimport p.C.*;\nimport r.E.*;\n'), null, WILD_LIBS).length);
		final free: String = module('import z.Zeta;\nimport p.C.*;\nimport r.G.*;\n');
		Assert.equals(1, violations(free, null, WILD_LIBS).length);
		Assert.equals(
			module('import p.C.*;\nimport r.G.*;\nimport z.Zeta;\n'), fixed(free, null, WILD_LIBS),
			'two wildcard members bind no shared name'
		);
	}

	/** A module import brings the module's module-level FIELDS in, and against a field wildcard the LAST wins. */
	@:pin('control') @:killer('M-BIND-FIELD-RANK-IGNORED', 'M-WILDGATE-MODULE-FIELDS-NONE')
	public function testAModuleLevelFieldOfAnExplicitImportBlocksAFieldWildcard(): Void {
		Assert.equals(0, violations(module('import z.Zeta;\nimport p.C.*;\nimport v.Fns;\n'), null, WILD_LIBS).length);
		Assert.equals(1, violations(module('import z.Zeta;\nimport p.C.*;\nimport v.Plain;\n'), null, WILD_LIBS).length);
	}

	/** An enum's wildcard binds its constructors, which a static of the same name meets. */
	@:pin('control') @:killer('M-WILDGATE-ENUM-STATICS-ONLY')
	public function testAnEnumConstructorIsANameTheWildcardBinds(): Void {
		Assert.equals(0, violations(module('import z.Zeta;\nimport p.Col.*;\nimport q.D.Red;\n'), null, WILD_LIBS).length);
	}

	// --- wildcard refusals: what the index cannot enumerate stays a boundary ---

	/** An explicit member the index cannot see may bring module-level fields of any name in. */
	@:pin('control') @:killer('M-WILDGATE-EXPLICIT-UNKNOWN-FREE')
	public function testAnUnindexedExplicitMemberKeepsAFieldWildcardABoundary(): Void {
		Assert.equals(
			0, violations(module('import tink.unit.Assert.*;\nimport fs.FSUtil;\nimport mystery.Box;\n'), null, WILD_LIBS).length
		);
	}

	@:pin('control') @:killer('M-WILDGATE-UNKNOWN-TYPE-JOINS')
	public function testAWildcardOfAnUnindexedTypeStaysABoundary(): Void {
		Assert.equals(0, violations(module('import z.Zeta;\nimport mystery.Thing.*;\nimport a.Alpha;\n'), null, WILD_LIBS).length);
	}

	/** A supertype may carry an `@:autoBuild` that adds statics no index lists. */
	@:pin('control') @:killer('M-WILDGATE-SUPERTYPE-READ')
	public function testAWildcardOfASubclassStaysABoundary(): Void {
		Assert.equals(0, violations(module('import z.Zeta;\nimport s.Sub.*;\nimport a.Alpha;\n'), null, WILD_LIBS).length);
	}

	@:pin('control') @:killer('M-WILDGATE-BUILD-READ')
	public function testAWildcardOfABuiltTypeStaysABoundary(): Void {
		Assert.equals(0, violations(module('import z.Zeta;\nimport s.Built.*;\nimport a.Alpha;\n'), null, WILD_LIBS).length);
	}

	/** A typedef's wildcard reads the statics of whatever it aliases. */
	@:pin('control') @:killer('M-WILDGATE-TYPEDEF-READ')
	public function testAWildcardOfATypedefStaysABoundary(): Void {
		Assert.equals(0, violations(module('import z.Zeta;\nimport s.Alias.*;\nimport a.Alpha;\n'), null, WILD_LIBS).length);
	}

	/**
	 * A wildcard member the merge would otherwise lift ABOVE a wedged `using` stays BELOW the group:
	 * what a `using` binds against a wildcard was never measured, while its order against the imports
	 * that do move up is free (the gate admitted it into their run). One ABOVE the `using` sorts into
	 * the block like any line.
	 */
	@:pin('control') @:killer('M-WEDGE-WILDCARD-LIFTED')
	public function testAWildcardBelowAWedgedUsingStaysBelowIt(): Void {
		final below: String = module('import a.Alpha;\nimport z.Zeta;\nusing ext.One;\nimport b.Bee;\nimport q.*;\n');
		Assert.equals(1, violations(below, null, WILD_LIBS).length);
		final merged: String = module('import a.Alpha;\nimport b.Bee;\nimport z.Zeta;\n\nusing ext.One;\nimport q.*;\n');
		Assert.equals(merged, fixed(below, null, WILD_LIBS));
		Assert.equals(0, violations(merged, null, WILD_LIBS).length, 'the fix converges in one pass');
		final above: String = module('import q.*;\nimport z.Zeta;\nusing ext.One;\nimport a.Alpha;\n');
		Assert.equals(module('import a.Alpha;\nimport q.*;\nimport z.Zeta;\n\nusing ext.One;\n'), fixed(above, null, WILD_LIBS));
	}

	/** A wildcard BETWEEN two wedged `using` groups could stay below only by crossing the later one, so the merge is refused. */
	@:pin('control') @:killer('M-WEDGE-WILDCARD-CROSSES-USING')
	public function testAWildcardBetweenTwoWedgedUsingsRefusesTheMerge(): Void {
		final src: String = module('import z.Zeta;\nusing ext.One;\nimport b.Bee;\nimport q.*;\nusing ext.Two;\nimport a.Alpha;\n');
		Assert.equals(1, violations(src, null, WILD_LIBS).length);
		Assert.equals(0, edits(src, null, WILD_LIBS).length);
	}

	/** The insert seat reads the same runs: a fresh import lands BEFORE the member wildcard it sorts ahead of. */
	@:pin('control') @:killer('M-SEAT-WILDCARD-BLIND')
	public function testTheInsertSeatSortsAroundAMemberWildcard(): Void {
		final src: String = module('import a.Alpha;\nimport q.*;\nimport z.Zeta;\n');
		final plugin: CachingGrammarPlugin = QueryTestHelpers.projectPlugin([{ file: 'app/C.hx', source: src }], WILD_LIBS);
		final anchor: ImportAnchor = ImportOrder.insertionFor(src, plugin.parseFile(src), plugin, 'b.Bee');
		Assert.equals(
			module('import a.Alpha;\nimport b.Bee;\nimport q.*;\nimport z.Zeta;\n'),
			'${src.substring(0, anchor.offset) + anchor.lead}import b.Bee;\n${anchor.trail}${src.substring(anchor.offset)}'
		);
	}

	/**
	 * End to end: a block holding a package and a field wildcard is reordered and the program prints
	 * the same line, compiled and run on `--interp`; the refused pair is load-bearing — swapping the
	 * two field wildcards that share `hello` by hand changes what it prints.
	 */
	@:pin('control') @:killer('M-WILDGATE-NEVER-JOINS', 'M-BIND-FIELD-RANK-IGNORED')
	public function testAReorderedWildcardBlockRunsTheSame(): Void {
		#if (sys || nodejs)
		final main: String = 'import z.Zed;\nimport r.*;\nimport q.T;\nimport p.Tools.*;\nimport a.Alpha;\n\n'
			+ 'import s.Two.*;\nimport b.Bee;\nimport s.One.*;\n\nclass Main {\n\tstatic function main() {\n'
			+ '\t\tSys.println(T.id() + " " + greet() + " " + Zed.id() + " " + Alpha.id() + " " + hello() + " " + Bee.id());\n\t}\n}\n';
		final libs: Array<{ name: String, source: String }> = [
			{ name: 'z/Zed.hx', source: idClass('z', 'Zed') },
			{ name: 'r/T.hx', source: idClass('r', 'T') },
			{ name: 'q/T.hx', source: idClass('q', 'T') },
			{ name: 'a/Alpha.hx', source: idClass('a', 'Alpha') },
			{ name: 'b/Bee.hx', source: idClass('b', 'Bee') },
			{ name: 'p/Tools.hx', source: staticClass('p', 'Tools', 'greet') },
			{ name: 's/One.hx', source: staticClass('s', 'One', 'hello') },
			{ name: 's/Two.hx', source: staticClass('s', 'Two', 'hello') }
		];
		final dir: String = CliFixture.writeTree('wildorder', libs.concat([{ name: 'Main.hx', source: main }]));
		final before: HaxeRun = runMain(dir);
		if (before.status != 0) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped: ${before.err}${before.failure}');
			return;
		}
		final files: Array<{ file: String, source: String }> = [for (f in libs) { file: '$dir/${f.name}', source: f.source }];
		files.push({ file: '$dir/Main.hx', source: main });
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ImportBlockOrder = configured(null);
		final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == '$dir/Main.hx');
		final reordered: String = CanonicalEdit.applyEdits(main, check.fix(main, own, plugin, SymbolIndex.build(files, plugin)));
		Assert.isTrue(
			reordered.startsWith('import a.Alpha;\nimport p.Tools.*;\nimport q.T;\nimport r.*;\nimport z.Zed;\n\nimport s.Two.*;\n'),
			reordered
		);
		File.saveContent('$dir/Main.hx', reordered);
		final after: HaxeRun = runMain(dir);
		File.saveContent(
			'$dir/Main.hx',
			main.replace('import s.Two.*;\nimport b.Bee;\nimport s.One.*;', 'import s.One.*;\nimport b.Bee;\nimport s.Two.*;')
		);
		final swapped: HaxeRun = runMain(dir);
		CliFixture.removeDir(dir);
		Assert.equals('q.T p.Tools.greet z.Zed a.Alpha s.One.hello b.Bee', before.out.trim(), before.err);
		Assert.equals(before.out, after.out, after.err);
		Assert.notEquals(before.out, swapped.out, 'the refused pair decides what `hello` means: ${swapped.err}');
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- plain pairs: what a module import binds besides its types (`ImportBindings`) ---

	/**
	 * Two module imports each declaring a MODULE-LEVEL `modfn`: Haxe calls the LAST one's, so the block is
	 * reported but not sorted — a name only the module's source spells, which the type names never showed.
	 * A block whose module-level fields are disjoint still sorts.
	 */
	@:pin('control') @:killer('M-BIND-FIELD-RANK-IGNORED', 'M-WILDGATE-MODULE-FIELDS-NONE')
	public function testTwoModulesDeclaringOneModuleLevelFieldAreNotReordered(): Void {
		final src: String = module('import v.Fns2;\nimport v.Fns;\n');
		final vs: Array<Violation> = violations(src, null, BIND_LIBS);
		Assert.equals(1, vs.length);
		Assert.equals(0, edits(src, null, BIND_LIBS).length, 'the reorder would change which `modfn` a bare call runs');
		final free: String = module('import w.Other;\nimport v.Fns2;\n');
		Assert.equals(module('import v.Fns2;\nimport w.Other;\n'), fixed(free, null, BIND_LIBS));
	}

	/**
	 * End to end: the refused block compiled and run on `--interp` prints the module-level field of the
	 * LAST import, and the order the rule would have sorted it into prints the other one — so the
	 * refusal is what keeps the program meaning what it says.
	 */
	@:pin('control') @:killer('M-BIND-FIELD-RANK-IGNORED', 'M-WILDGATE-MODULE-FIELDS-NONE')
	public function testTwoModulesBindingOneModuleLevelFieldKeepTheirOrderWhenRun(): Void {
		#if (sys || nodejs)
		final main: String =
			'import v.Fns2;\nimport v.Fns;\n\nclass Main {\n\tstatic function main() {\n\t\tSys.println(modfn());\n\t}\n}\n';
		final libs: Array<{ name: String, source: String }> = [
			{ name: 'v/Fns.hx', source: moduleField('v', 'Fns', 'modfn') },
			{ name: 'v/Fns2.hx', source: moduleField('v', 'Fns2', 'modfn') }
		];
		final dir: String = CliFixture.writeTree('modfieldorder', libs.concat([{ name: 'Main.hx', source: main }]));
		final before: HaxeRun = runMain(dir);
		if (before.status != 0) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped: ${before.err}${before.failure}');
			return;
		}
		final files: Array<{ file: String, source: String }> = [for (f in libs) { file: '$dir/${f.name}', source: f.source }];
		files.push({ file: '$dir/Main.hx', source: main });
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ImportBlockOrder = configured(null);
		final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == '$dir/Main.hx');
		final sortedEdits: Array<{ span: Span, text: String }> = check.fix(main, own, plugin, SymbolIndex.build(files, plugin));
		File.saveContent('$dir/Main.hx', main.replace('import v.Fns2;\nimport v.Fns;', 'import v.Fns;\nimport v.Fns2;'));
		final sorted: HaxeRun = runMain(dir);
		CliFixture.removeDir(dir);
		Assert.equals('v.Fns.modfn', before.out.trim(), before.err);
		Assert.equals('v.Fns2.modfn', sorted.out.trim(), 'the sorted order runs the other `modfn`: ${sorted.err}');
		Assert.equals(1, own.length);
		Assert.equals(0, sortedEdits.length, 'the reorder is refused');
		if (own.length == 1) Assert.isTrue((own[0].declineReason ?? '').contains('"modfn"'), own[0].declineReason);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two TYPE imports sharing a constructor: the LAST binds it (an enum's and a SECONDARY
	 * enum's alike — `import p.M;` binds `MSub.Red`), so neither block is sorted.
	 */
	@:pin('control') @:killer('M-BIND-TYPE-VALUE-RANK-IGNORED', 'M-BIND-TYPE-VALUES-NONE')
	public function testTwoTypeImportsSharingAConstructorAreNotReordered(): Void {
		Assert.equals(0, edits(module('import p.Col2;\nimport p.Col;\n'), null, BIND_LIBS).length);
		Assert.equals(0, edits(module('import p.M;\nimport p.Col;\n'), null, BIND_LIBS).length, 'a secondary enum binds its constructors');
	}

	/** A constructor outranks a module-level field of the same name in EITHER order, so the two never block. */
	@:pin('control') @:killer('M-BIND-RANKS-MERGED')
	public function testAConstructorAndAModuleLevelFieldOfOneNameNeverBlock(): Void {
		Assert.equals(module('import p.Col;\nimport v.Reds;\n'), fixed(module('import v.Reds;\nimport p.Col;\n'), null, BIND_LIBS));
	}

	/** A PRIVATE enum's constructors are not bound by its module's import, so they block nothing. */
	@:pin('control') @:killer('M-BIND-PRIVATE-TYPE-VALUES')
	public function testAPrivateEnumConstructorIsNotBound(): Void {
		Assert.equals(module('import p.Col;\nimport p.Pm;\n'), fixed(module('import p.Pm;\nimport p.Col;\n'), null, BIND_LIBS));
	}

	/** An enum abstract binds its VALUES, not its statics: `Ab3`'s static `Red` meets `Col.Red` nowhere. */
	@:pin('control') @:killer('M-BIND-ABSTRACT-STATICS')
	public function testAnEnumAbstractStaticIsNotAValueItsImportBinds(): Void {
		Assert.equals(module('import p.Ab3;\nimport p.Col;\n'), fixed(module('import p.Col;\nimport p.Ab3;\n'), null, BIND_LIBS));
	}

	/**
	 * A typedef binds the constructors of what it aliases (through `Null<T>` too), so an
	 * alias of `Col2` meets `Col` on `Red`; one whose target the compiler unwraps is unlisted.
	 */
	@:pin('control') @:killer('M-BIND-TYPEDEF-NOT-FOLLOWED', 'M-BIND-NULL-WRAPPER-FOLLOWED')
	public function testATypedefBindsTheConstructorsOfWhatItAliases(): Void {
		Assert.equals(0, edits(module('import p.TAlias;\nimport p.Col;\n'), null, BIND_LIBS).length);
		Assert.equals(0, edits(module('import p.TNull;\nimport p.Col;\n'), null, BIND_LIBS).length);
	}

	/** An enum carrying a build macro may hold constructors no source spells, so it refuses beside any other. */
	@:pin('control') @:killer('M-BIND-ENUM-BUILD-LISTED')
	public function testAnEnumCarryingABuildMacroIsUnlisted(): Void {
		Assert.equals(0, edits(module('import p.Col2;\nimport p.Built;\n'), null, BIND_LIBS).length);
	}

	/**
	 * A module the index never saw may declare any module-level field, so it refuses beside one that
	 * declares one. Two such modules are the documented residual: neither set can be listed, and they
	 * sort as before.
	 */
	@:pin('control') @:killer('M-BIND-UNLISTED-FREE-LEFT')
	public function testAnUnindexedModuleRefusesBesideAModuleLevelField(): Void {
		final src: String = module('import z.Zeta;\nimport mystery.Box;\nimport v.Fns;\n');
		Assert.equals(1, violations(src, null, BIND_LIBS).length);
		Assert.equals(0, edits(src, null, BIND_LIBS).length);
		Assert.equals(
			module('import mystery.Box;\nimport mystery.Two;\n'),
			fixed(module('import mystery.Two;\nimport mystery.Box;\n'), null, BIND_LIBS)
		);
	}

	/** An explicit import of a MODULE-LEVEL field binds that field, and nothing the line beside it binds. */
	@:pin('control') @:killer('M-BIND-FIELD-IMPORT-MODULE-FIELD')
	public function testAFieldImportOfAModuleLevelFieldIsListed(): Void {
		Assert.equals(
			module('import v.Fns.modfn;\nimport w.Other;\n'), fixed(module('import w.Other;\nimport v.Fns.modfn;\n'), null, BIND_LIBS)
		);
		Assert.equals(0, edits(module('import v.Fns2;\nimport v.Fns.modfn;\n'), null, BIND_LIBS).length);
	}

	/** A wedged `using` binds its module's constructors, and moving it below an import sharing one would rebind it. */
	public function testAWedgedUsingOvertakingAConstructorBinderRefusesTheMerge(): Void {
		final src: String = module('import a.Alpha;\nusing p.Col;\nimport p.Col2;\n');
		Assert.equals(1, violations(src, null, BIND_LIBS).length);
		Assert.equals(0, edits(src, null, BIND_LIBS).length);
	}

	/** A `using` brings no module-level field, so it may overtake an import declaring the same one. */
	@:pin('control') @:killer('M-BIND-USING-FIELDS')
	public function testAUsingBindsNoModuleLevelField(): Void {
		Assert.equals(
			module('import v.Fns;\nimport z.Zeta;\n\nusing v.Fns2;\n'),
			fixed(module('import z.Zeta;\nusing v.Fns2;\nimport v.Fns;\n'), null, BIND_LIBS)
		);
	}

	public function testBlockCommentEndsTheRun(): Void {
		// Only whole-line `//` comments are pinned to an import; a block comment between two
		// imports ends the run rather than being moved by a reorder that cannot read it.
		Assert.equals(0, violations('package app;\n\nimport z.Zeta;\n/* group two */\nimport a.Alpha;\n\nclass C {}\n').length);
	}

	public function testGuardedImportsAreNotPartOfTheBlock(): Void {
		Assert.equals(
			0, violations('package app;\n\nimport z.Zeta;\n#if js\nimport js.Browser;\n#end\nimport a.Alpha;\n\nclass C {}\n').length
		);
	}

	// --- the `using` wedge: runs separated by a `using` group are ONE block ---

	public function testWedgedUsingIsFlagged(): Void {
		final vs: Array<Violation> = violations(WEDGE);
		Assert.equals(1, vs.length);
		Assert.equals('import-order', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("'tink.CoreApi'"), 'names the wedged using: ${vs[0].message}');
	}

	public function testWedgedUsingIsMovedBelowTheMergedBlock(): Void {
		// Both runs are ordered on their own, so nothing was reported before the wedge reading — the
		// file was a fixed point no rule repaired. The fix must also be its own fixed point.
		final expected: String = 'package tests.unit;\n\n#if !UNIT_TESTS\n#error "unit only"\n#end\nimport tink.unit.Assert.*;\n'
			+ 'import fs.DrillsFolderWatcher;\nimport fs.FSUtil;\nimport fs.FolderWatcher;\nimport haxe.Exception;\n'
			+ 'import haxe.io.Path;\n\nusing tink.CoreApi;\n\nclass C {}\n';
		Assert.equals(expected, fixed(WEDGE));
		Assert.equals(0, violations(expected).length, 'the fix converges in one pass');
	}

	public function testWedgeFixOutputSurvivesTheWriter(): Void {
		switch CanonicalEdit.canonicalize(WEDGE, edits(WEDGE), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.contains('import haxe.io.Path;\n\nusing tink.CoreApi;'), text);
				Assert.isTrue(text.contains('import fs.FSUtil;\nimport fs.FolderWatcher;'), text);
			case Err(message):
				Assert.fail('wedge canonicalize Err: $message');
		}
	}

	public function testWedgeIsNotTouchedUnderTheOptOut(): Void {
		Assert.equals(0, violations(WEDGE, KEEP_USING).length);
		Assert.equals(WEDGE, fixed(WEDGE, KEEP_USING));
	}

	public function testSeveralWedgedUsingsKeepTheirRelativeOrder(): Void {
		// Haxe ranks static extensions in REVERSE declaration order, so the group may only move as a
		// whole. `ext.Two` before `ext.One` is the order the source carries and the order the output
		// must carry — a merge that SORTED the group would silently reverse the two extensions.
		final src: String = 'package app;\n\nimport z.Zeta;\nusing ext.Two;\nusing ext.One;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals('package app;\n\nimport a.Alpha;\nimport z.Zeta;\n\nusing ext.Two;\nusing ext.One;\n\nclass C {}\n', fixed(src));
	}

	public function testAChainedWedgeMergesEveryRunAtOnce(): Void {
		// run / using / run / using / run is ONE wedge carrying two `using` groups, not two wedges.
		final src: String =
			'package app;\n\nimport z.Zeta;\nusing ext.One;\nimport m.Mid;\nusing ext.Two;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(
			'package app;\n\nimport a.Alpha;\nimport m.Mid;\nimport z.Zeta;\n\nusing ext.One;\nusing ext.Two;\n\nclass C {}\n', fixed(src)
		);
	}

	public function testAMergedRunIsSortedByTheWedgeEditAlone(): Void {
		// Both runs are unordered AND wedged, so the file carries three findings — two per-run, one
		// wedge. Only the wedge's edit may be emitted: the per-run spans sit INSIDE its region, and
		// emitting both would hand the caller two overlapping edits over one range.
		final src: String = 'package app;\n\nimport z.Zeta;\nimport m.Mid;\nusing ext.One;\nimport b.Bee;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(3, violations(src).length);
		Assert.equals(1, edits(src).length);
		Assert.equals(
			'package app;\n\nimport a.Alpha;\nimport b.Bee;\nimport m.Mid;\nimport z.Zeta;\n\nusing ext.One;\n\nclass C {}\n', fixed(src)
		);
	}

	public function testAUsingOutsideEveryGapIsNotAWedge(): Void {
		// The blank-line GROUP is preserved: the file HAS a top-level `using`, but not between the
		// two runs, so no gap holds one and there is nothing to merge.
		final src: String =
			'package app;\n\nimport z.Alpha;\nimport z.Zeta;\n\nimport a.Alpha;\nimport a.Beta;\n\nusing ext.One;\n\nclass C {}\n';
		Assert.equals(0, violations(src).length);
	}

	public function testAWildcardBesideTheUsingBlocksTheMerge(): Void {
		// The gap must hold NOTHING but the `using` group: a wildcard binds names the ordering cannot
		// see, so the runs around it stay separate.
		Assert.equals(
			0, violations('package app;\n\nimport z.Zeta;\nusing ext.One;\nimport other.*;\nimport a.Alpha;\n\nclass C {}\n').length
		);
	}

	public function testAGuardedRegionBesideTheUsingBlocksTheMerge(): Void {
		final src: String =
			'package app;\n\nimport z.Zeta;\nusing ext.One;\n#if js\nimport js.Browser;\n#end\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(0, violations(src).length);
	}

	public function testAnUnliftableUsingRefusesEveryWedgeInTheFile(): Void {
		// Two `using` statements sharing a line cannot be moved as lines, so the file's `using` group
		// cannot be relocated intact — and a wedge LOWER in the file must not be repaired either.
		final src: String =
			'package app;\n\nusing ext.One; using ext.Two;\nimport z.Zeta;\nusing ext.Three;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(0, violations(src).length);
	}

	// --- wedge refusals: the merge is reported, the rewrite is not made ---

	public function testWedgeWithALeadingCommentOnTheBlockIsReportOnly(): Void {
		// Same refusal as the plain reorder: a comment above the block's FIRST import belongs to the
		// block, and the merge can neither carry it nor strand it.
		final src: String = 'package app;\n\n// third-party\nimport z.Zeta;\nusing ext.One;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testWedgeWithALeadingCommentOnAnInteriorRunIsReportOnly(): Void {
		// The SECOND run's head carries the label — which was a block head of its own until the merge
		// proposed to fold it in. Carrying `// second group` into the middle of the sorted block is
		// the same misattribution the first-line refusal exists to stop, one run down.
		final src: String =
			'package app;\n\nimport z.Zeta;\nusing ext.One;\n// second group\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testTwoMergedRunsBindingOneSimpleNameIsReportOnly(): Void {
		// The refusal only a MERGE can trip: `z.Alpha` and `a.Alpha` never shared a run, so no
		// per-run reorder could ever have compared them. Folding them into one block would let the
		// sort decide which declaration a bare `Alpha` means.
		final src: String =
			'package app;\n\nimport z.Zeta;\nimport z.Alpha;\nusing ext.One;\nimport a.Beta;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(3, violations(src).length);
		Assert.equals(
			'package app;\n\nimport z.Alpha;\nimport z.Zeta;\nusing ext.One;\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n', fixed(src),
			'the merge is refused, so each run is still reordered on its own'
		);
	}

	public function testAUsingOfAnUnknownModuleIsReportOnly(): Void {
		// `mystery.Facade` is in no index the run can see, so what it declares is UNKNOWN — and the
		// last-segment fallback would answer "binds only `Facade`, no collision" on no evidence.
		// Exactly the shape a multi-type facade module has, so the merge refuses until the project
		// declares the library.
		final src: String = 'package app;\n\nimport z.Zeta;\nusing mystery.Facade;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testUsingOvertakingAnImportItShadowsIsReportOnly(): Void {
		// `using ext.Shadow` declares a SECONDARY `Alpha` and currently loses that name to the import
		// BELOW it; moving it past that import would silently rebind the name.
		final src: String = 'package app;\n\nimport z.Zeta;\nusing ext.Shadow;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	// --- refusals: the order is load-bearing, or the lines are not separable ---

	public function testSameSimpleNameIsReportedButNotReordered(): Void {
		// Haxe accepts both and lets the LAST win, so their relative order decides what a bare
		// `Widget` means. Reporting is fine; permuting them is a silent rebind.
		final src: String = 'package app;\n\nimport z.Widget;\nimport a.Widget;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testDuplicatePathIsReportedButNotReordered(): Void {
		final src: String = 'package app;\n\nimport z.Zeta;\nimport a.Alpha;\nimport z.Zeta;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testTwoImportsOnOneLineEndTheBlock(): Void {
		// Neither shared-line import is separable as a line, so the run ends at them and what
		// remains is a run of one — nothing to report, nothing to permute. Without the two
		// separability guards the shared line joins a block and the reorder DUPLICATES it.
		final src: String = 'package app;\n\nimport m.Mid; import q.Q;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(0, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testFirstImportWithALeadingCommentIsReportOnly(): Void {
		// A comment above the block's FIRST import belongs to the block, not to that import — a
		// header, a license banner, a `CHECKSTYLE:OFF` marker, a group label. Moving it into the
		// block's middle and stranding it above a different import are both wrong, so the finding
		// stays report-only.
		final src: String = 'package app;\n\n// group two\nimport z.Zeta;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testCommentTextInsideABlockCommentIsNotAbsorbed(): Void {
		// A `//`-looking line INSIDE a `/* … */` region is comment TEXT. Absorbing it into the
		// first import's movable chunk would both tear the region apart and trip the
		// leading-comment refusal, leaving the block unfixed.
		final src: String = 'package app;\n\nimport z.Zeta;\n/* note\n// still inside */\nimport a.Beta;\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals(
			'package app;\n\nimport z.Zeta;\n/* note\n// still inside */\nimport a.Alpha;\nimport a.Beta;\n\nclass C {}\n', fixed(src)
		);
	}

	public function testSameSecondaryTypeNameIsReportOnly(): Void {
		// Two MODULE imports whose modules each declare a same-named secondary type bind that name
		// twice, and Haxe lets the last win — the module paths alone do not reveal it, so the
		// refusal has to read the resolution index.
		final src: String = 'package app;\n\nimport two.ModB;\nimport one.ModA;\n\nclass C {}\n';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'app/C.hx', source: src },
			{ file: 'one/ModA.hx', source: 'package one;\n\nclass ModA {}\n\nclass Shared {}\n' },
			{ file: 'two/ModB.hx', source: 'package two;\n\nclass ModB {}\n\nclass Shared {}\n' }
		];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ImportBlockOrder = new ImportBlockOrder();
		final vs: Array<Violation> = check.run(files, plugin).filter(v -> v.file == 'app/C.hx');
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, plugin, SymbolIndex.build(files, plugin)).length);
	}

	public function testAnInsertedImportSatisfiesTheRule(): Void {
		// The two halves of the feature must read a block the same way: an import the shared
		// `ImportOrder` seat places must not be a finding for the rule built on that same seat.
		final src: String = 'package app;\n\nimport app.base.Host;\nimport pkg.mid.events.Alpha;\nimport pkg.mid.SetBeta;\n\nclass C {}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(src, plugin.parseFile(src), plugin.importMap(src), plugin);
		printer.print('app.deep.Mod.Widget');
		final inserted: String = CanonicalEdit.applyEdits(src, printer.pendingImportEdits());
		Assert.equals(0, violations(inserted).length, 'the insert seat and the rule agree:\n$inserted');
	}

	public function testAnInsertIntoARunSplitFileSatisfiesTheRuleUnderTheOptOut(): Void {
		// The two-wave incident, as the acceptance for the RUN model. A `using` splits the imports
		// into two runs, each sorted, their concatenation not — read as one list the file looks
		// unordered, the fresh import is appended past the file's last import, and THIS rule then
		// reports the line the inserter had just placed. One shared run model, zero waves.
		// Read under the `usingAfterImports` opt-out, which is where the run model alone decides the
		// verdict: with the wedge merge on, the shape is a finding in its own right (see
		// `testWedgedUsingIsFlagged`) and would mask what this acceptance is about.
		final src: String = 'package app;\n\nimport a.Alpha;\nimport m.Mid;\nimport z.Zeta;\n'
			+ '\nusing ext.One;\n\nimport b.Bee;\nimport c.Cee;\n\nclass C {}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(0, violations(src, KEEP_USING).length, 'the shape starts clean');
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(src, plugin.parseFile(src), plugin.importMap(src), plugin);
		printer.print('a.Aaa');
		final inserted: String = CanonicalEdit.applyEdits(src, printer.pendingImportEdits());
		Assert.equals(0, violations(inserted, KEEP_USING).length, 'the insert seat and the rule agree:\n$inserted');
	}

	public function testAnInsertIntoARunSplitFileAddsNoOrderFinding(): Void {
		// The same acceptance under the SHIPPED default. The wedge finding is there before and after
		// — what the seat must not do is add a SECOND one by dropping its line in the wrong run.
		final src: String = 'package app;\n\nimport a.Alpha;\nimport m.Mid;\nimport z.Zeta;\n'
			+ '\nusing ext.One;\n\nimport b.Bee;\nimport c.Cee;\n\nclass C {}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(src, plugin.parseFile(src), plugin.importMap(src), plugin);
		printer.print('a.Aaa');
		final inserted: String = CanonicalEdit.applyEdits(src, printer.pendingImportEdits());
		final after: Array<Violation> = violations(inserted);
		Assert.equals(1, after.length, 'no finding beyond the wedge the shape already carried:\n$inserted');
		Assert.isTrue(after[0].message.contains('splits the import block'), after[0].message);
	}

	// --- comment pinning ---

	public function testLineCommentTravelsWithItsImport(): Void {
		final src: String = 'package app;\n\nimport a.Alpha;\n// the widget\nimport z.Zeta;\nimport a.Beta;\n\nclass C {}\n';
		Assert.equals('package app;\n\nimport a.Alpha;\nimport a.Beta;\n// the widget\nimport z.Zeta;\n\nclass C {}\n', fixed(src));
	}

	public function testTrailingCommentTravelsWithItsImport(): Void {
		final src: String = 'package app;\n\nimport z.Zeta; // last alphabetically\nimport a.Alpha;\n\nclass C {}\n';
		Assert.equals('package app;\n\nimport a.Alpha;\nimport z.Zeta; // last alphabetically\n\nclass C {}\n', fixed(src));
	}

	// --- registration ---

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('import-order');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'import-order is opt-in');
		Assert.equals(192, Linter.builtins().length);
	}

	/**
	 * A module whose WHOLE body is `#if`-guarded carries its import block inside the region, and the
	 * rule judges it there. Read at the top level only the file offers no block at all, so the same
	 * disorder that is a finding one line higher goes unreported — the gap that let an inserting
	 * fixer's own line stand unflagged.
	 */
	public function testGuardedBlockIsJudged(): Void {
		final source: String = 'package app;\n\n#if DEBUG\nimport z.Zed;\nimport a.Al;\nimport m.Mid;\n\nclass C {}\n#end\n';
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('import-order', vs[0].rule);
	}

	/** The guarded block's autofix sorts it in place, inside the region. */
	public function testGuardedBlockIsSortedInPlace(): Void {
		Assert.equals(
			'package app;\n\n#if DEBUG\nimport a.Al;\nimport m.Mid;\nimport z.Zed;\n\nclass C {}\n#end\n',
			fixed('package app;\n\n#if DEBUG\nimport z.Zed;\nimport a.Al;\nimport m.Mid;\n\nclass C {}\n#end\n')
		);
	}

	/**
	 * The refusal above is correct and it was SILENT: four of them on one tree were read as
	 * "import-order has no autofix", and a queue item was written to invent the very guard that
	 * produced them. `fix` must now name its guard on the finding it refused — in `fix`, not in
	 * `run`, because that is where the guard runs.
	 */
	public function testARefusedReorderNamesItsGuardOnTheFinding(): Void {
		final reason: Null<String> =
			refusalReasonFor('package app;\n\nimport z.Widget;\nimport a.Widget;\nimport a.Alpha;\n\nclass C {}\n');
		if (reason == null) {
			Assert.fail('a refused reorder must name its guard on the finding it refused');
			return;
		}
		Assert.isTrue(reason.indexOf('Widget') != -1, 'and name the colliding simple name, got: $reason');
	}

	/**
	 * The OTHER refusal names the cause it actually has: an absorbed leading comment above the
	 * block's first import.
	 *
	 * The guard reads `chunkFrom != startOfLine(declFrom)`, and it printed "its first import shares
	 * its line with something else" — a cause it can NEVER see. `ImportOrder.lineOf` returns null for
	 * a statement whose line carries code before it, so such a slot never becomes an `ImportLine` and
	 * never reaches this guard; `chunkFrom` can only be LESS than the line start, which is the
	 * leading-comment reach. Two real files (both explaining, in that very comment, why the order is
	 * deliberate) were told their import shared a line with something else.
	 *
	 * RED at base on both assertions. The second fixture is the discriminator and is green at base:
	 * drop the comment and the same block sorts, so the refusal is attributable to the comment and
	 * not to the block's shape.
	 */
	public function testTheLeadingCommentRefusalNamesTheComment(): Void {
		final reason: Null<String> = refusalReasonFor(
			'package app;\n\n// JValue first: its @:build macros define the siblings below.\nimport z.Zed;\nimport a.Alpha;\n\n'
			+ 'class C {}\n'
		);
		if (reason == null) {
			Assert.fail('a refused reorder must name its guard on the finding it refused');
			return;
		}
		Assert.isTrue(reason.indexOf('leading comment') != -1, 'the reason names the comment, got: $reason');
		Assert.equals(-1, reason.indexOf('shares its line'), 'and never the cause this guard cannot see, got: $reason');

		// DISCRIMINATOR: the same two imports with no comment above them ARE reordered, so the
		// refusal above is the comment's doing and not the block's.
		Assert.equals(
			'package app;\n\nimport a.Alpha;\nimport z.Zed;\n\nclass C {}\n',
			fixed('package app;\n\nimport z.Zed;\nimport a.Alpha;\n\nclass C {}\n')
		);
	}

	/**
	 * REFUTED and pinned as a control: a plain import from ANOTHER package between two
	 * `unit.*` runs does NOT split the block, so a misplaced import after it is still reported.
	 *
	 * The claim was that `test/RunTests.hx` had a blind spot — its `import utest.Runner;` splitting
	 * the `unit.*` imports into two trivially-sorted blocks, letting a misplaced one pass. It
	 * does not: a run ends at a blank line, a `using` / wildcard / alias, a block comment or a
	 * non-import declaration, and a plain import is none of those. On the base build the
	 * real file reported `import 'unit.grammar.haxe.HxSoleArgGluedCloseDedentTest' is out of order in its block`
	 * and one `--fix` pass sorted the whole thing, tail included.
	 *
	 * Green at base BY CONSTRUCTION, and a control rather than a regression pin: what would flip it
	 * is `ImportOrder.runsOf` learning to break a run at a package change, which is the "blind spot"
	 * this records as never having existed.
	 */
	public function testForeignPackageImportDoesNotSplitTheBlock(): Void {
		final source: String =
			'package app;\n\nimport unit.Alpha;\nimport unit.Charlie;\nimport utest.Runner;\nimport unit.Bravo;\n\nclass C {}\n';
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length, 'the four imports are ONE block: ${[for (v in vs) v.message].join(' / ')}');
		if (vs.length != 1) return;
		Assert.isTrue(vs[0].message.contains("'unit.Bravo'"), 'and the import past the foreign one is the offender: ${vs[0].message}');
		Assert.equals(
			'package app;\n\nimport unit.Alpha;\nimport unit.Bravo;\nimport unit.Charlie;\nimport utest.Runner;\n\nclass C {}\n',
			fixed(source), 'the fix sorts across it rather than around it'
		);
	}

	// --- helpers -------------------------------------------------------------------

	/**
	 * The reason `fix` wrote on `src`'s ONE finding after refusing to reorder it, or null when the
	 * fixture did not produce exactly one finding.
	 *
	 * Asserts on the way through that `run` declined nothing (the guards belong to the fix path) and
	 * that `fix` produced no edit — a reason without a refusal would be the opposite defect.
	 */
	private function refusalReasonFor(src: String): Null<String> {
		final files: Array<{ file: String, source: String }> = scope(src);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ImportBlockOrder = configured(null);
		final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == 'app/C.hx');
		Assert.equals(1, own.length);
		if (own.length != 1) return null;
		Assert.isTrue(own[0].declineReason == null, 'run() declines nothing — the guard belongs to the fix path');
		Assert.equals(0, check.fix(src, own, plugin, SymbolIndex.build(files, plugin)).length);
		return own[0].declineReason;
	}

	/**
	 * The scope `src` is read in: the file under test plus the stub library modules the `using`
	 * fixtures name. A wedge merge refuses a `using` whose module the index cannot see, so a
	 * fixture writing `using ext.One;` needs `ext/One.hx` to exist for the merge to be reachable at
	 * all — `mystery.Facade` is deliberately absent, which is what makes that refusal testable.
	 * `ext.Shadow` declares a SECONDARY `Alpha`, the collision the overtake refusal reads.
	 */
	private function scope(src: String, ?libs: Array<{ file: String, source: String }>): Array<{ file: String, source: String }> {
		return (libs ?? []).concat([
			{ file: 'app/C.hx', source: src },
			{ file: 'ext/One.hx', source: 'package ext;\n\nclass One {}\n' },
			{ file: 'ext/Two.hx', source: 'package ext;\n\nclass Two {}\n' },
			{ file: 'ext/Three.hx', source: 'package ext;\n\nclass Three {}\n' },
			{ file: 'ext/Shadow.hx', source: 'package ext;\n\nclass Shadow {}\n\nclass Alpha {}\n' },
			{ file: 'tink/CoreApi.hx', source: 'package tink;\n\nclass CoreApi {}\n' }
		]);
	}

	/**
	 * The check's findings for `src`, with `config` (raw `apqlint.json` text) in effect when given and `libs` joined to
	 * the stub library.
	 */
	private function violations(src: String, ?config: String, ?libs: Array<{ file: String, source: String }>): Array<Violation> {
		final check: ImportBlockOrder = configured(config);
		return check.run(scope(src, libs), new HaxeQueryPlugin()).filter(v -> v.file == 'app/C.hx');
	}

	/** The check's autofix edits for `src`, resolved against the stub-library index plus `libs`. */
	private function edits(
		src: String, ?config: String, ?libs: Array<{ file: String, source: String }>
	): Array<{ span: Span, text: String }> {
		final files: Array<{ file: String, source: String }> = scope(src, libs);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ImportBlockOrder = configured(config);
		final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == 'app/C.hx');
		return check.fix(src, own, plugin, SymbolIndex.build(files, plugin));
	}

	/** `src` with the check's raw edits spliced in — the reorder verbatim, before any writer pass. */
	private function fixed(src: String, ?config: String, ?libs: Array<{ file: String, source: String }>): String {
		return CanonicalEdit.applyEdits(src, edits(src, config, libs));
	}

	/** A check carrying `config` (raw `apqlint.json` text) as its per-file resolver, or the default one. */
	private function configured(config: Null<String>): ImportBlockOrder {
		final check: ImportBlockOrder = new ImportBlockOrder();
		if (config != null) {
			final parsed: LintConfig = LintConfig.parse(config);
			check.setConfigResolver(file -> parsed);
		}
		return check;
	}

	/** `imports` as the header of an `app` module declaring one class. */
	private static function module(imports: String): String {
		return 'package app;\n\n$imports\nclass C {}\n';
	}

	/** A fixture module `pack.Name` whose class answers `id()` with its own path. */
	private static function idClass(pack: String, name: String): String {
		return 'package $pack;\n\nclass $name {\n\tpublic static function id() return "$pack.$name";\n}\n';
	}

	/** A fixture module `pack.Name` whose class declares ONE static function `fn`, answering with its own path. */
	private static function staticClass(pack: String, name: String, fn: String): String {
		return 'package $pack;\n\nclass $name {\n\tpublic static function $fn() return "$pack.$name.$fn";\n}\n';
	}

	/** Compile and run `dir`'s `Main` on `--interp`. */
	private static function runMain(dir: String): HaxeRun {
		return HaxeSpawn.run(['-cp', '.', '-main', 'Main', '--interp'], dir, 1 << 20);
	}

	/** A fixture module `pack.Name` declaring one MODULE-LEVEL function `fn`, answering with its own path. */
	private static function moduleField(pack: String, name: String, fn: String): String {
		return 'package $pack;\n\nfunction $fn(): String {\n\treturn "$pack.$name.$fn";\n}\n\nclass $name {}\n';
	}

}
