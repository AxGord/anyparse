package anyparse.grammar.haxe;

/**
 * Marker class for the Trivia-mode writer of `HxModule` — mirror of
 * `HaxeModuleTriviaParser` on the write side. `{trivia: true}` on the
 * build call wires `WriterLowering` through its trivia branches: every
 * bearing rule's `writeXxx` becomes `writeXxxT`, accepts the synth
 * `*T` variant of the value, and emits captured leading/trailing
 * comments and blank-line separators around `@:trivia` Star elements.
 *
 * Usage:
 * ```haxe
 * final ast:Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
 * final rendered:String = HaxeModuleTriviaWriter.write(ast);
 * ```
 *
 * Plain-mode callers keep using `HxModuleWriter` against plain
 * `HxModule` — this marker is a sibling, not a replacement.
 *
 * `entries` adds `writeHxMemberDeclNode`, `writeHxStatementNode` and `writeHxExprNode`: a member, a
 * statement or an expression a grammar's `Constructs` built as a typed node, written alone by the
 * rules that write it in a file.
 */
@:keep
@:build(anyparse.macro.Build.buildWriter(anyparse.grammar.haxe.HxModule, anyparse.grammar.haxe.HxModuleWriteOptions, {
	trivia: true,
	entries: [
		anyparse.grammar.haxe.decl.HxMemberDecl,
		anyparse.grammar.haxe.stmt.HxStatement,
		anyparse.grammar.haxe.expr.HxExpr
	]
}))
@:nullSafety(Strict)
final class HaxeModuleTriviaWriter {}
