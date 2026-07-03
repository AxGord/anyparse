package anyparse.grammar.haxe;

import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.QueryNode;
import haxe.Exception;
import anyparse.query.SymbolIndex;

/**
 * The Haxe grammar's `NamingSupport`: projects the named declarations the
 * `naming` check inspects, and resolves a file's policy — a project's
 * `checkstyle.json` (discovered walking up from the file) when present, else
 * the built-in default convention.
 */
@:nullSafety(Strict)
final class HaxeNamingSupport implements NamingSupport {

	/**
	 * Modifier node kinds the Haxe projection surfaces as separate siblings
	 * preceding a declaration, mapped to neutral modifier strings. `Meta` (an
	 * `@:tag`) is part of the modifier run but contributes no modifier.
	 */
	private static final MOD_KIND_TO_NAME: Map<String, String> = [
		    'Public' => 'public', 'Private' => 'private', 'Static' => 'static',   'Inline' => 'inline',
		'Override' => 'override',     'Macro' => 'macro', 'Extern' => 'extern', 'Dynamic' => 'dynamic'
	];

	public function new() {}

	public function project(tree: QueryNode): Array<NamedDecl> {
		final out: Array<NamedDecl> = [];
		walk(tree, null, null, out);
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
				label: 'UPPER_SNAKE or camelCase static final'
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
				label: 'camelCase public field'
			},
			{
				category: NamingCategory.Method,
				requireMods: [],
				forbidMods: [],
				format: new EReg("^[a-z][a-zA-Z0-9_]*$", ''),
				label: 'camelCase method'
			},
			{
				category: NamingCategory.Local,
				requireMods: [],
				forbidMods: [],
				format: new EReg("^[a-z_][a-zA-Z0-9]*$", ''),
				label: 'camelCase local',
				normalize: lowercaseFirst
			},
			{
				category: NamingCategory.Param,
				requireMods: [],
				forbidMods: [],
				format: new EReg("^[a-z_][a-zA-Z0-9]*$", ''),
				label: 'camelCase parameter',
				normalize: lowercaseFirst
			},
			{
				category: NamingCategory.CatchVar,
				requireMods: [],
				forbidMods: [],
				format: new EReg("^[a-z_][a-zA-Z0-9]*$", ''),
				label: 'camelCase catch variable',
				normalize: lowercaseFirst
			}
		];
	}

	/**
	 * Walk `node`, appending a `NamedDecl` for every declaration whose kind
	 * maps to a category. `mods` come from the modifier siblings preceding the
	 * node in its parent (the projection surfaces `public static fn` as
	 * `(Public)(Static)(FnMember)`), so a `final` field is a Constant when
	 * static and a Field otherwise.
	 */
	private static function walk(node: QueryNode, parent: Null<QueryNode>, enclosingType: Null<String>, out: Array<NamedDecl>): Void {
		// Macro reification (`macro { … }`) is opaque: its identifiers are splice
		// templates (`$name`), not real declarations — skip the whole subtree, as
		// `unused-local` does with the plugin's `opaqueKinds`.
		if (node.kind == 'MacroExpr') return;
		final mods: Array<String> = modsOf(node, parent);
		var category: Null<NamingCategory> = categoryOf(node, mods);
		if (parent != null && parent.kind == 'EnumAbstractDecl' && (node.kind == 'FinalMember' || node.kind == 'VarMember'))
			category = NamingCategory.EnumValue;
		final name: Null<String> = node.name;
		if (category != null && name != null) {
			// Re-bind to non-null finals: strict null-safety does not narrow a
			// guarded local inside an anonymous struct literal.
			final categoryValue: NamingCategory = category;
			final declName: String = name;
			// Interface members carry no visibility modifier but are public.
			final inInterface: Bool = parent != null && parent.kind == 'InterfaceDecl';
			final declMods: Array<String> = inInterface && !mods.contains('public') ? mods.concat(['public']) : mods;
			out.push({
				span: node.span,
				name: declName,
				category: categoryValue,
				mods: declMods,
				enclosingType: enclosingType,
				implicitlyReachable: isImplicitlyReachable(categoryValue, declName, node, parent, mods)
			});
		}
		// A type decl becomes the enclosing type of its descendants — its name is
		// on the node carrying category Type (the inner ClassForm for a final class).
		final childEnclosing: Null<String> = category == NamingCategory.Type && name != null ? name : enclosingType;
		for (child in node.children) walk(child, node, childEnclosing, out);
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
			else if (siblings[i].kind != 'Meta') break;
			i--;
		}
		return mods;
	}

	/** The naming category of a declaration node, or null if its kind is not name-checked. */
	private static function categoryOf(node: QueryNode, mods: Array<String>): Null<NamingCategory> {
		return switch node.kind {
			case 'ClassDecl' | 'ClassForm' | 'InterfaceDecl' | 'EnumDecl' | 'AbstractDecl' | 'EnumAbstractDecl' | 'TypedefDecl': NamingCategory.Type;
			case 'FnMember' | 'FinalModifiedMember': NamingCategory.Method;
			case 'VarMember': NamingCategory.Field;
			case 'FinalMember': mods.contains('static') ? NamingCategory.Constant : NamingCategory.Field;
			case 'SimpleCtor' | 'ParamCtor': NamingCategory.EnumValue;
			case 'VarStmt' | 'FinalStmt': NamingCategory.Local;
			case 'Required' | 'Optional' | 'Rest' | 'LambdaParam': NamingCategory.Param;
			case 'CatchClause': NamingCategory.CatchVar;
			case _: null;
		}
	}

	/**
	 * The mechanical fix for a PascalCase local / param / catch name: lowercase
	 * the first character. Returns null only for the empty string. Not `inline`
	 * — it is passed as a `NamingRule.normalize` function value.
	 */
	private static function lowercaseFirst(name: String): Null<String> {
		return name.length == 0 ? null : name.charAt(0).toLowerCase() + name.substr(1);
	}

	/**
	 * The mechanical fix for a private field missing its `_` prefix: prepend `_`
	 * and lowercase the first letter (`shape`→`_shape`, `Shape`→`_shape`). Not
	 * `inline` — passed as a `NamingRule.normalize` function value.
	 */
	private static function underscoreCamel(name: String): Null<String> {
		return name.length == 0 ? null : '_' + name.charAt(0).toLowerCase() + name.substr(1);
	}

	/**
	 * Whether a member can be reached without an in-source identifier reference: a
	 * constructor (`new`), a property accessor (`get_` / `set_`, invoked through a
	 * `(get, set)` property), or an annotation-bearing member a framework / macro
	 * may reach. Non-members are never implicitly reachable.
	 */
	private static function isImplicitlyReachable(
		category: NamingCategory, name: String, node: QueryNode, parent: Null<QueryNode>, mods: Array<String>
	): Bool {
		return (category == NamingCategory.Field || category == NamingCategory.Method || category == NamingCategory.Constant)
			&& (name == 'new' || StringTools.startsWith(name, 'get_') || StringTools.startsWith(name, 'set_') || metaPrecedes(node, parent)
				|| node.kind == 'FinalMember' && mods.contains('static') && isTypeReferenceInit(node));
	}

	/**
	 * Does a `Meta` (`@:tag`) sibling precede `node` in its modifier / meta run?
	 * Scans the preceding siblings, skipping modifier kinds; a `Meta` reached
	 * before any non-modifier sibling means the declaration carries an annotation.
	 */
	private static function metaPrecedes(node: QueryNode, parent: Null<QueryNode>): Bool {
		if (parent == null) return false;
		final siblings: Array<QueryNode> = parent.children;
		var i: Int = siblings.indexOf(node) - 1;
		while (i >= 0) {
			final kind: String = siblings[i].kind;
			if (kind == 'Meta') return true;
			if (!MOD_KIND_TO_NAME.exists(kind)) break;
			i--;
		}
		return false;
	}

	/** A method name utest's `@:autoBuild` collects: a `test*` / `spec*` test or a `setup*` / `teardown*` fixture. */
	private static function isUtestMethodName(name: String): Bool {
		return StringTools.startsWith(name, 'test') || StringTools.startsWith(name, 'spec') || StringTools.startsWith(name, 'setup')
			|| StringTools.startsWith(name, 'teardown');
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

}
