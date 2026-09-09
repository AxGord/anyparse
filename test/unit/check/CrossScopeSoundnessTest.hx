package unit.check;

import anyparse.check.Check.CrossFileFix;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * ONE fixture for the whole class of defect S177, S179 and S180 found one call site at a time: a
 * check that asks the REPORT-scope index a question only the RESOLUTION scope can answer, and
 * reads "not found in the files this run was given" as "does not exist".
 *
 * The shape is always the same and is exactly what `hxq patch <one file> --write --fix` runs: the
 * report scope is ONE file, the project declares `resolutionRoots`, and a second file reaches into
 * the first by a route no single-file analysis can see — an `@:access` grant, an `@:allow` grant, a subtype, a reflection call
 * naming the member, a write to a public field, a hand-written call to an accessor. Every previously found site licensed a REWRITE
 * that way: `unused-private` called a live member dead (S177), `unused-parameter` deleted a
 * parameter a cross-file caller still passes (S179), `naming` renamed a field and orphaned an
 * `@:access` grantee (S179), and `naming` renamed a field a reflection call in another file reads
 * by name (S180).
 *
 * So the assertion is differential rather than per-rule, and it runs over `Linter.builtins()` —
 * the roster itself, so a new check joins it by being registered: for every cell, whatever the
 * NARROW-report run writes into the declaring file, the WIDE-report run over the same two files
 * must write too. An edit only the narrow run produces is an edit licensed by a file the run could
 * not see, which is the defect in its writing form. The sibling assertion covers
 * the reporting form: a `CrossFileFix` may only name files the report scope holds.
 *
 * S187 re-accounted what the fixture actually puts under those differentials. Two of the five rules writing in the narrow arm
 * were doing so on evidence the cells never supplied — `prefer-final-field` licenses `final` on the absence of a cross-file WRITE
 * and every cell only READ, `prefer-inline` licenses `inline` on the absence of an OVERRIDE and no cell declared one — so the
 * `access-write` and `subtype-override` cells supply exactly those two, and `FIX_WRITERS` replaced the count-of-five floor with a
 * census the fixture takes of itself. The second cell caught a live one on its first run: `prefer-inline`s subtype gate asked the
 * REPORT index, so a one-file `--fix` inlined a method an unlinted subtype overrides (arm `M-INLINE-SUBTYPE-REPORT-INDEX`). S191 (T895)
 * then built the six cells S187 had only NAMED — one per registered autofix of the same license shape that no cell reached, each
 * declaring a candidate the sibling file reaches beside a control it does not — and one of those, `accessor-call`, caught the next
 * live one: `orphan-accessor`s accessor-CALL scan walked the report files while the reflection scan on the line above it walked
 * the resolution scope, so a one-file `--fix` deleted a public `get_x` a sibling calls by hand (arm `M-ORPHAN-ACCESSOR-REPORT-SCOPE`).
 * Two cells, two live defects, in the two slices that added them: this fixture pays for itself by being EXTENDED, not by being re-run.
 *
 * `KNOWN_DIVERGENCES` is the escape hatch and it is EMPTY by contract. A line there is a filed
 * defect with an address, never a way to keep this green.
 *
 * A THIRD arm asks what those four repairs never did: what a project that declares `resolutionLibs`
 * and no `resolutionRoots` gets. The scope is still DECLARED and it holds an installed library, but
 * not one file of the project's own — the key fills `projectRoots` AND joins the library half, so
 * without it the widened index and the reflection scan are BOTH starved.
 * `LIBS_ONLY_REGRESSIONS` is what that costs over the same cells, and there the mitigation is a
 * sentence rather than soundness: source roots nobody declared cannot be invented, so the tool says so
 * out loud (`ConfigDisagreement.warnMissingProjectRoots`).
 */
class CrossScopeSoundnessTest extends Test {

	/** The declaring file — the only one in the report scope of the narrow arm. */
	private static inline final DECL_FILE: String = 'pkg/A.hx';

	/** The reaching file — outside the report scope of the narrow arm, inside its resolution scope. */
	private static inline final REACH_FILE: String = 'pkg/B.hx';

	/** The one file a `resolutionLibs`-only scope holds: installed, third-party, and no relation to the project. */
	private static inline final LIB_FILE: String = 'lib/third/Third.hx';

	/** A declared `resolutionRoots` file that reaches nothing — the roots half of the library-only placement. */
	private static inline final ROOT_FILE: String = 'pkg/C.hx';

	/** The reacher sits in `resolutionRoots` AND in the library — what `LintCommand` builds for a project declaring roots. */
	private static inline final ROOTS_AND_LIBRARY: String = 'roots-and-library';

	/**
	 * The reacher sits in the LIBRARY half alone, `resolutionRoots` holding an inert project file — so the
	 * roots are declared, `RefactorSupport.resolutionProjectSourcesOf` answers with files, and the reacher
	 * is not among them. T868's discriminator: the two seams differ HERE and nowhere else.
	 */
	private static inline final LIBRARY_ONLY: String = 'library-only';

	/** `resolutionLibs` declared and `resolutionRoots` absent — the Pony shape `LIBS_ONLY_REGRESSIONS` prices. */
	private static inline final LIBS_ONLY: String = 'libs-only';

	/** A declaration file whose private members are also read WITHIN it. */
	private static final A_USED: String = 'package pkg;\n\nclass A {\n\n\tprivate var My_Field: Int = 0;\n\n'
		+ '\tpublic function new() {}\n\n\tpublic function read(): Int {\n\t\treturn My_Field + helper(1, 2);\n\t}\n\n'
		+ '\tprivate function helper(a: Int, b: Int): Int {\n\t\treturn a;\n\t}\n\n}\n';

	/** The same declarations with NO in-file read — the `unused-private` / `unused-parameter` shape. */
	private static final A_UNUSED: String = 'package pkg;\n\nclass A {\n\n\tprivate var My_Field: Int = 0;\n\n'
		+ '\tpublic function new() {}\n\n\tprivate function helper(a: Int, b: Int): Int {\n\t\treturn a;\n\t}\n\n}\n';

	/** `A_USED` granting its private members to `B` from its own header. */
	private static final A_ALLOW: String = 'package pkg;\n\n@:allow(pkg.B)\nclass A {\n\n\tprivate var My_Field: Int = 0;\n\n'
		+ '\tpublic function new() {}\n\n\tpublic function read(): Int {\n\t\treturn My_Field + helper(1, 2);\n\t}\n\n'
		+ '\tprivate function helper(a: Int, b: Int): Int {\n\t\treturn a;\n\t}\n\n}\n';

