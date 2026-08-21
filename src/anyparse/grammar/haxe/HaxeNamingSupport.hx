package anyparse.grammar.haxe;

import anyparse.query.NamingPolicy.HoistedConstant;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * The Haxe grammar's `NamingSupport`: projects the named declarations the
 * `naming` check inspects, and resolves a file's policy — a project's
 * `checkstyle.json` (discovered walking up from the file) when present, else
 * the built-in default convention.
 */
@:nullSafety(Strict)
final class HaxeNamingSupport implements NamingSupport {

	/**
	 * Haxe reserved keywords. A de-prefixed local whose bare name lands on one of
	 * these is not a usable identifier, so its rename is skipped (report-only).
	 * Published through `RefShape.reservedWords` for the checks that DERIVE an
	 * identifier without going through a policy normalizer.
	 */
	public static final KEYWORDS: Array<String> = [
		'abstract',
		'break',
		'case',
		'cast',
		'catch',
		'class',
		'continue',
		'default',
		'do',
		'dynamic',
		'else',
		'enum',
		'extends',
		'extern',
		'false',
		'final',
		'for',
		'function',
		'if',
		'implements',
		'import',
		'in',
		'inline',
		'interface',
		'is',
		'macro',
		'new',
		'null',
		'operator',
		'overload',
		'override',
		'package',
		'private',
		'public',
		'return',
		'static',
		'super',
		'switch',
		'this',
		'throw',
		'true',
		'try',
		'typedef',
		'untyped',
		'using',
		'var',
		'while'
	];

	/** The node kind of a binding declared after the comma in `var a = 1, b = 2;` — see `VarHost`. */
	private static inline final VAR_MORE_KIND: String = 'VarMore';

	private static final CAMEL_CASE_PATTERN: String = "^[a-z_][a-zA-Z0-9]*$";

	/** Camel-case with NO leading underscore - a local must not carry the private-field `_` prefix. */
	private static final LOCAL_CASE_PATTERN: String = "^[a-z][a-zA-Z0-9]*$";

	/** A discard binding: underscores only, nothing to name (`for (_ in items)`). */
	private static final DISCARD_NAME_PATTERN: EReg = new EReg("^_+$", '');

	/** A magic dunder name (`__init__`) - a language / framework contract, not a style choice. */
	private static final DUNDER_NAME_PATTERN: EReg = new EReg("^__.+__$", '');

	/**
	 * Modifier node kinds the Haxe projection surfaces as separate siblings
	 * preceding a declaration, mapped to neutral modifier strings. `Meta` (an
	 * `@:tag`) is part of the modifier run but contributes no modifier.
	 */
	private static final MOD_KIND_TO_NAME: Map<String, String> = [
		'Public' => 'public',
		'Private' => 'private',
		'Static' => 'static',
		'Inline' => 'inline',
		'Override' => 'override',
		'Macro' => 'macro',
		'Extern' => 'extern',
		'Dynamic' => 'dynamic',
		'Abstract' => 'abstract'
	];

	/**
	 * The `Reflect` statics that address a member BY NAME through a string argument — the
	 * whole field-reflection API. A POSITIVE list on purpose: "any call taking a string"
	 * would veto every rename in a project, and the benefit side here is finite.
	 */
	private static final REFLECTION_FIELD_METHODS: Array<String> = [
		'field',
		'setField',
		'getProperty',
		'setProperty',
		'hasField',
		'deleteField',
		'callMethod'
	];

	/** Reads a plain string literal's content — the grammar's own lexer rules, not a second parser. */
	private static final STRING_FOLD: HaxeStringFoldSupport = new HaxeStringFoldSupport();

	/**
	 * The modifier kinds a HOISTED constant is emitted with, least-specific first (`Inline` is appended
	 * for the scalar arm). Kinds rather than names so the run has ONE spelling in this class: both
	 * halves of `hoistedConstant` — the neutral `mods` the policy selects a rule by, and the keyword
	 * prefix of the emitted text — come from `modNames` over this list, and cannot drift apart.
	 */
	private static final HOIST_MOD_KINDS: Array<String> = ['Private', 'Static'];

	public function new() {}

	public function project(tree: QueryNode): Array<NamedDecl> {
		final out: Array<NamedDecl> = [];
		walk(tree, [], null, false, null, out);
		return out;
	}

	public function policyFor(path: String): NamingPolicy {
		final content: Null<String> = CheckstyleConfigFinder.findConfigContent(path);
		return content == null ? defaults() : try CheckstyleConfigLoader.load(content) catch (exception: Exception) defaults();
	}

