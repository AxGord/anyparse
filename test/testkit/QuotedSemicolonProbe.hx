package testkit;

/**
 * Reifies each quotation twice, with and without the stray `;` that `empty-statement` deletes, so a test can
 * assert the deletion hands a macro the same AST — the premise of the rule's `QuotationAware` opt-out. The
 * comparison runs in the compiler, the only place a quotation is reified; the test sees its verdict as a constant.
 */
final class QuotedSemicolonProbe {

	/**
	 * The label of every pair whose two reifications differ; empty when the deleted `;` is never part of the AST.
	 * The kept forms are parsed from strings, so neither the rule nor its `--fix` ever touches them.
	 */
	public static macro function divergentPairs(): haxe.macro.Expr.ExprOf<Array<String>> {
		final pairs: Array<{ label: String, kept: String, deleted: String }> = [
			{ label: 'before else', kept: '{ if (c) { a(); }; else { b(); } }', deleted: '{ if (c) { a(); } else { b(); } }' },
			{ label: 'after for', kept: '{ for (i in x) { a(); }; b(); }', deleted: '{ for (i in x) { a(); } b(); }' },
			{
				label: 'after catch',
				kept: '{ try { a(); } catch (e:Dynamic) { b(); }; c(); }',
				deleted: '{ try { a(); } catch (e:Dynamic) { b(); } c(); }'
			},
			{ label: 'after block', kept: '{ { a(); }; b(); }', deleted: '{ { a(); } b(); }' },
			{ label: 'in case body', kept: '{ switch (c) { case _: { a(); }; } }', deleted: '{ switch (c) { case _: { a(); } } }' }
		];
		// A local function: the macro body is typed in the macro context only, so it needs no `#if macro` guard.
		function printed(code: String): String
			return haxe.macro.ExprTools.toString(haxe.macro.Context.parse(code, haxe.macro.Context.currentPos()));
		final out: Array<String> = [for (p in pairs) if (printed(p.kept) != printed(p.deleted)) p.label];
		// The member `;` below is the kept form under test; the `noqa` keeps the rule's own `--fix` off it.
		final klass: haxe.macro.Expr.TypeDefinition = macro class X {
			function f() {}; // noqa: empty-statement

			var v = 1;
		};
		if (klass.fields.length != 2) out.push('macro class member');
		return macro $v{out};
	}

}