	/** The reacher that takes the access by `@:access` on itself. */
	private static final B_ACCESS: String = 'package pkg;\n\n@:access(pkg.A)\nclass B {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function reach(a: A): Int {\n\t\treturn a.My_Field + a.helper(3, 4);\n\t}\n\n}\n';

	/** The reacher that inherits the access — a Haxe `private` member is visible to a subtype. */
	private static final B_SUBTYPE: String = 'package pkg;\n\nclass B extends A {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n'
		+ '\tpublic function reach(): Int {\n\t\treturn My_Field + helper(3, 4);\n\t}\n\n}\n';

	/** The reacher whose access comes from the DECLARING file's `@:allow`, so nothing in B says so. */
	private static final B_PLAIN: String = 'package pkg;\n\nclass B {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function reach(a: A): Int {\n\t\treturn a.My_Field + a.helper(3, 4);\n\t}\n\n}\n';

	/** The reacher that names the member as a STRING inside a reflection call. */
	private static final B_REFLECT: String = 'package pkg;\n\nclass B {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function reach(a: A): Dynamic {\n\t\treturn Reflect.field(a, \'My_Field\');\n\t}\n\n}\n';

	/**
	 * The reacher whose reflective string names the METHOD rather than the field — the evidence
	 * `prefer-inline` reads, and the only cell that supplies it.
	 *
	 * The field cell above cannot stand in for it: `prefer-inline` gates on METHOD names, so a
	 * `Reflect.field(a, 'My_Field')` leaves its scan silent and its report-scoped half of the
	 * defect invisible. What it licenses is real and measured on Haxe 4.3.7: under `--dce full` a
	 * method both statically called and read reflectively answers FOUND while plain and MISSING
	 * once marked `inline`.
	 *
	 * It keeps the FIELD name beside the method one so the cell stays a `reflection` cell for
	 * `naming` too, and S191 measured what dropping it costs: exactly one line, `edit:naming@reflection-method`,
	 * leaves `LIBS_ONLY_REGRESSIONS` — both arms then rename a field nothing reaches, so the cell stops
	 * pricing the FIELD route while saying nothing new about the method one. `FIX_WRITERS` does not move,
	 * and the doc here claimed it would ("a sixth rule in `FIX_WRITERS`"): `naming` reaches that census
	 * through T895's cells, whose sibling files spell no field name at all, and never through this one.
	 */
	private static final B_REFLECT_METHOD: String = 'package pkg;\n\nclass B {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function reach(a: A): Dynamic {\n\t\tReflect.field(a, \'My_Field\');\n'
		+ '\t\treturn Reflect.field(a, \'helper\');\n\t}\n\n}\n';

	/**
	 * The reacher that WRITES the private field rather than reading it — the evidence
	 * `prefer-final-field` needs and no other cell supplies.
	 */
	private static final B_WRITE: String = 'package pkg;\n\n@:access(pkg.A)\nclass B {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function reach(a: A): Void {\n\t\ta.My_Field = 5;\n\t}\n\n}\n';

	/**
	 * The reacher that OVERRIDES the private method — the evidence `prefer-inline` needs, and the
	 * one route by which a member this file calls trivial is not.
	 */
	private static final B_OVERRIDE: String = 'package pkg;\n\nclass B extends A {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n'
		+ '\toverride private function helper(a: Int, b: Int): Int {\n\t\treturn b;\n\t}\n\n}\n';

	/** A haxelib source — what `resolutionLibs` alone puts in the scope, and it reaches nothing of the project. */
	private static final LIB_THIRD_PARTY: String = 'package third;\n\nclass Third {\n\n\tpublic function new() {}\n\n}\n';

	/** A declared `resolutionRoots` file that reaches nothing — what the roots half holds while the reacher is elsewhere. */
	private static final C_INERT: String = 'package pkg;\n\nclass C {\n\n\tpublic function new() {}\n\n}\n';

	/** The reflective reacher with a token the grammar cannot read — present in the scope, answerable only as raw text. */
	private static final B_REFLECT_UNPARSEABLE: String = 'package pkg;\n\nclass B {\n\n\t?? ?? ??\n\n'
		+ '\tpublic function reach(a: A): Dynamic {\n\t\treturn Reflect.field(a, \'My_Field\');\n\t}\n\n}\n';

	/**
	 * A declaration carrying TWO public fields of one shape — the route's target and a control the
	 * route does not reach. T895's cells all take this form, and it is what makes each of them
	 * assert in both directions at once: the control proves the rule fires here at all (it is what
	 * puts the rule in `FIX_WRITERS`), the target proves the cross-file evidence stops it.
	 * A one-candidate cell can only ever show one of the two.
	 */
	private static final A_PUBLIC_FIELD: String = 'package pkg;\n\nclass A {\n\n\tpublic var reached: Int = 0;\n'
		+ '\tpublic var lonely: Int = 0;\n\n\tprivate var My_Field: Int = 0;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function read(): Int {\n\t\treturn My_Field;\n\t}\n\n}\n';

	/** The same pair, each field ALSO written inside the class — `prefer-read-only-field`'s candidate shape. */
	private static final A_PUBLIC_MUTATED: String = 'package pkg;\n\nclass A {\n\n\tpublic var reached: Int = 0;\n'
		+ '\tpublic var lonely: Int = 0;\n\n\tprivate var My_Field: Int = 0;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function bump(): Void {\n\t\treached = reached + 1;\n\t\tlonely = lonely + 1;\n\t}\n\n'
		+ '\tpublic function read(): Int {\n\t\treturn My_Field;\n\t}\n\n}\n';

	/** Two read-only properties over private backing fields, each getter trivial — `trivial-getter`'s collapse shape. */
	private static final A_PROPERTY: String = 'package pkg;\n\nclass A {\n\n\tpublic var reached(get, never): Int;\n'
		+ '\tpublic var lonely(get, never): Int;\n\n\tprivate var _reached: Int = 0;\n\tprivate var _lonely: Int = 0;\n'
		+ '\tprivate var My_Field: Int = 0;\n\n\tpublic function new() {}\n\n\tprivate function get_reached(): Int {\n'
		+ '\t\treturn _reached;\n\t}\n\n\tprivate function get_lonely(): Int {\n\t\treturn _lonely;\n\t}\n\n'
		+ '\tpublic function read(): Int {\n\t\treturn My_Field;\n\t}\n\n}\n';

