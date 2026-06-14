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
}

/** An ordered set of naming rules; the first applicable rule per declaration wins. */
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
}

/**
 * The per-grammar naming capability. A plugin that has a naming convention
 * returns an instance from `GrammarPlugin.namingSupport`; one without (a
 * binary format) returns null and the `naming` check no-ops for it.
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

}
