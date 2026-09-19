package anyparse.check;

import anyparse.query.BoolExprShape;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceText;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeRefPrinter;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using StringTools;

/**
 * Where an oracle-named type will be WRITTEN — the context that decides which of the compiler's
 * qualifiers are strippable. Both fields are proof-carrying: a non-null `methodName` means the
 * enclosing function DECLARES type parameters, a non-null `file` lets a private module type of
 * that very file be named bare. Null means "no proof", which always costs a strip, never a wrong
 * one.
 */
typedef AnnotationSite = {

	/** The file receiving the annotation, or null when the caller has none. */
	final file: Null<String>;

	/** The enclosing function's name, ONLY when it declares type parameters; null otherwise. */
	final methodName: Null<String>;

};

/**
 * A `new`-expression's written type: the verbatim text and whether it carries
 * explicit `<...>` type parameters — `writtenNewType`'s result.
 */
private typedef WrittenNewType = {
	var written: String;
	var generic: Bool;
}

/**
 * Shared statically-certain type inference for a declaration's initializer,
 * plus the two textual helpers that locate a declaration's type-annotation slot.
 * Extracted from `explicit-type` so the local-type check (`explicit-local-type`)
 * reuses the exact same rules rather than copying them: a field, a parameter and a
 * local all annotate the same statically-certain initializer shapes at the same
 * offset (right after the name), so the logic is one place.
 *
 * The same reason puts the type-NAME normalizer here (`normalizeWith`, `printerFor`, `admissibleLocal`): `explicit-type`,
 * `explicit-local-type` and the `avoid-dynamic` bag arm must not each decide on their own what a compiler-named type may be written as.
 */
@:nullSafety(Strict)
final class LiteralInfer {

	/**
	 * The type source to annotate for `init` when its type is statically certain, else
	 * null. Every enclosing parenthesis layer is peeled off FIRST
	 * (`RefactorSupport.unwrapParens` via the grammar's `parenKind` seam) — the arms below
	 * dispatch on the node KIND, so without it a wrapped `(-1)` would miss all of them
	 * while a bare `-1` annotates; unwrapping here rather than per-caller is what keeps a
	 * field, a parameter and a local agreeing on one initializer. A literal maps through
	 * `shape.literalTypeNames`; a `Neg` wrapping a numeric literal takes that literal's
	 * type; a `new T<...>()` with WRITTEN type parameters carries `T<...>` verbatim (a bare
	 * `new T()` — possibly generic — yields null); a typed cast / check-type takes its
	 * target type. Anything else (a call, a field read, an array / map / ternary) is null —
	 * report-only. The unwrap NARROWS the node, so the span-reading arms (the `new` type
	 * scan, the cast-target lookup) see the real expression's own position, exactly the view
	 * they would have without the parens; `insertPoint` still takes the caller's ORIGINAL
	 * initializer, whose start bounds the `=` search.
	 */
	public static function inferType(
		rawInit: QueryNode, source: String, shape: RefShape, castTargets: () -> Map<Int, String>
	): Null<String> {
		final init: QueryNode = BoolExprShape.unwrapParens(rawInit, shape.parenKind);
		final literalTypes: Map<String, String> = shape.literalTypeNames ?? [];
		final numeric: Array<String> = shape.numericLiteralKinds ?? [];
		final negKind: Null<String> = shape.negationKind;
		final newKind: Null<String> = shape.newExprKind;
		final castKinds: Array<String> = shape.typedCastKinds ?? [];
		final direct: Null<String> = literalTypes[init.kind];
		if (direct != null) return direct;
		if (negKind != null && init.kind == negKind && init.children.length == 1) {
			final inner: QueryNode = init.children[0];
			return numeric.contains(inner.kind) ? literalTypes[inner.kind] : null;
		}
		if (newKind != null && init.kind == newKind) return newTypeSource(init, source);
		final span: Null<Span> = init.span;
		return span != null && castKinds.contains(init.kind) ? TypeResolver.castTargetWithin(span, castTargets()) : null;
	}

