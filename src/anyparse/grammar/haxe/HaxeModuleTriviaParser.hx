package anyparse.grammar.haxe;

/**
 * Marker class for the Trivia-mode parser of `HxModule` — the same
 * grammar root as `HaxeModuleParser` but with the `{trivia: true}`
 * option that turns on `TriviaAnalysis` + `TriviaTypeSynth` at macro
 * time.
 *
 * In ω₄c the class body is generated identically to
 * `HaxeModuleParser` — Lowering does not yet emit trivia-aware parser
 * code. What ω₄c adds is compile-time visibility of the paired `*T`
 * types (`HxModuleT`, `HxStatementT`, `HxFnDeclT`, …) on every
 * trivia-bearing rule: `Context.defineModule` registers them
 * atomically in one synth module, so ω₄d Lowering has somewhere to
 * emit the `Trivial<T>`-wrapping parser output.
 *
 * `@:keep` forces inclusion even without direct runtime references so
 * the `@:build` pipeline fires regardless of DCE. The class body is
 * empty on purpose — edits would just be clobbered by the next
 * compile.
 *
 * `entries` adds one `parse<Type>Node` per listed type (a type, an expression, a function body, a lambda parameter and
 * the four import paths) and `parseHxStatementBlockStmtInterior` for a block's statement run: a part copied from a
 * source is read as exactly one node of the slot it fills, with its own trivia, and anything else is refused.
 */
@:keep
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.haxe.HxModule, {
	trivia: true,
	entries: [
		anyparse.grammar.haxe.types.HxType,
		anyparse.grammar.haxe.expr.HxExpr,
		anyparse.grammar.haxe.decl.HxFnBody,
		anyparse.grammar.haxe.expr.HxLambdaParam,
		anyparse.grammar.haxe.decl.HxWildPath,
		anyparse.grammar.haxe.decl.HxImportAlias,
		anyparse.grammar.haxe.decl.HxImportAliasIn,
		anyparse.grammar.haxe.types.HxTypeName,
		anyparse.grammar.haxe.stmt.HxStatement.BlockStmt
	]
}))
@:nullSafety(Strict)
final class HaxeModuleTriviaParser {}
