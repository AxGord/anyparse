package anyparse.query;

import anyparse.runtime.Span;

/**
 * The kind of declaration a `NamingRule` applies to — and the seam intro for
 * the whole naming layer.
 *
 * Naming conventions are a per-grammar capability, declared here alongside
 * `RefShape` / `MetaShape` rather than in the generic check: the check in
 * `anyparse.check.Naming` is language-agnostic and asks the plugin's
 * `NamingSupport` to project the declarations worth checking and to resolve
 * the effective policy for a file, then applies the policy. Every Haxe /
 * checkstyle specific lives behind this seam.
 *
 * `NamingCategory` is the neutral vocabulary shared by the plugin's
 * projection, the policy, and the checkstyle config adapter, so none of them
 * speaks the other's grammar-specific node kinds. Backed by `String` for
 * readable debug / labels; compared by value.
 */
enum abstract NamingCategory(String) {

	final Type = 'type';
	final Field = 'field';
	final Method = 'method';
	final Constant = 'constant';
	final Local = 'local';
	final Param = 'param';
	final EnumValue = 'enumValue';
	final CatchVar = 'catchVar';

}

/**
 * WHICH mechanism reaches a member without an in-source identifier naming it — the answer
 * `NamedDecl.implicitReach` carries, and the reason a rename of that member is refused.
 *
 * It was a `Bool`, and five disjoint mechanisms reached every consumer as one `true`. A yes/no
 * is all the unused checks need, but the naming autofix WRITES a decline sentence from it, and
 * one sentence over five mechanisms is a sentence that is false for four of them: a
 * `private function new()` declined with `the member carries metadata` and carried none. Same
 * defect `13177bff` split out of the ledger, one level down and inside a single sentence.
 *
 * Neutral, like `NamingCategory`: a grammar's projection decides which mechanism applies in ITS
 * language, and the check only maps the answer to a sentence. Backed by `String` for readable
 * debug; compared by value.
 */
enum abstract ImplicitReach(String) {

	/** The type's constructor — reached by every `new Owner(…)` and by no identifier spelling it. */
	final Constructor = 'constructor';

	/** A magic name the runtime itself calls (`__init__`), not a style choice. */
	final MagicName = 'magicName';

	/** A property accessor (`get_x` / `set_x`), invoked through the property's own `(get, set)`. */
	final Accessor = 'accessor';

	/** An annotated member a macro / `@:keep` / framework may reach by NAME. */
	final Annotation = 'annotation';

	/** A `static final` bound to a type reference — a `Class<T>` registry entry resolved by name. */
	final TypeRegistry = 'typeRegistry';

}

/**
 * One naming rule: a `format` every declaration of `category` (further
 * narrowed by `requireMods` / `forbidMods`) must match. `requireMods` are
 * neutral modifier strings (`'public'`, `'private'`, `'static'`, …) that must
 * all be present; `forbidMods` must all be absent. `label` is the
 * human-facing rule name surfaced in a violation message. Rules are applied
 * in policy order, first applicable wins — this is what lets a private-field
 * rule sit ahead of a public-field rule (checkstyle expresses the same split
 * via several per-modifier entries).
 */
typedef NamingRule = {
	var category: NamingCategory;
	var requireMods: Array<String>;
	var forbidMods: Array<String>;
	var format: EReg;
	var label: String;

	/**
	 * Optional mechanical name normalizer for the autofix: maps a violating
	 * name to a corrected one that should conform to `format`, or null when it
	 * cannot be fixed mechanically. Rules loaded from a `checkstyle.json` carry
	 * none (report-only); the built-in default attaches one to the rename-safe
	 * categories.
	 */
	@:optional var normalize: String -> Null<String>;
}
/**
 * The ordered list of `NamingRule`s the `naming` check applies to a file — the first rule whose category / modifier selector matches a declaration governs it. Loaded from a project `checkstyle.json` or the grammar built-in default.
 */
typedef NamingPolicy = Array<NamingRule>;

/**
 * A declaration the `naming` check should inspect, as projected by a
 * grammar's `NamingSupport`. `span` is the source range to report (null when
 * the grammar built the node without span tracking — the check skips it, like
 * `unused-local`); `name` is the identifier to test; `category` and `mods`
 * select the applicable rule.
 */
