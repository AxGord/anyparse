package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.ShortenTypeRef;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;

/**
 * The `shorten-type-ref` check: a DOTTED type reference the file itself spells differently.
 * Covers the `pack.SubType` HYBRID repair (to the short name with the import present, to the
 * module-qualified path without it), plain over-qualification across every type position the
 * grammar projects, the add-import arm and its threshold, the `#if` counting / rewriting /
 * freeness split, the five conflict gates, the metadata-argument and value-receiver refusals,
 * the index proof degrading a run to report-only, and idempotency.
 */
class ShortenTypeRefCheckTest extends Test {

	// --- helpers -------------------------------------------------------------------

	/** The library module carrying a MAIN type `Mod` and a SECONDARY type `Sub` — the hybrid's subject. */
	private static inline final MOD_SOURCE: String = 'package pkg.deep;\n\nclass Mod {}\n\ntypedef Sub = Int;\n';

	/** A second library module whose main type `Foo` is the plain over-qualification subject. */
	private static inline final FOO_SOURCE: String = 'package pkg.deep;\n\nclass Foo {}\n';

	/** A third library module, so an add-import test can prove two paths each get their own line. */
	private static inline final BAR_SOURCE: String = 'package pkg.deep;\n\nclass Bar {}\n';

	/** A same-simple-name type in ANOTHER package — the shadow that keeps a qualified path qualified. */
	private static inline final OTHER_FOO_SOURCE: String = 'package other;\n\nclass Foo {}\n';

	/** A type one package deep, for the `pkg.Holder` chain whose receiver a parameter can shadow. */
	private static inline final HOLDER_SOURCE: String = 'package pkg;\n\nclass Holder {}\n';

	/** An enum whose `Hash` CONSTRUCTOR takes the bare name in every file that imports the enum. */
	private static inline final BASECTION_SOURCE: String = 'package types;\n\nenum BASection {\n\tHash;\n\tPrepare;\n}\n';

	/** The class whose simple name that constructor collides with, in the consumer's OWN package. */
	private static inline final MODULE_HASH_SOURCE: String = 'package module;\n\nclass Hash {}\n';

	// --- ARM 1: the pack.SubType hybrid ---

	public function testHybridRepairedToTheImportedShortName(): Void {
		final src: String = consumer('import pkg.deep.Mod.Sub;\n\n', 'pkg.deep.Sub');
		Assert.equals('\t\tfinal v:Sub = g();', annotationLine(applyFix(src)));
	}

	public function testHybridIsFixableNotReportOnly(): Void {
		final vs: Array<Violation> = violations(consumer('import pkg.deep.Mod.Sub;\n\n', 'pkg.deep.Sub'));
		Assert.equals(1, vs.length);
		Assert.equals('shorten-type-ref', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('report-only') == -1, 'proven, got: ${vs[0].message}');
	}

	public function testViolationSpanIsThePathOnly(): Void {
		final src: String = consumer('import pkg.deep.Mod.Sub;\n\n', 'pkg.deep.Sub');
		final vs: Array<Violation> = violations(src);
		Assert.equals('pkg.deep.Sub', src.substring(vs[0].span.from, vs[0].span.to));
	}

	/**
	 * The whole point of arm 1: with the import GONE the hybrid no longer resolves, so the
	 * repair is the module-qualified path — never the short name (nothing binds it here) and
	 * never a fresh import (one occurrence is below the threshold).
	 */
	public function testHybridWithoutTheImportBecomesModuleQualified(): Void {
		final out: String = applyFix(consumer('', 'pkg.deep.Sub'));
		Assert.equals('\t\tfinal v:pkg.deep.Mod.Sub = g();', annotationLine(out));
		Assert.equals(-1, out.indexOf('import '), 'no import for a single occurrence');
	}

	// --- ARM 2: the short name is already visible ---

	public function testImportedMainTypeShortens(): Void {
		Assert.equals('\t\tfinal v:Foo = g();', annotationLine(applyFix(consumer('import pkg.deep.Foo;\n\n', 'pkg.deep.Foo'))));
	}

	public function testSamePackageMainTypeShortens(): Void {
		final src: String = 'package pkg.deep;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tfinal v:pkg.deep.Foo = g();\n\t}\n\n}\n';
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/deep/C.hx', source: src }];
		Assert.equals('\t\tfinal v:Foo = g();', annotationLine(applyFixWith(src, scopedPlugin(report), report)));
	}

	public function testShadowedShortNameKeepsTheQualifiedPath(): Void {
		// A bare `Foo` here means `other.Foo`; shortening would silently rebind the annotation.
		Assert.equals(0, violations(consumer('import other.Foo;\n\n', 'pkg.deep.Foo')).length);
	}

