# Formats journal

> **Journal, not contract.** Every number here is a reading of one tree at one moment; the
> contract lives in [`docs/formats.md`](../formats.md). Each block is the ORIGINAL text of a paragraph
> that the reference condensed or dropped, moved verbatim under the section it was written in
> (`From § …` names that section by its heading at the time), in the original order, so
> `git log -S` and the ledger's citations still resolve (the one edit: a link to a sibling doc
> gains `../`, and a same-file `#anchor` gains `../formats.md`, since this file lives one
> directory down). A `§` pointer inside moved text names a heading of the reference
> (`docs/formats.md`), not of this file. Nothing here is a norm, and nothing here is auto-loaded.

## From § The distinction is load-bearing

…the `JsonFormat` reference is a normal Haxe class lookup. The macro reads `JsonFormat`'s static fields at compile time and uses them as compile-time constants in the generated parser. If the user wants JSON5, they write `Json5Format` (possibly extending `JsonFormat`) and apply it to their schemas. The anyparse core knows nothing about JSON specifically.

## From § Format family interfaces › `Format` — base

```haxe
interface Format {
  var name:String;           // "JSON", "YAML", "MessagePack"
  var version:String;        // "1.0", "7", whatever the format calls itself
  var encoding:Encoding;     // UTF8 | UTF16LE | UTF16BE | ASCII | Binary
}
```

## From § Format family interfaces › `TextFormat` — structured text

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
  // ^ read TWICE at macro time: by the generated `skipWs`, and by the generated
  //   lexical pass (`strategies.md` § Lexical), which masks comments for the
  //   occurrence scans. Declaring them is what makes both true of a grammar.

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

## From § Format family interfaces › `BinaryFormat` — binary with tagged or length-prefixed layout

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

## From § Writing a format

1. **Decide which family it belongs to.** Most config-like formats are `TextFormat`. Binary protocols are `BinaryFormat`. Markup is `TagTreeFormat`. Etc.
2. **Create a class in the appropriate package.** A format that describes a grammar this repository ships lives *beside that grammar*: `anyparse.grammar.{family}.{Name}Format` — `anyparse.grammar.haxe.HaxeFormat`, `anyparse.grammar.json.JsonFormat`, and a `Json5Format` deriving from it. The reason is invariant 4: such a format names its own grammar's terminal types in `intType` / `floatType` / `boolType` / `stringType` / `anyType`, and a grammar-agnostic package may not name one grammar (`unit.query.LexicalRegionsSeamTest.testNoGrammarAgnosticModuleNamesOneGrammar` is the ratchet). `anyparse.format.{family}` keeps the family DESCRIPTORS — the `TextFormat` / `BinaryFormat` interfaces and the policy enums every format reads — plus a format that names no grammar of its own, as `anyparse.format.text.SExprFormat` and `anyparse.format.binary.ArFormat` do.
3. **Implement the interface fields** as `(default, null)` properties with initializers at the declaration site. Concrete values here become the format's literal vocabulary.
4. **Expose a `public static final instance` singleton** constructed via a private constructor — one shared object is enough since format classes hold pure configuration.
5. **Implement `escapeChar` and `unescapeChar`** if the format has string escapes. Binary formats skip both.
6. **Apply the format to a schema**: `@:schema(MyNewFormat) class MyType { ... }`.
7. **Write tests** using an existing format's test structure as a template.

## From § Writing a format › Example: JSON5 extending JSON

```haxe
package anyparse.grammar.json;

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

## From § Format composition — inheritance is fine, mixins are not

Formats can inherit from other formats to override specific fields. `Json5Format extends JsonFormat` is idiomatic.

Formats should not be composed from mixed-in traits at compile time. If a hypothetical `JsonWithComments` wants both JSON5's comments and strict JSON's quote rules, it extends one of them and overrides. Multiple inheritance is not a supported pattern, and we avoid it on purpose — it makes it impossible to reason about which field wins.

## From § Not shipping everything

Phase 1 ships `JsonFormat` as the first and only reference `TextFormat`. Other families are interface-only stubs. Real format implementations for XML, YAML, TOML, MessagePack, CBOR, etc. come later, driven by the phase roadmap and real needs.
