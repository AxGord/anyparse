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
	var mods: Array<String>;

	/**
	 * Simple name of the type declaration enclosing this declaration (the class
	 * a field / method belongs to), or null at top level. Lets the autofix ask
	 * the cross-file index whether a private member is confined to its file.
	 */
	var enclosingType: Null<String>;

	/**
	 * True when the member can be reached without an in-source identifier
	 * reference — a constructor, a property accessor invoked via (get, set), or an
	 * annotation-bearing member a framework / macro / @:keep may reference. The
	 * unused checks must not flag such a member; absent for non-members. Set by the
	 * grammar's projection, as the reachability rules are language-specific.
	 */
	@:optional var implicitlyReachable: Bool;

	/**
	 * True when the autofix must not mechanically rename this declaration even
	 * though the check still reports it - its identifier is a contract a
	 * single-file rename cannot honour. Two grammar-set cases: a structural /
	 * serialization field (a typedef or inline anon-structure member - a JSON /
	 * wire key whose cross-file consumers a rename never updates), and a property
	 * backed by physical `get_` / `set_` accessors a single-decl rename would
	 * leave dangling. The warning still fires; only `fix` skips it. Absent
	 * (false) for ordinary declarations.
	 */
	@:optional var renameUnsafe: Bool;
}
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
	 * index-free `NamedDecl.implicitlyReachable`.
	 */
	public function frameworkReachable(decl: NamedDecl, index: SymbolIndex): Bool;

}