	/**
	 * The `T<...>` type source of a `new T<...>(...)` when it carries WRITTEN type
	 * parameters, else null (a bare `new T(...)` could be a generic used without
	 * parameters, whose bare `:T` annotation would not type-check). Scans from after
	 * `new` for the balanced `<...>`; a `>` preceded by `-` is the arrow `->` inside
	 * a function-type parameter, not an angle close. A constructor `(` reached before
	 * any `<` means no written type parameters.
	 */
	public static function newTypeSource(newNode: QueryNode, source: String): Null<String> {
		final t: Null<WrittenNewType> = writtenNewType(newNode, source);
		return t != null && t.generic ? t.written : null;
	}

	/**
	 * The bare (parameterless) written type of a `new T(...)` — the text between
	 * `new` and the argument `(`, or null when the constructor writes type
	 * parameters (`newTypeSource`'s case) or the span is missing. The caller must
	 * prove `T` non-generic before using this as an annotation.
	 */
	public static function bareNewTypeName(newNode: QueryNode, source: String): Null<String> {
		final t: Null<WrittenNewType> = writtenNewType(newNode, source);
		return t != null && !t.generic ? t.written : null;
	}

	/**
	 * Whether a `:` type annotation precedes the declaration's initializer / default.
	 * The type sits between the name and the first child (the initializer / default
	 * value, when present) or the declaration's end; neither the keyword, the name,
	 * nor property accessors `(get, set)` contain a `:`, so a `:` in that prefix is
	 * the type. A node with no span cannot be judged and is treated as typed.
	 */
	public static function hasTypeBeforeInit(node: QueryNode, source: String): Bool {
		final span: Null<Span> = node.span;
		if (span == null) return true;
		var cutoff: Int = span.to;
		if (node.children.length > 0) {
			final firstSpan: Null<Span> = node.children[0].span;
			if (firstSpan != null) cutoff = firstSpan.from;
		}
		return source.substring(span.from, cutoff).indexOf(':') >= 0;
	}

	/**
	 * The offset right after the declaration's name — where a `:Type` annotation is
	 * inserted — found by walking back over whitespace from the assignment `=` that
	 * precedes the initializer. Returns -1 when no `=` is in the name-to-initializer
	 * prefix (a declaration with no initializer cannot be annotated by this fix).
	 */
	public static function insertPoint(node: QueryNode, init: QueryNode, source: String): Int {
		final span: Null<Span> = node.span;
		final initSpan: Null<Span> = init.span;
		if (span == null || initSpan == null) return -1;
		final prefix: String = source.substring(span.from, initSpan.from);
		final eq: Int = prefix.lastIndexOf('=');
		if (eq < 0) return -1;
		var pos: Int = span.from + eq;
		while (pos > span.from && source.isSpace(pos - 1)) pos--;
		return pos;
	}

	/**
	 * `normalizeWith` against an IMPORT-MAP-ONLY printer: the compiler-free entry point for a
	 * caller holding nothing but a file's plain imports. It shortens what that map (or the
	 * builtin top-level set) already puts in scope and leaves everything else fully qualified;
	 * it never adds an import, having no file to anchor one in. PURE and unit-testable.
	 */
	public static function normalizeInferredType(raw: String, importMap: Map<String, String>, maxAnonLen: Int): Null<String> {
		// No enclosing-function context here: the class-parameter half of the qualifier strip
		// still applies (it needs none), the method-parameter half is skipped.
		final printer: TypeRefPrinter = TypeRefPrinter.importsOnly(importMap);
		// No annotation POSITION either: an imports-only printer can anchor no import at all, so the
		// conditional-region gate has nothing to decide and -1 (the whole-file reading) is exact.
		return admissibleLocal(normalizeWith(raw, printer, maxAnonLen, { file: null, methodName: null }, -1), printer);
	}

