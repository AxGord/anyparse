# Formats

A **format** describes what a specific file format looks like: its literal syntax, policies, and conversion rules. A format is a plugin — an ordinary Haxe class implementing one of the format interfaces — and users can write their own without touching the core.

This is separate from `strategies.md`. A strategy is *how* we parse (PEG descent, Pratt, indent). A format is *what* we parse (`{` for JSON objects, `(` for S-expressions, `[section]` for INI headers). They combine: a strategy uses a format's literals and policies to generate a parser specialized for a given grammar.

## The distinction is load-bearing

There is no built-in `@:json` metadata in anyparse. There is no hardcoded list of supported formats in the core. When a user writes:

```haxe
@:schema(JsonFormat)
class User {
  @:field("id")   public var id:Int;
  @:field("name") public var name:String;
}
```

…the `JsonFormat` reference is a normal Haxe class lookup. The macro reads `JsonFormat`'s static fields at compile time and uses them as compile-time constants in the generated parser. If the user wants JSON5, they write `Json5Format` (possibly extending `JsonFormat`) and apply it to their schemas. The anyparse core knows nothing about JSON specifically.

This ensures that the set of supported formats is open-ended. Adding TOML, HJSON, MessagePack, or a proprietary format is writing one class, not filing a PR against anyparse.

## Format family interfaces

Real formats come in structural families. A single interface covering all families would either be a meaningless common denominator or an unmanageable union. Instead, anyparse ships one interface per family.

### `Format` — base

```haxe
interface Format {
  var name:String;           // "JSON", "YAML", "MessagePack"
  var version:String;        // "1.0", "7", whatever the format calls itself
  var encoding:Encoding;     // UTF8 | UTF16LE | UTF16BE | ASCII | Binary
}
```

Every format inherits from this. Only the minimum that every format has in common lives here.

### `TextFormat` — structured text

For JSON, YAML flow, TOML, INI, S-expressions, and similar mapping/sequence/scalar formats.

```haxe
interface TextFormat extends Format {
  // Structural literals
  var mappingOpen(default, null):String;         // "{"
  var mappingClose(default, null):String;        // "}"
  var sequenceOpen(default, null):Null<String>;  // "[" or null if format has no sequences
  var sequenceClose(default, null):Null<String>;
  var keyValueSep(default, null):String;         // ":"
  var entrySep(default, null):String;            // ","

  // Whitespace and comments
  var whitespace(default, null):String;                        // " \t\n\r"
  var lineComment(default, null):Null<String>;                 // "//" or ";" or null
  var blockComment(default, null):Null<BlockComment>;          // {"/*", "*/"} or null

  // Strings and keys
  var keySyntax(default, null):KeySyntax;        // Quoted | Unquoted | Either
  var stringQuote(default, null):Array<String>;  // ['"'] or ['"', "'"]

  // Field lookup strategy
  var fieldLookup(default, null):FieldLookup;    // ByName | ByPosition | ByTag

  // Policies
  var trailingSep(default, null):TrailingSepPolicy;  // Allowed | Disallowed | Required
  var onMissing(default, null):MissingPolicy;        // Error | Optional | UseDefault
  var onUnknown(default, null):UnknownPolicy;        // Skip | Error | Store

  // Primitives
  var intLiteral(default, null):EReg;            // regex for integer literals
  var floatLiteral(default, null):EReg;          // regex for float literals
  var boolLiterals(default, null):Null<BoolLiterals>;
  var nullLiteral(default, null):Null<String>;

  // Escape handling (functions, not data)
  function escapeChar(c:Int):String;
  function unescapeChar(input:String, pos:Int):UnescapeResult;
}
```

Fields use `(default, null)` property form — readable from any caller, writable only inside the declaring class — so the concrete format class can set them in its field initializer and treat them as effectively final. `BlockComment`, `BoolLiterals`, and `UnescapeResult` are named typedefs exported from the same module as the interface.

Format classes expose a `public static final instance` singleton. The writer and macro read configuration from that singleton — no per-parse allocation, one shared object for the whole process. The macro resolves the format class via `Context.getType` at compile time and extracts the field initializers so that literals become compile-time string constants in generated code; the instance is also available at runtime for hand-written writers and parsers that are generic over `TextFormat`.

### `BinaryFormat` — binary with tagged or length-prefixed layout

For MessagePack, CBOR, BSON, protobuf, and similar formats.

```haxe
interface BinaryFormat extends Format {
  var endianness:Endianness;       // Big | Little

  // Tag space
  var tagSize:Int;                 // usually 1 or 2 bytes
  var magicBytes:Null<haxe.io.Bytes>; // file signature, optional

  // Length encoding
  var lengthEncoding:LengthEncoding; // Varint | U8 | U16 | U32 | U64
  var countEncoding:LengthEncoding;
}
```

Binary formats do not need whitespace, comments, string escapes, or key quoting. They do need tag layouts, which live in grammar metadata (`@:tag`, `@:tagMask`, `@:fromTag`) rather than in the format class. The format describes the format-wide conventions; grammar metadata describes per-field layout.

### `TagTreeFormat` — XML and SGML descendants

Planned, not yet in Phase 1. For XML, HTML, SGML. These have elements with names, attributes, text content, and nested children — a fundamentally different structural model from mapping-based text formats.

