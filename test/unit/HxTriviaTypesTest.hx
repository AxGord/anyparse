package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HxModule;

/**
 * ω₄c — compile-time verification that `TriviaTypeSynth` synthesises a
 * `*T` paired typedef / enum for every `trivia.bearing` rule in the
 * Haxe grammar.
 *
 * Synthesised types live in a dedicated synth module at
 * `anyparse.grammar.haxe.trivia.Pairs` — atomic registration via
 * `Context.defineModule` is the cycle-safe alternative to the
 * `Context.onTypeNotFound` approach that empirically did not fire for
 * references nested inside callback-returned TypeDefinitions (see
 * `feedback_definetype_cycles.md`). The subpackage keeps the generated
 * artefacts out of the original grammar package.
 *
 * The synth module is registered during `HaxeModuleTriviaParser`'s
 * @:build — so any consumer that references `*T` types must be
 * typed **after** that marker class. The `_forceBuild` static below
 * keys on the marker class reference and is processed before any
 * method body is typed, so subsequent FQN uses of the synth types
 * inside method bodies resolve. Static-top-of-file `import` of the
 * synth sub-module types would be processed before the marker-class
 * static-init, which is too early — the FQN-in-body form is the only
 * reliable pattern until the synth module lives behind an init-macro.
 *
 * Before ω₄d lands the trivia-aware Lowering output, the Trivia-mode
 * marker class `HaxeModuleTriviaParser` still emits Plain-mode parser
 * code — `parse()` returns `HxModule`, not `HxModuleT`.
 *
 * Six bearing types are exercised below (out of the 19 the ω₄a
 * transitive closure identifies) — one direct-struct root, one
 * transitive-struct holder with `Array<HxDecl>` Star, one direct-
 * struct with optional `Null<HxType>` field, one bearing Alt enum
 * with a `@:trivia` Star branch, and one nested Seq with
 * `@:optional Null<HxStatement>` field — covering each synthesis
 * codepath in `buildTypeDefinition` / `shapeToComplexType`.
 */
class HxTriviaTypesTest extends Test {

	// Ensure `HaxeModuleTriviaParser` is typed (and its @:build runs,
	// registering every bearing `*T` type atomically via
	// `defineModule`) **before** this class's method bodies resolve
	// any `*T` reference. Without this forced reference the typing
	// order between the marker class and the synth module is
	// implementation-defined.
	private static final _forceBuild:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	public function testMarkerClassBuilds():Void {
		// Calling parse() proves the @:build pipeline completed without
		// error — if any stage (TriviaAnalysis, TriviaTypeSynth, Lowering,
		// Codegen) blew up, this test file would not compile. After ω₄d
		// the return type is the paired `HxModuleT` synth type instead
		// of Plain-mode `HxModule` because trivia-aware Lowering now
		// emits `Trivial<T>`-wrapped Star elements.
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse('class Foo {}');
		Assert.equals(1, m.decls.length);
	}

	public function testHxModuleTSynthesised():Void {
		// Direct bearing rule (`@:trivia` on `decls` field).
		final t:Null<anyparse.grammar.haxe.trivia.Pairs.HxModuleT> = null;
		Assert.isNull(t);
	}

	public function testHxDeclTSynthesised():Void {
		// Transitive bearing via enum refs to HxClassDecl / HxInterfaceDecl /
		// HxAbstractDecl (all direct bearings).
		final t:Null<anyparse.grammar.haxe.trivia.Pairs.HxDeclT> = null;
		Assert.isNull(t);
	}

	public function testHxFnDeclTSynthesised():Void {
		// Direct bearing rule (`@:trivia` on `body` field) with a
		// Null<HxType> optional field exercising the wrapOptional path.
		final t:Null<anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT> = null;
		Assert.isNull(t);
	}

	public function testHxStatementTSynthesised():Void {
		// Bearing enum with a @:trivia Star in its BlockStmt constructor.
		// Exercises the enum-Alt synthesis path + per-branch Star wrap.
		final t:Null<anyparse.grammar.haxe.trivia.Pairs.HxStatementT> = null;
		Assert.isNull(t);
	}

	public function testHxIfStmtTSynthesised():Void {
		// Transitive-bearing Seq with both a required Ref (thenBody) and
		// an optional Null<HxStatement> (elseBody) — verifies the
		// `@:optional` meta re-attach and `Null<T>` wrap both survive
		// synthesis so future ω₄d Lowering can build struct literals.
		final t:Null<anyparse.grammar.haxe.trivia.Pairs.HxIfStmtT> = null;
		Assert.isNull(t);
	}

	public function testHxExprTIsNotSynthesised():Void {
		// Negative: HxExpr is non-bearing (expressions have no @:trivia
		// Star in their transitive closure). Synth path skips non-bearing
		// rules — the `*T` name must not resolve to any registered enum
		// in the trivia.Pairs synth module.
		Assert.isNull(Type.resolveEnum('anyparse.grammar.haxe.trivia.Pairs.HxExprT'));
	}
}