	/** Two `get_` methods no property slot reaches — `orphan-accessor`'s deletion shape. */
	private static final A_ACCESSOR: String = 'package pkg;\n\nclass A {\n\n\tprivate var My_Field: Int = 0;\n\n'
		+ '\tpublic function new() {}\n\n\tpublic function get_reached(): Int {\n\t\treturn My_Field;\n\t}\n\n'
		+ '\tpublic function get_lonely(): Int {\n\t\treturn My_Field;\n\t}\n\n}\n';

	/** Two scalar `static final` constants — `inline-constant`'s candidate shape. */
	private static final A_CONSTANT: String = 'package pkg;\n\nclass A {\n\n\tprivate static final REACHED: Int = 1;\n'
		+ '\tprivate static final LONELY: Int = 2;\n\n\tprivate var My_Field: Int = 0;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function read(): Int {\n\t\treturn My_Field + REACHED + LONELY;\n\t}\n\n}\n';

	/** The same two constants as INSTANCE finals — `static-constant`'s promotion shape. */
	private static final A_INSTANCE_CONSTANT: String = 'package pkg;\n\nclass A {\n\n\tprivate final _reached: Int = 1;\n'
		+ '\tprivate final _lonely: Int = 2;\n\n\tprivate var My_Field: Int = 0;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function read(): Int {\n\t\treturn My_Field + _reached + _lonely;\n\t}\n\n}\n';

	/** The reacher that writes a PUBLIC field — no grant needed, and no single-file scan can see it. */
	private static final B_PUBLIC_WRITE: String =
		'package pkg;\n\nclass B {\n\n\tpublic function new() {}\n\n\tpublic function reach(a: A): Void {\n\t\ta.reached = 5;\n\t}\n\n}\n';

	/** The subtype that reads a private member of `A` by its bare name — the route both collapse rules gate on. */
	private static final B_SUBTYPE_FIELD: String = 'package pkg;\n\nclass B extends A {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n'
		+ '\tpublic function reach(): Int {\n\t\treturn _reached;\n\t}\n\n}\n';

	/** The reacher that CALLS an accessor by hand — what stops `orphan-accessor` deleting a method Haxe never calls but code does. */
	private static final B_ACCESSOR_CALL: String = 'package pkg;\n\nclass B {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function reach(a: A): Int {\n\t\treturn a.get_reached();\n\t}\n\n}\n';

	/** The reacher whose reflective string names a CONSTANT — the value `inline` erases. */
	private static final B_CONSTANT_REFLECT: String = 'package pkg;\n\nclass B {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function reach(a: A): Dynamic {\n\t\treturn Reflect.field(a, \'REACHED\');\n\t}\n\n}\n';


	/** The two-file cells: one per route by which the second file reaches the first. */
	private static final CELLS: Array<Cell> = [
		{ name: 'access-grant', decl: A_USED, grantee: B_ACCESS },
		{ name: 'subtype', decl: A_USED, grantee: B_SUBTYPE },
		{ name: 'allow-grant', decl: A_ALLOW, grantee: B_PLAIN },
		{ name: 'reflection', decl: A_USED, grantee: B_REFLECT },
		{ name: 'access-grant-unread-in-file', decl: A_UNUSED, grantee: B_ACCESS },
		{ name: 'reflection-unread-in-file', decl: A_UNUSED, grantee: B_REFLECT },
		{ name: 'access-write', decl: A_USED, grantee: B_WRITE },
		{ name: 'subtype-override', decl: A_USED, grantee: B_OVERRIDE },
		{ name: 'reflection-method', decl: A_USED, grantee: B_REFLECT_METHOD },
		{ name: 'public-write', decl: A_PUBLIC_FIELD, grantee: B_PUBLIC_WRITE },
		{ name: 'public-internal-write', decl: A_PUBLIC_MUTATED, grantee: B_PUBLIC_WRITE },
		{ name: 'subtype-backing-field', decl: A_PROPERTY, grantee: B_SUBTYPE_FIELD },
		{ name: 'accessor-call', decl: A_ACCESSOR, grantee: B_ACCESSOR_CALL },
		{ name: 'constant-reflection', decl: A_CONSTANT, grantee: B_CONSTANT_REFLECT },
		{ name: 'subtype-constant', decl: A_INSTANCE_CONSTANT, grantee: B_SUBTYPE_FIELD }
	];

	/**
	 * The `<rule>@<cell>` pairs whose narrow-report `fix` writes an edit the wide-report run does
	 * not. EMPTY is the contract; a line here is a filed defect with an address, never a way to
	 * keep this test green.
	 */
	private static final KNOWN_EDIT_DIVERGENCES: Array<String> = [];

	/** The same list for the REPORTING form of the defect. Empty by the same contract. */
	private static final KNOWN_REPORT_DIVERGENCES: Array<String> = [];

	/**
	 * The `<kind>:<rule>@<cell>` pairs a reflective string answers differently depending on WHICH half
	 * of one declared resolution scope it sits in. EMPTY by the same contract as the two above, and
	 * that emptiness IS T868's verdict: the two seams the check layer forked over — the wide
	 * `RefactorSupport.widestScopeIndex` and the narrow `resolutionProjectSourcesOf` — are now one
	 * (`ReflectionScan.scopeFiles`), so a library source and a `resolutionRoots` source carry the same
	 * weight for a name-keyed question.
	 */
	private static final KNOWN_PLACEMENT_DIVERGENCES: Array<String> = [];

