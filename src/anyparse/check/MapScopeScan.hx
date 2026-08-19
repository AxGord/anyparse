package anyparse.check;

import anyparse.check.PreferMapType.Scope;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * The NAME-BINDING half of `prefer-map-type`: reading one file's header into the `Scope`
 * record the rule's two resolution questions run off — does a short `IntMap` written here
 * MEAN `haxe.ds.IntMap`, and is the name `Map` free to be written at all.
 *
 * That is a self-contained walk over the module's imports, `using`s, wildcards, type
 * declarations and one-hop type aliases; nothing in it knows what a map is. Split out of
 * `PreferMapType`, which keeps the questions asked OF the resolved scope.
 */
@:access(anyparse.check.PreferMapType)
@:nullSafety(Strict)
final class MapScopeScan {

	/** The wildcard import's trailing segment, stripped to recover the imported package. */
	private static inline final WILDCARD_SUFFIX: String = '.*';

	/** The plain `import a.b.X;` declaration kind (spelled literally, as `UsingScan`'s import anchors are). */
	private static inline final IMPORT_DECL_KIND: String = 'ImportDecl';

	/** The `import a.b.*;` declaration kind. */
	private static inline final WILDCARD_IMPORT_KIND: String = 'ImportWildDecl';

	/** The `using a.b.*;` declaration kind — the `using` twin of `WILDCARD_IMPORT_KIND` (`UsingScan.USING_DECL_KIND` names the plain one). */
	private static inline final WILDCARD_USING_KIND: String = 'UsingWildDecl';

	/** The aliasing import kinds (`import a.b.X as Y;` / `… in Y;`) — each binds a simple name to an unexposed path. */
	private static final ALIAS_IMPORT_KINDS: Array<String> = ['ImportAliasDecl', 'ImportAliasInDecl'];

	/** What `tree`'s file binds — the header imports plus every type the module declares — with the `Map` answer precomputed. */
	public static function scopeOf(tree: QueryNode, shape: RefShape): Scope {
		final typeDecls: Array<String> = (shape.typeDeclKinds ?? []).copy();
		final enumAbstract: Null<String> = shape.enumAbstractDeclKind;
		if (enumAbstract != null && !typeDecls.contains(enumAbstract)) typeDecls.push(enumAbstract);
		// A `final class` projects as a nameless wrapper around the named form, so the name is read
		// through the same host list `misplaced-type-doc` reads it through.
		final nameHosts: Array<String> = (shape.visibilityContainerKinds ?? []).concat(shape.interfaceDeclKinds ?? []);
		final scope: Scope = {
			imports: [],
			aliases: [],
			wildcards: [],
			declared: [],
			aliasTargets: [],
			mapFree: false
		};
		collectScope(tree, typeDecls, shape.aliasingDeclKinds ?? [], nameHosts, scope);
		final boundMap: Null<String> = scope.imports[PreferMapType.UNIFIED_MAP];
		scope.mapFree = !scope.declared.contains(PreferMapType.UNIFIED_MAP) && !scope.aliases.contains(PreferMapType.UNIFIED_MAP)
			&& (boundMap == null || boundMap == PreferMapType.QUALIFIED_PREFIX + PreferMapType.UNIFIED_MAP);
		return scope;
	}

	/**
	 * Collect `node`'s subtree into `scope`. The walk is the WHOLE tree rather than the module's
	 * direct children so a declaration wrapped in a conditional region still registers as declared —
	 * the conservative direction for a shadowing question.
	 *
	 * A `using` binds a simple name exactly as an `import` does (it only ADDS extension resolution),
	 * so the two forms feed the same two slots: a foreign `using foo.Map;` shadows the unified name
	 * just as hard as `import foo.Map;`.
	 */
	private static function collectScope(
		node: QueryNode, typeDecls: Array<String>, aliasingDecls: Array<String>, nameHosts: Array<String>, scope: Scope
	): Void {
		final name: Null<String> = node.name;
		if (name != null) switch node.kind {
			case IMPORT_DECL_KIND, UsingScan.USING_DECL_KIND:
				scope.imports[CheckScan.simpleModuleName(name)] = name;
			case WILDCARD_IMPORT_KIND, WILDCARD_USING_KIND:
				if (StringTools.endsWith(name, WILDCARD_SUFFIX)) scope.wildcards.push(name.substr(0, name.length - WILDCARD_SUFFIX.length));
			case _:
				if (ALIAS_IMPORT_KINDS.contains(node.kind)) scope.aliases.push(name);
		}
		if (typeDecls.contains(node.kind)) {
			final declared: String = CheckScan.typeDeclName(node, nameHosts);
			scope.declared.push(declared);
			final target: Null<String> = aliasingDecls.contains(node.kind) ? aliasTargetOf(node) : null;
			if (target != null) scope.aliasTargets[declared] = target;
		}
		for (child in node.children) collectScope(child, typeDecls, aliasingDecls, nameHosts, scope);
	}

	/**
	 * The type a module-declared typedef / abstract stands for — a typedef's aliased type or an
	 * abstract's underlying type — or null when it is not a plain nominal.
	 *
	 * Both project as a LEADING run of type-reference children, and both may be preceded in that run
	 * by their own type-parameter constraints (`typedef T<K:Foo> = String` → `Foo`, then `String`;
	 * `abstract A<K:Foo>(MyClass)` → `Foo`, then `MyClass`). The head is therefore the LAST child of
	 * the run that is not NESTED inside an earlier one — the nesting test being what keeps
	 * `typedef T = Array<String>` answering `Array` rather than its type argument.
	 */
	private static function aliasTargetOf(node: QueryNode): Null<String> {
		var head: Null<QueryNode> = null;
		for (child in node.children) {
			if (child.kind != PreferMapType.ANNOTATION_TYPE_KIND && child.kind != PreferMapType.CLAUSE_TYPE_KIND) break;
			final span: Null<Span> = child.span;
			if (span == null) break;
			final current: Null<Span> = head?.span;
			if (current == null || span.from >= current.to || span.to <= current.from) head = child;
		}
		final name: Null<String> = head?.name;
		return name == null ? null : CheckScan.simpleModuleName(name);
	}

}
