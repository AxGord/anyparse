# Formats

A **format** describes what a specific file format looks like: its literal syntax, policies, and conversion rules. A format is a plugin — an ordinary Haxe class implementing one of the format interfaces — and users can write their own without touching the core.

This is separate from `strategies.md`. A strategy is *how* we parse (PEG descent, Pratt, indent). A format is *what* we parse (`{` for JSON objects, `(` for S-expressions, `[section]` for INI headers). They combine: a strategy uses a format's literals and policies to generate a parser specialized for a given grammar.

## The distinction is load-bearing

There is no built-in `@:json` metadata in anyparse. There is no hardcoded list of supported formats in the core. When a user writes:

```haxe
@:peg @:schema(JsonFormat) @:ws
typedef User = {
  var id: Int;
  @:key('full-name') var name: String;
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
@:peg @:schema(JsonFormat) @:ws
typedef User = {
  var id: Int;
  @:key('full-name') var name: String;
}
```

The macro:

1. Resolves `JsonFormat` via `Context.getType`.
2. Reads its field initializers as compile-time values.
3. Walks `User`'s fields, using `JsonFormat.instance.mappingOpen`, `JsonFormat.instance.keyValueSep`, etc. as literal constants inlined into generated code.
4. Emits a parser specialized for this exact pair: parses JSON, builds `User`, respects JSON's policies (missing, unknown, escape).

Changing the format means changing one annotation and recompiling. `@:schema(Json5Format)` on the same `User` gives a User parser that accepts comments and trailing commas — zero code changes elsewhere.

A by-name (`FieldLookup.ByName`) field is spelled in the document by its Haxe name unless it declares another with `@:key('<key>')` (`MetaInspect.wireKey`), which the generated parser and writer both honour — how a schema reads a key that is a Haxe keyword (`@:key('function') var member: String`) or no identifier at all (`@:key('full-name')`). The macro refuses a `@:key` that is not exactly one string, a key holding a quote, a backslash or a control character (the writer emits a key as written), and two fields spelled with one key.

A by-name entry whose value is the format's `nullLiteral` reads as the key being absent (`StructSeqLowering.lowerStructByName`): an optional field stays `null`, a required one fails as missing under its key, and a field typed as the format's `anyType` keeps the literal as a value. A config writer that spells an unset key as `null` — haxe-formatter's `--default-config` does — therefore reads like one that omits it.

## Reading and writing a JSON file of your own

The one way, from `src`, `tools/src` and `test` alike, and what the lint rule `avoid-haxe-json` names instead of `haxe.Json`: a schema typedef, a marker class that generates its parser (and one that generates its writer, when the file is written too), and a one-line call.

```haxe
// MyRecord.hx — one type per module; the macro finds a rule by its module path
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef MyRecord = { var name: String; @:optional var size: Int; };

// MyRecordParser.hx
@:build(anyparse.macro.Build.buildParser(my.pkg.MyRecord)) @:nullSafety(Strict)
class MyRecordParser {}

final record: MyRecord = MyRecordParser.parse(File.getContent(path));          // throws on malformed or wrong-shaped input
File.saveContent(path, MyRecordWriter.write(record, JsonFormat.instance.defaultWriteOptions));
```

The writer's marker is `@:build(anyparse.macro.Build.buildWriter(my.pkg.MyRecord, my.pkg.MyRecordWriteOptions))` over `typedef MyRecordWriteOptions = anyparse.format.WriteOptions & {};` and a private constructor. The typedef holds as many knobs as a struct literal can pass to a JVM constructor; past that the build refuses it, naming the count, and the options become a class with `@:build(anyparse.macro.Build.buildOptionsRecord())` whose field initializers are the defaults (`anyparse.macro.OptionsRecord`). What the schema can say: `Int`, `Float`, `Bool`, `String`, a nested schema typedef, `Array<T>`, `Map<String, T>` for a document whose keys are data (read only: the generated writer refuses a schema holding one), and `@:optional` for a key that may be absent (`Null<T>` alone does not make a key optional; a null optional is omitted on writing, unless the field also says `@:writeNull`, which writes it as `null` under its key — a reader takes that `null` for an absent key, so it reads back alike). `@:bare` on a struct of one required field writes the document as that field's value alone, with neither key nor braces: how a document whose root is an array is written, since a schema roots on a struct; its parser is refused, the document holding no key to read it by. Every nested type sits in a module of its own name. A document with no fixed shape is `JValue`: `JValueParser.parse(text)` reads the whole document and `JValueWriter.write(value, JsonFormat.instance.defaultWriteOptions)` writes one, and a field typed `JValue` (`Map<String, JValue>` for a map whose values are arrays or mixed) keeps one part raw while the rest stays typed. Examples: `SweepSnapshot`, `LintReportJson` (typed), `ApqLintConfig` (typed with raw parts), `FmtOwnershipRecord` (a map of raw values).