	/**
	 * Normalise a compiler-inferred type text to a sound annotation, or null when no
	 * annotation should be written. REJECTS: a monomorph / inference hole (`Unknown<` — the
	 * compiler could not pin it either), an anonymous structure longer than `maxAnonLen`
	 * (annotatable but noisy), and a bare `_` type-param placeholder (not a nameable type; a
	 * clean function type or a small anon struct is kept). Otherwise every nominal run is
	 * spelled by `printer` — short where already visible, short WITH a recorded import where
	 * the name is free, else the correct fully-qualified (module-qualified for a sub-type)
	 * form, which always resolves.
	 *
	 * `at` is the byte offset the annotation lands at, threaded to the printer for exactly one
	 * decision: a site inside a conditional-compilation region may not buy an import whose line
	 * would land outside that region — see `TypeRefPrinter.importReachesSite`, which owns the rule
	 * and the argument for it. Pass -1 when the caller has no position; that is the whole-file
	 * reading, and it costs at most a qualified spelling.
	 *
	 * It is a PARAMETER rather than an `AnnotationSite` field on purpose: the site describes which of
	 * the compiler's qualifiers are strippable, which is a question about the enclosing declaration,
	 * while this is a question about the file position — and the callers that hold one hold the other.
	 */
	public static function normalizeWith(
		raw: String, printer: TypeRefPrinter, maxAnonLen: Int, site: AnnotationSite, at: Int
	): Null<String> {
		final t: String = stripTypeParamQualifiers(raw.trim(), site);
		return if (t == '')
			null
		else if (t.indexOf('Unknown<') != -1)
			null
		else if (hasForeignPrivateType(t))
			null
		else if (t.indexOf('{') != -1 && t.length > maxAnonLen)
			null
		else if (hasBareUnderscore(t))
			null
		else
			printer.printTypeExpr(t, at);
	}

	/**
	 * The per-file type printer both oracle-assisted passes build identically: the file's import
	 * map from the grammar's `TypeInfoProvider` (empty when the plugin exposes none) plus the run's
	 * resolution index. The printer owns the short-name / add-import / fully-qualified decision for
	 * every nominal the oracle names, and accumulates the imports its short forms rely on.
	 */
	public static function printerFor(source: String, tree: QueryNode, plugin: GrammarPlugin): TypeRefPrinter {
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final importMap: Map<String, String> = provider != null ? provider.importMap(source) : [];
		return TypeRefPrinter.forFile(source, tree, importMap, plugin, RefactorSupport.resolutionIndexOf(plugin));
	}

	/**
	 * `printed` with COMPILER-QUALIFIED type parameters reduced to the bare names a source file
	 * can actually spell. The compiler prints a type parameter with its owner in front, in TWO
	 * forms, both unwritable (`Module pkg.Box does not define type T`): a CLASS parameter as
	 * `<owner type path>.<name>` (`pkg.Box.T`), a METHOD parameter as `<method name>.<name>`
	 * (`pair.U`). Both reach EVERY consumer of the oracle — a return type, a local, a `Dynamic`
	 * replacement — so the strip lives inside `normalizeWith` where none of them can forget it.
	 *
	 * The segment before the last tells the forms apart, because a real type reference the
	 * compiler prints never carries an upper-case segment anywhere but at the END — a module's
	 * SECONDARY type comes out as `pack.Sub` with the module dropped (`pkg.Box.Side` prints
	 * `pkg.Side`). So an upper-case non-final segment IS an owner type and the run is a
	 * class parameter; a lower-case one is a package segment unless it equals `methodName`,
	 * which the caller supplies ONLY for a function that DECLARES type parameters (null
	 * otherwise) — without that proof the same shape is an ordinary package-qualified type
	 * whose tail happens to match the function name.
	 *
	 * Both strips are sound ONLY because the annotation is written INSIDE the owner, where the
	 * bare name is in scope — this is not a general type-reference normaliser. Runs are cut on
	 * the same character class `TypeRefPrinter.printTypeExpr` uses, so the two agree on what a
	 * type reference is.
	 */
	public static function stripTypeParamQualifiers(printed: String, site: AnnotationSite): String {
		return mapTypeRuns(printed, run -> bareTypeParam(run, site));
	}