	/**
	 * The rules whose per-file `fix` writes on the declaring file in the NARROW arm — a CENSUS the
	 * fixture takes of itself, asserted by EQUALITY rather than by a floor.
	 *
	 * The floor it replaces (`exercised.length >= 5`) counted rules, not coverage, and two of its
	 * five were counted while the fixture supplied nothing they could react to:
	 * `prefer-final-field` licenses `final` on the absence of a WRITE and every cell only READ the
	 * field; `prefer-inline` licenses `inline` on the absence of an OVERRIDE and no cell declared
	 * one. The `access-write` and `subtype-override` cells supply exactly those two, and the second
	 * of them put `prefer-inline` into both differentials at once — its subtype gate asked the
	 * REPORT index, so a single-file `--fix` inlined a method an unlinted subtype overrides.
	 *
	 * What makes a rule belong here is the shape of its LICENSE, not the shape of its edit: it
	 * rewrites or removes a DECLARATION on the strength of a reference, write or override being
	 * ABSENT, and a file outside the report scope can supply any of the three. S187 read six
	 * registered autofixes of that shape off `LintCommand.partitionChecks`'s own `fullScopeIds`
	 * comments and found no cell reaching any of them; T895 built one cell each — `public-write`
	 * for `prefer-final-public-field`, `public-internal-write` for `prefer-read-only-field`,
	 * `subtype-backing-field` for `trivial-getter`, `accessor-call` for `orphan-accessor`,
	 * `constant-reflection` for `inline-constant`, `subtype-constant` for `static-constant`. Every
	 * one declares TWO candidates of one shape, the one the sibling file reaches and a control it
	 * does not, so the SAME cell proves the rule writes here at all (this list) and that the
	 * cross-file evidence stops it (the differentials); a one-candidate cell can only show one of
	 * the two, and a rule that only ever refused would fail the roster containment instead of
	 * joining this census.
	 *
	 * `accessor-call` caught a live defect on its first run, the second such find after `subtype-override`'s:
	 * `orphan-accessor`'s accessor-CALL scan walked the REPORT files while the reflection scan on the line
	 * above it walked `ReflectionScan.scopeFiles`, so a one-file `--fix` in a project declaring
	 * `resolutionRoots` DELETED a public `get_x` a sibling calls by hand — two deletions where the run over
	 * both files wrote one (arm `M-ORPHAN-ACCESSOR-REPORT-SCOPE`).
	 *
	 * The seven `fullScopeIds` no cell reaches are not all one class, and their own comments give the
	 * split. `map-keys-lookup`, `prefer-index-access`, `prefer-static-extension` and
	 * `redundant-tostring` need a type RESOLVED before they rewrite, so a narrow scope makes them MISS
	 * — never overreach — and there is no unsound direction to pin. `field-init-at-declaration` reads
	 * the same `FieldWriteIndex` the finalizing rules do, but its edit MOVES the sole assignment onto
	 * the declaration and no external write can precede construction, so a narrow scope costs its
	 * sole-assignment CLAIM rather than the behaviour the move preserves. Two DO share the license
	 * shape exactly and have no cell: `redundant-map-exists`, whose comment says an unseen writer
	 * turns an unprovable site into a wrongly PROVEN one, and `prefer-typed-throw`, where an absent
	 * `catch (e:String)` licenses a boxing the wider scope refuses. They are backlog items T918 and
	 * T919, not lines to add here.
	 *
	 * Every autofix OUTSIDE that class edits a node whose references cannot leave the file it is
	 * handed — a local, a case binder, a statement, an expression, an arm, a comment, whitespace —
	 * so a wider scope cannot change its answer and there is nothing to compare.
	 *
	 * `naming` sits in BOTH this list and `CROSS_FILE_WRITERS` since T895, and that is not a
	 * duplication. On the older cells the sibling file spells `My_Field`, so the rename has to leave
	 * through `crossFileFix` and `fix` emits nothing; T895's cells give `naming` a violation no
	 * sibling names, and there the in-file rename IS a `fix` edit.
	 *
	 * An equality here is the anti-rot half: a rule dropping out is the vacuity regression the old
	 * floor was watching for, and a NEW registered rule writing here is one nobody has classified
	 * yet. Neither is a line to edit until the reason is in this doc.
	 */
	private static final FIX_WRITERS: Array<String> = [
		'inline-constant',
		'naming',
		'orphan-accessor',
		'prefer-final-field',
		'prefer-final-public-field',
		'prefer-inline',
		'prefer-read-only-field',
		'static-constant',
		'trivial-getter',
		'unused-parameter',
		'unused-private',
		'unused-public-member'
	];

	/**
	 * The same family reached through `crossFileFix` instead of `fix`: `naming` refuses an in-file
	 * rename whenever a file outside the report scope spells the name or declares a subtype, and what
	 * it does emit leaves through the cross-file seam.
	 *
	 * It is NOT "never in the census above" — that was true only while every cell's sibling file spelled
	 * `My_Field`. T895's six cells give `naming` a violation no sibling names, so its in-file rename
	 * lands as an ordinary `fix` edit there and it appears in BOTH lists. The roster reads their union,
	 * so the overlap costs nothing; what it means is that a `naming` line vanishing from `FIX_WRITERS`
	 * is a statement about THOSE cells, not about the cross-file seam this list stands for.
	 *
	 * Its non-vacuity on the reporting side is asserted per cell, where the flag is observable whichever
	 * seam the edit takes.
	 */
	private static final CROSS_FILE_WRITERS: Array<String> = ['naming'];

