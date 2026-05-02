package anyparse.macro;

#if macro
import anyparse.format.text.FieldLookup;
import anyparse.format.text.KeySyntax;
import anyparse.format.text.MissingPolicy;
import anyparse.format.text.UnknownPolicy;
import haxe.macro.Context;
import haxe.macro.Type;

/**
 * Compile-time constants extracted from a resolved format class.
 *
 * Macro strategies read from this record instead of re-resolving the
 * format class every time they need a literal vocabulary value.
 * Binary schemas short-circuit the text-only fields with default
 * values that never reach the generator.
 */
typedef FormatInfo = {
	/** Characters to consume when `@:ws` is active on the schema. */
	whitespace:String,

	/** Fully qualified type path of the `@:schema` class (e.g. `anyparse.format.text.JsonFormat`). */
	schemaTypePath:String,

	/** True when the schema class has `encoding = Binary`. */
	isBinary:Bool,

	/** How parser matches input entries to schema fields. ByName enables the key-dispatch struct codepath. */
	fieldLookup:FieldLookup,

	/** Policy for input entries with no matching schema field — consumed in ByName codepath. */
	onUnknown:UnknownPolicy,

	/** Policy for schema fields absent from the input — consumed in ByName codepath. */
	onMissing:MissingPolicy,

	/** Key-literal syntax (`Quoted` = JSON-style double-quoted). */
	keySyntax:KeySyntax,

	/** Literal that opens a mapping block (e.g. `{`). */
	mappingOpen:String,

	/** Literal that closes a mapping block (e.g. `}`). */
	mappingClose:String,

	/** Separator between a key and its value (e.g. `:`). */
	keyValueSep:String,

	/** Separator between mapping entries (e.g. `,`). */
	entrySep:String,

	/**
	 * Literal that opens a sequence (array) block (e.g. `[`). `null` when
	 * the format has no sequence syntax — array-typed schema fields then
	 * have nowhere to anchor and the macro errors at lowering time.
	 */
	sequenceOpen:Null<String>,

	/** Literal that closes a sequence block (e.g. `]`). */
	sequenceClose:Null<String>,

	/**
	 * Format-declared grammar types for primitive / universal fields.
	 * The macro looks these up when shaping typed schemas: a `Int`
	 * field in a `@:schema(JsonFormat)` typedef becomes a `Ref` to the
	 * format's `intType` instead of an inline Terminal, and the
	 * ByName codepath routes `UnknownPolicy.Skip` through `anyType`.
	 * `null` slots mean the format does not opt into typed parsing
	 * for that kind — the macro falls back to inline handling.
	 */
	intType:Null<String>,
	floatType:Null<String>,
	boolType:Null<String>,
	stringType:Null<String>,
	anyType:Null<String>,

	/**
	 * Star struct field open-delimiters that take a leading space from
	 * the preceding token. Everything not listed stays tight against
	 * the previous field — so `main()` / `a[0]` / `new Foo(x)` work by
	 * default while Haxe-style `class Foo {` keeps its space by
	 * declaring `['{']`. Empty array (or absent field) means every
	 * lead is tight, matching JSON-like output.
	 */
	spacedLeads:Array<String>,

	/**
	 * Optional-field `@:lead(...)` strings that emit *tight* — no leading
	 * separator before the lead, no trailing space after it. Default
	 * optional-Ref layout (e.g. `else <body>`, `catch (...)`) inserts
	 * ` <lead> ` to keep keywords readable. Tight leads short-circuit
	 * that pattern for punctuation like Haxe `:` so `function f():Int`
	 * comes out compact instead of `function f() : Int`. Empty array
	 * (or absent field) means no tight leads — full spaced layout for
	 * every optional `@:lead`.
	 */
	tightLeads:Array<String>,

	/**
	 * Comment delimiter patterns recognized by the format. Built from the
	 * format class's `lineComment` and `blockComment` fields. Plain-mode
	 * parsers skip-and-discard any matching sequence between tokens;
	 * Trivia-mode parsers additionally capture the content between
	 * delimiters. Empty when the format has no comments (e.g. JSON).
	 */
	commentPatterns:Array<CommentPattern>,
};

/**
 * One recognised comment delimiter pair.
 *
 * `lineTerminated = true` means the comment runs from `open` until the
 * next `\n` (or EOF) and `close` is empty. `false` means the comment
 * runs from `open` until the next occurrence of `close` — may span
 * multiple lines.
 */