`JsonFormat.instance.compactWriteOptions` writes a document no one reads by eye on one line, with no whitespace (§ "The native door"). `JsonFormat.instance.expandedWriteOptions` writes a report a person reads and a tool diffs line by line: two spaces of indent, a space after each colon (the writer-only `WriteOptions.keyValueSpace`; the parser's separator is unchanged), and every non-empty container broken at any width (a line width of zero, where no group fits flat) — the bytes `JSON.stringify(value, null, '  ')` prints, which `lint --format json` and `lint-score --format json` hold to (`LintFindingsDocument`, `LintExplainedDocument`, `LintScoreDocument`). `JsonFormat.instance.quote(text)` is one JSON string, quotes and escapes included, in the bytes a native writer gives it (a control character in lower-case hex, a lone surrogate escaped). `JValueTools.field(value, key)` reads a key of a raw document the way a schema reads it: null for anything but an object and for a key holding `null`, and the last of two spellings; `JValueTools.at(value, 'a.0.b')` walks a dotted path of such keys and of decimal array indexes, null where a step finds nothing. A generated writer spells a `Float` as the target prints it (`1`, `0.5`, `1e+21`), as the compact writer and a native printer do, so `JValueWriter` writes a whole number as one a schema's `Int` reads back. The Doc writer escapes one code unit at a time, so unlike `quote` and the compact writer it writes a lone surrogate bare.

## The native door

A format may name a class through which generated code reaches the engine's own reader and writer: `JsonFormat.nativeDoor` names `anyparse.grammar.json.JsonNative`, and `JsonFormat.nativeTargets` the compile defines under which a parser reads through it: `js`, where the door is the engine's native `JSON.parse`, and `cpp` and `jvm`, where it is `haxe.Json`'s own parser — Haxe code, and still far ahead of the byte-level parser there. A target not listed keeps the byte-level parser. `nativeWriteTargets` (`js`) are where the compact writer goes through the door's writer too; elsewhere `haxe.Json`'s printer would spell an absent key as `null`, so it appends to a buffer. `FormatReader` reads both fields at compile time, and the core names no JSON: `anyparse.macro.NativeDocLowering` generates the calls, and a format that names no door generates none of this.

On a door target, a by-name schema's `XParser.parse(text)` parses through the door, then runs a generated shape check over the raw value, and hands that value back as the record. The check refuses a missing or `null` required key, an optional key holding `null` (the byte-level parser alone reads it as absent, so one mechanism says what `null` means), a value of another kind (an `Int` must be a whole 32-bit number, a string enum one of its values), and a nested record its own check refuses. It also sets a `@:key` field under its Haxe name, converts a raw `JValue` part (a part holding an object refuses: only the text keeps its key order), builds a `Map`, and sets an absent optional field to `null`, as the byte-level parser leaves it (the door alone leaves it `undefined` on js). Whatever the door or the check refuses goes to the byte-level parser, which reads it or throws its own error, so `parse` answers what it answered before. `XParser.parseNative(text)` is the door alone and answers null on a refusal. Two things differ from the byte-level reading: a whole number spelled with a fraction or an exponent (`1.0`) reads as an `Int`, and an unknown key stays on the record's object, where no writer reads it. A rule with an optional field visits the keys the object holds, never asking for one it may lack (an absent key is the slow lookup), and marks each optional key it met; a rule with none asks for each of its keys. The check costs a walk of the record on top of the engine's parse, and a measurement quotes the two apart. Where that walk costs more than the site may pay, the site keeps `haxe.Json` under a `noqa` stating why: the node lines of a facts file, which the same run's `TypedFactsMacro` wrote (`FactNodeRecords.parseLine`), and the reach-builds record `ReachBuildsCache` writes, built in the schema's key order (its read stays typed).

`XWriter.write(value, JsonFormat.instance.compactWriteOptions)` — that record, compared by identity — takes the compact writer. Under `nativeWriteTargets` it hands the door's writer a copy that holds the schema's keys in the schema's order; elsewhere it appends to one buffer. The output has no whitespace, a `Float` is spelled as the target prints it (`2`, not `2.0`, which a `Float` field reads back), and an absent optional key is left out. A schema with a raw part has no compact writer and renders the compact options through the Doc writer, its arrays spaced `, `; a schema with a map has no writer at all. `{direct: true}` as `buildWriter`'s third argument takes the buffer path on every target. Any other options, `defaultWriteOptions` included, keep the Doc writer, byte for byte. `@:build(anyparse.macro.Build.buildCompactWriter(T))` generates only the compact writers of the records under `T`, as `compact<Rule>(value)`, for a record whose text is wanted and no document (`FactNodeRecordText`, which identifies a fact across configurations). `JsonText.quote` is the one quoting of a string, a plain class with no import, so the compile-time side (`TypedFactsMacro`, run by `haxe --macro`, which refuses a `@:build` type) quotes through it too.

## Not shipping everything

Shipped: `JsonFormat` (the reference `TextFormat`), `SExprFormat` (the `apq ast` output format), `HaxeFormat` (the Haxe grammar's, with its write options), `ArFormat` (`BinaryFormat`, with the `ar` archive grammar under `anyparse.grammar.ar`), and `MermaidFormat` (the Mermaid flowchart grammar under `anyparse.grammar.mermaid`, a line-oriented DSL whose labels decode through a codec rather than an escape table). The other families are interface-only stubs. Real format implementations for XML, YAML, TOML, MessagePack, CBOR, etc. come later, driven by the phase roadmap and real needs.

The philosophy is to ship interfaces and one validated reference implementation per family, then let grammars drive what other formats get written. We do not pre-build formats that nobody is asking for.