typedef NamedDecl = {
	var span: Null<Span>;
	var name: String;
	var category: NamingCategory;

	/**
	 * The EFFECTIVE neutral modifiers of the declaration — not only the ones it spells. A grammar adds
	 * what the enclosing declaration confers: a Haxe interface member is `public` without writing it,
	 * and a member of an `extern` type is `extern` without writing it. That is what lets a rule select
	 * on either through `requireMods` / `forbidMods` instead of growing a flag per question.
	 */
	var mods: Array<String>;

	/**
	 * Simple name of the type declaration enclosing this declaration (the class
	 * a field / method belongs to), or null at top level. Lets the autofix ask
	 * the cross-file index whether a private member is confined to its file.
	 */
	var enclosingType: Null<String>;

	/**
	 * WHICH mechanism reaches this member without an in-source identifier naming it, or null when
	 * none does — a constructor, a magic name, a property accessor invoked via `(get, set)`, an
	 * annotation-bearing member a framework / macro / `@:keep` may reference, or a type-registry
	 * constant. The unused checks must not flag such a member and ask only whether this is null;
	 * the naming autofix writes its decline sentence from WHICH one, which is why the field names
	 * the mechanism rather than answering `true`. Absent for non-members. Set by the grammar's
	 * projection, as the reachability rules are language-specific.
	 */
	@:optional var implicitReach: Null<ImplicitReach>;

	/**
	 * True when the autofix must not mechanically rename this declaration even
	 * though the check still reports it - its identifier is a contract a
	 * single-file rename cannot honour. Three grammar-set cases: a structural /
	 * serialization field (a typedef or inline anon-structure member - a JSON /
	 * wire key whose cross-file consumers a rename never updates), a property
	 * backed by physical `get_` / `set_` accessors a single-decl rename would
	 * leave dangling, and a member of a class carrying `@:rtti` (serialized by
	 * reflecting on field NAMES, e.g. drill Node - renaming breaks saved files).
	 * The warning still fires; only `fix` skips it. Absent
	 * (false) for ordinary declarations.
	 */
	@:optional var renameUnsafe: Bool;

	/**
	 * True when the identifier is a language / framework idiom rather than a
	 * name the policy governs, so no rule applies to it at all. Three grammar-set
	 * cases in Haxe: a discard binding (`for (_ in items)` - there is nothing to
	 * rename), a magic dunder name (`__init__`, the static module
	 * initialiser - renaming it silently disables the code), and a property
	 * ACCESSOR method (`get_x` / `set_x` - its spelling is the property's, so the
	 * finding belongs to the property and a correction applied here alone would
	 * orphan it). Unlike
	 * `renameUnsafe`, this suppresses the WARNING too: the name is correct as
	 * written. Absent (false) for ordinary declarations.
	 */
	@:optional var reservedName: Bool;

	/**
	 * True when the identifier is part of an EXTERNAL contract rather than a name the project
	 * chooses: a field of an anonymous structure / typedef, which participates in structural
	 * typing and mirrors whatever wire format the structure describes (a server's JSON keys, a
	 * file format). Renaming it is not a style improvement, it changes the type — so like
	 * `reservedName` this suppresses the WARNING, not just the fix. Distinct from
	 * `renameUnsafe`, which marks a name that IS the project's to choose but that the autofix
	 * cannot rewrite safely (an accessor-backed property, an `@:rtti` member) and therefore
	 * still deserves a report. Absent (false) for ordinary declarations.
	 */
	@:optional var contractName: Bool;
}
/**
 * A grammar plugins projection for the `naming` check: `project` lists the name-checkable declarations of a tree, and the policy lookup resolves each file to its effective `NamingPolicy` (discovered project config or built-in default). Keeps the check free of grammar-specific node types.
 */
@:nullSafety(Strict)
interface NamingSupport {

	/** The declarations in `tree` worth name-checking, with their category / modifiers. */
	public function project(tree: QueryNode): Array<NamedDecl>;

	/**
	 * The effective naming policy for the file at `path`: a discovered project
	 * config (e.g. a `checkstyle.json` walking up from the file) when present,
	 * else the grammar's built-in default convention.
	 */
	public function policyFor(path: String): NamingPolicy;

	/**
	 * Whether `decl` is reachable through a framework or macro rather than an
	 * in-source reference, given the cross-file `index` (e.g. a utest `test*` method
	 * whose class transitively extends `Test`). Distinct from the per-decl,
	 * index-free `NamedDecl.implicitReach`.
	 */
	public function frameworkReachable(decl: NamedDecl, index: SymbolIndex): Bool;

	/**
	 * The member names `tree` reaches BY NAME through a reflection API — every string
	 * literal standing in an argument of a call the grammar recognises as reflection
	 * (`Reflect.getProperty(o, 'x')` and friends for Haxe). Such a reference is invisible
	 * to any identifier-level resolution, and renaming the member breaks it SILENTLY, so
	 * `Naming`'s autofix refuses a member whose name appears here.
	 *
	 * A call whose name argument is NOT a plain literal (`Reflect.field(o, key)`) is
	 * outside this projection on purpose: the name is unknowable, and treating any dynamic
	 * reflection as a project-wide veto would refuse every rename in a project that has
	 * one. A grammar with no reflection API returns an empty array.
	 */
	public function reflectionMemberNames(tree: QueryNode, source: String): Array<String>;

	/**
	 * The class-level member a local constant HOISTED out of a function body becomes, or null when
	 * the grammar has no such member form (the hoist arm then no-ops for it). `declarationText` is
	 * the local declaration verbatim from its own keyword on and terminated (`final PAD:Int = 40;`),
	 * so the type annotation and the initializer are carried exactly as written; the implementation
	 * only prefixes the modifier run.
	 *
	 * `scalar` says whether the initializer is a value the language folds at every use site, which
	 * is what earns an `inline` keyword. A String does not: on hxcpp an inlined String re-emits its
	 * bytes per use site, so it stays a plain static field (the same split `inline-constant` makes,
	 * for the same measured reason).
	 */
	public function hoistedConstant(declarationText: String, scalar: Bool): Null<HoistedConstant>;

}

/**
 * One member a constant hoist would emit: the declaration TEXT the grammar renders, and the
 * neutral modifier run that text carries.
 *
 * The two travel together because the caller needs both and they must not disagree: `mods` is what
 * selects the Constant `NamingRule` the emitted member will be judged by, and a policy may split
 * its Constant rules on exactly the modifier the two arms differ in (`inline`). Deriving `mods`
 * caller-side would encode the grammar's modifier run a second time, in the one place guaranteed
 * to drift from it.
 */
typedef HoistedConstant = {
	final text: String;

	/** The neutral modifiers `text` carries (`['private', 'static', 'inline']`) — the rule selector. */
	final mods: Array<String>;
};