	/**
	 * What a project declaring `resolutionLibs` and NO `resolutionRoots` loses — MEASURED, and the one
	 * list in this class that is not empty by contract.
	 *
	 * FORTY entries over the fifteen cells (twenty-seven over the nine before S191, twenty-four over the
	 * eight before S190, fourteen over the six the fixture had before S187), and unchanged by T868 — a
	 * libs-only scope holds the sibling in NEITHER half, so widening the name-keyed seam buys nothing
	 * here. TWENTY-SIX are WRITES and FOURTEEN are findings, which is the same defect one step earlier.
	 * Ten `edit:naming@` lines say the rename reaches ten of the fifteen cells, five
	 * `edit:unused-parameter@` that a parameter goes with cross-file callers still passing it, two
	 * `edit:unused-private@` that a live member is deleted.
	 *
	 * The ten S187 added are the two cells that supply cross-file WRITE and OVERRIDE evidence:
	 * `prefer-final-field` makes a field final that a grantee assigns, `prefer-inline` inlines a method a
	 * subtype overrides, and `naming` / `unused-parameter` lose the same proofs on the two new routes they
	 * lose on the old ones. The three S190 added are the `reflection-method` cell, where a libs-only scope
	 * loses BOTH reflective strings at once: `naming` renames the field one, `prefer-inline` inlines the
	 * method the other names.
	 *
	 * The thirteen S191 added are T895's six license-class cells, and each names a repair that a declared
	 * `resolutionRoots` makes and this scope shape undoes:
	 *
	 * - `prefer-final-public-field@public-write` — the sibling's `a.reached = 5` is invisible, the field
	 *   reads as never reassigned and becomes `final`; the sibling then does not compile.
	 * - `prefer-read-only-field@public-internal-write` — the same write lost, the field reads as written
	 *   only internally and gets `(default, null)`; same break at the same line.
	 * - `trivial-getter@subtype-backing-field` — the subtype's read of `_reached` is gone, so the property
	 *   collapses and DELETES the backing field the subtype still reads.
	 * - `static-constant@subtype-constant` — the subtype's mention of `_reached` is gone, so the instance
	 *   final is promoted to `static` and the subtype's unqualified read stops resolving.
	 * - `inline-constant@constant-reflection` — the sibling's `Reflect.field(a, 'REACHED')` is gone, so
	 *   `inline` erases the constant's runtime value and that read silently answers null.
	 * - `naming@subtype-backing-field` and `naming@subtype-constant` — the sibling declares a SUBTYPE, and
	 *   `naming` defers an in-file rename to `crossFileFix` whenever one exists. Here the subtype does not
	 *   spell `My_Field`, so the rename is harmless in fact; the entry prices the missing PROOF, which is
	 *   the same one the `subtype` cell loses where it is NOT harmless.
	 * - `orphan-accessor@accessor-call` is the one entry with no `report:` twin, and the asymmetry is the
	 *   point: both arms report both accessors as orphans at the same severity — nothing in either chain
	 *   declares the property — and only the DELETION verdict moves, so the cost exists in edits alone.
	 *   A list of findings would have missed it entirely.
	 *
	 * One cell is absent by right: `allow-grant` puts the `@:allow` in the DECLARING file, so the narrow
	 * report scope sees the grant without help and both arms refuse alike.
	 */
	private static final LIBS_ONLY_REGRESSIONS: Array<String> = [
		'edit:inline-constant@constant-reflection',
		'edit:naming@access-grant',
		'edit:naming@access-grant-unread-in-file',
		'edit:naming@access-write',
		'edit:naming@reflection',
		'edit:naming@reflection-method',
		'edit:naming@reflection-unread-in-file',
		'edit:naming@subtype',
		'edit:naming@subtype-backing-field',
		'edit:naming@subtype-constant',
		'edit:naming@subtype-override',
		'edit:orphan-accessor@accessor-call',
		'edit:prefer-final-field@access-write',
		'edit:prefer-final-public-field@public-write',
		'edit:prefer-inline@reflection-method',
		'edit:prefer-inline@subtype-override',
		'edit:prefer-read-only-field@public-internal-write',
		'edit:static-constant@subtype-constant',
		'edit:trivial-getter@subtype-backing-field',
		'edit:unused-parameter@access-grant',
		'edit:unused-parameter@access-grant-unread-in-file',
		'edit:unused-parameter@access-write',
		'edit:unused-parameter@subtype',
		'edit:unused-parameter@subtype-override',
		'edit:unused-private@access-grant-unread-in-file',
		'edit:unused-private@reflection-unread-in-file',
		'report:inline-constant@constant-reflection',
		'report:prefer-final-field@access-write',
		'report:prefer-final-public-field@public-write',
		'report:prefer-inline@reflection-method',
		'report:prefer-inline@subtype-override',
		'report:prefer-read-only-field@public-internal-write',
		'report:static-constant@subtype-constant',
		'report:trivial-getter@subtype-backing-field',
		'report:unused-parameter@access-grant',
		'report:unused-parameter@access-grant-unread-in-file',
		'report:unused-parameter@access-write',
		'report:unused-parameter@subtype',
		'report:unused-parameter@subtype-override',
		'report:unused-private@access-grant-unread-in-file'
	];

	/** No check writes into the declaring file an edit the same two files, both reported, refuse. */
	@:pin('control')
	@:killer('M-REFLECTION-REPORT-INDEX-DELETE')
	@:killer('M-INLINE-SUBTYPE-REPORT-INDEX')
	@:killer('M-INLINE-REFLECT-REPORT-SCOPE')
	@:killer('M-ORPHAN-ACCESSOR-REPORT-SCOPE')
	public function testNarrowReportWritesNothingTheWideRunRefuses(): Void {
		Assert.equals(KNOWN_EDIT_DIVERGENCES.join('\n'), narrowOnlyEdits().join('\n'));
	}

	/** No check REPORTS on the declaring file a finding the same two files, both reported, do not. */
	@:pin('control')
	@:killer('M-CONFINEMENT-REPORT-INDEX-DEAD')
	public function testNarrowReportFindsNothingTheWideRunDoesNot(): Void {
		Assert.equals(KNOWN_REPORT_DIVERGENCES.join('\n'), narrowOnlyFindings().join('\n'));
	}

	/**
	 * A cross-file autofix may only name files the report scope holds.
	 *
	 * Reported over BOTH files on purpose. Handed the declaring file ALONE this seam is UNREACHABLE:
	 * `crossFileFix` then gets an index over one file, no cross-file occurrence is expressible, and every
	 * `CrossFileFix` check returns an empty list, so the containment assertion never executes and the test
	 * cannot fail. S184 measured that at 0 slices over the fixture AS IT STOOD — six cells and four
	 * declared arm cuts. That count is a reading of THAT tree, not a standing fact: the fixture now carries
	 * fifteen cells and six arms, and the vacuity argument survives the arithmetic because it is structural
	 * rather than numeric.
	 *
	 * The slice counter is what stops the vacuity returning without anyone re-measuring — it is the one
	 * assertion here that fails when the loop above it produces nothing at all.
	 */
	public function testCrossFileEditsNameOnlyReportedFiles(): Void {
		final reportFiles: Array<String> = [DECL_FILE, REACH_FILE];
		var slices: Int = 0;
		for (cell in CELLS) {
			final report: Array<SourceFile> = [
				{ file: DECL_FILE, source: cell.decl },
				{ file: REACH_FILE, source: cell.grantee }
			];
			final plugin: CachingGrammarPlugin = scoped(report, []);
			final index: SymbolIndex = SymbolIndex.build(report, plugin);
			for (check in Linter.builtins()) {
				final cross: Null<CrossFileFix> = check is CrossFileFix ? cast check : null;
				if (cross == null) continue;
				for (rename in cross.crossFileFix(report, check.run(report, plugin), plugin, index)) for (slice in rename) {
					slices++;
					Assert.isTrue(
						reportFiles.contains(slice.file), '${check.id()}@${cell.name} names ${slice.file}, outside the report scope'
					);
				}
			}
		}
		Assert.isTrue(slices > 0, 'no CrossFileFix produced an edit on this fixture — the containment assertion would guard nothing');
	}

