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
 */
@:keep
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.haxe.HxModule, {trivia: true}))
@:nullSafety(Strict)
final class HaxeModuleTriviaParser {}
