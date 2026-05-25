package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Session 14 Phase 3 — struct-field `@:trailOpt(LIT)` parser capture.
 *
 * `Lowering` now captures `matchLit(trailText)` presence on every Ref
 * struct field carrying `@:trailOpt(LIT)` (both the mandatory-Ref and
 * the optional-Ref + kw/lead paths) into `_trailPresent_<field>:Bool`,
 * which is pushed onto the trivia-paired struct literal as
 * `<field>TrailPresent` (suffix shared with the `@:sep+@:trail` Star
 * case — disjoint host kinds within one Seq, no collision).
 *
 * Pilot site: `HxIfExpr.thenBranch` (`@:trailOpt(';')`), reached
 * through `HxStatement.FinalStmt` -> `HxVarDecl.init` -> `HxExpr.IfExpr`.
 * The slot is `@:optional Null<Bool>` per
 * `TriviaTypeSynth.buildStructFieldTrailPresentSlot`, populated `true`
 * on `;` hit and `false` on miss — never `null` on the Lowering path
 * (`null` is reserved for raw->paired upcasts via
 * `Converters.rawToPaired_*`, where preWrite plugins don't preserve
 * source presence).
 *
 * Phase 4 (future) will wire the writer to read this slot and gate
 * trail re-emission on source presence — until then the captured value
 * is unobserved and the writer falls back to its existing AST-shape
 * gates. Δsweep 0 is the hard invariant for Phase 3.
 *
 * Helper sigs CANNOT reference paired sub-module types — signature
 * typing precedes the marker class's static-init, so the synth module
 * isn't registered yet. Each test method inlines the destructuring
 * switch chain into its body (see lang-haxe gotcha "Helper Signatures
 * Cannot Reference Context.defineModule-Synth Sub-Module Types").
 */
class HxStructFieldTrailPresentSliceTest extends Test {

	private static final _forceBuild:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	public function new():Void {
		super();
	}

	public function testThenBranchTrailPresentTrue():Void {
		// Source has `;` after `b` -> HxIfExpr.thenBranch's @:trailOpt(';')
		// captures it, slot must be true.
		final source:String = 'class M { static function f() { final x = if (a) b; else c; } }';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		final fn:anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT = switch cls.members[0].node.member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
		final stmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch fn.body {
				case BlockBody(b): b.stmts;
				case _: throw 'expected BlockBody';
			};
		final varDecl:anyparse.grammar.haxe.trivia.Pairs.HxVarDeclT = switch stmts[0].node {
			case FinalStmt(decl): decl;
			case _: throw 'expected FinalStmt';
		};
		final init:anyparse.grammar.haxe.trivia.Pairs.HxExprT = switch varDecl.init {
			case null: throw 'expected init expr';
			case e: e;
		};
		final ifExpr:anyparse.grammar.haxe.trivia.Pairs.HxIfExprT = switch init {
			case IfExpr(decl): decl;
			case _: throw 'expected IfExpr';
		};
		Assert.equals(true, ifExpr.thenBranchTrailPresent);
	}

	public function testThenBranchTrailPresentFalse():Void {
		// Source omits the `;` between `b` and `else`. The @:trailOpt
		// matchLit fails (no `;`), `ctx.pos` rewinds, slot stays false.
		final source:String = 'class M { static function f() { final x = if (a) b else c; } }';
		final m:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final cls:anyparse.grammar.haxe.trivia.Pairs.HxClassDeclT = switch m.decls[0].node.decl {
			case ClassDecl(decl): decl;
			case _: throw 'expected ClassDecl';
		};
		final fn:anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT = switch cls.members[0].node.member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
		final stmts:Array<anyparse.runtime.Trivial<anyparse.grammar.haxe.trivia.Pairs.HxStatementT>>
			= switch fn.body {
				case BlockBody(b): b.stmts;
				case _: throw 'expected BlockBody';
			};
		final varDecl:anyparse.grammar.haxe.trivia.Pairs.HxVarDeclT = switch stmts[0].node {
			case FinalStmt(decl): decl;
			case _: throw 'expected FinalStmt';
		};
		final init:anyparse.grammar.haxe.trivia.Pairs.HxExprT = switch varDecl.init {
			case null: throw 'expected init expr';
			case e: e;
		};
		final ifExpr:anyparse.grammar.haxe.trivia.Pairs.HxIfExprT = switch init {
			case IfExpr(decl): decl;
			case _: throw 'expected IfExpr';
		};
		Assert.equals(false, ifExpr.thenBranchTrailPresent);
	}

	/**
	 * Session 14 Phase 4 — writer round-trip preserves source `;` presence
	 * on a struct-field `@:trailOpt(';')` slot. Mandatory-Ref path
	 * (`HxIfExpr.thenBranch`): source `if (a) b; else c;` keeps the
	 * trailing `;`, source `if (a) b else c;` keeps the absence. Pre-
	 * Phase-4 the writer silently dropped the trail (mandatory-Ref
	 * `@:trailOpt` had no emit branch at all — `trailText` reads only
	 * from `@:trail`, not `@:trailOpt`); pre-Phase-4 the present-`;`
	 * variant lost the `;` and the absent-`;` variant matched by accident.
	 *
	 * Source strings are written in the trivia writer's canonical Allman
	 * layout (tab indent, multi-line braces) so the round-trip can be
	 * byte-equal — the writer normalises whitespace structurally, so a
	 * single-line input would not round-trip with `Assert.equals(src, out)`
	 * even with Phase 4 working.
	 */
	public function testThenBranchRoundTripPreservesTrail():Void {
		final src:String = 'class M {\n\tstatic function f() {\n\t\tfinal x = if (a) b; else c;\n\t}\n}\n';
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), defaultOpts());
		Assert.equals(src, out);
	}

	public function testThenBranchRoundTripSuppressesAbsentTrail():Void {
		final src:String = 'class M {\n\tstatic function f() {\n\t\tfinal x = if (a) b else c;\n\t}\n}\n';
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), defaultOpts());
		Assert.equals(src, out);
	}

	private inline function defaultOpts():HxModuleWriteOptions {
		return HaxeFormat.instance.defaultWriteOptions;
	}
}
