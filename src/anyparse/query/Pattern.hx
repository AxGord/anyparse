package anyparse.query;

/**
 * Parsed `apq search` pattern — a `QueryNode` tree augmented with
 * metavariable identification.
 *
 * Pattern syntax (frozen in `docs/cli-query-tool.md`):
 *
 *  - `$X` — bound metavariable. Same name across the pattern must
 *    unify against structurally-identical subtrees.
 *  - `$_` — wildcard. Matches any subtree, no binding, independent
 *    across occurrences.
 *
 * The grammar plugin parses pattern source by the same parser as
 * input source — the metavariable extension is plugin-local (typically
 * textual `$X` → reserved-identifier substitution before parse, then
 * post-walk reclassification of those identifiers into `Metavar`-kind
 * `QueryNode`s). The engine sees `Metavar` as just another `kind`
 * value — it is not Haxe-specific.
 *
 * `category` records which syntactic wrapping the plugin used (decl /
 * stmt / expr / meta-args). The matcher does not inspect it directly;
 * it is kept for diagnostics and future selective-search behaviour.
 */
@:nullSafety(Strict)
final class Pattern {

	public final root: QueryNode;
	public final category: PatternCategory;
	public final source: String;

	/**
	 * Plugin-supplied kind-equivalence consulted ONLY by the search
	 * `Matcher`'s kind gate. `null` = strict string equality (the
	 * default for any plugin that does not supply one).
	 *
	 * Lets a grammar declare that several position-specific
	 * `QueryNode.kind` values denote the same construct for matching
	 * (Haxe: a `var` declaration is `VarDecl` / `VarMember` /
	 * `VarStmt` by position) WITHOUT collapsing those kinds in the
	 * `QueryNode` tree — `ast` / `--select` / `refs` / `meta` keep
	 * the precise per-position vocabulary (incl. the published
	 * `--on VarMember`). Search-scoped by construction: a `Pattern`
	 * exists only for `apq search`. The `Matcher` stays
	 * language-agnostic — it consults this opaque relation, never the
	 * grammar-specific kind names.
	 */
	public final kindEquivalence: Null<KindEquivalence>;

	public function new(root: QueryNode, category: PatternCategory, source: String, ?kindEquivalence: Null<KindEquivalence>) {
		this.root = root;
		this.category = category;
		this.source = source;
		this.kindEquivalence = kindEquivalence;
	}

	/**
	 * A pattern whose resolved root is a single leaf (no children) —
	 * a bare identifier, a lone metavar, or a bare literal. Such a
	 * pattern carries no code shape: `search` would only match the
	 * name in expression position, never a declaration or type. The
	 * CLI uses this to nudge toward `refs --decls` / `uses` / `ast`.
	 */
	public inline function isDegenerate(): Bool return root.children.length == 0;

}

/**
 * A symmetric kind-equivalence relation over `QueryNode.kind` strings,
 * built from a list of equivalence classes. Two kinds match iff they
 * are the same string or canonicalise to the same class
 * representative. Kinds in no class are equivalent only to themselves.
 *
 * Carried by `Pattern` and consulted only by the search `Matcher`, so
 * the relation is scoped to pattern matching and never alters the
 * `QueryNode` tree the other commands see.
 */
@:nullSafety(Strict)
final class KindEquivalence {

	private final _canonOf: Map<String, String>;

	public function new(classes: Array<Array<String>>) {
		_canonOf = [];
		for (group in classes) {
			if (group.length == 0) continue;
			final rep: String = group[0];
			for (k in group) _canonOf[k] = rep;
		}
	}

	public inline function canon(kind: String): String {
		final c: Null<String> = _canonOf[kind];
		return c ?? kind;
	}

	public inline function equivalent(a: String, b: String): Bool {
		return a == b || canon(a) == canon(b);
	}

}

enum abstract PatternCategory(Int) {

	final Decl = 0;
	final Stmt = 1;
	final Expr = 2;
	final MetaArgs = 3;

}

@:nullSafety(Strict)
final class Metavar {

	public static final KIND: String = 'Metavar';
	public static final WILDCARD_NAME: String = '_';
	private static final PLACEHOLDER_PREFIX: String = '__APQ_MV_';
	private static final PLACEHOLDER_SUFFIX: String = '_END__';

