package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.grammar.haxe.HxVarInitRegion;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Tests for `HxVarDecl.condInit` — a `#if <cond> = <expr> #end` region
 * in the initializer slot, where the `=` sits inside the guard while
 * the binding name and type stay outside it.
 *
 * The last four openfl modules blocked on a field-level conditional use
 * this shape (`Lib`, `Assets`, `AGALConverter`, `DisplayObject`); the
 * `DisplayObject` one also carries a conditional modifier run in the
 * same declaration, so both regions must coexist.
 *
 * The regression half matters more than the feature half here: the new
 * slot must not steal a `#if` that opens a guarded MEMBER or STATEMENT
 * after a terminated declaration, and must leave the two conditional
 * slots `HxVarDecl` already reached through — leading metadata and the
 * `type` position — untouched.
 */
class HxCondVarInitSliceTest extends HxTestHelpers {

	private static final TRIVIA_CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}}';

	public function testGuardedInitializerOnStaticField(): Void {
		final src: String = 'class C {\n\tpublic static var current:MovieClip #if flash = flash.Lib.current #end;\n}';
		final decl: HxVarDecl = firstVarDecl(HaxeModuleParser.parse(src));
		Assert.isNull(decl.init);
		final region: Null<HxVarInitRegion> = decl.condInit;
		if (region == null) {
			Assert.fail('expected a condInit region');
			return;
		}
		switch region {
			case Conditional(inner):
				Assert.equals('flash', (inner.cond: String));
				Assert.notNull(inner.init);
		}
	}

	public function testGuardedInitializerAlongsideGuardedModifier(): Void {
		// openfl DisplayObject: a conditional modifier run AND a conditional
		// initializer in one declaration.
		final src: String = 'class C {\n\tprivate static #if !js inline #end var d:Bool #if !js = false #end;\n}';
		final decl: HxVarDecl = firstVarDecl(HaxeModuleParser.parse(src));
		switch decl.condInit {
			case Conditional(inner):
				Assert.equals('!js', (inner.cond: String));
			case null:
				Assert.fail('expected a condInit region');
		}
	}

	public function testAllOpenflShapesWriteVerbatim(): Void {
		for (member in [
			'public static var current:MovieClip #if flash = flash.Lib.current #end;',
			'private static var limitedProfile:Null<Bool> #if !desktop = true #end;',
			'@:noCompletion private static var dispatcher:EventDispatcher #if !macro = new EventDispatcher() #end;',
			'private static #if !js inline #end var __supportDOM:Bool #if !js = false #end;'
		]) {
			final src: String = 'class C {\n\t$member\n}';
			Assert.isTrue(writeModule(src).indexOf(member) != -1, 'verbatim: $member');
			roundTrip(src, member);
		}
	}

	public function testGuardedLocalInitializer(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar x:Int #if a = 1 #end;\n\t}\n}';
		Assert.equals(1, HaxeModuleParser.parse(src).decls.length);
		roundTrip(src, 'guarded local initializer');
	}

	public function testGuardedMemberRegionStillClaimedByMemberConditional(): Void {
		// The `#if` opens AFTER the previous declaration's `;`, so it is a
		// guarded member — condInit must not swallow it.
		final src: String = 'class C {\n\tvar a:Int;\n\t#if flash\n\tvar b:Int;\n\t#end\n}';
		final decl: HxVarDecl = firstVarDecl(HaxeModuleParser.parse(src));
		Assert.isNull(decl.condInit);
		roundTrip(src, 'guarded member');
	}

	public function testUnguardedAndTypeSlotFormsUnaffected(): Void {
		for (src in [
			'class C {\n\tvar x:Int = 1;\n}',
			'class C {\n\tvar x:Int;\n}',
			'class C {\n\tvar x:#if a A #else B #end;\n}',
			'class C {\n\tfunction f():Void {\n\t\tvar x:Int;\n\t\t#if a\n\t\ttrace(1);\n\t\t#end\n\t}\n}'
		]) {
			Assert.isNull(firstVarDeclOrNull(HaxeModuleParser.parse(src))?.condInit, src);
			roundTrip(src, src);
		}
	}

	/**
	 * The `condInit` field sits between `type` and `init`; putting it AFTER
	 * `init` shifts the trivia slot the writer reads for the blank line
	 * following a declaration, which silently swallowed the blank after
	 * every `var x = try {...} catch {...}` in a real project tree. Neither
	 * the unit suite nor the corpus sweep caught that — this case is the
	 * net. Goes through the TRIVIA writer: `HxModuleWriter.write` normalises
	 * blocks and drops the blank regardless of this field's position.
	 */
	public function testBlankLineAfterTryCatchInitializerSurvives(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tfinal a:Int = try {\n\t\t\tg();\n\t\t} catch (e:Exception) {\n\t\t\th();\n\t\t}\n\n\t\tk();\n\t}\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(TRIVIA_CONFIG);
		opts.finalNewline = false;
		Assert.equals(src, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts));
	}

	private function firstVarDecl(ast: HxModule): HxVarDecl {
		final decl: Null<HxVarDecl> = firstVarDeclOrNull(ast);
		if (decl == null) throw 'no var declaration found';
		return decl;
	}

	private function firstVarDeclOrNull(ast: HxModule): Null<HxVarDecl> {
		return switch ast.decls[0].decl {
			case ClassDecl(c):
				var found: Null<HxVarDecl> = null;
				for (m in c.members) if (found == null) switch m.member {
					case VarMember(decl):
						found = decl;
					case _:
				}
				found;
			case _:
				throw 'expected ClassDecl, got ${ast.decls[0].decl}';
		};
	}

	private function writeModule(source: String): String {
		return anyparse.grammar.haxe.HxModuleWriter.write(HaxeModuleParser.parse(source));
	}

}
