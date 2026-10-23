package anyparse.grammar.mermaid;

/** A `---` … `---` YAML front-matter block, kept verbatim. */
@:re("---[ \\t]*\\r?\\n[\\s\\S]*?\\r?\\n---(?=[ \\t]*(?:\\r?\\n|$))")
@:rawString
abstract MmdFrontMatterLit(String) from String to String {}
