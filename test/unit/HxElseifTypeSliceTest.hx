package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxConditionalType;
import anyparse.grammar.haxe.HxConditionalTypeElse;
import anyparse.grammar.haxe.HxElseifType;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxTypedefDecl;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice ω-cond-comp-elseif-type: `#elseif` chained clauses in a
 * type-position conditional-compilation region — `typedef X = #if c1
 * T1 #elseif c2 T2 [#elseif c3 T3]* [#else Tn] #end` and the same
 * shape in a field-type slot.
 *
 * `HxConditionalType` gained an `elseifs: Array<HxElseifType>` field
 * (positioned before `elseClause`, mirroring `HxConditionalParam.
 * elseifs` / `HxConditionalMeta.elseifs` / `HxConditionalHeritage.
 * elseifs`). `HxElseifType` carries the `#elseif` keyword on its
 * `cond` field and a single `HxType` body with the same
 * `@:trailOpt(';')` shape as `HxConditionalType.type` — type-position
 * `#if`/`#elseif`/`#else` wraps exactly one type per branch in real
 * Haxe, so the array holds one-type-each clause structs rather than
 * Stars of types. `elseifs` carries `@:fmt(padLeading)`: unlike the
 * `type`→`elseClause` boundary (plain Ref-to-Ref, auto-spaced), a
 * Ref-to-Star boundary has no default pad, so without it the writer
 * glued `#elseif` straight onto the preceding type (`A#elseif hl C`).
 *
 * The corpus motivation is the real std-lib pattern used by
 * `haxe.ds.Vector` (typedef RHS) and `haxe.io.BytesInput` (field
 * type): `#if js ... #elseif (some_other_platform) ... #else ... #end`
 * chains longer than a single `#if`/`#else` pair. Before this slice
 * the parser accepted only the two-branch form; a third+ branch died
 * exactly at the `#elseif` token (`HxConditionalType.elseClause`'s
 * `@:kw('#else')` rejects `#elseif`, and the outer ctor's
 * `@:trail('#end')` never gets a chance to fire).
 *
 * Regression cases pin: the plain `#if`/`#else` two-branch form (no
 * `#elseif` at all — already covered by `HxConditionalTypeSliceTest`,
 * repeated here as the mechanism's own net) and an unguarded plain
 * typedef.
 */
class HxElseifTypeSliceTest extends HxTestHelpers {

	// -- One #elseif clause, #else present --

	public function testConditionalTypedefOneElseif(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef X = #if js A #elseif hl C #else B #end');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		final cond: HxConditionalType = expectConditionalType(td.type);
		Assert.equals('js', (cond.cond: String));
		Assert.equals('A', (expectNamedType(cond.type).name: String));
		Assert.equals(1, cond.elseifs.length);
		final clause: HxElseifType = cond.elseifs[0];
		Assert.equals('hl', (clause.cond: String));
		Assert.equals('C', (expectNamedType(clause.type).name: String));
		final elseClause: Null<HxConditionalTypeElse> = cond.elseClause;
		Assert.notNull(elseClause);
		if (elseClause != null) Assert.equals('B', (expectNamedType(elseClause.type).name: String));
	}

	// -- One #elseif clause, no #else --

	public function testConditionalTypedefElseifNoElse(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef X = #if js A #elseif hl C #end');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		final cond: HxConditionalType = expectConditionalType(td.type);
		Assert.equals(1, cond.elseifs.length);
		Assert.equals('C', (expectNamedType(cond.elseifs[0].type).name: String));
		Assert.isNull(cond.elseClause);
	}

	// -- Two chained #elseif clauses --

	public function testConditionalTypedefTwoElseif(): Void {
		final src: String = 'typedef X = #if js A #elseif hl C #elseif flash D #else B #end';
		final td: HxTypedefDecl = expectTypedefDecl(HaxeModuleParser.parse(src).decls[0]);
		final cond: HxConditionalType = expectConditionalType(td.type);
		Assert.equals(2, cond.elseifs.length);
		Assert.equals('hl', (cond.elseifs[0].cond: String));
		Assert.equals('C', (expectNamedType(cond.elseifs[0].type).name: String));
		Assert.equals('flash', (cond.elseifs[1].cond: String));
		Assert.equals('D', (expectNamedType(cond.elseifs[1].type).name: String));
	}

	// -- Field-type slot (haxe.io.BytesInput shape) --

	public function testFieldTypeElseif(): Void {
		final vd: HxVarDecl = parseSingleVarDecl('class C { var x: #if js Int #elseif hl String #else Float #end; }');
		final cond: HxConditionalType = expectConditionalType(vd.type);
		Assert.equals(1, cond.elseifs.length);
		Assert.equals('String', (expectNamedType(cond.elseifs[0].type).name: String));
	}

	// -- Writer round-trips verbatim, including field-type slot --

	public function testElseifTypeWritesVerbatim(): Void {
		for (src in [
			'typedef X = #if js A #elseif hl C #else B #end;',
			'typedef X = #if js A #elseif hl C #end;',
			'typedef X = #if js A #elseif hl C #elseif flash D #else B #end;',
			'class C {\n\tvar x:#if js Int #elseif hl String #else Float #end;\n}'
		]) roundTrip(src, src);
	}

	// -- Regression: plain #if/#else (no #elseif) still parses and writes --

	public function testPlainIfElseRegression(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef X = #if js String; #else Int; #end');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		final cond: HxConditionalType = expectConditionalType(td.type);
		Assert.equals(0, cond.elseifs.length);
		Assert.notNull(cond.elseClause);
		roundTrip('typedef X = #if js A #else B #end;');
	}

	// -- Regression: an unguarded plain typedef is unaffected --

	public function testNoConditionalTypeRegression(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef Y = Array<Int>;');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('Array', (expectNamedType(td.type).name: String));
	}

}
