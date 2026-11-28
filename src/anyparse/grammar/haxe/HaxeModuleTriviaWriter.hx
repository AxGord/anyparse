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
 * `entries` adds one `write<Type>Node` per listed type (a member, a statement, an expression, a type, a
 * declaration and a member modifier): a node a grammar's `Constructs` built as a typed node, written alone
 * by the rules that write it in a file.
 */
@:keep
@:build(anyparse.macro.Build.buildWriter(anyparse.grammar.haxe.HxModule, anyparse.grammar.haxe.HxModuleWriteOptions, {
	trivia: true,
	entries: [
		anyparse.grammar.haxe.decl.HxMemberDecl,
		anyparse.grammar.haxe.stmt.HxStatement,
		anyparse.grammar.haxe.expr.HxExpr,
		anyparse.grammar.haxe.types.HxType,
		anyparse.grammar.haxe.decl.HxDecl,
		anyparse.grammar.haxe.meta.HxMemberModifier
	]
}))
@:nullSafety(Strict)
final class HaxeModuleTriviaWriter {}