### `SectionedFormat` — flat with section headers

Planned, not yet in Phase 1. For INI, properties files, TOML's full form. Flat key-value pairs grouped under section headers, with no deep nesting.

### `IndentedFormat` — whitespace-significant text

Planned, not yet in Phase 1. For YAML block style, Python source, CoffeeScript. Uses the Indent strategy (see `strategies.md`).

### `TabularFormat` — row-based text

Planned, not yet in Phase 1. For CSV, TSV, fixed-width. One record per line, no nesting.

## Writing a format

High-level procedure for a new text format:

1. **Decide which family it belongs to.** Most config-like formats are `TextFormat`. Binary protocols are `BinaryFormat`. Markup is `TagTreeFormat`. Etc.
2. **Create a class in the appropriate package.** Convention: `anyparse.format.{family}.{Name}Format`. Example: `anyparse.format.text.JsonFormat`, `anyparse.format.text.Json5Format`.
3. **Implement the interface fields** as `(default, null)` properties with initializers at the declaration site. Concrete values here become the format's literal vocabulary.
4. **Expose a `public static final instance` singleton** constructed via a private constructor — one shared object is enough since format classes hold pure configuration.
5. **Implement `escapeChar` and `unescapeChar`** if the format has string escapes. Binary formats skip both.
6. **Apply the format to a schema**: `@:schema(MyNewFormat) class MyType { ... }`.
7. **Write tests** using an existing format's test structure as a template.

### Example: JSON5 extending JSON

```haxe
package anyparse.format.text;

final class Json5Format extends JsonFormat {
  public static final instance:Json5Format = new Json5Format();

  override public var lineComment(default, null):Null<String> = "//";
  override public var blockComment(default, null):Null<BlockComment> = {open: "/*", close: "*/"};
  override public var trailingSep(default, null):TrailingSepPolicy = TrailingSepPolicy.Allowed;
  override public var stringQuote(default, null):Array<String> = ['"', "'"];

  private function new() { super(); }
}
```

A handful of overridden fields is the entire differential between JSON and JSON5 at the format level. Anything that inherits other JSON settings comes from the parent's field initializers.

### Example: MessagePack

```haxe
package anyparse.format.binary;

import anyparse.format.Encoding;

final class MsgPackFormat implements BinaryFormat {
  public static final instance:MsgPackFormat = new MsgPackFormat();

  public var name(default, null):String = "MessagePack";
  public var version(default, null):String = "v5";
  public var encoding(default, null):Encoding = Encoding.Binary;
  public var endianness(default, null):Endianness = Endianness.Big;
  public var tagSize(default, null):Int = 1;
  public var magicBytes(default, null):Null<haxe.io.Bytes> = null;
  public var lengthEncoding(default, null):LengthEncoding = LengthEncoding.Varint;
  public var countEncoding(default, null):LengthEncoding = LengthEncoding.Varint;

  private function new() {}
}
```

The format class is small. All the per-tag decoding (is `0xA0..0xBF` a fixstr? is `0xC0` a null?) lives in grammar metadata on a `@:bin` enum, not here.

## Format vs grammar — where does a decision live?

Some things are format-wide (characters, policies), some are grammar-specific (which constructor maps to which tag). A rule of thumb:

- **Format**: things that are true for *every* document in this format. Whitespace characters, comment syntax, escape rules, boolean spelling, null spelling, which integers look like what.
- **Grammar**: things that are true for *this specific document type*. The name of a field, which enum constructor corresponds to which tag byte, what the shape of the tree is, whether this field is optional.

When unsure, ask: does the answer change if I switch from `User` to `Product`, both in JSON? If yes, it is grammar. If no, it is format.

## Format composition — inheritance is fine, mixins are not

Formats can inherit from other formats to override specific fields. `Json5Format extends JsonFormat` is idiomatic.

Formats should not be composed from mixed-in traits at compile time. If a hypothetical `JsonWithComments` wants both JSON5's comments and strict JSON's quote rules, it extends one of them and overrides. Multiple inheritance is not a supported pattern, and we avoid it on purpose — it makes it impossible to reason about which field wins.

## Formats and schemas — the composition point

The macro combines format and schema at compile time. Given:

```haxe
@:schema(JsonFormat)
class User {
  @:field("id")    public var id:Int;
  @:field("name")  public var name:String;
}
```

The macro:

1. Resolves `JsonFormat` via `Context.getType`.
2. Reads its field initializers as compile-time values.
3. Walks `User`'s fields, using `JsonFormat.instance.mappingOpen`, `JsonFormat.instance.keyValueSep`, etc. as literal constants inlined into generated code.
4. Emits a parser specialized for this exact pair: parses JSON, builds `User`, respects JSON's policies (missing, unknown, escape).

Changing the format means changing one annotation and recompiling. `@:schema(Json5Format) class User { ... }` gives a User parser that accepts comments and trailing commas — zero code changes elsewhere.

## Not shipping everything

Phase 1 ships `JsonFormat` as the first and only reference `TextFormat`. Other families are interface-only stubs. Real format implementations for XML, YAML, TOML, MessagePack, CBOR, etc. come later, driven by the phase roadmap and real needs.

The philosophy is to ship interfaces and one validated reference implementation per family, then let grammars drive what other formats get written. We do not pre-build formats that nobody is asking for.