	/**
	 * The fixture is not inert, in both dimensions the two differentials read.
	 *
	 * A differential over two runs that produce NOTHING is green for the wrong reason, and both
	 * assertions above compare a list against an empty one — the exact shape that rots into a
	 * tautology unnoticed. The three rules named here are the ones that DELETE or REWRITE a member
	 * on cross-file reachability evidence, which is the family the whole fixture exists for; a name
	 * dropping out is a coverage regression to look at, never a line to delete.
	 */
	public function testFixtureExercisesTheWritingRules(): Void {
		Assert.equals(FIX_WRITERS.join('\n'), narrowRulesEmittingEdits().join('\n'));
		// `naming` reaches the census above only on the cells whose sibling file does not spell the
		// renamed field — T895's six; on every older cell it REFUSES the in-file rename and what it
		// emits leaves through `crossFileFix` rather than `fix`. Its non-vacuity is therefore asserted
		// on the REPORTING side, where the flag is observable whichever seam the edit takes — and per
		// cell, so reordering `CELLS` cannot quietly re-point this at a different fixture.
		for (cell in CELLS) {
			final keys: Array<String> = findingKeys([{ file: DECL_FILE, source: cell.decl }], [{ file: REACH_FILE, source: cell.grantee }]);
			Assert.isTrue(
				keys.length >= 5, '${cell.name}: only ${keys.length} finding(s) — the reporting differential has nothing to compare'
			);
			Assert.equals(1, keys.filter(k -> k.split('|')[0] == 'naming').length, '${cell.name}: naming must still flag the declaration');
		}
	}

	/**
	 * The Pony shape — `resolutionLibs` declared, `resolutionRoots` ABSENT — puts every proof S177,
	 * S179 and S180 widened back where it started.
	 *
	 * The key starves BOTH halves of the scope, and a one-variable matrix over this fixture says which half costs
	 * what: `projectRoots` empty with the sibling still in the library gave ONE divergence when this was written and
	 * gives ZERO since T868 moved that scan onto `ReflectionScan.scopeFiles`; the sibling gone from the library with
	 * `projectRoots` full gives THIRTEEN, and always did. So every remaining entry reads the index `widestScopeIndex`
	 * hands back, which is `report ∪ library` — on a project declaring roots the library CONTAINS them
	 * (`LintCommand.resolutionThunk` concatenates), on a libs-only one it is haxelibs and the std and not
	 * one file of the project's own.
	 *
	 * So the list above is what `hxq lint <one file> --fix` writes there that the same command in this
	 * project refuses. It shrinks when the two arms CONVERGE, which is a repair in one direction and a
	 * regression of the roots-declared arm in the other — read a shrink together with the two differentials
	 * above, which go red for the second cause. A line APPEARING is a new site of the same defect. Until it
	 * is empty the mitigation is a sentence, not soundness — `ConfigDisagreement.warnMissingProjectRoots`.
	 */
	public function testALibsOnlyScopeLosesProofsTheRootsArmKeeps(): Void {
		Assert.equals(LIBS_ONLY_REGRESSIONS.join('\n'), libsOnlyExtras().join('\n'));
	}

	/**
	 * T868: for a name-keyed reflection question, WHICH half of the declared scope holds the reflective
	 * string must not decide the answer.
	 *
	 * The fork this pins was two seams answering one question. `check/Naming`'s reflection scan asked
	 * `RefactorSupport.widestScopeIndex` — report UNION the library, so an installed haxelib and the std
	 * counted — while `check/UnusedPrivate`'s asked `resolutionProjectSourcesOf`, report UNION the
	 * declared `resolutionRoots` and nothing third-party. Both err toward refusal, so neither was a
	 * correctness bug on its own; what they were is two incompatible precedents for the next site.
	 *
	 * The narrow seam's own argument is what settles it, by not carrying over: it reasons that a WRITE to
	 * a project type's field has to NAME that type, which no haxelib does. A reflective string names no
	 * type at all — `Reflect.field(o, 'name')` reaches a project member from a library without ever
	 * spelling the project — so the exclusion the write proof earns, the reflection proof does not.
	 *
	 * `LIBRARY_ONLY` is what makes the difference observable: `resolutionRoots` is declared and holds one
	 * inert file, so the narrow seam answers with files and simply does not contain the reacher.
	 */
	@:pin('control')
	@:killer('M-REFLECTION-SCOPE-PROJECT-ONLY')
	public function testTheScopeHalfHoldingAReflectiveStringDoesNotMatter(): Void {
		Assert.equals(KNOWN_PLACEMENT_DIVERGENCES.join('\n'), placementDivergences().join('\n'));
	}

	/**
	 * T867: a scope file the PARSER could not read still spells the name, and must license nothing that a
	 * readable one refuses.
	 *
	 * `Naming`'s reflection scan walked `SymbolIndex.allFiles()`, which a skip-parsed file is absent from,
	 * so the reflective read in one contributed no name to refuse on. The confinement proof beside it has
	 * `RawSourceScan.skippedMayReference` for exactly this and the reflection guard had nothing — the
	 * asymmetry T867 names.
	 *
	 * The assertion is one-directional on purpose. An unreadable sibling can only ever make the run MORE
	 * conservative, so the readable arm is the ceiling and the unreadable one has to stay under it;
	 * equality would fail on refusals that are correct.
	 */
	public function testAnUnreadableReflectiveFileLicensesNothingExtra(): Void {
		final arms: { extras: Array<String>, readableEdits: Int, readableFindings: Int } = unreadableExtras();
		// Non-vacuity floor (S184 review): a comparison whose READABLE arm reports and writes nothing
		// passes on nothing. The sibling placements carry the same floor.
		Assert.isTrue(
			arms.readableFindings >= 5,
			'the readable arm reported ${arms.readableFindings} finding(s) on the declaration file — the comparison is vacuous'
		);
		Assert.isTrue(arms.readableEdits > 0, 'the readable arm wrote no edit — the comparison is vacuous');
		Assert.equals('', arms.extras.join('\n'));
	}

