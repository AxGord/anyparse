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

…the `JsonFormat` reference is a normal Haxe class lookup. The macro reads `JsonFormat`'s static fields at compile time and uses them as compile-time constants in the generated parser. If the user wants JSON5, they write `Json5Format` (a clone of `JsonFormat` with the differing fields changed) and apply it to their schemas. The anyparse core knows nothing about JSON specifically.

This ensures that the set of supported formats is open-ended. Adding TOML, HJSON, MessagePack, or a proprietary format is writing one class, not filing a PR against anyparse.

## Format family interfaces

Real formats come in structural families. A single interface covering all families would either be a meaningless common denominator or an unmanageable union. Instead, anyparse ships one interface per family.

### `Format` — base

`anyparse.format.Format`: `name`, `version`, `encoding` (`Encoding`: UTF8 | UTF16LE | UTF16BE | ASCII | Binary), all `(default, null)` properties. Every format inherits from this. Only the minimum that every format has in common lives here.

### `TextFormat` — structured text

For JSON, YAML flow, TOML, INI, S-expressions, and similar mapping/sequence/scalar formats.

The interface is `anyparse.format.text.TextFormat` (`src/anyparse/format/text/TextFormat.hx`) and its member list is the contract; this is the shape of it. Structural literals: `mappingOpen` / `mappingClose`, `sequenceOpen` / `sequenceClose` (nullable — a format with no sequences), `keyValueSep`, `entrySep`. Whitespace and comments: `whitespace`, `lineComment`, `blockComment` (`Null<BlockCommentDelims>`) — read TWICE at macro time, by the generated `skipWs` and by the generated lexical pass (`strategies.md` § Lexical), which masks comments for the occurrence scans; declaring them is what makes both true of a grammar. Strings and keys: `keySyntax` (`KeySyntax`: Quoted | Unquoted | Either), `stringQuote`. Field lookup: `fieldLookup` (`FieldLookup`: ByName | ByPosition | ByTag). Policies: `trailingSep` (`TrailingSepPolicy`), `onMissing` (`MissingPolicy`), `onUnknown` (`UnknownPolicy`). Primitives: `intLiteral`, `floatLiteral` (`EReg`), `boolLiterals` (`Null<BoolLiterals>`), `nullLiteral`. Escape handling as functions, not data: `escapeChar`, `unescapeChar` (returning `UnescapeResult`). The policy enums live beside the interface in `anyparse.format.text`, each with its members' meaning in its own doc.

Fields use `(default, null)` property form — readable from any caller, writable only inside the declaring class — so the concrete format class sets them in its field initializers and treats them as effectively final. `BlockCommentDelims`, `BoolLiterals`, and `UnescapeResult` are named typedefs exported from the same module as the interface.

Format classes expose a `public static final instance` singleton. The writer and macro read configuration from that singleton — no per-parse allocation, one shared object for the whole process. The macro resolves the format class via `Context.getType` at compile time and extracts the field initializers so that literals become compile-time string constants in generated code; the instance is also available at runtime for hand-written writers and parsers that are generic over `TextFormat`.

### `BinaryFormat` — binary with tagged or length-prefixed layout

For MessagePack, CBOR, BSON, protobuf, and similar formats.

`anyparse.format.binary.BinaryFormat`: `endianness` (`Endianness`: Big | Little), the tag space (`tagSize`, `magicBytes` — an optional file signature), and the length encodings (`lengthEncoding`, `countEncoding`: `LengthEncoding`).

Binary formats do not need whitespace, comments, string escapes, or key quoting. They do need tag layouts, which live in grammar metadata rather than in the format class — today the `Bin` strategy's `@:bin` / `@:magic` / `@:align` / `@:length`; the tagged-union tags (`@:tag`, `@:tagMask`, `@:fromTag`) are planned with the first tagged format and exist nowhere yet. The format describes the format-wide conventions; grammar metadata describes per-field layout.

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
2. **Create a class in the appropriate package.** A format that describes a grammar this repository ships lives *beside that grammar*: `anyparse.grammar.{family}.{Name}Format` — `anyparse.grammar.haxe.HaxeFormat`, `anyparse.grammar.json.JsonFormat`, and a `Json5Format` cloned from it. The reason is invariant 4: such a format names its own grammar's terminal types in `intType` / `floatType` / `boolType` / `stringType` / `anyType`, and a grammar-agnostic package may not name one grammar (`unit.query.LexicalRegionsSeamTest.testNoGrammarAgnosticModuleNamesOneGrammar` is the ratchet). `anyparse.format.{family}` keeps the family DESCRIPTORS — the `TextFormat` / `BinaryFormat` interfaces and the policy enums every format reads — plus a format that names no grammar of its own, as `anyparse.format.text.SExprFormat` and `anyparse.format.binary.ArFormat` do.
3. **Implement the interface fields** as `(default, null)` properties with initializers at the declaration site. Concrete values here become the format's literal vocabulary.
4. **Expose a `public static final instance` singleton** constructed via a private constructor — one shared object is enough since format classes hold pure configuration.
5. **Implement `escapeChar` and `unescapeChar`** if the format has string escapes. Binary formats skip both.
6. **Apply the format to a schema**: `@:schema(MyNewFormat) class MyType { ... }`.
7. **Write tests** using an existing format's test structure as a template.

### Example: a second text format

```haxe
package anyparse.grammar.json;

final class Json5Format implements TextFormat {
  public static final instance:Json5Format = new Json5Format();

  // every field JsonFormat spells, spelled again — plus the four that differ:
  public var lineComment(default, null):Null<String> = "//";
  public var blockComment(default, null):Null<BlockCommentDelims> = {open: "/*", close: "*/"};
  public var trailingSep(default, null):TrailingSepPolicy = TrailingSepPolicy.Allowed;
  public var stringQuote(default, null):Array<String> = ['"', "'"];

  private function new() {}
}
```

A handful of differing fields is the entire differential between JSON and JSON5 at the format level — but it is a CLONE, not a subclass: the shipped `JsonFormat` is a `final class`, and a `(default, null)` property cannot be assigned from a subclass anyway (Haxe has no `override var`), so a derived format spells its whole vocabulary. `JsonFormat`'s own doc says clone; the composition rule below is what that reduces to.

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

## Format composition — one class per format

A format is one class that spells its whole vocabulary. There is no inheritance between the shipped formats (`JsonFormat`, `SExprFormat`, `HaxeFormat`, `ArFormat` are each `final`) and no mixin composition: a hypothetical `JsonWithComments` that wants JSON5's comments and strict JSON's quote rules is a third class stating both, which is what makes "which field wins" a question with one answer. The interface's `(default, null)` fields are the mechanism — a value is set where it is declared and nowhere else.

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

Shipped: `JsonFormat` (the reference `TextFormat`), `SExprFormat` (the `apq ast` output format), `HaxeFormat` (the Haxe grammar's, with its write options), and `ArFormat` (`BinaryFormat`, with the `ar` archive grammar under `anyparse.grammar.ar`). The other families are interface-only stubs. Real format implementations for XML, YAML, TOML, MessagePack, CBOR, etc. come later, driven by the phase roadmap and real needs.

The philosophy is to ship interfaces and one validated reference implementation per family, then let grammars drive what other formats get written. We do not pre-build formats that nobody is asking for.