	public function frameworkReachable(decl: NamedDecl, index: SymbolIndex): Bool {
		if (decl.category != NamingCategory.Method) return false;
		final owner: Null<String> = decl.enclosingType;
		return owner != null && isUtestMethodName(decl.name) && transitivelyExtendsTest(owner, index);
	}

	public function reflectionMemberNames(tree: QueryNode, source: String): Array<String> {
		final out: Array<String> = [];
		collectReflectionNames(tree, source, out);
		return out;
	}

	public function hoistedConstant(declarationText: String, scalar: Bool): Null<HoistedConstant> {
		final mods: Array<String> = modNames(scalar ? HOIST_MOD_KINDS.concat(['Inline']) : HOIST_MOD_KINDS);
		return { text: '${mods.join(' ')} $declarationText', mods: mods };
	}

	/**
	 * The built-in Haxe naming convention (the user's `preferences-haxe`
	 * rules), applied when no `checkstyle.json` governs the file. Ordered: the
	 * private-field rule precedes the public-field rule, and the constant rule
	 * is reached via the projection's static-final → Constant categorisation.
	 */
	public static function defaults(): NamingPolicy {
		return [
			{
				category: NamingCategory.Type,
				requireMods: [],
				forbidMods: [],
				format: new EReg("^[A-Z][a-zA-Z0-9]*$", ''),
				label: 'PascalCase type'
			},
			{
				category: NamingCategory.EnumValue,
				requireMods: [],
				forbidMods: [],
				format: new EReg("^[A-Z][a-zA-Z0-9_]*$", ''),
				label: 'PascalCase or UPPER_SNAKE enum value'
			},
			{
				category: NamingCategory.Constant,
				requireMods: [],
				forbidMods: [],
				format: new EReg("^([A-Z][A-Z0-9_]*|[a-z][a-zA-Z0-9]*)$", ''),
				label: 'UPPER_SNAKE or camelCase static final',
				normalize: stripUnderscorePrefix
			},
			{
				category: NamingCategory.Field,
				requireMods: [],
				forbidMods: ['public', 'static'],
				format: new EReg("^_[a-z][a-zA-Z0-9]*$", ''),
				label: 'private field _ prefix',
				normalize: underscoreCamel
			},
			{
				category: NamingCategory.Field,
				requireMods: ['public'],
				forbidMods: [],
				format: new EReg("^[a-z][a-zA-Z0-9]*$", ''),
				label: 'camelCase public field',
				// The same correction the Constant / Method rules derive, for the same reason: the `_`
				// prefix is a PRIVATE-field marker and carries nothing on a public one. Only a leading
				// underscore is derivable - an UPPER_SNAKE public field (`STORE_FILE_NAME`) strips to
				// itself, so `correctedName` yields null and the finding stays report-only.
				normalize: stripUnderscorePrefix
			},
			{
				category: NamingCategory.Method,
				requireMods: [],
				forbidMods: [],
				format: new EReg("^[a-z][a-zA-Z0-9_]*$", ''),
				label: 'camelCase method',
				normalize: stripUnderscorePrefix
			},
			{
				category: NamingCategory.Local,
				requireMods: [],
				forbidMods: [],
				format: new EReg(LOCAL_CASE_PATTERN, ''),
				label: 'camelCase local (no _ prefix)',
				normalize: snakeToCamel
			},
			{
				category: NamingCategory.Param,
				requireMods: [],
				forbidMods: [],
				format: new EReg(CAMEL_CASE_PATTERN, ''),
				label: 'camelCase parameter',
				normalize: snakeToCamel
			},
			{
				category: NamingCategory.CatchVar,
				requireMods: [],
				forbidMods: [],
				format: new EReg(CAMEL_CASE_PATTERN, ''),
				label: 'camelCase catch variable',
				normalize: snakeToCamel
			}
		];
	}

	/**
	 * Whether a projected declaration is a structural / serialization field - a
	 * typedef or inline anon-structure member (a `Required` / `Optional` node
	 * whose parent is `Anon`). Its name is a wire contract (a server JSON key, a
	 * structural-typed payload), so the autofix must not rename it: cross-file
	 * consumers are invisible to a single-file rename. Covers named typedefs,
	 * inline anon types in signatures / type params, and structure-extension
	 * bodies alike - all descend through an `Anon` node.
	 */
	private static inline function isStructuralField(parent: Null<QueryNode>): Bool {
		return parent != null && parent.kind == 'Anon';
	}