typedef CommentPattern = {
	open:String,
	close:String,
	lineTerminated:Bool,
};

/**
 * Resolves a `@:schema(ClassName)` reference at macro time and extracts
 * compile-time constants from its field initializers.
 *
 * The mechanism is deliberately simple: we call `Context.getType` to
 * force the format class to be typed, then walk its `fields` array and
 * pattern-match the typed initializer of each field we care about.
 * Fields declared as `(default, null)` properties with a literal
 * initializer at the declaration site come through here as
 * `TConst(TString(...))` / `TConst(TInt(...))` etc. — enough for the
 * JSON case. Richer extraction (expressions, references) is left for
 * later phases when real formats need it.
 */
class FormatReader {

	public static function resolve(typePath:String):FormatInfo {
		final t:Type = Context.getType(typePath);
		final cl:ClassType = switch t {
			case TInst(ref, _): ref.get();
			case _:
				Context.fatalError('@:schema($typePath) must resolve to a class', Context.currentPos());
				throw 'unreachable';
		};
		final isBinary:Bool = detectBinary(cl);
		return {
			whitespace: isBinary ? '' : readStringField(cl, 'whitespace'),
			schemaTypePath: typePath,
			isBinary: isBinary,
			fieldLookup: isBinary ? FieldLookup.ByPosition : readEnumAbstractField(cl, 'fieldLookup'),
			onUnknown: isBinary ? UnknownPolicy.Error : readEnumAbstractField(cl, 'onUnknown'),
			onMissing: isBinary ? MissingPolicy.Error : readEnumAbstractField(cl, 'onMissing'),
			keySyntax: isBinary ? KeySyntax.Quoted : readEnumAbstractField(cl, 'keySyntax'),
			mappingOpen: isBinary ? '' : readStringField(cl, 'mappingOpen'),
			mappingClose: isBinary ? '' : readStringField(cl, 'mappingClose'),
			keyValueSep: isBinary ? '' : readStringField(cl, 'keyValueSep'),
			entrySep: isBinary ? '' : readStringField(cl, 'entrySep'),
			sequenceOpen: isBinary ? null : readStringFieldOpt(cl, 'sequenceOpen'),
			sequenceClose: isBinary ? null : readStringFieldOpt(cl, 'sequenceClose'),
			intType: isBinary ? null : readStringFieldOpt(cl, 'intType'),
			floatType: isBinary ? null : readStringFieldOpt(cl, 'floatType'),
			boolType: isBinary ? null : readStringFieldOpt(cl, 'boolType'),
			stringType: isBinary ? null : readStringFieldOpt(cl, 'stringType'),
			anyType: isBinary ? null : readStringFieldOpt(cl, 'anyType'),
			spacedLeads: isBinary ? [] : readStringArrayField(cl, 'spacedLeads'),
			tightLeads: isBinary ? [] : readStringArrayField(cl, 'tightLeads'),
			commentPatterns: isBinary ? [] : readCommentPatterns(cl),
		};
	}

	/**
	 * Build `commentPatterns` by reading the format class's `lineComment`
	 * (`Null<String>`) and `blockComment` (`Null<{open:String, close:String}>`)
	 * fields. Missing or `null` fields contribute nothing — a format with
	 * neither (e.g. JSON) yields an empty array.
	 */
	private static function readCommentPatterns(cl:ClassType):Array<CommentPattern> {
		final out:Array<CommentPattern> = [];
		final line:Null<String> = readStringFieldOpt(cl, 'lineComment');
		if (line != null) out.push({open: line, close: '', lineTerminated: true});
		final block:Null<{open:String, close:String}> = readBlockCommentFieldOpt(cl, 'blockComment');
		if (block != null) out.push({open: block.open, close: block.close, lineTerminated: false});
		return out;
	}

	/**
	 * Read a `{open:String, close:String}` struct-literal field
	 * initializer. Returns `null` when the field is missing, `null`, or
	 * its initializer does not have both sub-fields as string literals.
	 */
	private static function readBlockCommentFieldOpt(cl:ClassType, fieldName:String):Null<{open:String, close:String}> {
		final fields:Array<ClassField> = cl.fields.get();
		for (f in fields) if (f.name == fieldName) {
			final texpr:Null<TypedExpr> = f.expr();
			if (texpr != null) return extractBlockComment(texpr);
		}
		return null;
	}