	/**
	 * Every rule this fixture PROVES reacts to the resolution scope is in the roster — the
	 * differential that keeps the roster from being a hand list nobody reconciles.
	 *
	 * The proof is a measurement, not a declaration: the report scope is held fixed at the
	 * declaring file and only the declared SHAPE of the resolution scope moves
	 * (`ROOTS_AND_LIBRARY` -> `LIBS_ONLY`), so a rule whose answer differs read the scope, whatever
	 * seam it read it through. That matters because the seams are not one: `unused-private` and
	 * `unused-parameter` ask `RefactorSupport.widestScopeIndex`, `unused-public-member`
	 * `resolutionSourcesOf`, `prefer-final-field` reaches it through `MemberWriteScan`, and a grep
	 * for any fixed list of them undercounts — which is how `prefer-final-field` sat in the old
	 * floor's count of five while nobody had classified it.
	 *
	 * SUBSET rather than equality: a roster entry may be scope-INSENSITIVE on these cells and still
	 * belong (`unused-public-member` deletes `read()` in both scope shapes here, because nothing in
	 * either names it), so the direction with teeth is the other one — a rule reacting to the scope
	 * that no roster entry covers.
	 */
	public function testEveryScopeSensitiveRuleIsInTheRoster(): Void {
		final roster: Array<String> = FIX_WRITERS.concat(CROSS_FILE_WRITERS);
		final sensitive: Array<String> = scopeSensitiveRules();
		// Non-vacuity floor, in the ONE dimension a count belongs in: the measurement itself must
		// have found something, or every containment below holds over nothing.
		Assert.isTrue(sensitive.length > 0, 'no rule reacted to the resolution scope — the containment holds over nothing');
		for (rule in sensitive)
			Assert.isTrue(roster.contains(rule), '$rule reacts to the resolution scope on this fixture and no roster entry covers it');
	}

	/**
	 * Every `<kind>:<rule>@<cell>` the two REFLECTION cells answer differently when the reacher moves from
	 * `resolutionRoots` into the library half of the same declared scope.
	 *
	 * BOTH directions are collected: the claim is that the halves are interchangeable, so either side
	 * gaining an answer the other lacks refutes it. The one-directional shape the other differentials use
	 * fits a SUBSET claim, and this is not one.
	 */
	private function placementDivergences(): Array<String> {
		final out: Array<String> = [];
		for (cell in CELLS) if (cell.grantee == B_REFLECT) {
			final report: Array<SourceFile> = [{ file: DECL_FILE, source: cell.decl }];
			final reach: Array<SourceFile> = [{ file: REACH_FILE, source: cell.grantee }];
			final rootsEdits: Map<String, Array<String>> = editsByRule(report, reach, cell.decl);
			final libEdits: Map<String, Array<String>> = editsByRule(report, reach, cell.decl, LIBRARY_ONLY);
			final rootsFindings: Array<String> = findingKeys(report, reach);
			final libFindings: Array<String> = findingKeys(report, reach, LIBRARY_ONLY);
			extraEdits(libEdits, rootsEdits, 'edit:', cell.name, out);
			extraEdits(rootsEdits, libEdits, 'edit:', cell.name, out);
			extraFindings(libFindings, rootsFindings, 'report:', cell.name, out);
			extraFindings(rootsFindings, libFindings, 'report:', cell.name, out);
			Assert.isTrue(
				rootsFindings.length >= 5,
				'${cell.name}: only ${rootsFindings.length} finding(s) — the placement differential has nothing to compare'
			);
		}
		out.sort(Reflect.compare);
		return out;
	}

	/**
	 * Every `<kind>:<rule>@<cell>` an UNREADABLE reflective reacher produces on the declaring file that
	 * the same reacher, readable, does not — the T867 residue.
	 *
	 * Both arms place the reacher in `LIBRARY_ONLY`, so the ONE variable between them is whether the
	 * grammar can parse it.
	 */
	private function unreadableExtras(): { extras: Array<String>, readableEdits: Int, readableFindings: Int } {
		final out: Array<String> = [];
		var readableEdits: Int = 0;
		var readableFindings: Int = 0;
		for (cell in CELLS) if (cell.grantee == B_REFLECT) {
			final report: Array<SourceFile> = [{ file: DECL_FILE, source: cell.decl }];
			final readable: Array<SourceFile> = [{ file: REACH_FILE, source: cell.grantee }];
			final unreadable: Array<SourceFile> = [{ file: REACH_FILE, source: B_REFLECT_UNPARSEABLE }];
			final readableByRule: Map<String, Array<String>> = editsByRule(report, readable, cell.decl, LIBRARY_ONLY);
			final readableKeys: Array<String> = findingKeys(report, readable, LIBRARY_ONLY);
			for (edits in readableByRule) readableEdits += edits.length;
			readableFindings += readableKeys.length;
			extraEdits(editsByRule(report, unreadable, cell.decl, LIBRARY_ONLY), readableByRule, 'edit:', cell.name, out);
			extraFindings(findingKeys(report, unreadable, LIBRARY_ONLY), readableKeys, 'report:', cell.name, out);
		}
		out.sort(Reflect.compare);
		return { extras: out, readableEdits: readableEdits, readableFindings: readableFindings };
	}

	/**
	 * Every `<kind>:<rule>@<cell>` the LIBS-ONLY arm produces on the declaring file and the
	 * roots-declared arm does not — both kinds in one list, because the defect has both forms and the
	 * scope shape is what they share.
	 */
	private function libsOnlyExtras(): Array<String> {
		final out: Array<String> = [];
		for (cell in CELLS) {
			final report: Array<SourceFile> = [{ file: DECL_FILE, source: cell.decl }];
			final reach: Array<SourceFile> = [{ file: REACH_FILE, source: cell.grantee }];
			extraEdits(editsByRule(report, reach, cell.decl, LIBS_ONLY), editsByRule(report, reach, cell.decl), 'edit:', cell.name, out);
			extraFindings(findingKeys(report, reach, LIBS_ONLY), findingKeys(report, reach), 'report:', cell.name, out);
		}
		out.sort(Reflect.compare);
		return out;
	}

	/**
	 * Every rule with an edit in `some` that `every` does not also carry, appended to `out` as
	 * `<tag><rule>@<cell>`.
	 *
	 * The destination is a parameter because the three differentials in this class differ ONLY in
	 * which pair of arms they compare and how they tag the result — `libsOnlyExtras` collects both
	 * kinds into one list, the other two collect one kind each.
	 */
	private function extraEdits(
		some: Map<String, Array<String>>, every: Map<String, Array<String>>, tag: String, cell: String, out: Array<String>
	): Void {
		for (rule => edits in some) {
			final seen: Array<String> = every[rule] ?? [];
			for (edit in edits) if (!seen.contains(edit)) {
				final tagged: String = '$tag$rule@$cell';
				if (!out.contains(tagged)) out.push(tagged);
				break;
			}
		}
	}

	/** The same over finding KEYS, which carry a severity and an offset the tag drops. */
	private function extraFindings(some: Array<String>, every: Array<String>, tag: String, cell: String, out: Array<String>): Void {
		for (key in some) if (!every.contains(key)) {
			final tagged: String = '$tag${key.split('|')[0]}@$cell';
			if (!out.contains(tagged)) out.push(tagged);
		}
	}