	/** Whether `kind` is a metadata sibling — a bare `@:tag` (`Meta`) or an argumented `@:tag(...)` (`MetaCall`, e.g. `@:op(A < B)`). */
	private static inline function isMetaKind(kind: String): Bool {
		return kind == 'Meta' || kind == 'MetaCall';
	}

	/** Whether `category` is a type MEMBER (field / constant / method) - the categories a `@:rtti` class's reflection reads by name. */
	private static inline function isMemberCategory(category: NamingCategory): Bool {
		return category == NamingCategory.Field || category == NamingCategory.Constant || category == NamingCategory.Method;
	}

	/** Whether `c` is an ASCII decimal digit. */
	private static inline function isDigit(c: Int): Bool {
		return c >= '0'.code && c <= '9'.code;
	}

	/**
	 * Walk `node`, appending a `NamedDecl` for every declaration whose kind
	 * maps to a category. `mods` come from the modifier siblings preceding the
	 * node in its parent (the projection surfaces `public static fn` as
	 * `(Public)(Static)(FnMember)`), so a `final` field is a Constant when
	 * static and a Field otherwise, and a `static inline var` is a Constant too
	 * (a compile-time constant - a write to it is a compile error).
	 */
	private static function walk(
		node: QueryNode, ancestors: Array<QueryNode>, enclosingType: Null<String>, enclosingRtti: Bool, host: Null<VarHost>,
		out: Array<NamedDecl>
	): Void {
		// Macro reification (`macro { … }`) is opaque: its identifiers are splice
		// templates (`$name`), not real declarations — skip the whole subtree, as
		// `unused-local` does with the plugin's `opaqueKinds`.
		if (node.kind == 'MacroExpr') return;
		// The chain the leading-run walk needs: a member declared inside a conditional-compilation
		// region continues its run in the region's OWN run, one level out.
		final parent: Null<QueryNode> = ancestors.length > 0 ? ancestors[ancestors.length - 1] : null;
		// A `VarMore` is a binding after the comma in `var a = 1, b = 2;` — the same kind whatever
		// declaration it continues, so it has no category of its own and inherits the head binding's
		// whole context: category, the modifier run that precedes the HEAD (`static var a = 1, b = 2`
		// makes both Constants), and its structural-field status.
		final inherited: Null<VarHost> = node.kind == VAR_MORE_KIND ? host : null;
		final mods: Array<String> = inherited == null ? modsOf(node, parent) : inherited.mods;
		final structural: Bool = inherited == null ? isStructuralField(parent) : inherited.structural;
		var category: Null<NamingCategory> = inherited == null ? categoryOf(node, mods) : inherited.category;
		if (parent != null && parent.kind == 'EnumAbstractDecl' && (node.kind == 'FinalMember' || node.kind == 'VarMember'))
			category = NamingCategory.EnumValue;
		final name: Null<String> = node.name;
		if (category != null && name != null)
			out.push(namedDeclOf(node, parent, ancestors, category, name, mods, structural, enclosingType, enclosingRtti));
		// A type decl becomes the enclosing type of its descendants — its name is
		// on the node carrying category Type (the inner ClassForm for a final
		// class, the flattened AbstractClassDecl for an abstract class).
		final childEnclosing: Null<String> = category == NamingCategory.Type && name != null ? name : enclosingType;
		// A `@:rtti` type serializes by reflecting on its field NAMES, so its member
		// fields are rename-unsafe. Once true it stays true for every descendant.
		final childEnclosingRtti: Bool = category == NamingCategory.Type
			? enclosingRtti || metaInRun(node, ancestors, NamingCategory.Type, '@:rtti')
			: enclosingRtti;
		// The head binding's context, handed to the `VarMore` chain hanging off it. A `VarMore` passes
		// its own inherited context straight on, since the chain is right-recursive (`a{more:[b{more:[c]}]}`).
		final resolved: Null<NamingCategory> = category;
		final childHost: Null<VarHost> = resolved == null ? null : { category: resolved, mods: mods, structural: structural };
		ancestors.push(node);
		for (child in node.children) walk(child, ancestors, childEnclosing, childEnclosingRtti, childHost, out);
		ancestors.pop();
	}