	public function testAlreadyShortAnnotationIsNotFlagged(): Void {
		Assert.equals(0, violations(consumer('import pkg.deep.Foo;\n\n', 'Foo')).length);
	}

	public function testIsOperandShortens(): Void {
		final out: String = applyFix(inClass('import pkg.deep.Foo;\n\n', '\t\tif (g() is pkg.deep.Foo) g();\n'));
		Assert.isTrue(out.indexOf('if (g() is Foo)') != -1, 'shortened, got: $out');
	}

	public function testNewExpressionShortens(): Void {
		final out: String = applyFix(inClass('import pkg.deep.Foo;\n\n', '\t\tfinal v = new pkg.deep.Foo();\n'));
		Assert.isTrue(out.indexOf('new Foo();') != -1, 'shortened, got: $out');
	}

	/**
	 * A `new pkg.T(...)` node's span opens on the `new` keyword, so the path is LOCATED inside it
	 * rather than read off the span start — and a comment between the two is the trap. A
	 * comment-blind forward search takes the FIRST match, rewrites the COMMENT and leaves the real
	 * path qualified; the result compiles, so the `RiskyFix` verifier never reverts it, and the
	 * next fixpoint pass shortens the real path with the mangled comment left behind.
	 */
	public function testNewExpressionWithAnInteriorCommentShortensTheRealPath(): Void {
		final src: String = inClass('import pkg.deep.Foo;\n\n', '\t\tfinal a = new /* pkg.deep.Foo */ pkg.deep.Foo();\n');
		Assert.equals(1, violations(src).length);
		Assert.isTrue(applyFix(src).indexOf('new /* pkg.deep.Foo */ Foo();') != -1, 'comment intact, got: ${applyFix(src)}');
	}