	/**
	 * `printed` when it is an annotation a LOCAL may be given, else null — the two refusals the
	 * shared normalizer must NOT make, because `ExplicitType` reaches the same normalizer for a
	 * RETURN type where both answers are legitimate (`Void` above all). So they live in this SEPARATE
	 * entry, on the path only a local declaration takes: `inadmissibleType` (what no local should say) and
	 * `spellable` (what this file cannot spell).
	 */
	public static function admissibleLocal(printed: Null<String>, printer: TypeRefPrinter): Null<String> {
		return printed == null || inadmissibleType(printed) ? null : spellable(printed, printer);
	}

	/**
	 * Whether `t` is a type no local declaration should be given.
	 *
	 * `Dynamic` / `Any` ANYWHERE in it: the display server answers `Dynamic` for an expression it
	 * could not type — a file outside its hxml's compiled set resolves nothing, so every identifier
	 * in it degrades — and writing that is WORSE than writing nothing. It compiles, and it switches
	 * type checking off for the very binding this rule exists to strengthen, leaving no compiler
	 * error for the verification pass to revert. `Unknown<…>`, the monomorph spelling refused just
	 * above, is the SAME failure under a name that cannot be mistaken for a type; `Dynamic` is it
	 * wearing one that can (`final f: Dynamic = Fs.createWriteStream(file);` for a value whose
	 * type is `js.node.fs.WriteStream`). A project running `avoid-dynamic` also gains a finding of
	 * THAT rule from every such annotation. The cost is a correct `Class<Dynamic>` or
	 * `Map<String, Dynamic>` left report-only, which is the trade the rule's owner asked for.
	 *
	 * A BARE `Void`: not merely unhelpful — `var x:Void` is not a declaration Haxe accepts at all,
	 * so this is the compiler having answered about some enclosing statement or block rather than
	 * the initializer, in the one situation where nothing downstream can catch it. `Void` INSIDE a
	 * type stays admissible: `() -> Void` is an ordinary local type.
	 */
	public static function inadmissibleType(t: String): Bool {
		if (t == 'Void') return true;
		var found: Bool = false;
		mapTypeRuns(t, run -> {
			if (run == 'Dynamic' || run == 'Any') found = true;
			return run;
		});
		return found;
	}

	/**
	 * Scan a `new T(...)`'s written type: the text between `new` and the argument
	 * `(`. A balanced `<...>` before the `(` marks explicit type parameters
	 * (`generic: true`, text includes them); a `>` preceded by `-` is the arrow
	 * `->` inside a function-type parameter, not an angle close. Null when the
	 * span is missing, the text is empty, or the params never close.
	 */
	private static function writtenNewType(newNode: QueryNode, source: String): Null<WrittenNewType> {
		final span: Null<Span> = newNode.span;
		if (span == null) return null;
		final full: String = source.substring(span.from, span.to);
		var i: Int = 3;
		while (i < full.length && full.isSpace(i)) i++;
		final typeStart: Int = i;
		var depth: Int = 0;
		while (i < full.length) {
			switch full.fastCodeAt(i) {
				case '('.code if (depth == 0):
					final bare: String = full.substring(typeStart, i).rtrim();
					return bare == '' ? null : { written: bare, generic: false };
				case '<'.code:
					depth++;
				case '>'.code if (full.fastCodeAt(i - 1) != '-'.code):
					depth--;
					if (depth == 0) return { written: full.substring(typeStart, i + 1), generic: true };
				case _:
			}
			i++;
		}
		return null;
	}