	/**
	 * The neutral modifiers of `node`: its contiguous run of preceding
	 * modifier siblings (`Public` / `Static` / …) in `parent`, skipping `Meta`
	 * entries. Empty for any node not preceded by a modifier run.
	 */
	private static function modsOf(node: QueryNode, parent: Null<QueryNode>): Array<String> {
		if (parent == null) return [];
		final siblings: Array<QueryNode> = parent.children;
		var i: Int = siblings.indexOf(node) - 1;
		final mods: Array<String> = [];
		while (i >= 0) {
			final mod: Null<String> = MOD_KIND_TO_NAME[siblings[i].kind];
			if (mod != null)
				mods.push(mod);
			else if (!isMetaKind(siblings[i].kind))
				break;
			i--;
		}
		return mods;
	}

	/**
	 * The naming category of a declaration node, or null if its kind is not name-checked. A local
	 * `function` / `inline function` statement is a Local: its name is a binding scoped to one body,
	 * exactly like a `var`, so the same rules govern it. Both forms are decl hosts of the reference
	 * walker and open their own parameter scope, so a rename derived from either resolves its
	 * occurrence set like any other local's.
	 */
	private static function categoryOf(node: QueryNode, mods: Array<String>): Null<NamingCategory> {
		return switch node.kind {
			case 'ClassDecl', 'ClassForm', 'AbstractClassDecl', 'InterfaceDecl', 'EnumDecl', 'AbstractDecl', 'EnumAbstractDecl',
				'TypedefDecl': NamingCategory.Type;
			case 'FnMember', 'FinalModifiedMember': NamingCategory.Method;
			case 'VarMember': mods.contains('static') && mods.contains('inline') ? NamingCategory.Constant : NamingCategory.Field;
			case 'FinalMember': mods.contains('static') ? NamingCategory.Constant : NamingCategory.Field;
			case 'SimpleCtor', 'ParamCtor': NamingCategory.EnumValue;
			case 'VarStmt', 'FinalStmt', 'ForStmt', 'ForExpr', 'KeyValueBinder', 'LocalFnStmt', 'LocalInlineFnStmt': NamingCategory.Local;
			case 'Required', 'Optional', 'Rest', 'LambdaParam': NamingCategory.Param;
			case 'CatchClause': NamingCategory.CatchVar;
			case _: null;
		}
	}

	/**
	 * The mechanical fix for a private field missing its `_` prefix: prepend `_` to the shared
	 * `camelCore` (`shape` -> `_shape`, `Shape` -> `_shape`, `HEIGHT` -> `_height`, `URLPath` ->
	 * `_urlPath`, `CELLS_NUM_X` -> `_cellsNumX`). Sharing `camelCore` - and through it
	 * `smartSegment` - is what stops the fix MANUFACTURING a lowercase-head-over-caps-tail name
	 * (`_hEIGHT`), which the `naming` artifact arm could never report back: its pattern is anchored
	 * at the head, and the `_` prefix hides it. Splitting on `_` is what makes an UPPER_SNAKE
	 * private field FIXABLE rather than report-only - the rule's own format (`^_[a-z][a-zA-Z0-9]*$`)
	 * admits no internal underscore, so a name that keeps one can never satisfy the rule it is
	 * being corrected for. No keyword test: every result opens with `_`, so none can be a keyword.
	 * Not `inline` - passed as a `NamingRule.normalize` function value.
	 */
	private static function underscoreCamel(name: String): Null<String> {
		final core: Null<String> = camelCore(name);
		return core == null ? null : '_$core';
	}

	/**
	 * The mechanical fix for a static final wrongly given a private-field `_` prefix:
	 * strip the leading underscore(s), keeping the result whenever it is a
	 * syntactically valid identifier (`_forceBuild` → `forceBuild`, `_FORCE_BUILD` →
	 * `FORCE_BUILD`). Whether the stripped name actually conforms to the Constant
	 * rule's format is decided by the caller (`Naming.renameEditsFor` gates on
	 * `rule.format.match`), so both camelCase and UPPER_SNAKE pass here while a name
	 * matching neither (`_FORCE_build` → `FORCE_build`) is filtered there. A strip that
	 * leaves an invalid identifier, or one that lands on a Haxe keyword (`_new` → `new`, the
	 * CONSTRUCTOR name), → null. Not `inline` — passed as a `NamingRule.normalize` function value.
	 */
	private static function stripUnderscorePrefix(name: String): Null<String> {
		var i: Int = 0;
		while (i < name.length && name.fastCodeAt(i) == '_'.code) i++;
		if (i == 0) return null;
		final stripped: String = name.substr(i);
		return new EReg("^[a-zA-Z][a-zA-Z0-9_]*$", '').match(stripped) && !KEYWORDS.contains(stripped) ? stripped : null;
	}

