package anyparse.query;

import anyparse.runtime.Span;

using Lambda;
using StringTools;

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

	/**
	 * Metavariable names the user WROTE that no node in `root` carries — the
	 * pattern is therefore wider (or, for an undecoded name slot, narrower)
	 * than the source says, and silently so.
	 *
	 * A metavar disappears when it lands in a source position the grammar does
	 * not project as a node: a declared type (`final $n:$t = $v` keeps `$n` and
	 * `$v`, never `$t`), a `cast($x, $T)` target type, a metadata name (`@:$m`,
	 * whose placeholder is not even decodable — the name slot reads
	 * `@:__APQ_MV_m_END__` and can never match). Reported once per lost
	 * OCCURRENCE-set rather than per occurrence, so `f($x, $x)` with one half
	 * dropped still names `x`.
	 */
	public final ignoredMetavars: Array<String>;

	public function new(
		root: QueryNode, category: PatternCategory, source: String, ?kindEquivalence: Null<KindEquivalence>,
		?ignoredMetavars: Null<Array<String>>
	) {
		this.root = root;
		this.category = category;
		this.source = source;
		this.kindEquivalence = kindEquivalence;
		this.ignoredMetavars = ignoredMetavars ?? [];
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

	private final _canonOf: Map<String, String> = [];

	public function new(classes: Array<Array<String>>) {
		for (group in classes) if (group.length != 0) {
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

/**
 * The `$X` / `$_` metavariable token machinery for structural patterns: substitutes each metavariable with a reserved placeholder identifier the language lexer accepts, so a pattern parses as ordinary source, then maps captured nodes back by placeholder.
 */
@:nullSafety(Strict)
final class Metavar {

	public static final KIND: String = 'Metavar';
	public static final WILDCARD_NAME: String = '_';

	private static final PLACEHOLDER_PREFIX: String = '__APQ_MV_';
	private static final PLACEHOLDER_SUFFIX: String = '_END__';

	/**
	 * Substitute `$X` / `$_` tokens — and the `...` ellipsis in a child slot,
	 * see `PatternStar` — with reserved placeholder identifiers that the
	 * language's lexer accepts as ordinary identifiers. Skips occurrences
	 * inside string literals (single-quoted, double-quoted) and comments
	 * (line-style and block-style) — Haxe's specific string-comment rules;
	 * other grammars override the policy. The ellipsis rides in this ONE pass
	 * rather than a second scan so the string / comment policy that decides
	 * what is a token is written down exactly once.
	 *
	 * Returns the rewritten source. The placeholder format is
	 * `__APQ_MV_<bareName>__` — reversed by `decodePlaceholderName`.
	 */
	public static function substituteMetavarsHaxe(source: String): String {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		final len: Int = source.length;
		inline function copyRun(from: Int, end: Int): Int {
			buf.addSub(source, from, end - from);
			return end;
		}
		while (i < len) {
			final c: Int = source.fastCodeAt(i);
			if (c == '\''.code || c == '"'.code) {
				i = copyRun(i, scanStringEnd(source, i, c));
				continue;
			}
			if (c == '/'.code && i + 1 < len) {
				final c2: Int = source.fastCodeAt(i + 1);
				if (c2 == '/'.code) {
					i = copyRun(i, scanLineCommentEnd(source, i));
					continue;
				}
				if (c2 == '*'.code) {
					i = copyRun(i, scanBlockCommentEnd(source, i));
					continue;
				}
			}
			// `...` standing alone in a child slot is the ellipsis; a range
			// (`0...n`) or a spread (`f(...arr)`) has an operand on one side
			// and is copied through as ordinary source.
			if (
				c == '.'.code && i + PatternStar.TOKEN_LENGTH <= len && source.fastCodeAt(i + 1) == '.'.code
				&& source.fastCodeAt(i + 2) == '.'.code && PatternStar.isStarSlot(source, i)
			) {
				buf.add(PatternStar.PLACEHOLDER);
				i += PatternStar.TOKEN_LENGTH;
				continue;
			}
			if (c == '$'.code && i + 1 < len) {
				final next: Int = source.fastCodeAt(i + 1);
				if (isIdentStart(next)) {
					var j: Int = i + 1;
					while (j < len && isIdentCont(source.fastCodeAt(j))) j++;
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
		return if (!ident.startsWith(PLACEHOLDER_PREFIX))
			null
		else if (!ident.endsWith(PLACEHOLDER_SUFFIX))
			null
		else
			ident.substring(PLACEHOLDER_PREFIX.length, ident.length - PLACEHOLDER_SUFFIX.length);
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
	public static function reclassify(tree: QueryNode, identKind: String): QueryNode {
		final n: Null<String> = tree.name;
		final newChildren: Array<QueryNode> = [for (c in tree.children) reclassify(c, identKind)];
		if (n != null) {
			final bare: Null<String> = decodePlaceholderName(n);
			if (bare != null) {
				return tree.kind == identKind && newChildren.length == 0
					? new QueryNode(KIND, bare, [], tree.span)
					: new QueryNode(tree.kind, '$$$bare', newChildren, tree.span);
			}
		}
		return new QueryNode(tree.kind, n, newChildren, tree.span);
	}

	/**
	 * How many times each metavariable name occurs in `substituted` (the
	 * output of `substituteMetavarsHaxe`). Counted on the substituted text
	 * rather than the raw source so the string / comment policy that decided
	 * what IS a metavar is applied exactly once.
	 */
	public static function placeholderCounts(substituted: String): Map<String, Int> {
		final out: Map<String, Int> = [];
		var i: Int = substituted.indexOf(PLACEHOLDER_PREFIX);
		while (i >= 0) {
			final from: Int = i + PLACEHOLDER_PREFIX.length;
			final end: Int = substituted.indexOf(PLACEHOLDER_SUFFIX, from);
			if (end < 0) break;
			final bare: String = substituted.substring(from, end);
			out[bare] = (out[bare] ?? 0) + 1;
			i = substituted.indexOf(PLACEHOLDER_PREFIX, end + PLACEHOLDER_SUFFIX.length);
		}
		return out;
	}

	/** How many times each metavariable name survives in a reclassified pattern tree. */
	public static function treeCounts(tree: QueryNode): Map<String, Int> {
		final out: Map<String, Int> = [];
		countInto(tree, out);
		return out;
	}

	/**
	 * Metavariable names written in `substituted` that `tree` carries fewer
	 * times than the source did — the positions the grammar did not project as
	 * nodes. `$_` is counted like any other name: a wildcard lost in a type
	 * annotation is the same silent widening as a named one.
	 */
	public static function ignoredNames(substituted: String, tree: QueryNode): Array<String> {
		final written: Map<String, Int> = placeholderCounts(substituted);
		final kept: Map<String, Int> = treeCounts(tree);
		final out: Array<String> = [for (name => count in written) if (count > kept[name] ?? 0) name];
		out.sort(Reflect.compare);
		return out;
	}

	private static inline function isIdentStart(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
	}

	private static inline function isIdentCont(c: Int): Bool {
		return isIdentStart(c) || (c >= '0'.code && c <= '9'.code);
	}

	private static function scanStringEnd(source: String, start: Int, quote: Int): Int {
		var i: Int = start + 1;
		final len: Int = source.length;
		while (i < len) {
			final c: Int = source.fastCodeAt(i);
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
		while (i < len && source.fastCodeAt(i) != '\n'.code) i++;
		return i;
	}

	private static function scanBlockCommentEnd(source: String, start: Int): Int {
		var i: Int = start + 2;
		final len: Int = source.length;
		while (i + 1 < len) {
			if (source.fastCodeAt(i) == '*'.code && source.fastCodeAt(i + 1) == '/'.code) return i + 2;
			i++;
		}
		return len;
	}


	private static function countInto(node: QueryNode, into: Map<String, Int>): Void {
		final n: Null<String> = node.name;
		if (n != null) {
			final bare: Null<String> = if (node.kind == KIND)
				n;
			else if (n.startsWith('$'))
				n.substring(1);
			else
				null;
			if (bare != null) into[bare] = (into[bare] ?? 0) + 1;
		}
		for (c in node.children) countInto(c, into);
	}

}

/**
 * The `...` ellipsis — "any run of children here", the one variable-arity
 * construct in the pattern language.
 *
 * **Why `...` and not `$...` / `$*`.** `docs/cli-query-tool.md` already
 * reserved this exact token ("The 'anywhere in this container' form is
 * reserved for a future ellipsis syntax (`...`)"), so no other spelling was
 * a free choice. It also reads right: `$` is the language's BINDS marker,
 * and a star does NOT bind (see below), so spelling it `$...` would promise
 * a capture that does not exist. And it is free: `f(...)`, `new $T(...)` and
 * `[...]` are all hard parse refusals today, so no pattern changes meaning.
 *
 * **What it does NOT touch.** Haxe's own two `...` are the range operator
 * (`0...n`) and rest/spread (`f(...arr)`, `function f(...xs:Int)`). Neither
 * ever stands ALONE in a child slot, so `isStarSlot` recognises the ellipsis
 * only when the nearest non-space neighbours on both sides are slot
 * punctuation — an operand on either side means it is a range or a spread and
 * the token is passed through untouched.
 *
 * **It does not bind.** A star absorbs zero or more siblings; `Match.bindings`
 * maps one name to one `QueryNode` and the `search --json` binding schema is
 * frozen as `{name, text, span}`, so there is nowhere to put a node LIST
 * without breaking both. Consequence: `Rewrite` (`apq rewrite`) refuses a
 * starred pattern outright — its replacement template can only name bound
 * metavars, so the absorbed children would be deleted in silence. The
 * `--match` op locator is NOT gated: it only addresses a node, and the op
 * that follows edits that node under its own semantics.
 */
@:nullSafety(Strict)
final class PatternStar {

	/** `TOKEN.length`, spelled as a constant so neither the scanner's lookahead nor its advance is a magic number. */
	public static inline final TOKEN_LENGTH: Int = 3;

	public static final KIND: String = 'PatternStar';

	/** The reserved identifier `...` is substituted for, so the grammar's own parser accepts a starred pattern unchanged. */
	public static final PLACEHOLDER: String = '__APQ_STAR__';

	private static final TOKEN: String = '...';
	private static final ROOT_STAR_REFUSAL: String = 'pattern: `...` alone matches every node — it is a wildcard, not a pattern ('
		+ 'use `$$_` for "any ONE node", or put the `...` inside a call / constructor / literal: `f(...)`, `new T(...)`, `[...]`)';
	private static final NAME_SLOT_REFUSAL: String = 'pattern: `...` cannot stand where the grammar needs a name — it marks a run of '
		+ 'CHILDREN, so it belongs inside the brackets (' + '`new T(...)`), not in place of the type or callee';
	private static final TWO_STARS_REFUSAL: String = 'pattern: two `...` in one child list — the matcher anchors one prefix and one suffix '
		+ 'around a SINGLE star, so a second one has nothing to anchor against ('
		+ '`new $$T<...>(...)` in particular cannot work: a constructor call keeps its type '
		+ 'arguments and its value arguments in ONE flat child list, so the two stars would be ' + 'indistinguishable)';

	/**
	 * True when the `...` starting at `at` stands alone in a child slot —
	 * the nearest non-space character before it is one of `([{,<` or the
	 * start of the pattern, and after it one of `)]},>` or the end. A range
	 * (`0...n`) has an operand before, a spread (`...arr`) has one after.
	 */
	public static function isStarSlot(source: String, at: Int): Bool {
		var before: Int = at - 1;
		while (before >= 0 && isSpace(source.fastCodeAt(before))) before--;
		if (before >= 0) {
			final c: Int = source.fastCodeAt(before);
			if (c != '('.code && c != '['.code && c != '{'.code && c != ','.code && c != '<'.code) return false;
		}
		var after: Int = at + TOKEN_LENGTH;
		final len: Int = source.length;
		while (after < len && isSpace(source.fastCodeAt(after))) after++;
		if (after < len) {
			final c: Int = source.fastCodeAt(after);
			if (c != ')'.code && c != ']'.code && c != '}'.code && c != ','.code && c != '>'.code) return false;
		}
		return true;
	}

	/**
	 * Turn each node that IS the placeholder into a `PatternStar` node
	 * (name-less: nothing can reference it).
	 *
	 * "Is the placeholder" is decided by SPAN, not by kind — childless, and
	 * occupying exactly the placeholder's own text. That is the same trap
	 * `64f9eee7` fell into for metavars (`new $x()` collapsed wholesale into a
	 * match-everything hole because the NewExpr was childless too), and the
	 * same trap in the other direction: `Metavar.reclassify` answers it with a
	 * plugin-supplied `identKind`, which cannot serve here because the star has
	 * to reach a TYPE-argument slot as well (`new $T<...>()` projects `Named`,
	 * not the identifier kind). A span comparison needs no grammar vocabulary
	 * and separates the two cases exactly: in `new __APQ_STAR__()` the
	 * `NewExpr`'s span runs from `new` to `)`, so the placeholder is a PART of
	 * that node and the node is left named — `validate` then refuses it.
	 *
	 * Runs BEFORE `Metavar.reclassify` so the metavar path never sees the
	 * placeholder: the star's whole point is that it is not a metavar.
	 */
	public static function reclassify(tree: QueryNode): QueryNode {
		final children: Array<QueryNode> = [for (c in tree.children) reclassify(c)];
		final span: Null<Span> = tree.span;
		return tree.name == PLACEHOLDER && children.length == 0 && span != null && span.to - span.from == PLACEHOLDER.length
			? new QueryNode(KIND, null, [], span)
			: new QueryNode(tree.kind, tree.name, children, tree.span);
	}

	/**
	 * The three refusals, as one message or `null` when the pattern is sound:
	 *
	 *  - a star as the pattern ROOT (`...`, and `new ...()` whose whole node
	 *    collapses into one) — that is a match-everything wildcard, not a
	 *    pattern, and `$_` already spells "one of anything";
	 *  - TWO stars in ONE child list — the matcher anchors a prefix from the
	 *    left and a suffix from the right around exactly one star, and a
	 *    second needs backtracking. For the position that would motivate it,
	 *    `new $T<...>(...)`, it would be a lie anyway: `NewExpr` flattens type
	 *    arguments and value arguments into one child list, so the two stars
	 *    are indistinguishable and the pattern would mean exactly `new $T(...)`;
	 *  - the placeholder surviving in a NAME slot — the ellipsis was written
	 *    where an identifier is required.
	 */
	public static function validate(root: QueryNode): Null<String> {
		return root.kind == KIND ? ROOT_STAR_REFUSAL : checkNode(root);
	}

	/** True when `root` contains at least one star — the gate every text-producing op consults. */
	public static function contains(root: QueryNode): Bool {
		if (root.kind == KIND) return true;
		return root.children.exists(c -> contains(c));
	}

	private static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

	private static function checkNode(node: QueryNode): Null<String> {
		if (node.name == PLACEHOLDER) return NAME_SLOT_REFUSAL;
		var stars: Int = 0;
		for (c in node.children) if (c.kind == KIND) stars++;
		if (stars > 1) return TWO_STARS_REFUSAL;
		for (c in node.children) {
			final message: Null<String> = checkNode(c);
			if (message != null) return message;
		}
		return null;
	}

}