	/** Every `<rule>@<cell>` whose narrow-report `fix` wrote an edit the wide-report run did not. */
	private function narrowOnlyEdits(): Array<String> {
		final out: Array<String> = [];
		for (cell in CELLS) {
			final report: Array<SourceFile> = [{ file: DECL_FILE, source: cell.decl }];
			final reach: Array<SourceFile> = [{ file: REACH_FILE, source: cell.grantee }];
			extraEdits(editsByRule(report, reach, cell.decl), editsByRule(report.concat(reach), [], cell.decl), '', cell.name, out);
		}
		out.sort(Reflect.compare);
		return out;
	}

	/**
	 * Every `<rule>@<cell>` whose narrow-report `run` REPORTS a finding on the declaring file that
	 * the wide-report run over the same two files does not — the same defect in its reporting form,
	 * one step before the writing one (`unused-private` called a live member dead that way in S177).
	 * A finding is keyed by rule, severity and start offset, so a message whose text merely re-renders
	 * is not a divergence.
	 */
	private function narrowOnlyFindings(): Array<String> {
		final out: Array<String> = [];
		for (cell in CELLS) {
			final report: Array<SourceFile> = [{ file: DECL_FILE, source: cell.decl }];
			final reach: Array<SourceFile> = [{ file: REACH_FILE, source: cell.grantee }];
			extraFindings(findingKeys(report, reach), findingKeys(report.concat(reach), []), '', cell.name, out);
		}
		out.sort(Reflect.compare);
		return out;
	}

	/** Every finding the roster reports on the declaring file, as `<rule>|<severity>|<from>`. */
	private function findingKeys(
		report: Array<SourceFile>, reach: Array<SourceFile>, placement: String = ROOTS_AND_LIBRARY
	): Array<String> {
		final plugin: CachingGrammarPlugin = scoped(report, reach, placement);
		return [
			for (check in Linter.builtins()) for (v in check.run(
				report, plugin
			)) if (v.file == DECL_FILE) '${v.rule}|${v.severity}|${v.span?.from}'
		];
	}

	/**
	 * Every rule that emitted at least one edit on the declaring file in the NARROW arm, over any
	 * cell — the narrow arm alone, because it is the side whose output the differential requires
	 * to be a subset, and a floor met by the wide arm would leave that subset trivially empty.
	 */
	private function narrowRulesEmittingEdits(): Array<String> {
		final out: Array<String> = [];
		for (cell in CELLS) {
			final report: Array<SourceFile> = [{ file: DECL_FILE, source: cell.decl }];
			final reach: Array<SourceFile> = [{ file: REACH_FILE, source: cell.grantee }];
			for (rule => edits in editsByRule(report, reach, cell.decl)) if (edits.length > 0 && !out.contains(rule)) out.push(rule);
		}
		out.sort(Reflect.compare);
		return out;
	}

	/** Each check's `fix` edits for the declaring file, keyed by rule id, each rendered `from:to:text`. */
	private function editsByRule(
		report: Array<SourceFile>, reach: Array<SourceFile>, declSource: String, placement: String = ROOTS_AND_LIBRARY
	): Map<String, Array<String>> {
		final plugin: CachingGrammarPlugin = scoped(report, reach, placement);
		final index: SymbolIndex = SymbolIndex.build(report, plugin);
		final out: Map<String, Array<String>> = [];
		for (check in Linter.builtins()) {
			final vs: Array<Violation> = check.run(report, plugin).filter(v -> v.file == DECL_FILE);
			if (vs.length == 0) continue;
			final edits: Array<{ span: Span, text: String }> = check.fix(declSource, vs, plugin, index);
			out[check.id()] = [for (edit in edits) '${edit.span.from}:${edit.span.to}:${edit.text}'];
		}
		return out;
	}

	/**
	 * The plugin `LintCommand` builds for a project that declares `resolutionRoots`: the scope is
	 * DECLARED, and the library half carries the root files the report scope does not hold.
	 *
	 * `LIBS_ONLY` is the OTHER shape a real config has — `resolutionLibs` declared and
	 * `resolutionRoots` absent — and it is not merely a narrower version of the first: the scope is still
	 * DECLARED, it just holds an installed library where the project's own sources should be. Both halves
	 * lose them at once, which is what one key filling both buys: `RefactorSupport.resolutionProjectSourcesOf`
	 * answers null on the empty `projectRoots`, and the index behind `widestScopeIndex` becomes the report
	 * files plus a haxelib. What that costs is `LIBS_ONLY_REGRESSIONS`. Flipping `declared` to false as
	 * well changes none of it — the pinned cost is equally the cost of declaring no resolution at all —
	 * so the arm is named for the config shape it models, not for a behaviour only it has.
	 *
	 * `LIBRARY_ONLY` is the third placement, and the ONLY one that separates the two seams T868 forked over: `resolutionRoots`
	 * is declared and non-empty, so the narrow seam answers with files — one inert file — while the reacher sits in the library
	 * half alone and is therefore THIRD-PARTY, exactly as an installed haxelib source is. The library carries the roots too,
	 * the way `LintCommand.resolutionThunk` concatenates them, so `thirdPartyFiles` tags the reacher and nothing else.
	 */
	private function scoped(
		report: Array<SourceFile>, reach: Array<SourceFile>, placement: String = ROOTS_AND_LIBRARY
	): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final roots: Array<SourceFile> = switch placement {
			case LIBS_ONLY: [];
			case LIBRARY_ONLY: [{ file: ROOT_FILE, source: C_INERT }];
			case _: reach;
		};
		final library: Array<SourceFile> = placement == LIBS_ONLY
			? [{ file: LIB_FILE, source: LIB_THIRD_PARTY }]
			: roots.concat(placement == LIBRARY_ONLY ? reach : []);
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {report: report, projectRoots: roots, library: new LibrarySources(library) }
		});
		return plugin;
	}

	/**
	 * The rule ids `libsOnlyExtras` names, deduplicated — every rule whose report or edit on the
	 * declaring file changed when the declared scope shape did.
	 */
	private function scopeSensitiveRules(): Array<String> {
		final out: Array<String> = [];
		for (entry in libsOnlyExtras()) {
			final rule: String = entry.split(':')[1].split('@')[0];
			if (!out.contains(rule)) out.push(rule);
		}
		out.sort(Reflect.compare);
		return out;
	}

}

/** One two-file cell: the declaring source, the reaching source, and the route's name. */
private typedef Cell = {
	final name: String;
	final decl: String;
	final grantee: String;
};

/** One source a scope half holds. */
private typedef SourceFile = {
	var file: String;
	var source: String;
};