	/**
	 * Is a member of `category` named `name` reachable without an in-source
	 * identifier reference? A constructor (`new`), a magic dunder name the runtime
	 * calls (`__init__` - the static module initialiser), a `get_` / `set_`
	 * property accessor invoked through `(get, set)`, an annotated member a
	 * framework / macro / `@:keep` may reach, and a static final initialised with a
	 * type reference (a `Class<T>` registry entry) all qualify.
	 */
	private static function isImplicitlyReachable(
		category: NamingCategory, name: String, node: QueryNode, ancestors: Array<QueryNode>, mods: Array<String>
	): Bool {
		return (category == NamingCategory.Field || category == NamingCategory.Method || category == NamingCategory.Constant)
			&& (name == 'new' || DUNDER_NAME_PATTERN.match(name) || name.startsWith('get_') || name.startsWith('set_')
				|| metaInRun(node, ancestors, category) || node.kind == 'FinalMember' && mods.contains('static')
				&& isTypeReferenceInit(node));
	}

	/**
	 * Whether a var / final member named `name` is a property backed by physical
	 * `get_<name>` / `set_<name>` accessor methods declared as siblings. Renaming
	 * the property alone (e.g. to a `_`-prefixed form) would orphan those
	 * accessors - Haxe then requires `get_<newName>` / `set_<newName>` - so the
	 * single-decl autofix must skip it. Only `VarMember` / `FinalMember` hosts qualify.
	 */
	private static function hasPhysicalAccessors(node: QueryNode, parent: Null<QueryNode>, name: String): Bool {
		if (parent == null || (node.kind != 'VarMember' && node.kind != 'FinalMember')) return false;
		final getName: String = 'get_$name';
		final setName: String = 'set_$name';
		return parent.children.exists(sib -> sib.kind == 'FnMember' && (sib.name == getName || sib.name == setName));
	}

	/**
	 * Does an annotation - `metaName` when given, any `Meta` / `MetaCall` otherwise - precede `node`
	 * in its leading modifier / meta run? Scans the preceding siblings, skipping modifier kinds and
	 * annotations that are not the requested one; anything else ends the run, so an annotation
	 * written for one declaration cannot reach the next.
	 *
	 * A conditional-compilation region is a SEAM in that run, not its end, and the run crosses it in
	 * BOTH directions. Forward: `@:op(A << B) #if (haxe_ver >= 4.2) extern #else @:extern #end
	 * private inline function add_op` projects `MetaCall`, `Conditional`, `Private`, `Inline`,
	 * `FnMember` as five siblings, and stopping at the region read every member of the cross-version
	 * `extern` idiom as unannotated - `unused-private --fix` then deleted six `@:op` overloads and a
	 * `@:from` from one real file, after which `signal << listener` was the builtin integer shift.
	 * Outward: a member declared INSIDE a region continues its run in the region's own leading run,
	 * so `@:keep #if js private function f() {} #end` is annotated too - without that step the same
	 * `--fix` deleted it and `naming --fix` renamed it.
	 *
	 * A region grants NOTHING of its own: an annotation in one of its branches says nothing about
	 * the member that FOLLOWS it, and counting one would exempt every `extern inline` private in the
	 * tree. What ends the run is a region holding a declaration THE RUN COULD HAVE BEEN WRITTEN FOR,
	 * and which declaration that is depends on `target`, the category whose run is being walked:
	 * `@:rtti` before a region holding a type belongs to that type, exactly as `@:keep` before a
	 * region holding a member belongs to that member. Asking only about members let `@:rtti` step
	 * over `#if js class Holder {} #end` and mark the NEXT type's fields rename-unsafe.
	 *
	 * INSIDE a region nothing ends the run at all. The projection flattens `#if` / `#elseif` /
	 * `#else` into ONE child list with no branch marker, so a declaration preceding this one there
	 * may be its `#else` twin rather than a sibling that took the annotation - reading it as an end
	 * deleted the `#else` member of an `@:keep`-ed region. The run instead runs out and continues one
	 * level out, which at worst hands a SECOND member of the same branch an annotation written for
	 * the first: a forfeited rewrite, never a wrong one.
	 */
	private static function metaInRun(node: QueryNode, ancestors: Array<QueryNode>, target: NamingCategory, ?metaName: String): Bool {
		var subject: QueryNode = node;
		var depth: Int = ancestors.length - 1;
		while (depth >= 0) {
			final parent: QueryNode = ancestors[depth];
			final inRegion: Bool = parent.kind == 'Conditional';
			final siblings: Array<QueryNode> = parent.children;
			var i: Int = siblings.indexOf(subject) - 1;
			while (i >= 0) {
				final sibling: QueryNode = siblings[i];
				i--;
				final kind: String = sibling.kind;
				if (isMetaKind(kind)) {
					if (metaName == null || sibling.name == metaName) return true;
					continue;
				}
				final crossable: Bool = kind == 'Conditional' ? !holdsRunTarget(sibling, target) : MOD_KIND_TO_NAME.exists(kind);
				if (crossable) continue;
				if (!inRegion) return false;
				break;
			}
			if (!inRegion) return false;
			subject = parent;
			depth--;
		}
		return false;
	}