	/**
	 * `printed` with every dotted type-reference run replaced by `f(run)`, everything between them
	 * copied verbatim. Runs are cut on the same character class `TypeRefPrinter.printTypeExpr` uses,
	 * so this tokenizer and the printer agree on what a type reference is.
	 */
	private static function mapTypeRuns(printed: String, f: String -> String): String {
		final buf: StringBuf = new StringBuf();
		final n: Int = printed.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = printed.fastCodeAt(i);
			if (!SourceText.isIdentChar(c) && c != '.'.code) {
				buf.addChar(c);
				i++;
				continue;
			}
			final start: Int = i;
			while (i < n) {
				final cc: Int = printed.fastCodeAt(i);
				if (!SourceText.isIdentChar(cc) && cc != '.'.code) break;
				i++;
			}
			buf.add(f(printed.substring(start, i)));
		}
		return buf.toString();
	}

	/** `run` cut down to its last segment when it is a qualified type parameter, else `run` verbatim. */
	private static function bareTypeParam(run: String, site: AnnotationSite): String {
		final parts: Array<String> = run.split('.');
		if (parts.length < 2) return run;
		final last: String = parts[parts.length - 1];
		for (i in 0...parts.length - 1) {
			if (SourceText.isUpperInitial(parts[i])) return last;
			if (isOwnPrivateModule(parts.slice(0, i + 1), site.file)) return last;
		}
		return site.methodName != null && parts[parts.length - 2] == site.methodName ? last : run;
	}

	/**
	 * Whether `segment` is the synthetic private-module name (`_Holder`) of the module `file` itself
	 * — the one place a private type IS nameable, by its bare name. Compared on the file's basename,
	 * so no classpath root has to be known.
	 */
	private static function isOwnPrivateModule(path: Array<String>, file: Null<String>): Bool {
		final segment: String = path[path.length - 1];
		if (file == null || segment.length < 2 || segment.fastCodeAt(0) != '_'.code) return false;
		// The segments BEFORE the synthetic name are the package, so the whole run pins one path —
		// matching the basename alone would accept a same-named module of a different package.
		path[path.length - 1] = segment.substr(1);
		final expected: String = '${path.join('/')}.hx';
		return file == expected || file.endsWith('/$expected');
	}

	/**
	 * Whether `printed` still names a PRIVATE module type after the strip — a `_`-prefixed segment in
	 * any but the last position of a dotted run. What survives `bareTypeParam` belongs to ANOTHER
	 * module, and Haxe offers no spelling that reaches it, so the annotation stays report-only.
	 */
	private static function hasForeignPrivateType(printed: String): Bool {
		var found: Bool = false;
		mapTypeRuns(printed, run -> {
			final parts: Array<String> = run.split('.');
			for (p in 0...parts.length - 1) if (parts[p].length > 1 && parts[p].fastCodeAt(0) == '_'.code) found = true;
			return run;
		});
		return found;
	}

	/**
	 * `printed` when this file can actually SPELL every nominal in it, else null. A qualified run
	 * the printer neither shortened nor promised an import for is one it could not place — the file
	 * already binds that simple name to something else, or no import can be anchored — and the
	 * fully-qualified fallback it emits instead is correct only if the path is REAL. A compiler
	 * answer is not evidence of that: a display server resolves a file no `-cp` of its hxml covers
	 * through the implicit process-cwd classpath, and then names every module by its REPO-relative
	 * path (a file built with `-cp tests/test` and declaring `package magic;` is answered
	 * `tests.test.magic.NinjaClass` — `Type not found` at that spelling, while the structural pass
	 * gets a correct bare `NinjaClass` for the declaration beside it).
	 *
	 * The proof is the resolution index, so only a printer that HAS one can be asked: without it
	 * `resolvePath` answers null for everything and this would abstain on every qualified
	 * annotation rather than on the unproven ones. A printer built from an import map alone
	 * (`normalizeInferredType`) therefore keeps the older fallback — it carries no file scope to
	 * resolve against either.
	 */
	private static function spellable(printed: String, printer: TypeRefPrinter): Null<String> {
		if (!printer.hasResolutionIndex()) return printed;
		var placed: Bool = true;
		mapTypeRuns(printed, run -> {
			if (run.indexOf('.') != -1 && SourceText.isUpperInitial(SourceText.lastSegment(run)) && printer.resolvePath(run) == null)
				placed = false;
			return run;
		});
		return placed ? printed : null;
	}

	/** Whether `t` contains a standalone `_` identifier run — an unnameable type-param placeholder. */
	private static function hasBareUnderscore(t: String): Bool {
		final n: Int = t.length;
		var i: Int = 0;
		while (i < n) {
			if (!SourceText.isIdentChar(t.fastCodeAt(i))) {
				i++;
				continue;
			}
			final start: Int = i;
			while (i < n && SourceText.isIdentChar(t.fastCodeAt(i))) i++;
			if (t.substring(start, i) == '_') return true;
		}
		return false;
	}

}
