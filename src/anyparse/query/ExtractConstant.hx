package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * `extract-constant` — replace every occurrence of a plain single- or
 * double-quoted string literal inside one type with a reference to a fresh
 * `private static final` constant, so a repeated key / tag lives in one
 * named place (a typo in one of many occurrences becomes impossible).
 *
 *     if (k == 'base.ref') …          // ×N across the type
 *
 * becomes
 *
 *     private static final BASE_REF:String = 'base.ref';
 *     …
 *     if (k == BASE_REF) …            // every occurrence
 *
 * ## Boundary
 *
 * Both plain single- AND double-quoted literals match — only an
 * interpolated `'$x'` (not a constant value; a SingleStringExpr with more
 * than one child) is left untouched. Haxe double-quoted strings never
 * interpolate, so any `"…"` is a plain literal. The caller supplies the
 * exact literal CONTENT (the text between the quotes). A value that appears
 * in both quote styles is matched in each and unified into one constant; a
 * value containing a quote has different raw forms per style (`'it\'s'` vs
 * `"it's"`), so those match per style, not cross-unified. The constant
 * reuses the first occurrence's verbatim source token, so its quote style
 * and escaping are preserved. Refuses a name that is not a valid
 * identifier, a name that collides with an existing member, a non-unique /
 * missing type, or a literal that does not occur. Semantic sameness is the
 * caller's judgement — the op couples only the occurrences it is told to.
 * Writer-emitted and canonical-gated like the other structural-insert ops.
 */
@:nullSafety(Strict)
final class ExtractConstant {

	/**
	 * Extract the plain string literal `literal` (single- or double-quoted) in `typeName` into a `private static final` named `name`. `reformat` canonicalises a drifted file. Returns `Ok(rewritten)` or an `Err`.
	 */
	public static function extractConstant(
		source: String, typeName: String, name: String, literal: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		if (!SourceText.isIdentifier(name)) return Err('"$name" is not a valid identifier for a constant name');

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err('source does not parse: $exception')
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final decl: Null<TypeDeclMatch> = RefactorSupport.uniqueTypeDeclNamed(tree, typeName);
		if (decl == null) return Err('no unique type "$typeName" in the source');
		final declNN: TypeDeclMatch = decl;
		final shape: RefShape = plugin.refShape();
		if (MemberBranchScan.declaresMemberNamed(declNN, shape, source, name, plugin.lexicalRegions.bind(source)))
			return Err('type "$typeName" already has a member named "$name"');

		final occurrences: Array<Span> = collectOccurrences(declNN.nameNode, literal);
		if (occurrences.length == 0) return Err('no plain literal \'$literal\' occurs in type "$typeName"');

		final insertAt: Int = firstMemberStart(source, declNN, shape, plugin.lexicalRegions(source));
		if (insertAt < 0) return Err('type "$typeName" has no member to anchor the constant before');

		final firstOcc: Span = occurrences[0];
		final token: String = source.substring(firstOcc.from, firstOcc.to);
		final edits: Array<{ span: Span, text: String }> = [
			{ span: new Span(insertAt, insertAt), text: 'private static final $name:String = $token;\n' }
		];
		for (occ in occurrences) edits.push({ span: occ, text: name });

		return CanonicalEdit.canonicalize(source, edits, reformat, plugin, optsJson);
	}