	private static function extractBlockComment(texpr:TypedExpr):Null<{open:String, close:String}> {
		return switch texpr.expr {
			case TObjectDecl(fields):
				var open:Null<String> = null;
				var close:Null<String> = null;
				for (f in fields) switch f.name {
					case 'open': open = extractString(f.expr);
					case 'close': close = extractString(f.expr);
				}
				if (open != null && close != null) {open: open, close: close} else null;
			case TCast(inner, _): extractBlockComment(inner);
			case TParenthesis(inner): extractBlockComment(inner);
			case _: null;
		};
	}

	private static function detectBinary(cl:ClassType):Bool {
		final fields:Array<ClassField> = cl.fields.get();
		for (f in fields) if (f.name == 'encoding') {
			final texpr:Null<TypedExpr> = f.expr();
			if (texpr != null) return extractInt(texpr) == 4; // Encoding.Binary = 4
		}
		return false;
	}

	private static function extractInt(texpr:TypedExpr):Int {
		return switch texpr.expr {
			case TConst(TInt(v)): v;
			case TCast(inner, _): extractInt(inner);
			case TParenthesis(inner): extractInt(inner);
			case _: -1;
		};
	}

	private static function readStringField(cl:ClassType, fieldName:String):String {
		final fields:Array<ClassField> = cl.fields.get();
		for (f in fields) if (f.name == fieldName) {
			final texpr:Null<TypedExpr> = f.expr();
			if (texpr != null) {
				final s:Null<String> = extractString(texpr);
				if (s != null) return s;
			}
		}
		Context.fatalError('format class ${cl.name} has no readable String field "$fieldName"', Context.currentPos());
		throw 'unreachable';
	}

	private static function readIntField(cl:ClassType, fieldName:String):Int {
		final fields:Array<ClassField> = cl.fields.get();
		for (f in fields) if (f.name == fieldName) {
			final texpr:Null<TypedExpr> = f.expr();
			if (texpr != null) return extractInt(texpr);
		}
		Context.fatalError('format class ${cl.name} has no readable Int field "$fieldName"', Context.currentPos());
		throw 'unreachable';
	}

	/**
	 * Read an `enum abstract(Int)` field initializer and return the
	 * value typed as `T`, where `T` is the declared field's enum
	 * abstract type (inferred from the call site's target). The unsafe
	 * step — an `Int` → `T` cast — is localised here so the main
	 * `resolve()` assembly stays cast-free; the underlying Int is
	 * already constrained to the abstract's declared values because
	 * Haxe typed the initializer against `T` at the format class's
	 * own compilation.
	 */
	private static function readEnumAbstractField<T>(cl:ClassType, fieldName:String):T {
		return cast readIntField(cl, fieldName);
	}

	/**
	 * Read a format field that is allowed to be missing or `null` —
	 * e.g. optional typed-parsing hooks. Returns `null` when the field
	 * isn't declared or its initializer isn't a `String` literal.
	 */
	private static function readStringFieldOpt(cl:ClassType, fieldName:String):Null<String> {
		final fields:Array<ClassField> = cl.fields.get();
		for (f in fields) if (f.name == fieldName) {
			final texpr:Null<TypedExpr> = f.expr();
			if (texpr != null) return extractString(texpr);
		}
		return null;
	}

	private static function extractString(texpr:TypedExpr):Null<String> {
		return switch texpr.expr {
			case TConst(TString(s)): s;
			case TCast(inner, _): extractString(inner);
			case TParenthesis(inner): extractString(inner);
			case _: null;
		};
	}

	/**
	 * Read an `Array<String>` field initializer declared as a literal
	 * `[...]` at the format class's declaration site. Returns an empty
	 * array when the field is missing or its initializer cannot be
	 * reduced to a string-literal list — the consumer then falls back
	 * to the empty-policy default (everything tight, no leading space).
	 */
	private static function readStringArrayField(cl:ClassType, fieldName:String):Array<String> {
		final fields:Array<ClassField> = cl.fields.get();
		for (f in fields) if (f.name == fieldName) {
			final texpr:Null<TypedExpr> = f.expr();
			if (texpr != null) return extractStringArray(texpr);
		}
		return [];
	}

	private static function extractStringArray(texpr:TypedExpr):Array<String> {
		return switch texpr.expr {
			case TArrayDecl(values):
				final out:Array<String> = [];
				for (v in values) {
					final s:Null<String> = extractString(v);
					if (s != null) out.push(s);
				}
				out;
			case TCast(inner, _): extractStringArray(inner);
			case TParenthesis(inner): extractStringArray(inner);
			case _: [];
		};
	}
}
#end