	/**
	 * Substitute `$X` / `$_` tokens with reserved placeholder identifiers
	 * that the language's lexer accepts as ordinary identifiers. Skips
	 * occurrences inside string literals (single-quoted, double-quoted)
	 * and comments (line-style and block-style) — Haxe's specific
	 * string-comment rules; other grammars override the policy.
	 *
	 * Returns the rewritten source. The placeholder format is
	 * `__APQ_MV_<bareName>__` — reversed by `decodePlaceholderName`.
	 */
	public static function substituteMetavarsHaxe(source: String): String {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		final len: Int = source.length;
		while (i < len) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == '\''.code) {
				final end: Int = scanStringEnd(source, i, '\''.code);
				buf.addSub(source, i, end - i);
				i = end;
				continue;
			}
			if (c == '"'.code) {
				final end: Int = scanStringEnd(source, i, '"'.code);
				buf.addSub(source, i, end - i);
				i = end;
				continue;
			}
			if (c == '/'.code && i + 1 < len) {
				final c2: Int = StringTools.fastCodeAt(source, i + 1);
				if (c2 == '/'.code) {
					final end: Int = scanLineCommentEnd(source, i);
					buf.addSub(source, i, end - i);
					i = end;
					continue;
				}
				if (c2 == '*'.code) {
					final end: Int = scanBlockCommentEnd(source, i);
					buf.addSub(source, i, end - i);
					i = end;
					continue;
				}
			}
			if (c == '$'.code && i + 1 < len) {
				final next: Int = StringTools.fastCodeAt(source, i + 1);
				if (isIdentStart(next)) {
					var j: Int = i + 1;
					while (j < len && isIdentCont(StringTools.fastCodeAt(source, j))) j++;
					final bare: String = source.substring(i + 1, j);
					buf.add(PLACEHOLDER_PREFIX);
					buf.add(bare);
					buf.add(PLACEHOLDER_SUFFIX);
					i = j;
					continue;
				}
			}
			buf.addChar(c);
			i++;
		}
		return buf.toString();
	}

	/**
	 * Reverse of `substituteMetavarsHaxe`: pulls the bare metavar name
	 * out of a `__APQ_MV_<bareName>__` placeholder. Returns `null` when
	 * the input is not a placeholder.
	 */
	public static function decodePlaceholderName(ident: String): Null<String> {
		return !StringTools.startsWith(ident, PLACEHOLDER_PREFIX)
			? null
			: !StringTools.endsWith(ident, PLACEHOLDER_SUFFIX)
				? null
				: ident.substring(PLACEHOLDER_PREFIX.length, ident.length - PLACEHOLDER_SUFFIX.length);
	}

	/**
	 * Walk `tree` and reclassify placeholder-encoded metavars:
	 *  - leaf nodes (no children) whose name decodes to a metavar →
	 *    replaced wholesale with a `kind='Metavar'` node carrying the
	 *    bare name. This is the bare `$X` / `$_` form, e.g. a
	 *    standalone identifier in an expression position.
	 *  - composite nodes (with children) whose name decodes to a
	 *    metavar → name is rewritten to `$<bareName>` but the node
	 *    structure and children are preserved. This captures patterns
	 *    where the metavar appears in a name slot AND the node carries
	 *    sibling structure, e.g. `FieldAccess(receiver, $f)` — the
	 *    matcher recognises `$`-prefixed names as a name-position
	 *    metavar match-and-bind.
	 *
	 * Returns a new tree (or the same shape if no replacements
	 * happened).
	 */
	public static function reclassify(tree: QueryNode): QueryNode {
		final n: Null<String> = tree.name;
		final newChildren: Array<QueryNode> = [for (c in tree.children) reclassify(c)];
		if (n != null) {
			final bare: Null<String> = decodePlaceholderName(n);
			if (bare != null) {
				return newChildren.length == 0
					? new QueryNode(KIND, bare, [], tree.span)
					: new QueryNode(tree.kind, '$$' + bare, newChildren, tree.span);
			}
		}
		return new QueryNode(tree.kind, n, newChildren, tree.span);
	}

	private static function scanStringEnd(source: String, start: Int, quote: Int): Int {
		var i: Int = start + 1;
		final len: Int = source.length;
		while (i < len) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == '\\'.code) {
				i += 2;
				continue;
			}
			if (c == quote) return i + 1;
			i++;
		}
		return i;
	}

	private static function scanLineCommentEnd(source: String, start: Int): Int {
		var i: Int = start + 2;
		final len: Int = source.length;
		while (i < len && StringTools.fastCodeAt(source, i) != '\n'.code) i++;
		return i;
	}

	private static function scanBlockCommentEnd(source: String, start: Int): Int {
		var i: Int = start + 2;
		final len: Int = source.length;
		while (i + 1 < len) {
			if (StringTools.fastCodeAt(source, i) == '*'.code && StringTools.fastCodeAt(source, i + 1) == '/'.code) return i + 2;
			i++;
		}
		return len;
	}

	private static inline function isIdentStart(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
	}

	private static inline function isIdentCont(c: Int): Bool {
		return isIdentStart(c) || (c >= '0'.code && c <= '9'.code);
	}

}
