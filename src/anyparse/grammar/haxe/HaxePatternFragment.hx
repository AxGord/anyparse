package anyparse.grammar.haxe;

import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * Pattern-fragment wrap/extract support behind `HaxeQueryPlugin.parsePattern`'s
 * category cascade: wraps a fragment into a synthetic parseable module
 * (`_ApqPattern`) per pattern category and extracts the pattern root node
 * back out of the parsed tree.
 */
final class HaxePatternFragment {

	/**
	 * Whether the extracted pattern root's span covers (nearly) the whole
	 * variant text — the guard against a partial Decl extraction (slack of one
	 * byte tolerates a span that excludes the trailing `;`).
	 */
	public static function consumesVariant(extracted: QueryNode, variant: String): Bool {
		final span: Null<Span> = extracted.span;
		return span == null || span.to - span.from >= StringTools.trim(variant).length - 1;
	}

	public static function wrapAsStmt(src: String): String {
		return 'class _ApqPattern { static function _apq() { ${trimTrailingSemicolons(src)}; } }';
	}

	public static function wrapAsExpr(src: String): String {
		return 'class _ApqPattern { static function _apq() { var _v = ${trimTrailingSemicolons(src)}; } }';
	}

	public static function wrapAsMetaArgs(src: String): String {
		return 'class _ApqPattern { $src var _v:Int = 0; }';
	}

	public static function extractFirstDecl(module: QueryNode): Null<QueryNode> {
		return module.children.length == 0 ? null : module.children[0];
	}

	public static function extractFirstStmt(module: QueryNode): Null<QueryNode> {
		// module → ClassDecl wrapper → FunctionField → FnDecl struct →
		// HxFnBody.BlockBody (enum) → HxFnBlock struct (flattened) →
		// stmts[0]. We navigate by enum kind names; struct envelopes are
		// transparent in the QueryNode tree.
		final cls: Null<QueryNode> = findFirstByKind(module, 'ClassDecl');
		if (cls == null) return null;
		final block: Null<QueryNode> = findFirstByKind(cls, 'BlockBody');
		if (block == null) return null;
		if (block.children.length == 0) return null;
		final first: QueryNode = block.children[0];
		// A bare expression-statement pattern (`$a + $b`, `$f($_)`,
		// `trace($_);`) wraps its expression in a synthetic `ExprStmt`
		// node. Returning that wrapper as the pattern root constrains
		// matches to statement position only — the expression stays
		// invisible in var-init / argument / sub-expression position (the
		// common case). Reject it so the cascade proceeds to the Expr
		// attempt, which yields the bare expression as the root; the
		// matcher then walks every subtree and finds it anywhere.
		// Non-expression statements (if/for/while/return/var/switch/try/
		// throw) are not `ExprStmt` and pass through unchanged. Node-level
		// analog of the `trimTrailingSemicolons` wrapper-artifact fix (#3).
		return first.kind == 'ExprStmt' ? null : first;
	}

	public static function extractFirstExpr(module: QueryNode): Null<QueryNode> {
		final cls: Null<QueryNode> = findFirstByKind(module, 'ClassDecl');
		if (cls == null) return null;
		final varStmt: Null<QueryNode> = findFirstByKind(cls, 'VarStmt');
		return varStmt == null ? null : varStmt.children.length == 0 ? null : varStmt.children[varStmt.children.length - 1];
	}

	public static function extractFirstMeta(module: QueryNode): Null<QueryNode> {
		final cls: Null<QueryNode> = findFirstByKind(module, 'ClassDecl');
		return cls == null ? null : findFirstByKind(cls, 'HxMeta') ?? findFirstByKind(cls, 'Meta') ?? findFirstByKindPrefix(cls, 'Meta');
	}

	/**
	 * Drop the trailing run of `;` and whitespace from a pattern fragment.
	 * A statement or expression pattern is naturally written with a
	 * closing `;` (`return $_;`), but `wrapAsStmt` / `wrapAsExpr` append
	 * their own `;`; without trimming, the wrapped source becomes `…;;`
	 * and the Haxe grammar — which has no empty-statement production —
	 * rejects it, failing the whole cascade on a valid statement pattern.
	 * The unwrapped decl attempt keeps the original source (a
	 * `typedef X = Y;` decl pattern needs its `;`), so the trim is scoped
	 * to the wrappers only.
	 */
	private static function trimTrailingSemicolons(src: String): String {
		var end: Int = src.length;
		while (end > 0) {
			final c: Int = StringTools.fastCodeAt(src, end - 1);
			if (c == ';'.code || c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code)
				end--;
			else
				break;
		}
		return src.substring(0, end);
	}

	private static function findFirstByKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = findFirstByKind(c, kind);
			if (found != null) return found;
		}
		return null;
	}

	private static function findFirstByKindPrefix(node: QueryNode, prefix: String): Null<QueryNode> {
		if (StringTools.startsWith(node.kind, prefix)) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = findFirstByKindPrefix(c, prefix);
			if (found != null) return found;
		}
		return null;
	}

}