	/**
	 * Whether `region` declares, in any branch at any nesting depth, something the leading run being
	 * walked could have been written for - the test that makes a conditional-compilation region a
	 * SEAM in that run rather than its end. Asked through `categoryOf`, the one place this projection
	 * decides what each kind IS, so there is no second list of kinds to drift out of step with it.
	 */
	private static function holdsRunTarget(region: QueryNode, target: NamingCategory): Bool {
		return region.children.exists(child -> {
			final category: Null<NamingCategory> = categoryOf(child, []);
			return category != null && sameRunScope(category, target) || holdsRunTarget(child, target);
		});
	}

	/**
	 * Whether a declaration of `category` sits in the same run scope as one of `target` - the scope a
	 * leading modifier / meta run spans. Member scope holds the three member categories
	 * interchangeably (a `@:keep` run reaches whichever of field / constant / method follows it);
	 * every other scope is its own, so a type's run is ended by a type and by nothing else.
	 */
	private static inline function sameRunScope(category: NamingCategory, target: NamingCategory): Bool {
		return isMemberCategory(target) ? isMemberCategory(category) : category == target;
	}

	/** A method name utest's `@:autoBuild` collects: a `test*` / `spec*` test or a `setup*` / `teardown*` fixture. */
	private static function isUtestMethodName(name: String): Bool {
		return name.startsWith('test') || name.startsWith('spec') || name.startsWith('setup') || name.startsWith('teardown');
	}

	/** Whether `member`'s initializer is a bare PascalCase type reference (`= SomeType`) — the macro-force anchor shape. */
	private static function isTypeReferenceInit(member: QueryNode): Bool {
		final init: Null<QueryNode> = member.children.length > 0 ? member.children[0] : null;
		if (init == null || init.kind != 'IdentExpr') return false;
		final n: Null<String> = init.name;
		if (n == null || n.length == 0) return false;
		final c: Int = StringTools.fastCodeAt(n, 0);
		return c >= 'A'.code && c <= 'Z'.code;
	}

	/**
	 * Whether `typeName` transitively extends a `Test` base (utest), via BFS over the
	 * index's per-type direct-supertype names (`extends utest.Test` is indexed as the
	 * simple name `Test`). Resolves the intermediate-base case a single tree cannot.
	 */
	private static function transitivelyExtendsTest(typeName: String, index: SymbolIndex): Bool {
		final superMap: Map<String, Array<String>> = [];
		for (f in index.allFiles()) for (t in f.types) superMap[t.name] = t.supertypes;
		final seen: Array<String> = [typeName];
		var i: Int = 0;
		while (i < seen.length) {
			final supers: Null<Array<String>> = superMap[seen[i]];
			i++;
			if (supers == null) continue;
			for (s in supers) {
				if (s == 'Test') return true;
				if (!seen.contains(s)) seen.push(s);
			}
		}
		return false;
	}

	/**
	 * One `snake_case` segment normalized. An ALL-UPPERCASE segment (a screaming
	 * constant word like `FILE`) is lowercased whole so the camel join reads
	 * naturally (`missingFile`, not `mISSINGFILE`). A segment OPENING with an acronym
	 * run - two or more uppercase (or embedded digit) characters immediately followed by
	 * a lowercase letter - lowercases that run EXCEPT its last character, which heads the
	 * next word (`URLPath` -> `urlPath`, `HTTP2Server` -> `http2Server`). Any other segment
	 * carrying a lowercase letter is kept verbatim, preserving an already-camel word (`Id`,
	 * `scaleX`). A digit-only segment has no letters and is kept as-is. Not `inline` - a
	 * helper of `snakeToCamel`.
	 */
	private static function smartSegment(segment: String): String {
		if (new EReg("^[A-Z][A-Z0-9]*$", '').match(segment)) return segment.toLowerCase();
		final run: Int = leadingAcronymRun(segment);
		return run < 2 ? segment : segment.substr(0, run - 1).toLowerCase() + segment.substr(run - 1);
	}

