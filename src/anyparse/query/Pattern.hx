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

	public final root:QueryNode;
	public final category:PatternCategory;
	public final source:String;

	public function new(root:QueryNode, category:PatternCategory, source:String) {
		this.root = root;
		this.category = category;
		this.source = source;
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

	public static final KIND:String = 'Metavar';
	public static final WILDCARD_NAME:String = '_';
	private static final PLACEHOLDER_PREFIX:String = '__APQ_MV_';
	private static final PLACEHOLDER_SUFFIX:String = '_END__';

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
	public static function substituteMetavarsHaxe(source:String):String {
		final buf:StringBuf = new StringBuf();
		var i:Int = 0;
		final len:Int = source.length;
		while (i < len) {
			final c:Int = StringTools.fastCodeAt(source, i);
			if (c == '\''.code) {
				final end:Int = scanStringEnd(source, i, '\''.code);
				buf.addSub(source, i, end - i);
				i = end;
				continue;
			}
			if (c == '"'.code) {
				final end:Int = scanStringEnd(source, i, '"'.code);
				buf.addSub(source, i, end - i);
				i = end;
				continue;
			}
			if (c == '/'.code && i + 1 < len) {
				final c2:Int = StringTools.fastCodeAt(source, i + 1);
				if (c2 == '/'.code) {
					final end:Int = scanLineCommentEnd(source, i);
					buf.addSub(source, i, end - i);
					i = end;
					continue;
				}
				if (c2 == '*'.code) {
					final end:Int = scanBlockCommentEnd(source, i);
					buf.addSub(source, i, end - i);
					i = end;
					continue;
				}
			}
			if (c == '$'.code && i + 1 < len) {
				final next:Int = StringTools.fastCodeAt(source, i + 1);
				if (isIdentStart(next)) {
					var j:Int = i + 1;
					while (j < len && isIdentCont(StringTools.fastCodeAt(source, j))) j++;
					final bare:String = source.substring(i + 1, j);
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
	public static function decodePlaceholderName(ident:String):Null<String> {
		if (!StringTools.startsWith(ident, PLACEHOLDER_PREFIX)) return null;
		if (!StringTools.endsWith(ident, PLACEHOLDER_SUFFIX)) return null;
		return ident.substring(PLACEHOLDER_PREFIX.length, ident.length - PLACEHOLDER_SUFFIX.length);
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
	public static function reclassify(tree:QueryNode):QueryNode {
		final n:Null<String> = tree.name;
		final newChildren:Array<QueryNode> = [for (c in tree.children) reclassify(c)];
		if (n != null) {
			final bare:Null<String> = decodePlaceholderName(n);
			if (bare != null) {
				if (newChildren.length == 0) return new QueryNode(KIND, bare, [], tree.span);
				return new QueryNode(tree.kind, '$$' + bare, newChildren, tree.span);
			}
		}
		return new QueryNode(tree.kind, n, newChildren, tree.span);
	}

	private static function scanStringEnd(source:String, start:Int, quote:Int):Int {
		var i:Int = start + 1;
		final len:Int = source.length;
		while (i < len) {
			final c:Int = StringTools.fastCodeAt(source, i);
			if (c == '\\'.code) {
				i += 2;
				continue;
			}
			if (c == quote) return i + 1;
			i++;
		}
		return i;
	}

	private static function scanLineCommentEnd(source:String, start:Int):Int {
		var i:Int = start + 2;
		final len:Int = source.length;
		while (i < len && StringTools.fastCodeAt(source, i) != '\n'.code) i++;
		return i;
	}

	private static function scanBlockCommentEnd(source:String, start:Int):Int {
		var i:Int = start + 2;
		final len:Int = source.length;
		while (i + 1 < len) {
			if (StringTools.fastCodeAt(source, i) == '*'.code && StringTools.fastCodeAt(source, i + 1) == '/'.code)
				return i + 2;
			i++;
		}
		return len;
	}

	private static inline function isIdentStart(c:Int):Bool {
		return (c >= 'a'.code && c <= 'z'.code)
			|| (c >= 'A'.code && c <= 'Z'.code)
			|| c == '_'.code;
	}

	private static inline function isIdentCont(c:Int):Bool {
		return isIdentStart(c) || (c >= '0'.code && c <= '9'.code);
	}
}