	/**
	 * The same shape on the add-import arm, where TWO comment-blind scans have to be fixed: the
	 * `owned` freeness exemption must name the REAL path (pointed at the comment, the real path's
	 * own token vetoes the import), and the freeness scan itself must not read the comment's
	 * mention of the name as a binding — a comment binds nothing.
	 */
	public function testNewExpressionWithAnInteriorCommentStillEarnsItsImport(): Void {
		final src: String = inClass('', '\t\tfinal a = new /* pkg.deep.Foo */ pkg.deep.Foo();\n\t\tfinal b = new pkg.deep.Foo();\n');
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('import pkg.deep.Foo;') != -1, 'import added, got: $out');
		Assert.isTrue(out.indexOf('new /* pkg.deep.Foo */ Foo();') != -1, 'comment intact, got: $out');
		Assert.isTrue(out.indexOf('final b = new Foo();') != -1, 'second use shortened, got: $out');
	}

	public function testStaticAccessChainShortens(): Void {
		final out: String = applyFix(inClass('import pkg.deep.Foo;\n\n', '\t\tg(pkg.deep.Foo.make());\n'));
		Assert.isTrue(out.indexOf('g(Foo.make());') != -1, 'shortened, got: $out');
	}

	public function testHeritageShortens(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Foo;\n\nclass C extends pkg.deep.Foo {\n\n}\n';
		Assert.isTrue(applyFix(src).indexOf('class C extends Foo {') != -1, 'shortened, got: ${applyFix(src)}');
	}

	/**
	 * Field, parameter and return annotations. The rule was locals-only while it sliced an
	 * annotation REGION out of the source text; the type-refs projection hands each nominal out
	 * as a node with an exact span, so every host shape is now the same code.
	 */
	public function testFieldParameterAndReturnAnnotationsShorten(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tpublic var field:pkg.deep.Foo;\n\n'
			+ '\tpublic function f(p:pkg.deep.Foo):pkg.deep.Foo {\n\t\treturn p;\n\t}\n\n}\n';
		Assert.equals(3, violations(src).length);
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('public var field:Foo;') != -1, 'field, got: $out');
		Assert.isTrue(out.indexOf('function f(p:Foo):Foo {') != -1, 'param + return, got: $out');
	}

	// --- ARM 3: add the import ---

	public function testRepeatedPathGainsAnImport(): Void {
		final out: String = applyFix(inClass('', '\t\tg(pkg.deep.Foo.make());\n\t\tg(pkg.deep.Foo.other());\n'));
		// The raw edit anchors on the `package` statement's own end; `lint --fix` canonicalises the
		// file afterwards, which is what restores the blank line between the two.
		Assert.equals('package app;\nimport pkg.deep.Foo;\n\n', out.substring(0, out.indexOf('class C')));
		Assert.isTrue(out.indexOf('g(Foo.make());') != -1 && out.indexOf('g(Foo.other());') != -1, 'both shortened, got: $out');
	}

	public function testTheAddedImportIsReportedAsSuch(): Void {
		final vs: Array<Violation> = violations(inClass('', '\t\tg(pkg.deep.Foo.make());\n\t\tg(pkg.deep.Foo.other());\n'));
		Assert.equals(2, vs.length);
		Assert.isTrue(vs[0].message.indexOf('an import would let it') != -1, 'import arm, got: ${vs[0].message}');
	}

	public function testOneImportForSeveralOccurrences(): Void {
		final out: String = applyFix(inClass('', '\t\tg(pkg.deep.Foo.a());\n\t\tg(pkg.deep.Foo.b());\n\t\tg(pkg.deep.Foo.c());\n'));
		Assert.isTrue(out.indexOf('import pkg.deep.Foo;') != -1, 'import added, got: $out');
		Assert.equals(out.indexOf('import pkg.deep.Foo;'), out.lastIndexOf('import pkg.deep.Foo;'));
	}

	/**
	 * The insert respects the ORDER the file's own import block carries — `ImportOrder` owns
	 * that, and this is the assertion that the rule goes through it rather than appending.
	 */
	public function testTheImportLandsInsideASortedBlock(): Void {
		final out: String = applyFix(
			inClass('import aaa.First;\nimport zzz.Last;\n\n', '\t\tg(pkg.deep.Foo.a());\n\t\tg(pkg.deep.Foo.b());\n')
		);
		Assert.equals(
			'package app;\n\nimport aaa.First;\nimport pkg.deep.Foo;\nimport zzz.Last;\n\n', out.substring(0, out.indexOf('class C'))
		);
	}

	public function testAnUnsortedBlockIsAppendedTo(): Void {
		final out: String = applyFix(
			inClass('import zzz.Last;\nimport aaa.First;\n\n', '\t\tg(pkg.deep.Foo.a());\n\t\tg(pkg.deep.Foo.b());\n')
		);
		Assert.equals(
			'package app;\n\nimport zzz.Last;\nimport aaa.First;\nimport pkg.deep.Foo;\n\n', out.substring(0, out.indexOf('class C'))
		);
	}

	public function testSingleOccurrenceGetsNoImport(): Void {
		final src: String = inClass('', '\t\tg(pkg.deep.Foo.make());\n');
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	public function testTwoDifferentPathsEachGainTheirOwnImport(): Void {
		final out: String = applyFix(
			inClass('', '\t\tg(pkg.deep.Foo.a(), pkg.deep.Bar.a());\n\t\tg(pkg.deep.Foo.b(), pkg.deep.Bar.b());\n')
		);
		Assert.equals('package app;\nimport pkg.deep.Bar;\nimport pkg.deep.Foo;\n\n', out.substring(0, out.indexOf('class C')));
		Assert.isTrue(out.indexOf('g(Foo.a(), Bar.a());') != -1, 'both shortened, got: $out');
	}

	public function testImportArmIsIdempotent(): Void {
		final once: String = applyFix(inClass('', '\t\tg(pkg.deep.Foo.a());\n\t\tg(pkg.deep.Foo.b());\n'));
		Assert.isTrue(once.indexOf('import pkg.deep.Foo;') != -1, 'import added, got: $once');
		Assert.equals(0, violations(once).length, 'the rewritten source is already canonical');
		Assert.equals(once, applyFix(once));
	}

	/**
	 * The real shape the arm was losing: a test file whose assertion messages happen to spell the
	 * simple name. The message is inert TEXT — it binds nothing — so it must not close the arm,
	 * and the fix must leave its bytes exactly as written.
	 */
	public function testAnAssertionMessageMentionDoesNotCloseTheImportArm(): Void {
		final body: String = "\t\tg(pkg.deep.Foo.a(), 'Foo should exist');\n\t\tg(pkg.deep.Foo.b(), \"Foo content should match\");\n";
		final out: String = applyFix(inClass('', body));
		Assert.isTrue(out.indexOf('import pkg.deep.Foo;') != -1, 'import added, got: $out');
		Assert.isTrue(out.indexOf("g(Foo.a(), 'Foo should exist');") != -1, 'first shortened, message intact, got: $out');
		Assert.isTrue(out.indexOf('g(Foo.b(), "Foo content should match");') != -1, 'second shortened, message intact, got: $out');
	}

	/**
	 * The other half of the same gate: an INTERPOLATED mention is a read of `Foo`, so the arm
	 * stays closed and every occurrence keeps its qualified spelling.
	 */
	public function testAnInterpolatedMentionStillClosesTheImportArm(): Void {
		final body: String = "\t\tg(pkg.deep.Foo.a(), 'at ${Foo.tag}');\n\t\tg(pkg.deep.Foo.b());\n";
		final src: String = inClass('', body);
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	// --- conditional compilation ---

	public function testConditionalRegionIsNotRewritten(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Mod.Sub;\n\nclass C {\n\n\tpublic function f():Void {\n\t\t#if debug\n'
			+ '\t\tfinal v:pkg.deep.Sub = g();\n\t\t#end\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * An EXPRESSION-position `#if` projects as `ConditionalExpr`, not the `Conditional` that
	 * `RefShape.conditionalMemberKind` names — which is why the skip tests the `#if` DIRECTIVE
	 * rather than a kind.
	 */
	public function testConditionalExpressionRegionIsNotRewritten(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Mod.Sub;\n\nclass C {\n\n\tpublic function f():Void {\n'
			+ '\t\tfinal x = #if debug { final v:pkg.deep.Sub = g(); v; } #else 0 #end;\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A path whose EVERY occurrence sits inside `#if` gets no import: the file may not spell the name
	 * at all in some build.
	 *
	 * A BEHAVIOUR pin, not a gate test. The `targets.length == 0` early-out that reads as its guard
	 * does not discriminate it — deleting that line flips nothing, because a path with no plain
	 * occurrence is never offered the freeness exemption either, so the printer answers with the
	 * canonical path and the plan is dropped one line later. What DOES flip this is the
	 * `!o.conditional` target filter, and that filter already has four sibling tests. Same honest
	 * label as `testModuleLocalTypeOfTheSameNameRefusesTheShortForm`.
	 */
	public function testConditionalOnlyOccurrencesGetNoImport(): Void {
		final src: String = inClass('', '\t\t#if sys\n\t\tg(pkg.deep.Foo.a());\n\t\tg(pkg.deep.Foo.b());\n\t\t#end\n');
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/** A guarded occurrence does not COUNT: one plain use plus one guarded use stays below the threshold. */
	public function testConditionalOccurrenceDoesNotCountTowardTheThreshold(): Void {
		final src: String = inClass('', '\t\tg(pkg.deep.Foo.a());\n\t\t#if sys\n\t\tg(pkg.deep.Foo.b());\n\t\t#end\n');
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/**
	 * A guarded occurrence IS exempt from the printer's freeness scan, though — it is still the
	 * path's own text. Without the exemption the guarded `Foo` would read as a foreign binding
	 * and veto the import the two plain uses have earned.
	 */
	public function testConditionalOccurrenceDoesNotVetoTheImport(): Void {
		final out: String = applyFix(
			inClass('', '\t\tg(pkg.deep.Foo.a());\n\t\tg(pkg.deep.Foo.b());\n\t\t#if sys\n\t\tg(pkg.deep.Foo.c());\n\t\t#end\n')
		);
		Assert.isTrue(out.indexOf('import pkg.deep.Foo;') != -1, 'import added, got: $out');
		Assert.isTrue(out.indexOf('g(Foo.a());') != -1 && out.indexOf('g(Foo.b());') != -1, 'plain uses shortened, got: $out');
		Assert.isTrue(out.indexOf('g(pkg.deep.Foo.c());') != -1, 'the guarded use stays qualified, got: $out');
	}

	// --- conflict gates ---

	/**
	 * Gate 1 — DUELLING imports of one simple name. A `#if`-guarded `import other.Foo;` beside
	 * an unconditional `import pkg.deep.Foo;` makes a bare `Foo` mean different types in
	 * different builds; the plain-import map is a top-level scan and sees only the unconditional
	 * one, so without `TypeRefPrinter.shadowedByGuardedImport` arm 2 would shorten both uses.
	 */
	public function testGuardedImportOfTheSameNameRefusesTheShortForm(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Foo;\n#if flash\nimport other.Foo;\n#end\n\nclass C {\n\n'
			+ '\tpublic function f():Void {\n\t\tg(pkg.deep.Foo.a());\n\t\tg(pkg.deep.Foo.b());\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/**
	 * Gate 1, NESTED. The grammar flattens a conditional region's BRANCHES into one node's
	 * children, but it does NOT flatten nested REGIONS: `#if a #if b import … #end #end` projects
	 * as `Conditional > Conditional > ImportDecl`, so a one-level walk over the top-level
	 * conditionals never reaches the import and the bare name shortens into the other path under
	 * `flash && legacy`. The one-level sibling above is the control.
	 */
	public function testNestedGuardedImportOfTheSameNameRefusesTheShortForm(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Foo;\n#if flash\n#if legacy\nimport other.Foo;\n#end\n#end\n\nclass C {\n\n'
			+ '\tpublic function f():Void {\n\t\tg(pkg.deep.Foo.a());\n\t\tg(pkg.deep.Foo.b());\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/** Gate 2 — an ALIAS is not "an exact import": the alias NAME is what resolves, so that is what is printed. */
	public function testAliasedImportPrintsTheAlias(): Void {
		final out: String = applyFix(inClass('import pkg.deep.Foo as F;\n\n', '\t\tg(pkg.deep.Foo.make());\n'));
		Assert.isTrue(out.indexOf('g(F.make());') != -1, 'alias printed, got: $out');
	}

	/**
	 * Gate 2 — an alias CLAIMING the simple name for ANOTHER path keeps the reference qualified,
	 * even beside an exact import of it: Haxe lets the last binding of a simple name win, so a
	 * bare `Foo` here is `other.Bar`. Without the alias arm of `shadowedLocally` the exact import
	 * would answer "already visible" and the rewrite would silently rebind the reference.
	 */
	public function testAliasClaimingTheShortNameRefusesTheShortForm(): Void {
		final src: String = inClass(
			'import pkg.deep.Foo;\nimport other.Bar as Foo;\n\n', '\t\tg(pkg.deep.Foo.a());\n\t\tg(pkg.deep.Foo.b());\n'
		);
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/**
	 * Gate 3 — two consecutive upper-initial segments is a SUB-MODULE type access
	 * (`pkg.deep.Mod.Sub`), whose short form has resolution semantics this rule does not model.
	 * The import of `Mod` and the indexed `pkg.deep.Mod` are what make this discriminate: drop
	 * the gate and the `pkg.deep.Mod` half becomes a proven, already-imported arm-2 candidate.
	 */
	public function testSubModuleAccessChainIsRefused(): Void {
		final src: String = inClass('import pkg.deep.Mod;\n\n', '\t\tg(pkg.deep.Mod.Sub.make());\n');
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/** Gate 5 — a PARAMETER holding the simple name; an import would collide with it. */
	public function testShortNameBoundByAParameterRefusesTheImport(): Void {
		final src: String = 'package app;\n\nclass C {\n\n\tpublic function f(Foo:Int):Void {\n\t\tg(pkg.deep.Foo.a());\n'
			+ '\t\tg(pkg.deep.Foo.b());\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/**
	 * A type DECLARED in this module already binds the simple name, and in Haxe's resolution
	 * order it OUTRANKS an import of the same name — so the reference stays qualified.
	 *
	 * A BEHAVIOUR pin, not a gate test: THREE independent arms refuse this shape (the
	 * module-local arm of `shadowedLocally`, the same-package arm — the index sees the very
	 * declaration — and, in the add-import direction, the freeness scan, which reads the
	 * declaration's own `Foo` token). None of them flips this on its own, verified by disabling
	 * each; no fixture can isolate the module-local arm while an index is present, because a
	 * module-local type IS a same-package type to the index.
	 */
	public function testModuleLocalTypeOfTheSameNameRefusesTheShortForm(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tg(pkg.deep.Foo.a());\n'
			+ '\t\tg(pkg.deep.Foo.b());\n\t}\n\n}\n\nclass Foo {}\n';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/**
	 * Metadata ARGUMENTS are dot-paths the compiler resolves without the file's imports —
	 * verified against the compiler, `@:access(Foo)` beside an `import pkg.deep.Foo;` silently
	 * grants nothing and the build then fails at the private access. The import here is what
	 * makes this discriminate: without the metadata skip it is a proven arm-2 candidate.
	 */
	public function testMetadataArgumentIsNeverShortened(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Foo;\n\n@:access(pkg.deep.Foo)\nclass C {\n\n}\n';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/**
	 * A receiver that resolves to a VALUE binding makes the chain an instance field access, not
	 * a package path — `holder.Holder.x` where `holder` is a parameter. `pkg.Holder` is indexed,
	 * so dropping the binding check would shorten this into a compile error.
	 */
	public function testValueReceiverChainIsNotATypePath(): Void {
		final src: String =
			'package app;\n\nclass C {\n\n\tpublic function f(pkg:Dynamic):Void {\n\t\tg(pkg.Holder.a);\n\t\tg(pkg.Holder.b);\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	public function testMacroReificationIsSkipped(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tmacro static function m() {\n'
			+ '\t\treturn macro { final v:pkg.deep.Foo = g(); };\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * The TYPE reification `macro : T` is a quotation exactly as `macro { … }` is — it builds a
	 * `ComplexType` the surrounding macro splices into ANOTHER module, where an import this file
	 * carries does not apply. The path is shortenable here on paper (`import pkg.deep.Foo;` is
	 * right there), which is precisely what made the miss silent: the edit compiles in this file
	 * and breaks at the macro's call site with `Type not found`.
	 */
	public function testMacroTypeReificationIsSkipped(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tmacro static function m() {\n'
			+ '\t\treturn macro :pkg.deep.Foo;\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/** Same for the third quotation spelling, `macro class { … }`, in both a member type and a `new`. */
	public function testMacroClassReificationIsSkipped(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tmacro static function m() {\n'
			+ '\t\treturn macro class D {\n\t\t\tpublic var v:pkg.deep.Foo = new pkg.deep.Foo();\n\t\t};\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	// --- macro-time bodies earn no module-level import ---

	/**
	 * A `macro` function's body typechecks ONLY in the macro context, so a `sys.*` path is legal
	 * there on every target. A module-level import resolves in EVERY context, so hoisting the path
	 * out of the body breaks the module on js / flash — measured on Pony's `pony.text.TextTools`,
	 * whose neko + nodejs oracle is blind to it by construction.
	 */
	public function testMacroOnlyBodyEarnsNoImport(): Void {
		final src: String =
			'package app;\n\nclass C {\n\n\tmacro static function m() {\n\t\tg(pkg.deep.Foo.a());\n\t\tg(pkg.deep.Foo.b());\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/** The gate is the IMPORT, not the rewrite: an import the file already carries is not this rule's to justify. */
	public function testMacroBodyStillShortensAgainstAnExistingImport(): Void {
		final src: String =
			'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tmacro static function m() {\n\t\tg(pkg.deep.Foo.a());\n\t}\n\n}\n';
		Assert.equals(1, violations(src).length);
		Assert.isTrue(applyFix(src).indexOf('g(Foo.a());') != -1, 'shortened, got: ${applyFix(src)}');
	}

	/**
	 * ONE occurrence outside a macro body lifts the gate: the module already needs the type at
	 * runtime, so the import adds no constraint the file did not already carry — and both
	 * occurrences then shorten, the macro-time one included.
	 */
	public function testOneRuntimeUseLiftsTheMacroBodyGate(): Void {
		final src: String = 'package app;\n\nclass C {\n\n\tmacro static function m() {\n\t\tg(pkg.deep.Foo.a());\n\t}\n\n'
			+ '\tpublic function f():Void {\n\t\tg(pkg.deep.Foo.b());\n\t}\n\n}\n';
		Assert.equals(2, violations(src).length);
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('import pkg.deep.Foo;') != -1, 'import added, got: $out');
		Assert.isTrue(out.indexOf('g(Foo.a());') != -1 && out.indexOf('g(Foo.b());') != -1, 'both shortened, got: $out');
	}

	// --- an imported enum takes its CONSTRUCTOR names too ---

	/**
	 * `import types.BASection;` binds every constructor of that enum as a bare identifier, so the
	 * simple name `Hash` is TAKEN in this file even though the type `module.Hash` sits in its own
	 * package. Verified against the compiler: the constructor wins in expression position over a
	 * same-package class AND over an explicit `import module.Hash;`, in either import order —
	 * `types.BASection should be Class<… module.Module>`.
	 */
	public function testImportedEnumConstructorShadowsTheSamePackageType(): Void {
		final src: String = enumConsumer('import types.BASection;\n\n');
		Assert.equals(0, enumViolations(src).length);
		Assert.equals(src, enumApplyFix(src));
	}

	/** The gate is the IMPORT: an enum in the resolution scope that this file does NOT import binds nothing here. */
	public function testUnimportedEnumConstructorDoesNotShadow(): Void {
		final src: String = enumConsumer('');
		Assert.equals(2, enumViolations(src).length);
		Assert.isTrue(enumApplyFix(src).indexOf('g(Hash);') != -1, 'shortened, got: ${enumApplyFix(src)}');
	}

	// --- the index proof ---

	public function testWithoutAResolutionIndexTheRunIsReportOnly(): Void {
		final src: String = consumer('import pkg.deep.Mod.Sub;\n\n', 'pkg.deep.Sub');
		final check: ShortenTypeRef = new ShortenTypeRef();
		// A bare plugin carries no resolution scope, so nothing PROVES which declaration
		// `pkg.deep.Sub` names — the finding stands, the rewrite does not.
		final vs: Array<Violation> = check.run([{ file: 'app/C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'degraded message, got: ${vs[0].message}');
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length, 'an unproven finding yields no edit');
	}

	/** An unproven path is never even OFFERED the add-import arm — the freeness exemption is gated on the proof. */
	public function testAnUnprovenRepeatedPathGainsNoImport(): Void {
		final src: String = inClass('', '\t\tg(zz.absent.Ghost.a());\n\t\tg(zz.absent.Ghost.b());\n');
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	// --- type parameters, per-occurrence independence ---

	public function testTypeParameterShortens(): Void {
		Assert.equals(
			'\t\tfinal v:Array<Sub> = g();', annotationLine(applyFix(consumer('import pkg.deep.Mod.Sub;\n\n', 'Array<pkg.deep.Sub>')))
		);
	}

	/**
	 * Each nominal of an annotation is its OWN occurrence with its own span and its own proof —
	 * the type-refs projection hands them out one node each. Here BOTH components change (`Sub`
	 * is the hybrid, `Foo` has an exact import) but only `Sub` is in the resolution scope, so the
	 * proven half is repaired and the unproven half is reported and left exactly as written. The
	 * annotation is no longer an all-or-nothing unit, which it had to be while it was reprinted
	 * from one sliced string.
	 */
	public function testProvenAndUnprovenComponentsAreIndependent(): Void {
		final src: String = consumer('import pkg.deep.Mod.Sub;\nimport pkg.deep.Foo;\n\n', 'Map<pkg.deep.Sub, pkg.deep.Foo>');
		final report: Array<{ file: String, source: String }> = [{ file: 'app/C.hx', source: src }];
		final check: ShortenTypeRef = new ShortenTypeRef();
		// Only `pkg/deep/Mod.hx` joins the scope, so `pkg.deep.Foo` resolves to no declaration.
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({
			declared: true,
			sources: () -> {report: report, library: new LibrarySources([{ file: 'pkg/deep/Mod.hx', source: MOD_SOURCE }]) }
		});
		final vs: Array<Violation> = check.run(report, scoped);
		Assert.equals(2, vs.length);
		Assert.equals(1, [for (v in vs) if (v.message.indexOf('report-only') == -1) v].length, 'exactly one proven half');
		Assert.equals('\t\tfinal v:Map<Sub, pkg.deep.Foo> = g();', annotationLine(applyFixWith(src, scoped, report)));
	}

	// --- shapes the annotation-region slice used to refuse ---

	public function testCommentInsideTheAnnotationNoLongerMatters(): Void {
		// The region slice carried the comment into the reprint, so it refused the whole
		// annotation; the projection hands out the nominal's own span and the comment is trivia.
		final src: String = 'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tpublic function f():Void {\n'
			+ '\t\tfinal v:/* c */ pkg.deep.Foo = g();\n\t}\n\n}\n';
		Assert.equals(1, violations(src).length);
		Assert.isTrue(applyFix(src).indexOf('final v:/* c */ Foo = g();') != -1, 'shortened, got: ${applyFix(src)}');
	}

	public function testMultiDeclaratorStatementShortens(): Void {
		// The region slice spanned both declarators of the one grammar node and refused on the
		// depth-0 comma; the projection addresses the annotation itself.
		final src: String = 'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tpublic function f():Void {\n'
			+ '\t\tvar a:pkg.deep.Foo, b = null;\n\t}\n\n}\n';
		Assert.isTrue(applyFix(src).indexOf('var a:Foo, b = null;') != -1, 'shortened, got: ${applyFix(src)}');
	}

	public function testTopLevelAnonymousStructureAnnotationShortens(): Void {
		// The region slice needed an `=` after the `:` and the grammar makes the `Anon` child 0,
		// so the region came out empty; the projection carries a node per anon FIELD type.
		final src: String = 'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tpublic function f():Void {\n'
			+ '\t\tfinal u:{x:pkg.deep.Foo} = g();\n\t}\n\n}\n';
		Assert.isTrue(applyFix(src).indexOf('final u:{x:Foo} = g();') != -1, 'shortened, got: ${applyFix(src)}');
	}

	/**
	 * An anonymous structure used as a GENERIC ARGUMENT. The type-refs projection used to stop
	 * at the generic head — `QueryWalkerLowering` emitted nothing for an `Anon` reached through a
	 * `type` field — so no node carried the nominal inside the braces and the check could not see
	 * it. Every other nesting (anon at the annotation head, generic in generic, function type in
	 * generic) already projected.
	 */
	public function testAnonymousStructureInsideAGenericArgumentShortens(): Void {
		final src: String = consumer('import pkg.deep.Foo;\n\n', 'Array<{x:pkg.deep.Foo}>');
		Assert.equals(1, violations(src).length, 'the qualified name inside the anon is reachable');
		Assert.equals('\t\tfinal v:Array<{x:Foo}> = g();', annotationLine(applyFix(src)));
	}

	/**
	 * Occurrences inside anon structures COUNT toward `IMPORT_THRESHOLD` like any other — and the
	 * import they earn lands once, not once per occurrence.
	 */
	public function testAnonymousStructureOccurrencesCountTowardTheImportThreshold(): Void {
		final src: String = inClass('', '\t\tfinal a:Array<{x:pkg.deep.Foo}> = g();\n\t\tfinal b:Array<{y:pkg.deep.Foo}> = g();\n');
		final out: String = applyFix(src);
		Assert.equals(1, out.split('import pkg.deep.Foo;').length - 1, 'exactly one import added, got: $out');
		Assert.isTrue(out.indexOf('final a:Array<{x:Foo}> = g();') != -1, 'first use shortened, got: $out');
		Assert.isTrue(out.indexOf('final b:Array<{y:Foo}> = g();') != -1, 'second use shortened, got: $out');
	}

	public function testAnnotationWithoutAnInitializerShortens(): Void {
		final src: String =
			'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tvar v:pkg.deep.Foo;\n\t}\n\n}\n';
		Assert.isTrue(applyFix(src).indexOf('var v:Foo;') != -1, 'shortened, got: ${applyFix(src)}');
	}

	public function testUnannotatedLocalIsNotFlagged(): Void {
		final src: String =
			'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tfinal v = g();\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	// --- idempotency ---

	public function testFixIsIdempotent(): Void {
		final once: String = applyFix(consumer('import pkg.deep.Mod.Sub;\n\n', 'pkg.deep.Sub'));
		Assert.equals(0, violations(once).length, 'the rewritten source is already canonical');
		Assert.equals(once, applyFix(once));
	}

	public function testQualifiedRepairIsIdempotent(): Void {
		final once: String = applyFix(consumer('', 'pkg.deep.Sub'));
		Assert.equals(0, violations(once).length);
		Assert.equals(once, applyFix(once));
	}

	// --- registration ---

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('shorten-type-ref'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('shorten-type-ref'));
	}

	public function testIsDefaultOff(): Void {
		Assert.isTrue(new ShortenTypeRef() is DefaultOff);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, new ShortenTypeRef().run([{ file: 'C.hx', source: 'class Bad { function f() { final v:' }], new HaxeQueryPlugin()).length
		);
	}

	/** A consumer in `package app;` carrying `imports` verbatim and one local annotated `annotation`. */
	private function consumer(imports: String, annotation: String): String {
		return inClass(imports, '\t\tfinal v:$annotation = g();\n');
	}

	/** A consumer in `package app;` carrying `imports` verbatim and `body` as its one method's statements. */
	private function inClass(imports: String, body: String): String {
		return 'package app;\n\n${imports}class C {\n\n\tpublic function f():Void {\n$body\t}\n\n}\n';
	}

	/** The declaration line of the local named `v`, for an exact whole-line assertion. */
	private function annotationLine(source: String): String {
		for (line in source.split('\n')) {
			final trimmed: String = StringTools.trim(line);
			if (trimmed.indexOf('final v') == 0 || trimmed.indexOf('var v') == 0) return line;
		}
		return source;
	}

	private function scopedPlugin(report: Array<{ file: String, source: String }>): CachingGrammarPlugin {
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({
			declared: true,
			sources: () -> {
				report: report,
				library: new LibrarySources([
					{ file: 'pkg/deep/Mod.hx', source: MOD_SOURCE },
					{ file: 'pkg/deep/Foo.hx', source: FOO_SOURCE },
					{ file: 'pkg/deep/Bar.hx', source: BAR_SOURCE },
					{ file: 'pkg/Holder.hx', source: HOLDER_SOURCE },
					{ file: 'other/Foo.hx', source: OTHER_FOO_SOURCE }
				])
			}
		});
		return scoped;
	}

	/** A `module.Clean` consumer carrying `imports` verbatim and two `module.Hash` references. */
	private function enumConsumer(imports: String): String {
		return 'package module;\n\n${imports}class Clean {\n\n\tpublic function f():Void {\n'
			+ '\t\tg(module.Hash);\n\t\tg(module.Hash);\n\t}\n\n}\n';
	}

	/** The enum-shadow scope: the consumer itself, the enum that binds `Hash`, and the class of the same name. */
	private function enumPlugin(report: Array<{ file: String, source: String }>): CachingGrammarPlugin {
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({
			declared: true,
			sources: () -> {
				report: report,
				library: new LibrarySources([
					{ file: 'types/BASection.hx', source: BASECTION_SOURCE },
					{ file: 'module/Hash.hx', source: MODULE_HASH_SOURCE }
				])
			}
		});
		return scoped;
	}

	private function enumViolations(src: String): Array<Violation> {
		final report: Array<{ file: String, source: String }> = [{ file: 'module/Clean.hx', source: src }];
		return new ShortenTypeRef().run(report, enumPlugin(report));
	}

	private function enumApplyFix(src: String): String {
		final report: Array<{ file: String, source: String }> = [{ file: 'module/Clean.hx', source: src }];
		return applyFixWith(src, enumPlugin(report), report);
	}

	private function violations(src: String): Array<Violation> {
		final report: Array<{ file: String, source: String }> = [{ file: 'app/C.hx', source: src }];
		return new ShortenTypeRef().run(report, scopedPlugin(report));
	}

	private function applyFix(src: String): String {
		final report: Array<{ file: String, source: String }> = [{ file: 'app/C.hx', source: src }];
		return applyFixWith(src, scopedPlugin(report), report);
	}

	private function applyFixWith(src: String, plugin: CachingGrammarPlugin, report: Array<{ file: String, source: String }>): String {
		final check: ShortenTypeRef = new ShortenTypeRef();
		return CheckFixture.applyEdits(src, check.fix(src, check.run(report, plugin), plugin));
	}

}