	/**
	 * The length of `segment`'s leading uppercase (or embedded-digit) run when a LOWERCASE
	 * letter follows it, else 0: `URLPath` -> 4, `HTTP2Server` -> 6, `MyLocal` -> 1,
	 * `HEIGHT` -> 0 (nothing follows the run), `scaleX` -> 0. A digit counts only inside the
	 * run, never as its first character, so a name can never open with a digit anyway.
	 */
	private static function leadingAcronymRun(segment: String): Int {
		var i: Int = 0;
		while (i < segment.length) {
			final c: Int = segment.fastCodeAt(i);
			final upper: Bool = c >= 'A'.code && c <= 'Z'.code;
			final digit: Bool = i > 0 && c >= '0'.code && c <= '9'.code;
			if (!upper && !digit) break;
			i++;
		}
		if (i == 0 || i >= segment.length) return 0;
		final next: Int = segment.fastCodeAt(i);
		return next >= 'a'.code && next <= 'z'.code ? i : 0;
	}

	/**
	 * The mechanical fix for a local / param / catch name violating camelCase: the shared
	 * `camelCore` (`_items` -> `items`, `__scaleX` -> `scaleX`, `MyLocal` -> `myLocal`, `min_gap` ->
	 * `minGap`), refused when the result is a Haxe keyword (`_new` -> `new`) - not a usable
	 * identifier here, unlike under `underscoreCamel`'s `_` prefix, so the binding stays
	 * report-only. Subsumes the former de-prefix / lowercase-first normalizers. Not `inline` -
	 * passed as a `NamingRule.normalize` function value.
	 */
	private static function snakeToCamel(name: String): Null<String> {
		final lowered: Null<String> = camelCore(name);
		return lowered == null || KEYWORDS.contains(lowered) ? null : lowered;
	}

	/**
	 * The camelCase core both `snakeToCamel` and `underscoreCamel` correct through: strip every
	 * leading underscore, split the rest on `_`, apply `smartSegment`'s word policy per segment,
	 * join with capitalised heads, and lowercase the first letter. An all-uppercase segment is
	 * lowercased whole (`MISSING_FILE` -> `missingFile`); a segment opening with an acronym run
	 * keeps only that run's last character capitalised (`URLPath` -> `urlPath`); a mixed-case
	 * segment is preserved (`coachingQualification_Id` -> `coachingQualificationId`). Null when
	 * nothing survives the strip (`_`, `__`), or when a separator falls between two DIGIT runs and
	 * camelCase therefore cannot re-encode it (see the loop). The keyword test and the `_` prefix
	 * belong to the callers - that is the whole of what the two corrections differ by.
	 */
	private static function camelCore(name: String): Null<String> {
		var start: Int = 0;
		while (start < name.length && name.fastCodeAt(start) == '_'.code) start++;
		final segments: Array<String> = [for (s in name.substr(start).split('_')) if (s.length > 0) smartSegment(s)];
		if (segments.length == 0) return null;
		final buf: StringBuf = new StringBuf();
		buf.add(segments[0]);
		for (i in 1...segments.length) {
			final seg: String = segments[i];
			final prev: String = segments[i - 1];
			// A `_` BETWEEN TWO DIGIT RUNS is the one separator camelCase cannot re-encode: the capital
			// that marks every other segment boundary does not exist for a digit, so the two runs fuse
			// into one and the name changes meaning - `_u5_7` (an age band "U5 - 7") would read as
			// `_u57`, and `_u1_14` / `_u11_4` would BOTH land on `_u1114`. A digit run next to a LETTER
			// keeps its boundary either way (`HEADLINE_1` -> `Headline1`, `1_TEXTFORMAT` -> `1Textformat`),
			// so only this pairing refuses. No derivable correction means the declaration stays
			// report-only, which is what the rule already did for every multi-segment name before the
			// split landed.
			if (isDigit(seg.fastCodeAt(0)) && isDigit(prev.fastCodeAt(prev.length - 1))) return null;
			buf.add(seg.charAt(0).toUpperCase() + seg.substr(1));
		}
		final joined: String = buf.toString();
		return joined.charAt(0).toLowerCase() + joined.substr(1);
	}