	/**
	 * Extract every occurrence of the plain `literal` (single- or double-quoted) across `scopeFiles` into a shared `public static final` named `name` on the constants module `moduleClass` (package `modulePkg`). Each occurrence becomes `<moduleClass>.<name>`; a scope file whose package differs from the modules gains an `import`. When `moduleExists` the constant is added to `moduleSource` (refused if a `name` member already exists); otherwise a new `final class` module is created with a private constructor. `reformat` canonicalises drifted files. Returns the changed files plus the final module source, or an `Err`.
	 */
	public static function extractInto(
		scopeFiles: Array<{ file: String, source: String }>, modulePkg: String, moduleClass: String, moduleExists: Bool,
		moduleSource: Null<String>, name: String, literal: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): ExtractIntoResult {
		if (!SourceText.isIdentifier(name)) return Err('"$name" is not a valid identifier for a constant name');

		final modulePath: String = modulePkg == '' ? moduleClass : '$modulePkg.$moduleClass';
		final ref: String = '$moduleClass.$name';
		final changes: Array<{ file: String, newSource: String, count: Int }> = [];
		var token: Null<String> = null;
		var total: Int = 0;

		for (sf in scopeFiles) {
			final tree: QueryNode = try plugin.parseFile(sf.source) catch (exception: ParseError) return Err(
				'${sf.file} does not parse: $exception'
			)
			catch (exception: Exception) return Err('${sf.file} does not parse: ${exception.message}');

			final occurrences: Array<Span> = collectOccurrences(tree, literal);
			if (occurrences.length == 0) continue;
			total += occurrences.length;
			if (token == null) token = sf.source.substring(occurrences[0].from, occurrences[0].to);

			final edits: Array<{ span: Span, text: String }> = [for (occ in occurrences) { span: occ, text: ref }];
			final replaced: String = switch CanonicalEdit.canonicalize(sf.source, edits, reformat, plugin, optsJson) {
				case Ok(text): text;
				case Err(message): return Err('${sf.file}: $message');
			};

			// Same-package files (and a root-package module, globally visible)
			// reference the module with no import; a differing real package needs one.
			final needsImport: Bool = modulePkg != '' && ModuleScan.packageOf(tree) != modulePkg && !alreadyImportsModule(tree, modulePath);
			final newSource: String = if (!needsImport)
				replaced
			else
				switch AddImport.addImport(replaced, modulePath, false, true, plugin, optsJson) {
					case Ok(text): text;
					case Err(message): return Err('${sf.file}: import: $message');
				};
			changes.push({ file: sf.file, newSource: newSource, count: occurrences.length });
		}

		if (total == 0 || token == null) return Err('no plain literal \'$literal\' occurs across the scope');
		final constToken: String = token;
		final memberText: String = 'public static final $name:String = $constToken;';

		return switch buildModuleSource(
			moduleExists, moduleSource, modulePkg, moduleClass, modulePath, name, memberText, reformat, plugin, optsJson
		) {
			case Ok(moduleFinal): Ok(changes, moduleFinal, !moduleExists);
			case Err(message): Err(message);
		};
	}

	/**
	 * Spans of every plain string literal equal to `literal` anywhere under `typeNode`: a single-quoted `SingleStringExpr` with exactly one `Literal` child (an interpolated string carries extra children, so it is skipped), or any `DoubleStringExpr` (Haxe double-quoted strings never interpolate, so each is a plain literal). Matched on the raw source between the quotes; metadata subtrees are skipped.
	 */
	private static function collectOccurrences(typeNode: QueryNode, literal: String): Array<Span> {
		final spans: Array<Span> = [];
		function walk(node: QueryNode): Void {
			// A literal inside `@:meta('x')` must stay a literal — metadata needs a
			// constant string, not an identifier reference.
			if (MemberKinds.META_KINDS.contains(node.kind)) return;
			if (node.kind == 'SingleStringExpr' && node.children.length == 1) {
				final only: QueryNode = node.children[0];
				final span: Null<Span> = node.span;
				if (only.kind == 'Literal' && only.name == literal && span != null) spans.push(span);
			} else if (node.kind == 'DoubleStringExpr') {
				// Haxe double-quoted strings never interpolate, so every DoubleStringExpr is a plain
				// literal; its `name` is the raw `"..."` token INCLUDING the quotes.
				final span: Null<Span> = node.span;
				final tok: Null<String> = node.name;
				if (span != null && tok != null && tok.length >= 2 && tok.substring(1, tok.length - 1) == literal) spans.push(span);
			}
			for (c in node.children) walk(c);
		}
		walk(typeNode);
		return spans;
	}

