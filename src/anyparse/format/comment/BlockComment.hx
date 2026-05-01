package anyparse.format.comment;

/**
 * Shared C-family block comment grammar.
 *
 * Lives in the engine's `anyparse.format.comment` package so any grammar
 * (Haxe, AS3, JS, C/C++, Rust, etc.) using `/* … *\/` block comments
 * gets parsing, writing and indent canonicalization for free — no
 * format plugin code, just `import anyparse.format.comment.BlockComment`
 * and wire `BlockCommentNormalizer.processCapturedBlockComment` into
 * the format's `defaultWriteOptions.blockCommentAdapter`.
 *
 * Per-line capture: each newline in the source content splits a
 * `BlockCommentLine` carrying `{ws, body}`. The wrap is always
 * `/*` ... `*\/`. Leading / trailing `*` runs of `/** … **\/` source
 * are absorbed into line[0].body / line[N].body (regex
 * `(?:(?!\*\/)[^\n])*` accepts wrap-adjacent stars).
 *
 * `@:fmt(preWrite(...))` wires the macro writer's per-rule entry to
 * the engine-level normalizer: AST→AST common-prefix-reduce + bake
 * indent unit. Plugin grammars carry zero comment-specific code; the
 * widget owns the heuristics.
 *
 * `@:schema(JsonFormat)` is a no-op binding — `@:raw` suppresses the
 * format's whitespace, and the wrap / sep literals come from the
 * grammar itself, not the format. Any `TextFormat` would do; JSON is
 * the simplest existing format we can point at.
 */
@:peg
@:raw
@:schema(anyparse.format.comment.CFamilyCommentFormat)
@:fmt(preWrite(anyparse.format.comment.BlockCommentNormalizer.normalize))
typedef BlockComment = {
	@:lead('/*') @:trail('*/') @:sep('\n') var lines:Array<BlockCommentLine>;
};