	/**
	 * Is `name` a Haxe idiom no naming policy governs? A discard binding
	 * (`_`, `__` - `for (_ in items)`, a placeholder param) carries no meaning to
	 * spell correctly, and a dunder name (`__init__` - the static module
	 * initialiser; `__initializeUtest__`) is a language / framework contract a
	 * rename silently breaks. A single leading `__` is NOT reserved: `__width` is
	 * an ordinary field the policy still governs.
	 */
	private static function isReservedName(name: String): Bool {
		return DISCARD_NAME_PATTERN.match(name) || DUNDER_NAME_PATTERN.match(name);
	}

	/**
	 * Every plain string literal standing in an argument of a reflection call reachable from
	 * `node`, deduplicated into `out`. Recurses through the whole subtree, so a call nested
	 * in another expression counts.
	 */
	private static function collectReflectionNames(node: QueryNode, source: String, out: Array<String>): Void {
		final children: Array<QueryNode> = node.children;
		if (node.kind == 'Call' && children.length > 0 && isReflectionCallee(children[0])) for (i in 1...children.length) {
			final content: Null<String> = STRING_FOLD.literalOf(children[i], source)?.content;
			if (content != null && !out.contains(content)) out.push(content);
		}
		for (child in children) collectReflectionNames(child, source, out);
	}

	/**
	 * Whether `callee` addresses a member by name: a `FieldAccess` naming one of
	 * `REFLECTION_FIELD_METHODS` over the bare `Reflect` identifier. The receiver is matched
	 * because `field` / `setProperty` are ordinary method names any type may carry.
	 */
	private static function isReflectionCallee(callee: QueryNode): Bool {
		if (callee.kind != 'FieldAccess' || !REFLECTION_FIELD_METHODS.contains(callee.name ?? '')) return false;
		final receiver: Array<QueryNode> = callee.children;
		return receiver.length > 0 && receiver[0].kind == 'IdentExpr' && receiver[0].name == 'Reflect';
	}

	/**
	 * The `NamedDecl` for a declaration node already resolved to a `category` and a
	 * `name` — the record-building half of `walk`, split out so the walk itself
	 * stays a plain context-threading recursion.
	 */
	private static function namedDeclOf(
		node: QueryNode, parent: Null<QueryNode>, ancestors: Array<QueryNode>, category: NamingCategory, name: String, mods: Array<String>,
		structural: Bool, enclosingType: Null<String>, enclosingRtti: Bool
	): NamedDecl {
		// Interface members carry no visibility modifier but are public.
		final inInterface: Bool = parent != null && parent.kind == 'InterfaceDecl';
		final declMods: Array<String> = inInterface && !mods.contains('public') ? mods.concat(['public']) : mods;
		return {
			span: node.span,
			name: name,
			category: category,
			mods: declMods,
			enclosingType: enclosingType,
			implicitlyReachable: isImplicitlyReachable(category, name, node, ancestors, mods),
			renameUnsafe: structural || hasPhysicalAccessors(node, parent, name) || (enclosingRtti && isMemberCategory(category)),
			contractName: structural,
			reservedName: isReservedName(name)
		};
	}

	/**
	 * The neutral modifier names of `kinds` — the same projection `modsOf` reads OFF a declaration,
	 * asked here for a run this class is about to WRITE. An unmapped kind passes through as its own
	 * spelling, which no caller produces (the list is a literal in this file).
	 */
	private static function modNames(kinds: Array<String>): Array<String> {
		return [for (kind in kinds) MOD_KIND_TO_NAME[kind] ?? kind];
	}

}

/**
 * The head binding's context, handed down to the `VarMore` chain that continues it
 * (`var a = 1, b = 2;`). A `VarMore` is one kind whatever declaration it continues — a local
 * statement, a class member, a structure field — so it carries no category of its own and no
 * modifier run of its own (`static var a = 1, b = 2` writes `static` once, before the head).
 */
private typedef VarHost = {
	final category: NamingCategory;

	/** The modifier run preceding the HEAD binding, which governs every binding in the list. */
	final mods: Array<String>;

	/** Whether the head binding is an anon-structure field, whose name is a wire contract. */
	final structural: Bool;
};