	/**
	 * Source offset just before the first member, with its leading `/**` doc comment and modifier run included (via `docExtendedSpan`) — where the constant is spliced so it becomes the types first member while the original first member keeps its own doc. -1 when the type has no member.
	 */
	private static function firstMemberStart(source: String, decl: TypeDeclMatch, shape: RefShape, regions: Array<LexRegion>): Int {
		final condKind: Null<String> = shape.conditionalMemberKind;
		// A `#if` region opening the body is a member position too: the constant is spliced BEFORE it,
		// so it exists in every build. Splicing INSIDE the region would guard the constant, and treating
		// the region as "no member at all" (which this scan used to do when every member was guarded)
		// sent the caller down the append path instead.
		for (child in decl.nameNode.children) if (
			MemberKinds.isFieldMemberKind(child.kind) || MemberKinds.FN_DECL_KINDS.contains(child.kind)
			|| (condKind != null && child.kind == condKind)
		) {
			final span: Null<Span> = child.span;
			if (span == null) continue;
			final group: Span = ElementSpan.declGroupSpan(child, decl.nameNode, span);
			return ElementSpan.docExtendedSpan(source, group, regions).from;
		}
		return -1;
	}

	/**
	 * Build the constants-module source: append `memberText` to the existing
	 * `moduleSource` (refused on a duplicate `name` member or a missing
	 * `moduleClass` type), or create a fresh `final class` module holding that
	 * member plus a private constructor. Returns the module source or an `Err`.
	 */
	private static function buildModuleSource(
		moduleExists: Bool, moduleSource: Null<String>, modulePkg: String, moduleClass: String, modulePath: String, name: String,
		memberText: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		if (!moduleExists) return switch NewFile.create({
			className: moduleClass,
			pkg: modulePkg,
			fields: [memberText, 'private function new() {}']
		}, plugin, optsJson).result {
			case Ok(text): Ok(text);
			case Err(message): Err('module: $message');
		};

		if (moduleSource == null) return Err('module "$modulePath" is marked existing but no source was provided');
		final existing: String = moduleSource;
		final mtree: QueryNode = try plugin.parseFile(existing) catch (exception: ParseError) return Err(
			'module "$modulePath" does not parse: $exception'
		)
		catch (exception: Exception) return Err('module "$modulePath" does not parse: ${exception.message}');
		final decl: Null<TypeDeclMatch> = RefactorSupport.uniqueTypeDeclNamed(mtree, moduleClass);
		if (decl == null) return Err('module "$modulePath" has no unique type "$moduleClass"');
		final declNN: TypeDeclMatch = decl;
		final shape: RefShape = plugin.refShape();
		if (MemberBranchScan.declaresMemberNamed(declNN, shape, existing, name, plugin.lexicalRegions.bind(existing)))
			return Err('module "$moduleClass" already has a member named "$name"');
		// Splice the constant into the constants rank (before the first member) rather than
		// appending — an appended `public static final` after the holder's `private new()`
		// would sit out of canonical member order. Empty module (no member): fall back to append.
		final insertAt: Int = firstMemberStart(existing, declNN, shape, plugin.lexicalRegions(existing));
		return insertAt < 0
			? AddMember.addMember(existing, moduleClass, memberText, reformat, plugin, optsJson)
			: CanonicalEdit.canonicalize(
				existing,
				[{ span: new Span(insertAt, insertAt), text: '$memberText\n' }],
				reformat, plugin, optsJson
			);
	}

	/**
	 * Does `tree` already carry a top-level `import <modulePath>;` / `using
	 * <modulePath>;`? Mirrors `AddImport`'s own dedup so a consumer that already
	 * imports the shared module is left as-is instead of aborting the whole
	 * cross-file op with an "already imported" error.
	 */
	private static function alreadyImportsModule(tree: QueryNode, modulePath: String): Bool {
		return tree.children.exists(c -> (c.kind == 'ImportDecl' || c.kind == 'UsingDecl') && c.name == modulePath);
	}

}

/**
 * Cross-file `extract-constant --into` result: the changed scope files
 * (each with the literal replaced by `<ModuleClass>.<NAME>`, plus an
 * import when the file's package differs from the module's), the final
 * constants-module source, and whether that module was freshly created.
 */
enum ExtractIntoResult {
	Ok(changes: Array<{ file: String, newSource: String, count: Int }>, moduleSource: String, created: Bool);
	Err(message: String);
}
